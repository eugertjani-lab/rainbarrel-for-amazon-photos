import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Amazon session: storage, cookie import, headers and secrecy")
struct SessionTests {
    private let session = StoredSession(
        host: "www.amazon.com",
        cookies: [
            SessionCookie(name: "session-id", value: "123-4567890-1234567", domain: ".amazon.com", expiresAt: Date(timeIntervalSince1970: 4_000_000_000)),
            SessionCookie(name: "session-token", value: "tok-ABCDEFGHIJKLMNOP", domain: ".amazon.com"),
        ],
        savedAt: Date(timeIntervalSince1970: 1_791_000_000))

    // MARK: File store

    @Test func fileStoreRoundTripsWithOwnerOnlyPermissions() throws {
        let directory = try TempDirectory()
        let store = FileSessionStore(url: directory.url.appendingPathComponent("session.json"))
        #expect(try store.load() == nil)
        try store.save(session)
        #expect(try store.load() == session)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Saving again replaces it; delete removes it and is harmless twice.
        var changed = session
        changed.cookies.removeLast()
        try store.save(changed)
        #expect(try store.load()?.cookies.count == 1)
        try store.delete()
        try store.delete()
        #expect(try store.load() == nil)
        // Only the session file is left in the folder: no temporary copies.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func fileStoreRefusesAFileOthersCanRead() throws {
        let directory = try TempDirectory()
        let store = FileSessionStore(url: directory.url.appendingPathComponent("session.json"))
        try store.save(session)
        for mode in [0o644, 0o640, 0o604, 0o660, 0o666] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: store.url.path)
            do {
                _ = try store.load()
                Issue.record("mode \(String(mode, radix: 8)) was accepted")
            } catch let error as SessionStoreError {
                guard case .insecurePermissions(_, let shown) = error else {
                    Issue.record("unexpected error \(error)")
                    continue
                }
                #expect(shown == "0" + String(mode, radix: 8))
                #expect(error.description.contains("chmod 600"))
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: store.url.path)
        #expect(try store.load() == session)
    }

    @Test func fileStoreRefusesLinksAndGarbage() throws {
        let directory = try TempDirectory()
        let target = directory.url.appendingPathComponent("real.json")
        let store = FileSessionStore(url: directory.url.appendingPathComponent("session.json"))
        try FileSessionStore(url: target).save(session)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
        #expect(throws: SessionStoreError.self) { _ = try store.load() }
        try FileManager.default.removeItem(at: store.url)
        try Data("not json".utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        do {
            _ = try store.load()
            Issue.record("garbage was accepted")
        } catch let error as SessionStoreError {
            guard case .corrupt = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test func storedJSONHasTheDocumentedShape() throws {
        let json = try JSONSerialization.jsonObject(with: session.jsonData()) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["host", "cookies", "savedAt"])
        #expect(json?["host"] as? String == "www.amazon.com")
        let cookies = json?["cookies"] as? [[String: Any]]
        #expect(Set(cookies?[0].keys.map { $0 } ?? []) == ["name", "value", "domain", "path", "expiresAt", "secure"])
        #expect(Set(cookies?[1].keys.map { $0 } ?? []) == ["name", "value", "domain", "path", "secure"])  // no expiry for a session cookie
        #expect(json?["savedAt"] as? Double == 1_791_000_000)
        #expect(try StoredSession.decode(session.jsonData()) == session)
    }

    @Test func printingASessionNeverShowsCookieValues() {
        let text = "\(session) \(String(reflecting: session)) \(session.cookies[0]) \(String(describing: session.cookies))"
        #expect(!text.contains("123-4567890-1234567"))
        #expect(!text.contains("tok-ABCDEFGHIJKLMNOP"))
    }

    #if canImport(Security)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RAINBARREL_KEYCHAIN_TEST"] == "1", "writes a throw-away item to the login keychain; run by hand"))
    func keychainStoreRoundTrip() throws {
        let store = KeychainSessionStore(
            service: "io.github.eugertjani-lab.rainbarrel.session.unit-test-\(UUID().uuidString)", account: "unit-test")
        defer { try? store.delete() }
        #expect(try store.load() == nil)
        try store.save(session)
        #expect(try store.load() == session)
        var changed = session
        changed.cookies.removeLast()
        try store.save(changed)  // saving again replaces the item
        #expect(try store.load()?.cookies.count == 1)
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()  // deleting nothing is fine
    }
    #endif

    // MARK: Import

    private let netscape = """
        # Netscape HTTP Cookie File
        # This is a generated file!  Do not edit.

        .amazon.com\tTRUE\t/\tTRUE\t4000000000\tsession-id\t123-4567890-1234567
        #HttpOnly_.amazon.com\tTRUE\t/\tTRUE\t4000000000\tsession-token\ttok-ABCDEFGHIJKLMNOP
        www.amazon.com\tFALSE\t/drive\tTRUE\t0\tx-main\tabc
        .amazon.com\tTRUE\t/\tTRUE\t1000\texpired\tgone
        .example.com\tTRUE\t/\tTRUE\t4000000000\tother-site\tsecret-elsewhere
        .evilamazon.com\tTRUE\t/\tTRUE\t4000000000\tlookalike\tsecret-lookalike
        .amazon.co.uk\tTRUE\t/\tTRUE\t4000000000\tuk-cookie\tsecret-uk
        www.amazon.com\tFALSE\t/\tTRUE\t4000000000\tbad\tline;with;semicolon
        """

    @Test func importKeepsOnlyCookiesOfTheConfiguredHost() throws {
        let cookies = try CookieImporter.parse(Data(netscape.utf8), host: "www.amazon.com", now: Date(timeIntervalSince1970: 1_791_000_000))
        #expect(cookies.map(\.name).sorted() == ["session-id", "session-token", "x-main"])
        let main = cookies.first { $0.name == "x-main" }
        #expect(main?.path == "/drive")
        #expect(main?.expiresAt == nil)  // expiry 0 is a session cookie
        #expect(main?.secure == true)
        let id = cookies.first { $0.name == "session-id" }
        #expect(id?.expiresAt == Date(timeIntervalSince1970: 4_000_000_000))
        #expect(id?.domain == ".amazon.com")
        // Another region has its own host and keeps only its own cookies.
        let uk = try CookieImporter.parse(Data(netscape.utf8), host: "www.amazon.co.uk", now: Date(timeIntervalSince1970: 1_791_000_000))
        #expect(uk.map(\.name) == ["uk-cookie"])
    }

    @Test func importReadsOurJSONAndPlainCookieLists() throws {
        let storedForm = try session.jsonData()
        let fromStored = try CookieImporter.parse(storedForm, host: "www.amazon.com", now: Date(timeIntervalSince1970: 1_791_000_000))
        #expect(fromStored.count == 2)
        let list = Data(#"""
            [{"name":"session-id","value":"abc-123456","domain":".amazon.com","path":"/","secure":true,"expirationDate":4000000000.5},
             {"name":"foreign","value":"zzzzzzzz","domain":".example.com"}]
            """#.utf8)
        let fromList = try CookieImporter.parse(list, host: "www.amazon.com", now: Date(timeIntervalSince1970: 1_791_000_000))
        #expect(fromList.map(\.name) == ["session-id"])
        #expect(fromList[0].expiresAt == Date(timeIntervalSince1970: 4_000_000_000.5))
        #expect(throws: ToolError.self) {
            _ = try CookieImporter.parse(Data(#"{"unrelated": true}"#.utf8), host: "www.amazon.com")
        }
        #expect(try CookieImporter.parse(Data(), host: "www.amazon.com").isEmpty)
    }

    // MARK: Headers

    @Test func cookieHeaderCarriesOnlyMatchingUnexpiredCookies() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let cookies = [
            SessionCookie(name: "a", value: "1", domain: ".amazon.com"),
            SessionCookie(name: "b", value: "2", domain: "www.amazon.com", path: "/drive"),
            SessionCookie(name: "c", value: "3", domain: ".amazon.com", path: "/other"),
            SessionCookie(name: "d", value: "4", domain: ".amazon.com", expiresAt: Date(timeIntervalSince1970: 1_000)),
            SessionCookie(name: "e", value: "5", domain: ".example.com"),
            SessionCookie(name: "f", value: "bad\nvalue", domain: ".amazon.com"),
        ]
        let url = URL(string: "https://www.amazon.com/drive/v1/nodes/X")!
        #expect(CookieMatching.header(for: url, cookies: cookies, now: now) == "b=2; a=1")  // longest path first
        #expect(CookieMatching.header(for: URL(string: "https://smile.amazon.com/")!, cookies: cookies, now: now) == "a=1")
        #expect(CookieMatching.header(for: URL(string: "https://content.amazonaws.com/x")!, cookies: cookies, now: now) == nil)
        #expect(CookieMatching.header(for: URL(string: "http://www.amazon.com/")!, cookies: cookies, now: now) == nil)
        #expect(CookieMatching.header(for: URL(string: "https://notamazon.com/")!, cookies: cookies, now: now) == nil)
    }

    @Test func sessionIdComesFromTheSessionIdCookie() {
        #expect(session.sessionID(at: Date(timeIntervalSince1970: 1_791_000_000)) == "123-4567890-1234567")
        #expect(session.sessionID(at: Date(timeIntervalSince1970: 4_100_000_000)) == nil)  // expired
        #expect(StoredSession(host: "h", cookies: []).sessionID() == nil)
        #expect(!StoredSession(host: "h", cookies: []).isUsable())
    }

    // MARK: Redirect rules

    @Test func redirectsAreAllowedOnlyToAmazonHostsOverHTTPS() {
        let domains = AmazonEndpoints.allowedRedirectDomains(forHost: "www.amazon.com")
        func allowed(_ text: String) -> Bool { AmazonEndpoints.isAllowedRedirect(URL(string: text)!, domains: domains) }
        #expect(allowed("https://www.amazon.com/x"))
        #expect(allowed("https://content-na.drive.amazonaws.com/cdproxy/x?token=1"))
        #expect(allowed("https://d1234.cloudfront.net/x"))
        #expect(allowed("https://amazon.com/x"))
        #expect(!allowed("http://www.amazon.com/x"))
        #expect(!allowed("https://evil.example.org/x"))
        #expect(!allowed("https://amazon.com.evil.org/x"))
        #expect(!allowed("https://notamazon.com/x"))
        #expect(!allowed("https://evilamazonaws.com/x"))
        #expect(!allowed("https://www.amazon.com:8443/x"))
        #expect(!allowed("https://user:pass@www.amazon.com/x"))
        #expect(!allowed("ftp://www.amazon.com/x"))
        // The host's own registrable domain is allowed too (other regions).
        let uk = AmazonEndpoints.allowedRedirectDomains(forHost: "www.amazon.co.uk")
        #expect(AmazonEndpoints.isAllowedRedirect(URL(string: "https://images.amazon.co.uk/x")!, domains: uk))
        #expect(!AmazonEndpoints.isAllowedRedirect(URL(string: "https://amazon.de/x")!, domains: uk))
        #expect(AmazonEndpoints.registrableDomain(of: "www.amazon.co.uk") == "amazon.co.uk")
        #expect(AmazonEndpoints.registrableDomain(of: "www.amazon.com.au") == "amazon.com.au")
        #expect(AmazonEndpoints.registrableDomain(of: "www.amazon.de") == "amazon.de")
    }

    @Test func endpointsMatchTheDocumentedURLsAndRefuseOddInput() throws {
        #expect(try AmazonEndpoints.contentURL(host: "www.amazon.com", nodeId: "aB-_9").absoluteString
            == "https://www.amazon.com/drive/v1/nodes/aB-_9/contentRedirection?querySuffix=%3Fdownload%3Dtrue")
        #expect(try AmazonEndpoints.metadataURL(host: "www.amazon.com", nodeId: "aB-_9").absoluteString
            == "https://www.amazon.com/drive/v1/nodes/aB-_9?resourceVersion=V2&ContentType=JSON")
        for bad in ["", "a/b", "a b", "../x", "a?b", "a#b", "a%2Fb", String(repeating: "a", count: 201)] {
            #expect(throws: DownloadError.self, "\(bad)") { _ = try AmazonEndpoints.contentURL(host: "www.amazon.com", nodeId: bad) }
        }
        for host in ["", "localhost", "a b.com", "evil.com/x", "x.com:80", "-a.com", "a..com", "ünï.com"] {
            #expect(throws: DownloadError.self, "\(host)") { _ = try AmazonEndpoints.contentURL(host: host, nodeId: "X") }
        }
    }

    // MARK: Secrecy

    @Test func redactionRemovesCookieValuesHeadersAndLinkQueries() {
        let redactor = SecretRedactor(session: session)
        let text = "failed with 123-4567890-1234567 and tok-ABCDEFGHIJKLMNOP; Cookie: session-id=zzz; x=y\nx-amzn-sessionid: 123\nfetched https://files.amazonaws.com/a/b?sig=SECRET&exp=1 done"
        let clean = redactor.redact(text)
        #expect(!clean.contains("123-4567890-1234567"))
        #expect(!clean.contains("tok-ABCDEFGHIJKLMNOP"))
        #expect(!clean.contains("session-id=zzz"))
        #expect(!clean.contains("SECRET"))
        #expect(clean.contains("https://files.amazonaws.com/a/b?[redacted]"))
        #expect(clean.contains("done"))
        // Short harmless values are left alone so that ordinary words survive.
        #expect(SecretRedactor(session: StoredSession(host: "h", cookies: [SessionCookie(name: "lc", value: "en", domain: ".amazon.com")])).redact("english") == "english")
    }
}
