import Foundation
import Testing
@testable import RainbarrelCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func signIn(
    id: String = "sid-0001-abcdef", token: String = "token-0001-abcdef", savedAt: Date = noonOct16,
    host: String = "www.amazon.com"
) -> StoredSession {
    StoredSession(
        host: host,
        cookies: [
            SessionCookie(name: "session-id", value: id, domain: ".amazon.com"),
            SessionCookie(name: "session-token", value: token, domain: ".amazon.com"),
            SessionCookie(name: "at-main", value: "at-main-value-0001", domain: ".amazon.com"),
        ],
        savedAt: savedAt)
}

private func answer(
    _ status: Int = 200, from url: String = "https://www.amazon.com/drive/v1/nodes", cookies: [String]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Set-Cookie": cookies.joined(separator: ", ")])!
}

private func value(_ name: String, in session: StoredSession) -> String? {
    session.cookies.first { $0.name == name }?.value
}

@Suite("Cookies that Amazon refreshes during a run")
struct SessionRefreshTests {
    // MARK: Merge rules

    @Test func aRefreshedCookieReplacesTheOneWithTheSameNameDomainAndPath() {
        let start = signIn()
        let jar = SessionJar(session: start, host: "www.amazon.com")
        let changed = jar.accept(answer(cookies: ["session-token=token-0002-ghijkl; Domain=.amazon.com; Path=/; Secure"]))
        #expect(changed)
        let now = jar.current
        #expect(now.cookies.map(\.name) == ["session-id", "session-token", "at-main"])  // replaced in place
        #expect(value("session-token", in: now) == "token-0002-ghijkl")
        #expect(value("session-id", in: now) == "sid-0001-abcdef")
        // The sign-in time and host stay those of the sign-in.
        #expect(now.savedAt == start.savedAt && now.host == start.host)
        #expect(jar.generation == 1)

        // The same name on another path is a different cookie and is added.
        jar.accept(answer(cookies: ["session-token=path-cookie-000003; Domain=.amazon.com; Path=/gp"]))
        #expect(jar.current.cookies.filter { $0.name == "session-token" }.count == 2)
        // A new name is added at the end.
        jar.accept(answer(cookies: ["ubid-main=134-0000000-0000000; Domain=.amazon.com; Path=/; Max-Age=31536000"]))
        let added = jar.current.cookies.last
        #expect(added?.name == "ubid-main" && added?.expiresAt != nil)
    }

    @Test func aCookieWithTheSameValueIsNoChange() {
        let jar = SessionJar(session: signIn(), host: "www.amazon.com")
        let same = answer(cookies: ["session-token=token-0001-abcdef; Domain=.amazon.com; Path=/; Secure"])
        #expect(!jar.accept(same))
        #expect(jar.generation == 0)
    }

    @Test func aDottedAndABareDomainAreTheSameCookie() {
        let jar = SessionJar(session: signIn(), host: "www.amazon.com")
        jar.accept(answer(cookies: ["session-token=token-0002-ghijkl; Domain=amazon.com; Path=/"]))
        #expect(jar.current.cookies.filter { $0.name == "session-token" }.count == 1)
        #expect(value("session-token", in: jar.current) == "token-0002-ghijkl")
    }

    @Test func onlyCookiesOfTheAmazonDomainAreKept() {
        let jar = SessionJar(session: signIn(), host: "www.amazon.com")
        let before = jar.current
        // Another site, and a registrable domain that merely ends the same way.
        jar.accept(answer(cookies: [
            "other-site=other-site-secret-1; Domain=.example.org; Path=/",
            "lookalike=lookalike-value-1; Domain=.notamazon.com; Path=/",
        ]))
        #expect(jar.current == before)
        // A response from the storage host cannot set a cookie for the Amazon domain.
        jar.accept(answer(
            from: "https://bucket.s3.amazonaws.com/files/N1",
            cookies: ["session-token=planted-value-0001; Domain=.amazon.com; Path=/"]))
        #expect(jar.current == before)
        // A host-only cookie of the Amazon host itself, and one of a sub-domain, are kept.
        jar.accept(answer(cookies: ["host-only=host-only-value-1; Path=/"]))
        let kept = jar.current.cookies.first { $0.name == "host-only" }
        #expect(kept?.domain.lowercased().hasSuffix("www.amazon.com") == true)
    }

    @Test func aCookieThatCannotGoInAHeaderIsDropped() throws {
        let unsafe = try #require(HTTPCookie(properties: [
            .name: "bad", .value: "a;b", .domain: ".amazon.com", .path: "/",
        ]))
        let start = signIn().cookies
        let merged = SessionCookieMerge.apply(
            [unsafe], to: start, responseHost: "www.amazon.com", configuredHost: "www.amazon.com", now: noonOct16)
        #expect(merged == start)
    }

    @Test func aCookieThatArrivesExpiredRemovesTheOldOne() {
        let jar = SessionJar(session: signIn(), host: "www.amazon.com")
        // An Expires in the past.
        jar.accept(answer(cookies: [
            "session-token=; Domain=.amazon.com; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
        ]))
        #expect(jar.current.cookies.map(\.name) == ["session-id", "at-main"])
        // Max-Age=0.
        jar.accept(answer(cookies: ["at-main=; Domain=.amazon.com; Path=/; Max-Age=0"]))
        #expect(jar.current.cookies.map(\.name) == ["session-id"])
        // Removing a cookie that is not there changes nothing.
        let generation = jar.generation
        #expect(!jar.accept(answer(cookies: ["never-had=; Domain=.amazon.com; Path=/; Max-Age=0"])))
        #expect(jar.generation == generation)
    }

    @Test func aDeletionOnAnotherPathLeavesTheCookieAlone() {
        let jar = SessionJar(session: signIn(), host: "www.amazon.com")
        jar.accept(answer(cookies: ["session-token=; Domain=.amazon.com; Path=/gp; Max-Age=0"]))
        #expect(value("session-token", in: jar.current) == "token-0001-abcdef")
    }

    @Test func onlyAnswersWithStatus200To399CountAndRedirectsAmongThem() {
        for status in [400, 401, 403, 404, 408, 429, 500, 503] {
            let jar = SessionJar(session: signIn(), host: "www.amazon.com")
            let before = jar.current
            let changed = jar.accept(answer(status, cookies: [
                "session-token=from-error-\(status)-000; Domain=.amazon.com; Path=/",
                "at-main=; Domain=.amazon.com; Path=/; Max-Age=0",
            ]))
            #expect(!changed && jar.current == before && jar.generation == 0, "status \(status)")
        }
        for status in [200, 204, 301, 302, 307] {
            let jar = SessionJar(session: signIn(), host: "www.amazon.com")
            #expect(jar.accept(answer(status, cookies: ["session-token=from-ok-\(status)-0000; Domain=.amazon.com; Path=/"])))
            #expect(value("session-token", in: jar.current) == "from-ok-\(status)-0000", "status \(status)")
        }
    }

    @Test func theFieldNameMayComeInAnyCase() {
        let response = HTTPURLResponse(
            url: URL(string: "https://www.amazon.com/x")!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["set-cookie": "session-token=lower-case-field-1; Domain=.amazon.com; Path=/"])!
        let jar = SessionJar(session: signIn(), host: "www.amazon.com")
        #expect(jar.accept(response))
        #expect(value("session-token", in: jar.current) == "lower-case-field-1")
    }

    @Test func theRedactorHidesNewAndReplacedValues() {
        let jar = SessionJar(session: signIn(), host: "www.amazon.com")
        jar.accept(answer(cookies: ["session-token=token-0002-ghijkl; Domain=.amazon.com; Path=/"]))
        let redacted = jar.redactor.redact("failed with token-0001-abcdef and token-0002-ghijkl")
        #expect(!redacted.contains("token-0001-abcdef") && !redacted.contains("token-0002-ghijkl"))
        #expect(redacted.contains("[redacted]"))
        // A redactor built from the first session alone does not know the new value; adding teaches it.
        let first = SecretRedactor(session: signIn())
        #expect(first.redact("token-0002-ghijkl") == "token-0002-ghijkl")
        #expect(first.adding(jar.current).redact("token-0002-ghijkl token-0001-abcdef") == "[redacted] [redacted]")
    }

    @Test func replacingTheSessionSwitchesEverythingAndCountsAsAChange() {
        let jar = SessionJar(session: signIn(), host: "www.amazon.com")
        let newer = signIn(id: "sid-0002-zyxwvu", token: "token-9999-zyxwvu", savedAt: noonOct16.addingTimeInterval(500))
        jar.replace(with: newer)
        #expect(jar.current == newer)
        #expect(jar.epoch == 1 && jar.generation == 1)
        let credentials = jar.credentials(for: URL(string: "https://www.amazon.com/x")!, now: noonOct16)
        #expect(credentials.sessionID == "sid-0002-zyxwvu")
        #expect(credentials.cookie?.contains("token-9999-zyxwvu") == true)
        #expect(!jar.redactor.redact("sid-0001-abcdef").contains("sid-0001-abcdef"))
    }

    // MARK: Through the client

    @Test func theNextRequestUsesTheRefreshedCookies() async throws {
        let item = TestFile(nodeId: "N1", name: "a.jpg", data: bytes(2000))
        let fx = try DownloadFixture(files: [item])
        let rotatedID = "rotated-session-id-998877"
        fx.accept(sessionID: rotatedID)
        // Every API answer sets a new token; the first one also rotates the session id.
        fx.overrideAPIHeaders { index in
            var cookies = "session-token=rotated-token-\(index)-0001; Domain=.amazon.com; Path=/; Secure"
            if index == 0 { cookies += ", session-id=\(rotatedID); Domain=.amazon.com; Path=/; Secure" }
            return ["Set-Cookie": cookies]
        }
        let client = try AmazonClient(
            session: fx.session, host: fx.host, configuration: fx.environment.sessionConfiguration(),
            timeouts: fx.timeouts)
        defer { client.invalidate() }
        _ = try await client.fetchMetadata(nodeId: "N1")
        _ = try await client.fetchMetadata(nodeId: "N1")

        let sent = fx.server.requests(host: fx.host)
        #expect(sent.count == 2)
        #expect(sent[0].header("Cookie")?.contains(fx.secretToken) == true)
        #expect(sent[0].header("x-amzn-sessionid") == fx.sessionID)
        // The second request carries what the first answer set, and no longer the old token or id.
        let second = try #require(sent[1].header("Cookie"))
        #expect(second.contains("session-token=rotated-token-0-0001"))
        #expect(!second.contains(fx.secretToken) && !second.contains(fx.sessionID))
        #expect(sent[1].header("x-amzn-sessionid") == rotatedID)
        #expect(!second.contains("other-site"))
        // The client's session carries the sign-in time of the original.
        #expect(client.currentSession.savedAt == fx.session.savedAt)
        #expect(client.cookieGeneration == 2)
        // And its redactor hides the old and the new values.
        let text = client.redactor.redact("\(fx.secretToken) rotated-token-1-0001 \(rotatedID)")
        #expect(!text.contains(fx.secretToken) && !text.contains("rotated-token-1-0001") && !text.contains(rotatedID))
    }

    @Test func cookiesOfARedirectAnswerAreKept() async throws {
        let item = TestFile(nodeId: "N1", name: "a.jpg", data: bytes(2000))
        let fx = try DownloadFixture(files: [item])
        // Only the content request answers with a redirect; metadata calls would carry the header too.
        fx.overrideAPIHeaders { _ in ["Set-Cookie": "session-token=from-redirect-0001; Domain=.amazon.com; Path=/; Secure"] }
        let client = try AmazonClient(
            session: fx.session, host: fx.host, configuration: fx.environment.sessionConfiguration(),
            timeouts: fx.timeouts)
        defer { client.invalidate() }
        try await client.downloadContent(nodeId: "N1") { _ in 0 }
        #expect(value("session-token", in: client.currentSession) == "from-redirect-0001")
        // The storage host got neither the cookie nor the session id.
        let storage = fx.server.requests(host: fx.storageHost)
        #expect(storage.count == 1 && storage[0].header("Cookie") == nil && storage[0].header("x-amzn-sessionid") == nil)
    }

    @Test func anErrorAnswerDoesNotChangeTheCookies() async throws {
        let item = TestFile(nodeId: "N1", name: "a.jpg", data: bytes(2000))
        let fx = try DownloadFixture(files: [item])
        fx.overrideContent { _, _ in
            .body(Data(), status: 500, headers: [
                "Set-Cookie": "session-token=from-error-0001; Domain=.amazon.com; Path=/, at-main=; Domain=.amazon.com; Path=/; Max-Age=0",
            ])
        }
        let client = try AmazonClient(
            session: fx.session, host: fx.host, configuration: fx.environment.sessionConfiguration(),
            timeouts: fx.timeouts)
        defer { client.invalidate() }
        await #expect(throws: DownloadError.throttled(status: 500, retryAfter: nil)) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
        #expect(client.currentSession == fx.session)
        #expect(client.cookieGeneration == 0)
    }
}
