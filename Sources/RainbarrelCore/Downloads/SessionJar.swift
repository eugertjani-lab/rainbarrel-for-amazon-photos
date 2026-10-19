import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The cookies of one `AmazonClient` while it runs: the stored session, changed by what Amazon sends
/// back in `Set-Cookie` headers. `savedAt` and `host` stay those of the sign-in.
///
/// The jar is the only place that changes the cookies; requests read them from here, one consistent
/// copy at a time. Printing one shows nothing of the cookie values.
final class SessionJar: @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession
    private var hidden: SecretRedactor
    private var changes = 0
    private var switches = 0
    private let host: String

    /// `host` is the configured Amazon host: only cookies of its registrable domain are kept.
    init(session: StoredSession, host: String) {
        self.session = session
        self.host = host
        hidden = SecretRedactor(session: session)
    }

    /// The session with the cookies as they are now.
    var current: StoredSession { lock.withLock { session } }

    /// Hides every cookie value the jar has held, including the ones that were replaced.
    var redactor: SecretRedactor { lock.withLock { hidden } }

    /// Counts every change of the cookies. Equal numbers mean equal cookies.
    var generation: Int { lock.withLock { changes } }

    /// Counts how often the whole session was replaced by another sign-in.
    var epoch: Int { lock.withLock { switches } }

    /// The `Cookie` header for `url` and the session id, read together so that both come from one session.
    func credentials(for url: URL, now: Date) -> (cookie: String?, sessionID: String?) {
        lock.withLock {
            (CookieMatching.header(for: url, cookies: session.cookies, now: now), session.sessionID(at: now))
        }
    }

    /// Switch to another sign-in.
    func replace(with other: StoredSession) {
        lock.withLock {
            session = other
            hidden = hidden.adding(other)
            changes += 1
            switches += 1
        }
    }

    /// Take over the cookies that `response` sets. Only answers with status 200 to 399 count, redirects
    /// among them: an error page says nothing the session should believe. Returns true when the
    /// cookies changed.
    @discardableResult
    func accept(_ response: HTTPURLResponse) -> Bool {
        guard (200..<400).contains(response.statusCode), let url = response.url,
            let header = Self.setCookieHeader(of: response)
        else { return false }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url)
        guard !parsed.isEmpty else { return false }
        let now = Date()
        let maxAges = SessionCookieMerge.maxAges(inSetCookie: header)
        return lock.withLock {
            let merged = SessionCookieMerge.apply(
                parsed, to: session.cookies, responseHost: url.host ?? "", configuredHost: host, now: now,
                maxAges: maxAges)
            guard merged != session.cookies else { return false }
            session.cookies = merged
            hidden = hidden.adding(session)
            changes += 1
            return true
        }
    }

    /// All `Set-Cookie` fields of the answer as one value, whatever the case of the field name.
    static func setCookieHeader(of response: HTTPURLResponse) -> String? {
        var values: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, name.lowercased() == "set-cookie", let text = value as? String else { continue }
            values.append(text)
        }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

/// The rules for taking cookies from an answer into a session.
enum SessionCookieMerge {
    /// `setCookies` applied to `cookies`:
    /// - only cookies of the registrable domain of `configuredHost` that are safe in a `Cookie` header
    ///   are used, and only when `responseHost` may set them (the cookie's domain covers it);
    /// - a cookie replaces the one with the same name, domain and path, or is added;
    /// - a cookie that arrives already expired (an `Expires` in the past, or `Max-Age=0`) removes the
    ///   one with the same name, domain and path.
    ///
    /// `maxAges` holds the `Max-Age` of each cookie by name, read from the raw header with
    /// `maxAges(inSetCookie:)`. Foundation on Linux ignores that attribute, so it is applied here, and
    /// it wins over `Expires` as RFC 6265 asks.
    static func apply(
        _ setCookies: [HTTPCookie], to cookies: [SessionCookie], responseHost: String, configuredHost: String,
        now: Date, maxAges: [String: Int] = [:]
    ) -> [SessionCookie] {
        let candidates = setCookies.map { cookie in
            let expiresAt = maxAges[cookie.name].map { seconds in
                seconds > 0 ? now.addingTimeInterval(TimeInterval(seconds)) : Date(timeIntervalSince1970: 0)
            } ?? cookie.expiresDate
            return SessionCookie(
                name: cookie.name, value: cookie.value, domain: cookie.domain,
                path: cookie.path.isEmpty ? "/" : cookie.path, expiresAt: expiresAt, secure: cookie.isSecure)
        }
        // The sign-in filter, run as if nothing had expired yet, so that expiry can still remove cookies.
        let allowed = WebSignIn.sessionCookies(from: candidates, host: configuredHost, now: .distantPast)
            .filter { CookieMatching.domainMatches(cookieDomain: $0.domain, host: responseHost) }
        var result = cookies
        for cookie in allowed {
            let index = result.firstIndex { sameCookie($0, cookie) }
            if cookie.isExpired(at: now) {
                if let index { result.remove(at: index) }
            } else if let index {
                result[index] = cookie
            } else {
                result.append(cookie)
            }
        }
        return result
    }

    private static func sameCookie(_ a: SessionCookie, _ b: SessionCookie) -> Bool {
        a.name == b.name && bareDomain(a.domain) == bareDomain(b.domain) && normalizedPath(a.path) == normalizedPath(b.path)
    }

    private static func bareDomain(_ domain: String) -> String {
        let lower = domain.lowercased()
        return lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
    }

    private static func normalizedPath(_ path: String) -> String { path.isEmpty ? "/" : path }

    /// The `Max-Age` of each cookie in a `Set-Cookie` value, by cookie name. Several cookies in one
    /// value are separated by commas, and a comma only starts a new cookie when a `name=` follows it
    /// before the next `;`, which keeps the comma inside an `Expires` date where it belongs.
    static func maxAges(inSetCookie header: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for cookie in splitCookies(header) {
            let fields = cookie.split(separator: ";", omittingEmptySubsequences: false)
            guard let first = fields.first, let equals = first.firstIndex(of: "=") else { continue }
            let name = first[..<equals].trimmingCharacters(in: .whitespaces)
            for attribute in fields.dropFirst() {
                let pieces = attribute.split(separator: "=", maxSplits: 1)
                guard pieces.count == 2,
                    pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "max-age",
                    let seconds = Int(pieces[1].trimmingCharacters(in: .whitespaces))
                else { continue }
                result[name] = seconds
            }
        }
        return result
    }

    private static func splitCookies(_ header: String) -> [Substring] {
        var cookies: [Substring] = []
        var start = header.startIndex
        var index = header.startIndex
        while let comma = header[index...].firstIndex(of: ",") {
            let rest = header[header.index(after: comma)...]
            let field = rest.prefix { $0 != ";" && $0 != "," }
            if field.contains("=") {
                cookies.append(header[start..<comma])
                start = header.index(after: comma)
            }
            index = header.index(after: comma)
        }
        cookies.append(header[start...])
        return cookies
    }
}
