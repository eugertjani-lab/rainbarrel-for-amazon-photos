import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RainbarrelCore

// MARK: Stub network

/// Answers requests for the hosts it is registered for; the real network is never used.
final class StubServer: @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let headers: [String: String]
        var method = "GET"
        var body = Data()

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    enum Reply: Sendable {
        case body(Data, status: Int = 200, headers: [String: String] = [:])
        case redirect(to: String)
        case fail(URLError.Code)
        case failWith(NSError)
        case hang
    }

    private let lock = NSLock()
    private var log: [Request] = []
    private var active = 0
    private var maxActive = 0
    private let hosts: [String]
    /// Real seconds each answer is delayed (to make requests overlap).
    var responseDelay: TimeInterval = 0
    var chunkSize = 16 * 1024
    var handler: @Sendable (Request) -> Reply = { _ in .body(Data(), status: 404) }

    init(hosts: [String]) {
        self.hosts = hosts.map { $0.lowercased() }
        for host in self.hosts { StubRegistry.register(self, host: host) }
    }

    deinit {
        for host in hosts { StubRegistry.unregister(host: host) }
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func requests(host: String) -> [Request] { requests.filter { $0.url.host == host } }

    var maxConcurrentRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxActive
    }

    fileprivate func begin(_ request: Request, countsForConcurrency: Bool) -> Reply {
        lock.lock()
        log.append(request)
        if countsForConcurrency {
            active += 1
            maxActive = max(maxActive, active)
        }
        lock.unlock()
        return handler(request)
    }

    fileprivate func end(countsForConcurrency: Bool) {
        guard countsForConcurrency else { return }
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

enum StubRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    static func register(_ server: StubServer, host: String) {
        lock.lock()
        servers[host] = server
        lock.unlock()
    }

    static func unregister(host: String) {
        lock.lock()
        servers[host] = nil
        lock.unlock()
    }

    static func server(forHost host: String) -> StubServer? {
        lock.lock()
        defer { lock.unlock() }
        return servers[host.lowercased()]
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private var server: StubServer?
    private var counted = false
    private var finished = false
    private let finishLock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return StubRegistry.server(forHost: host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = StubRegistry.server(forHost: url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        self.server = server
        // Only the file bytes count for the concurrency tests, not the API calls.
        counted = url.path.hasPrefix("/files/")
        let reply = server.begin(
            StubServer.Request(
                url: url, headers: request.allHTTPHeaderFields ?? [:], method: request.httpMethod ?? "GET",
                body: Self.bodyData(of: request)),
            countsForConcurrency: counted)
        // URLProtocol is not Sendable on Linux; the closure runs once and `self` outlives it.
        nonisolated(unsafe) let me = self
        let deliver: @Sendable () -> Void = {
            switch reply {
            case .body(let data, let status, let headers):
                var fields = headers
                if fields["Content-Type"] == nil { fields["Content-Type"] = "application/octet-stream" }
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
                me.client?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
                var offset = 0
                while offset < data.count {
                    let end = min(offset + server.chunkSize, data.count)
                    me.client?.urlProtocol(me, didLoad: data.subdata(in: offset..<end))
                    offset = end
                }
                me.client?.urlProtocolDidFinishLoading(me)
            case .redirect(let target):
                let response = HTTPURLResponse(
                    url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
                let next = URLRequest(url: URL(string: target)!)
                #if canImport(FoundationNetworking)
                me.followRedirectByHand(response: response, to: next)
                #else
                me.client?.urlProtocol(me, wasRedirectedTo: next, redirectResponse: response)
                #endif
            case .fail(let code):
                me.client?.urlProtocol(me, didFailWithError: URLError(code))
            case .failWith(let error):
                me.client?.urlProtocol(me, didFailWithError: error)
            case .hang:
                break
            }
            me.markFinished()
        }
        if server.responseDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + server.responseDelay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() { markFinished() }

    #if canImport(FoundationNetworking)
    /// swift-corelibs-foundation traps in `URLProtocolClient.urlProtocol(_:wasRedirectedTo:redirectResponse:)`,
    /// because its own redirect handling lives in the built-in HTTP protocol and a custom protocol
    /// cannot reach it. This asks the task's delegate the question URLSession would ask, then serves the
    /// approved request, or hands back the redirect response itself when the delegate refuses. The
    /// delegate runs on another queue, as it does in URLSession, because it may cancel the task.
    private func followRedirectByHand(response: HTTPURLResponse, to next: URLRequest) {
        nonisolated(unsafe) let me = self
        DispatchQueue.global().async {
            guard let task = me.task, let delegate = task.delegate else {
                me.client?.urlProtocol(me, didFailWithError: URLError(.badServerResponse))
                return
            }
            delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: next) { approved in
                if let approved {
                    let leg = StubURLProtocol(request: approved, cachedResponse: nil, client: me.client)
                    leg.task = task
                    leg.startLoading()
                } else {
                    me.client?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
                    me.client?.urlProtocolDidFinishLoading(me)
                }
            }
        }
    }
    #endif

    /// The request body: URLSession hands uploads to the protocol as a stream.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func markFinished() {
        finishLock.lock()
        let first = !finished
        finished = true
        finishLock.unlock()
        if first { server?.end(countsForConcurrency: counted) }
    }
}

// MARK: Fake clock

/// A clock that only moves when somebody sleeps: waiting costs no real time.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var slept: [TimeInterval] = []

    init(start: Date) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var sleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return slept
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    var clock: DownloadClock {
        DownloadClock(
            now: { [self] in now },
            sleep: { [self] seconds in
                try Task.checkCancellation()
                recordSleep(seconds)
                await Task.yield()
            })
    }

    private func recordSleep(_ seconds: TimeInterval) {
        lock.lock()
        slept.append(seconds)
        current = current.addingTimeInterval(max(seconds, 0))
        lock.unlock()
    }
}

/// UTC Gregorian calendar, so that "local" times in tests do not depend on the machine.
let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2026-10-16 12:00:00 UTC.
let noonOct16 = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!

// MARK: Fake Amazon

private let fakeCounter = Counter()

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// A test file in the fake cloud.
struct TestFile {
    var nodeId: String
    var name: String
    var data: Data
    var folder: String? = "F-PHONE"
    var takenAt: Int64 = t2019
    var kind: CloudItemKind = .file
    var ext: String? = nil
    /// Parent override (a Live Photo video's photo).
    var parent: String? = nil

    var md5: String { MD5Hasher.hexDigest(of: Array(data)) }

    var item: CloudItem {
        CloudItem(
            nodeId: nodeId, kind: kind, name: name, md5: md5, size: Int64(data.count), takenAt: takenAt, ext: ext,
            parentId: parent ?? folder)
    }
}

func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

/// The standard cloud folder tree: root > Pictures > Phone, and root > Docs.
let testFolders = [
    CloudFolder(nodeId: "ROOT", name: "", parentId: nil),
    CloudFolder(nodeId: "F-PICS", name: "Pictures", parentId: "ROOT"),
    CloudFolder(nodeId: "F-PHONE", name: "Phone", parentId: "F-PICS"),
    CloudFolder(nodeId: "F-DOCS", name: "Docs", parentId: "ROOT"),
]

/// Everything for a download test: a data folder, a drive folder, a catalog, a stub server and a clock.
final class DownloadFixture: @unchecked Sendable {
    let home: TempDirectory
    let drive: TempDirectory
    let paths: AppPaths
    let host: String
    let storageHost: String
    let sessionID = "session-id-value-123456"
    let secretToken = "secret-token-value-ABCDEF"
    let server: StubServer
    let clock: FakeClock
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var storageOverride: (@Sendable (String, Int) -> StubServer.Reply?)?
    private var contentOverride: (@Sendable (String, Int) -> StubServer.Reply?)?
    private var storageCalls: [String: Int] = [:]
    private var contentCalls: [String: Int] = [:]
    var config: Config
    var timeouts = AmazonClient.Timeouts(request: 5, stall: 5)
    var freeSpace: @Sendable (String) -> Int64? = { _ in nil }
    var start = noonOct16

    init(files list: [TestFile], folders: [CloudFolder] = testFolders, throttle: ThrottleConfig? = nil) throws {
        let id = fakeCounter.next()
        host = "t\(id).amazon.com"
        storageHost = "s\(id).amazonaws.com"
        home = try TempDirectory()
        drive = try TempDirectory()
        paths = AppPaths(dataDirectory: home.url.appendingPathComponent("data", isDirectory: true))
        try paths.ensureDataDirectory()
        server = StubServer(hosts: [host, storageHost])
        clock = FakeClock(start: noonOct16)
        var settings = throttle ?? ThrottleConfig()
        if throttle == nil { settings.minFreeSpaceGB = 0 }
        config = Config(
            driveRoot: drive.path, scanSubpath: "Amazon Drive", amazonHost: host, throttle: settings)
        for file in list { files[file.nodeId] = file.data }
        try drive.url.appendingPathComponent("Amazon Drive").withDirectory()
        try fill(list.map(\.item), folders: folders)
        server.handler = { [unowned self] request in handle(request) }
    }

    /// Put items and folders into the catalog (replacing what was there).
    func fill(_ items: [CloudItem], folders: [CloudFolder] = testFolders) throws {
        let store = try StateStore(path: paths.stateURL.path)
        try store.replaceCloudCatalog { itemSink, folderSink in
            for folder in folders { try folderSink(folder) }
            for item in items { try itemSink(item) }
            return CatalogReadResult(
                sourceDescription: "test", sourceModifiedAt: noonOct16, itemCount: items.count,
                folderCount: folders.count)
        }
    }

    func serve(_ nodeId: String, _ data: Data) {
        lock.lock()
        files[nodeId] = data
        lock.unlock()
    }

    /// Replace the answer for file bytes: called with the node id and how many times it was asked before (from 0).
    func overrideStorage(_ body: @escaping @Sendable (String, Int) -> StubServer.Reply?) {
        lock.lock()
        storageOverride = body
        lock.unlock()
    }

    /// Replace the answer of `contentRedirection` requests.
    func overrideContent(_ body: @escaping @Sendable (String, Int) -> StubServer.Reply?) {
        lock.lock()
        contentOverride = body
        lock.unlock()
    }

    var session: StoredSession {
        StoredSession(
            host: host,
            cookies: [
                SessionCookie(name: "session-id", value: sessionID, domain: ".amazon.com"),
                SessionCookie(name: "session-token", value: secretToken, domain: ".amazon.com"),
                SessionCookie(name: "other-site", value: "other-site-secret-9999", domain: ".example.org"),
            ],
            savedAt: noonOct16)
    }

    private func handle(_ request: StubServer.Request) -> StubServer.Reply {
        let url = request.url
        if url.host == storageHost {
            let id = String(url.path.dropFirst("/files/".count))
            lock.lock()
            let count = storageCalls[id, default: 0]
            storageCalls[id] = count + 1
            let override = storageOverride
            let data = files[id]
            lock.unlock()
            if let reply = override?(id, count) { return reply }
            guard let data else { return .body(Data(), status: 404) }
            return .body(data)
        }
        guard request.header("x-amzn-sessionid") == sessionID else {
            return .body(Data(#"{"message":"No Auth Method Provided"}"#.utf8), status: 401,
                         headers: ["Content-Type": "application/json"])
        }
        let parts = url.path.split(separator: "/").map(String.init)  // drive v1 nodes <id> [contentRedirection]
        guard parts.count >= 4 else { return .body(Data(), status: 404) }
        let id = parts[3]
        if parts.count == 5, parts[4] == "contentRedirection" {
            lock.lock()
            let count = contentCalls[id, default: 0]
            contentCalls[id] = count + 1
            let override = contentOverride
            lock.unlock()
            if let reply = override?(id, count) { return reply }
            return .redirect(to: "https://\(storageHost)/files/\(id)")
        }
        lock.lock()
        let data = files[id]
        lock.unlock()
        guard let data else { return .body(Data(), status: 404) }
        let json = #"{"name":"x","contentProperties":{"md5":"\#(MD5Hasher.hexDigest(of: Array(data)))","size":\#(data.count)}}"#
        return .body(Data(json.utf8), headers: ["Content-Type": "application/json"])
    }

    var environment: DownloadEnvironment {
        DownloadEnvironment(
            clock: clock.clock, random: { 1.0 }, freeSpace: freeSpace,
            sessionConfiguration: {
                let configuration = AmazonClient.defaultConfiguration()
                configuration.protocolClasses = [StubURLProtocol.self]
                return configuration
            },
            timeouts: timeouts, calendar: utcCalendar)
    }

    var engine: DownloadEngine { DownloadEngine(paths: paths, environment: environment) }

    func store() throws -> StateStore { try StateStore(path: paths.stateURL.path) }

    @discardableResult
    func run(_ options: DownloadOptions = DownloadOptions(), session: StoredSession? = nil) async throws -> DownloadSummary {
        try await engine.run(config: config, session: session ?? self.session, options: options)
    }

    /// Path of a file below the drive root.
    func driveFile(_ relative: String) -> String { drive.path(relative) }

    func contents(_ relative: String) -> Data? { FileManager.default.contents(atPath: drive.path(relative)) }

    /// Relative paths of every file below the drive root.
    func driveFiles() -> [String] {
        var result: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: drive.path)
        while let relative = enumerator?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: drive.path(relative), isDirectory: &isDirectory), !isDirectory.boolValue {
                result.append(relative)
            }
        }
        return result.sorted()
    }

    func jobs() throws -> [DownloadJob] {
        let store = try store()
        return try store.database.rows(
            "SELECT node_id, kind, md5, size, taken_at, target_rel_path, status, attempts, last_error, updated_at FROM download_jobs ORDER BY node_id",
            map: { DownloadJobTable.job(from: $0) })
    }

    func job(_ nodeId: String) throws -> DownloadJob? { try jobs().first { $0.nodeId == nodeId } }
}

extension URL {
    /// Create the folder (and its parents) at this URL.
    func withDirectory() throws {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}

/// Collects progress snapshots from a run.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DownloadProgress] = []

    func add(_ progress: DownloadProgress) {
        lock.lock()
        items.append(progress)
        lock.unlock()
    }

    var snapshots: [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// A session store in memory.
final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?
    var location: String { "memory" }

    init(_ session: StoredSession? = nil) {
        self.session = session
    }

    func load() throws -> StoredSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    func save(_ session: StoredSession) throws {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        session = nil
        lock.unlock()
    }
}
