import Foundation
#if canImport(Glibc)
import Glibc
#endif
#if canImport(Security)
import Security
#endif

/// One browser cookie of the signed-in Amazon session. Printing one shows its name, never its value.
public struct SessionCookie: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    /// Nil for a session cookie. Stored as Unix seconds.
    public var expiresAt: Date?
    public var secure: Bool

    public init(
        name: String, value: String, domain: String, path: String = "/", expiresAt: Date? = nil,
        secure: Bool = true
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.secure = secure
    }

    private enum CodingKeys: String, CodingKey {
        case name, value, domain, path, expiresAt, secure, expirationDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        domain = try container.decode(String.self, forKey: .domain)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? "/"
        secure = try container.decodeIfPresent(Bool.self, forKey: .secure) ?? false
        // `expirationDate` is what browser cookie export extensions call it.
        let seconds = try container.decodeIfPresent(Double.self, forKey: .expiresAt)
            ?? container.decodeIfPresent(Double.self, forKey: .expirationDate)
        expiresAt = seconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
        try container.encode(domain, forKey: .domain)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(expiresAt?.timeIntervalSince1970, forKey: .expiresAt)
        try container.encode(secure, forKey: .secure)
    }

    public var description: String { "SessionCookie(\(name), value hidden)" }
    public var debugDescription: String { description }

    /// True when the cookie has an expiry date that has passed.
    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Name and value can be sent in a Cookie header without breaking it.
    var isHeaderSafe: Bool {
        func safe(_ text: String, allowSemicolon: Bool) -> Bool {
            !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || (!allowSemicolon && $0 == ";") }
        }
        return !name.isEmpty && safe(name, allowSemicolon: false) && !name.contains("=")
            && safe(value, allowSemicolon: false)
    }
}

/// The Amazon session as kept in the Keychain or in `session.json`. Printing one shows the host and
/// the number of cookies, never their values.
public struct StoredSession: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var host: String
    public var cookies: [SessionCookie]
    public var savedAt: Date

    public init(host: String, cookies: [SessionCookie], savedAt: Date = Date()) {
        self.host = host
        self.cookies = cookies
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey { case host, cookies, savedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        cookies = try container.decode([SessionCookie].self, forKey: .cookies)
        savedAt = Date(timeIntervalSince1970: try container.decodeIfPresent(Double.self, forKey: .savedAt) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(cookies, forKey: .cookies)
        try container.encode(savedAt.timeIntervalSince1970, forKey: .savedAt)
    }

    public var description: String { "StoredSession(host: \(host), \(cookies.count) cookies, values hidden)" }
    public var debugDescription: String { description }

    /// The JSON form: `{host, cookies:[{name,value,domain,path,expiresAt?,secure}], savedAt}`, with
    /// every date as Unix seconds.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> StoredSession {
        try JSONDecoder().decode(StoredSession.self, from: data)
    }

    /// Value of the `session-id` cookie, which Amazon expects again in the `x-amzn-sessionid` header.
    public func sessionID(at now: Date = Date()) -> String? {
        cookies.first { $0.name == "session-id" && !$0.value.isEmpty && !$0.isExpired(at: now) }?.value
    }

    /// True when the cookies are too old to work: `session-id` is missing or expired.
    public func isUsable(at now: Date = Date()) -> Bool { sessionID(at: now) != nil }
}

public enum SessionStoreError: Error, CustomStringConvertible, Sendable, Equatable {
    case insecurePermissions(path: String, mode: String)
    case notOwnedByUser(path: String)
    case notARegularFile(path: String)
    case corrupt(String)
    case keychain(status: Int32, message: String)
    case io(String)

    public var description: String {
        switch self {
        case .insecurePermissions(let path, let mode):
            return "Refusing to read \(path): its permissions (\(mode)) let other users read it. Run `chmod 600` on it, or sign in again."
        case .notOwnedByUser(let path):
            return "Refusing to read \(path): it belongs to another user."
        case .notARegularFile(let path):
            return "Refusing to read \(path): it is not a regular file."
        case .corrupt(let detail):
            return "The stored Amazon session is unreadable (\(detail)). Import your cookies again."
        case .keychain(let status, let message):
            return "Keychain error \(status): \(message)"
        case .io(let detail):
            return "Cannot access the stored session: \(detail)"
        }
    }
}

/// Where the Amazon session is kept. The menu-bar app writes the same Keychain item.
public protocol SessionStore: Sendable {
    /// Short description for messages, for example "macOS Keychain".
    var location: String { get }
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func delete() throws
}

/// The session in a file with permissions 0600. A file that other users can read is not trusted.
public struct FileSessionStore: SessionStore {
    public let url: URL
    public var location: String { url.path }

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> StoredSession? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw SessionStoreError.io(String(cString: strerror(errno)))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw SessionStoreError.notARegularFile(path: url.path) }
        guard info.st_uid == geteuid() else { throw SessionStoreError.notOwnedByUser(path: url.path) }
        let permissions = info.st_mode & 0o777
        guard permissions & 0o077 == 0 else {
            throw SessionStoreError.insecurePermissions(
                path: url.path, mode: "0" + String(permissions, radix: 8))
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw SessionStoreError.io(error.localizedDescription)
        }
        do { return try StoredSession.decode(data) } catch {
            throw SessionStoreError.corrupt("not valid session JSON")
        }
    }

    /// Writes a new file with mode 0600 next to the target and renames it into place, so the
    /// content is never visible with wider permissions.
    public func save(_ session: StoredSession) throws {
        let data = try session.jsonData()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".session-\(UUID().uuidString).tmp").path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw SessionStoreError.io(String(cString: strerror(errno))) }
        var failure: String?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = String(cString: strerror(errno))
                    return
                }
                offset += written
            }
        }
        if failure == nil, fsync(descriptor) != 0 { failure = String(cString: strerror(errno)) }
        close(descriptor)
        if failure == nil, rename(temporary, url.path) != 0 { failure = String(cString: strerror(errno)) }
        if let failure {
            unlink(temporary)
            throw SessionStoreError.io(failure)
        }
    }

    public func delete() throws {
        if unlink(url.path) != 0, errno != ENOENT {
            throw SessionStoreError.io(String(cString: strerror(errno)))
        }
    }
}

#if canImport(Security)
/// The session as a generic password item in the login keychain.
public struct KeychainSessionStore: SessionStore {
    public static let service = "io.github.eugertjani-lab.rainbarrel.session"
    public static let account = "amazon"

    public let service: String
    public let account: String
    public var location: String { "macOS Keychain" }

    public init(service: String = KeychainSessionStore.service, account: String = KeychainSessionStore.account) {
        self.service = service
        self.account = account
    }

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func failure(_ status: OSStatus) -> SessionStoreError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return .keychain(status: Int32(status), message: message)
    }

    public func load() throws -> StoredSession? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = result as? Data else { throw SessionStoreError.corrupt("empty keychain item") }
        do { return try StoredSession.decode(data) } catch {
            throw SessionStoreError.corrupt("not valid session JSON")
        }
    }

    public func save(_ session: StoredSession) throws {
        let data = try session.jsonData()
        var attributes = identity
        attributes[kSecValueData as String] = data
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
}
#endif

public enum SessionStoreFactory {
    /// The store to use: the Keychain on macOS and `session.json` in the data folder elsewhere.
    /// `RAINBARREL_SESSION_STORE=file` picks the file on macOS too (`keychain` picks the Keychain).
    public static func make(
        paths: AppPaths, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any SessionStore {
        let choice = environment["RAINBARREL_SESSION_STORE"]?.lowercased()
        #if canImport(Security)
        if choice != "file" { return KeychainSessionStore() }
        #endif
        return FileSessionStore(url: paths.sessionURL)
    }
}

/// Reads browser cookie exports and keeps the cookies that belong to the configured Amazon host.
public enum CookieImporter {
    /// Parse a Netscape `cookies.txt` or the JSON form (a stored session, or a plain list of cookies)
    /// and keep only the cookies whose domain covers `host`. Cookies that have expired are dropped.
    public static func parse(_ data: Data, host: String, now: Date = Date()) throws -> [SessionCookie] {
        let all: [SessionCookie]
        let first = data.first { !" \t\r\n".utf8.contains($0) }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            all = try parseJSON(data)
        } else {
            all = parseNetscape(String(decoding: data, as: UTF8.self))
        }
        return all.filter {
            CookieMatching.domainMatches(cookieDomain: $0.domain, host: host) && !$0.isExpired(at: now)
                && $0.isHeaderSafe
        }
    }

    static func parseJSON(_ data: Data) throws -> [SessionCookie] {
        let decoder = JSONDecoder()
        if let session = try? decoder.decode(StoredSession.self, from: data) { return session.cookies }
        if let list = try? decoder.decode([SessionCookie].self, from: data) { return list }
        throw ToolError("The file is JSON but not a cookie list. Use a Netscape cookies.txt or the JSON that Rainbarrel stores.")
    }

    /// Netscape format: seven tab-separated fields per line (domain, include subdomains, path,
    /// secure, expiry in Unix seconds, name, value). `#HttpOnly_` marks a cookie, other `#` lines are comments.
    static func parseNetscape(_ text: String) -> [SessionCookie] {
        var cookies: [SessionCookie] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = String(rawLine)
            if line.hasPrefix("#HttpOnly_") {
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { continue }
            let expires = Double(fields[4]) ?? 0
            cookies.append(SessionCookie(
                name: fields[5], value: fields.count > 6 ? fields[6] : "", domain: fields[0],
                path: fields[2].isEmpty ? "/" : fields[2],
                expiresAt: expires > 0 ? Date(timeIntervalSince1970: expires) : nil,
                secure: fields[3].uppercased() == "TRUE"))
        }
        return cookies
    }
}

/// Which cookies go to which URL.
public enum CookieMatching {
    public static func domainMatches(cookieDomain: String, host: String) -> Bool {
        var domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        let host = host.lowercased()
        guard !domain.isEmpty, domain.contains(".") else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    /// The value of a `Cookie` header for `url`, or nil when no cookie applies. Only https URLs get cookies.
    public static func header(for url: URL, cookies: [SessionCookie], now: Date = Date()) -> String? {
        guard url.scheme == "https", let host = url.host else { return nil }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let matching = cookies.filter { cookie in
            guard domainMatches(cookieDomain: cookie.domain, host: host), !cookie.isExpired(at: now),
                cookie.isHeaderSafe
            else { return false }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            if cookiePath == "/" || requestPath == cookiePath { return true }
            let prefix = cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/"
            return requestPath.hasPrefix(prefix)
        }
        guard !matching.isEmpty else { return nil }
        let ordered = matching.sorted { ($0.path.count, $1.name) > ($1.path.count, $0.name) }
        return ordered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// Removes secrets from text that is shown to a person or stored: cookie values of the session,
/// credential-looking header lines, and the query part of links (signed links carry tokens there).
public struct SecretRedactor: Sendable {
    private let secrets: [String]

    public init(session: StoredSession?) {
        self.init(secrets: Self.secretValues(in: session))
    }

    private init(secrets: [String]) {
        self.secrets = Array(Set(secrets)).sorted { $0.count > $1.count }
    }

    public static let none = SecretRedactor(session: nil)

    /// A redactor that hides the cookie values of `session` as well as the ones this one hides. The
    /// old values stay hidden, because an error text may still carry a value that was replaced since.
    public func adding(_ session: StoredSession) -> SecretRedactor {
        SecretRedactor(secrets: secrets + Self.secretValues(in: session))
    }

    private static func secretValues(in session: StoredSession?) -> [String] {
        var values: [String] = []
        for cookie in session?.cookies ?? [] where cookie.value.count >= 6 || cookie.name == "session-id" {
            if !cookie.value.isEmpty { values.append(cookie.value) }
        }
        return values
    }

    public func redact(_ text: String) -> String {
        var result = text
        for secret in secrets { result = result.replacingOccurrences(of: secret, with: "[redacted]") }
        result = Self.replace(
            #"(?i)\b(cookie|set-cookie|x-amzn-sessionid|authorization)(["']?\s*[:=]\s*)[^\r\n]*"#,
            in: result, with: "$1$2[redacted]")
        result = Self.replace(#"(https?://[^\s?"'<>]+)\?[^\s"'<>]*"#, in: result, with: "$1?[redacted]")
        return result
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
