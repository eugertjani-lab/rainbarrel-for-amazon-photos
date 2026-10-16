import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What `GET /drive/v1/nodes/{id}` says about a node.
public struct NodeMetadata: Sendable, Equatable {
    public var name: String?
    public var md5: String?
    public var size: Int64?
}

/// URLs and host rules for the Amazon Drive web API.
public enum AmazonEndpoints {
    /// Host names only: letters, digits, hyphens and dots, at least two labels.
    public static func isValidHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.utf8.count <= 253 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy {
                    ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || $0 == "-"
                }
        }
    }

    /// Node ids are short URL-safe tokens; anything else is refused before it reaches a URL.
    public static func isValidNodeId(_ id: String) -> Bool {
        (1...200).contains(id.utf8.count) && id.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" || $0 == "_" || $0 == "." || $0 == "~"
        }
    }

    public static func metadataURL(host: String, nodeId: String) throws -> URL {
        try url(host: host, nodeId: nodeId, suffix: "", query: "resourceVersion=V2&ContentType=JSON")
    }

    /// The original file: redirects to the storage location.
    public static func contentURL(host: String, nodeId: String) throws -> URL {
        try url(host: host, nodeId: nodeId, suffix: "/contentRedirection", query: "querySuffix=%3Fdownload%3Dtrue")
    }

    private static func url(host: String, nodeId: String, suffix: String, query: String) throws -> URL {
        guard isValidHost(host) else { throw DownloadError.invalidHost(host) }
        guard isValidNodeId(nodeId) else { throw DownloadError.invalidNodeId(nodeId) }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = "/drive/v1/nodes/\(nodeId)\(suffix)"
        components.percentEncodedQuery = query
        guard let url = components.url else { throw DownloadError.invalidHost(host) }
        return url
    }

    /// The last two labels of a host name, or the last three under a country-code second level
    /// such as `co.uk` or `com.au`: `www.amazon.co.uk` gives `amazon.co.uk`.
    public static func registrableDomain(of host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevels: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu"]
        let take = (labels[labels.count - 1].count == 2 && secondLevels.contains(labels[labels.count - 2])) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// Domains that downloads may be redirected to, besides the registrable domain of `host`.
    public static func allowedRedirectDomains(forHost host: String) -> [String] {
        var domains = ["amazon.com", "amazonaws.com", "cloudfront.net"]
        let own = registrableDomain(of: host)
        if !own.isEmpty, !domains.contains(own) { domains.append(own) }
        return domains
    }

    /// A redirect target is allowed when it is https, on the default port, has no user name, and
    /// its host is one of `domains` or a sub-domain of one.
    public static func isAllowedRedirect(_ url: URL, domains: [String]) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
            url.port == nil || url.port == 443, let host = url.host?.lowercased()
        else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Talks to the Amazon Drive web API with the stored session cookies.
///
/// Cookies are sent in a `Cookie` header that is built here (the shared cookie storage is not used),
/// only over https, and only to hosts that the cookies belong to. Redirects are followed only to
/// Amazon, AWS and CloudFront hosts over https; any other target is refused.
public final class AmazonClient: @unchecked Sendable {
    public struct Timeouts: Sendable, Equatable {
        /// Longest wait for the answer to a request (and for the first byte of a file).
        public var request: TimeInterval
        /// Longest time without new bytes while a file is coming in.
        public var stall: TimeInterval

        public init(request: TimeInterval = 60, stall: TimeInterval = 120) {
            self.request = request
            self.stall = stall
        }

        public static let `default` = Timeouts()
    }

    public static let userAgent = "Rainbarrel/\(RainbarrelInfo.version)"

    public let host: String
    private let session: StoredSession
    let timeouts: Timeouts
    private let redactor: SecretRedactor
    private let allowedDomains: [String]
    private let ownDomain: String
    let streaming: StreamingSession

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForResource = 24 * 3600
        return configuration
    }

    public init(
        session: StoredSession, host: String, configuration: URLSessionConfiguration = defaultConfiguration(),
        timeouts: Timeouts = .default
    ) throws {
        let host = host.lowercased()
        guard AmazonEndpoints.isValidHost(host) else { throw DownloadError.invalidHost(host) }
        guard session.sessionID() != nil else {
            throw DownloadError.sessionInvalid("there is no unexpired session-id cookie")
        }
        self.host = host
        self.session = session
        self.timeouts = timeouts
        redactor = SecretRedactor(session: session)
        allowedDomains = AmazonEndpoints.allowedRedirectDomains(forHost: host)
        ownDomain = AmazonEndpoints.registrableDomain(of: host)
        // Cookies are set by hand; nothing may add or store any.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        streaming = StreamingSession(configuration: configuration)
    }

    deinit { streaming.invalidate() }

    /// Cancel everything that is still running and release the connection pool.
    public func invalidate() { streaming.invalidate() }

    // MARK: Requests

    /// Check the session on a known node. A valid session answers 200 with the node's metadata; a
    /// missing or expired one answers 401.
    public func fetchMetadata(nodeId: String) async throws -> NodeMetadata {
        let url = try AmazonEndpoints.metadataURL(host: host, nodeId: nodeId)
        let response = try await streaming.perform(
            try request(for: url), timeouts: timeouts, collectLimit: 1_000_000, onData: nil,
            redirect: { [self] in redirectRequest(to: $0) })
        try check(response)
        struct Payload: Decodable {
            struct Properties: Decodable { var md5: String?; var size: Int64? }
            var name: String?
            var contentProperties: Properties?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body) else {
            throw DownloadError.invalidResponse("the node description is not JSON")
        }
        return NodeMetadata(
            name: payload.name, md5: payload.contentProperties?.md5?.lowercased(),
            size: payload.contentProperties?.size)
    }

    /// Stream the original file of `nodeId` to `onData`. `onData` runs for every chunk, in order and
    /// one at a time; it returns how long the transfer should pause afterwards (0 for none) and may
    /// throw to abort the transfer, in which case that error is thrown from here.
    public func downloadContent(
        nodeId: String, expectsHTML: Bool = false,
        onData: @escaping @Sendable (Data) throws -> TimeInterval
    ) async throws {
        let url = try AmazonEndpoints.contentURL(host: host, nodeId: nodeId)
        let response = try await streaming.perform(
            try request(for: url), timeouts: timeouts, collectLimit: 0, onData: onData,
            redirect: { [self] in redirectRequest(to: $0) })
        try check(response)
        // A sign-in page that comes back with status 200 would otherwise be taken for the file.
        if !expectsHTML, response.contentType?.lowercased().hasPrefix("text/html") == true {
            throw DownloadError.sessionExpired
        }
    }

    // MARK: Building requests

    /// The request for `url` with the session's credentials. A `body` makes it a JSON POST. `timeouts`
    /// default to the client's and set how long URLSession itself waits.
    func request(for url: URL, body: Data? = nil, timeouts: Timeouts? = nil) throws -> URLRequest {
        guard url.scheme == "https" else { throw DownloadError.insecureURL }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        let waits = timeouts ?? self.timeouts
        request.timeoutInterval = max(waits.request, waits.stall) + 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        applyCredentials(to: &request, url: url)
        return request
    }

    /// Cookies go to hosts they belong to; the session id header only to Amazon's own domain.
    private func applyCredentials(to request: inout URLRequest, url: URL) {
        let now = Date()
        if let cookie = CookieMatching.header(for: url, cookies: session.cookies, now: now) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let host = url.host?.lowercased(), host == ownDomain || host.hasSuffix("." + ownDomain),
            let id = session.sessionID(at: now)
        {
            request.setValue(id, forHTTPHeaderField: "x-amzn-sessionid")
        }
    }

    /// The request for a redirect target, or nil to refuse it. Built from scratch so that the headers
    /// of the first request never travel to another host.
    func redirectRequest(to url: URL) -> URLRequest? {
        guard AmazonEndpoints.isAllowedRedirect(url, domains: allowedDomains) else { return nil }
        return try? request(for: url)
    }

    // MARK: Answers

    func check(_ response: StreamingSession.Response) throws {
        switch response.status {
        case 200:
            return
        case 401, 403:
            throw DownloadError.sessionExpired
        case 408:
            throw DownloadError.network("the request timed out")
        case 429, 500...599:
            throw DownloadError.throttled(status: response.status, retryAfter: Self.parseRetryAfter(response.retryAfter))
        default:
            throw DownloadError.httpStatus(response.status)
        }
    }

    /// `Retry-After` is a number of seconds or an HTTP date.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds >= 0, seconds.isFinite { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(date.timeIntervalSince(now), 0)
    }
}

/// One URLSession whose delegate hands every task's events to the matching call. Streaming through
/// a delegate works the same on macOS and Linux.
final class StreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var retryAfter: String?
        var contentType: String?
        var body: Data
    }

    private final class Call: @unchecked Sendable {
        let onData: (@Sendable (Data) throws -> TimeInterval)?
        let collectLimit: Int
        let redirect: @Sendable (URL) -> URLRequest?
        let timeouts: AmazonClient.Timeouts
        var continuation: CheckedContinuation<Response, Error>?
        var response: HTTPURLResponse?
        var collected = Data()
        var failure: Error?
        var watchdog: DispatchSourceTimer?
        private let lock = NSLock()
        private var lastActivity = Date()
        private var receivedBody = false

        init(
            onData: (@Sendable (Data) throws -> TimeInterval)?, collectLimit: Int,
            redirect: @escaping @Sendable (URL) -> URLRequest?, timeouts: AmazonClient.Timeouts
        ) {
            self.onData = onData
            self.collectLimit = collectLimit
            self.redirect = redirect
            self.timeouts = timeouts
        }

        func touch(body: Bool = false) {
            lock.lock()
            lastActivity = Date()
            if body { receivedBody = true }
            lock.unlock()
        }

        /// Seconds without activity, and the limit that applies right now.
        func idle() -> (seconds: TimeInterval, limit: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            return (Date().timeIntervalSince(lastActivity), receivedBody ? timeouts.stall : timeouts.request)
        }
    }

    private let lock = NSLock()
    private var calls: [Int: Call] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "rainbarrel.download.delegate"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func perform(
        _ request: URLRequest, timeouts: AmazonClient.Timeouts, collectLimit: Int,
        onData: (@Sendable (Data) throws -> TimeInterval)?,
        redirect: @escaping @Sendable (URL) -> URLRequest?
    ) async throws -> Response {
        let call = Call(onData: onData, collectLimit: collectLimit, redirect: redirect, timeouts: timeouts)
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                call.continuation = continuation
                lock.lock()
                calls[task.taskIdentifier] = call
                lock.unlock()
                startWatchdog(for: task, call: call)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func startWatchdog(for task: URLSessionTask, call: Call) {
        let interval = max(min(call.timeouts.request, call.timeouts.stall) / 4, 0.05)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler {
            let (idle, limit) = call.idle()
            if idle > limit {
                if call.failure == nil { call.failure = DownloadError.network("no data for \(Int(limit)) seconds") }
                task.cancel()
            }
        }
        call.watchdog = timer
        timer.resume()
    }

    private func call(for task: URLSessionTask) -> Call? {
        lock.lock()
        defer { lock.unlock() }
        return calls[task.taskIdentifier]
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let call = call(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        call.response = response as? HTTPURLResponse
        call.touch()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let call = call(for: dataTask) else { return }
        call.touch(body: true)
        guard let status = call.response?.statusCode, status == 200 else { return }
        if let onData = call.onData {
            do {
                let pause = try onData(data)
                if pause > 0 {
                    dataTask.suspend()
                    DispatchQueue.global().asyncAfter(deadline: .now() + pause) { dataTask.resume() }
                }
            } catch {
                if call.failure == nil { call.failure = error }
                dataTask.cancel()
            }
        } else if call.collected.count + data.count <= call.collectLimit {
            call.collected.append(data)
        } else {
            if call.failure == nil { call.failure = DownloadError.invalidResponse("the answer is unexpectedly large") }
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let call = call(for: task), let url = request.url else {
            completionHandler(nil)
            return
        }
        call.touch()
        if let safe = call.redirect(url) {
            completionHandler(safe)
        } else {
            // Do not wait for the redirect answer to arrive: end the transfer with a clear error.
            let host = url.scheme == "https" ? (url.host ?? "unknown host") : "a non-https address"
            if call.failure == nil { call.failure = DownloadError.redirectRefused(host: host) }
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let call = calls.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let call, let continuation = call.continuation else { return }
        call.watchdog?.cancel()
        call.continuation = nil
        if let failure = call.failure {
            continuation.resume(throwing: failure)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: DownloadError.network(Self.describe(error)))
            }
        } else if let response = call.response {
            continuation.resume(returning: Response(
                status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                contentType: response.value(forHTTPHeaderField: "Content-Type"), body: call.collected))
        } else {
            continuation.resume(throwing: DownloadError.invalidResponse("no response"))
        }
    }

    /// A short, link-free description of a transport error.
    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "the connection timed out"
            case .notConnectedToInternet: return "no internet connection"
            case .networkConnectionLost: return "the connection was lost"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "cannot reach the server"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "the secure connection failed"
            default: return "URL error \(urlError.code.rawValue)"
            }
        }
        return "transport error"
    }
}
