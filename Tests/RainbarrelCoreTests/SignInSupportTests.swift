import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Sign-in support for the menu-bar app")
struct SignInSupportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cookie(
        _ name: String, _ value: String = "v", domain: String = ".amazon.com", expires: TimeInterval? = nil
    ) -> SessionCookie {
        SessionCookie(
            name: name, value: value, domain: domain,
            expiresAt: expires.map { Date(timeIntervalSince1970: $0) })
    }

    // MARK: Cookies of a sign-in browser

    @Test func onlyCookiesOfTheHostsDomainSurvive() {
        let cookies = [
            cookie("session-id", domain: ".amazon.com"),
            cookie("at-main", domain: "www.amazon.com"),
            cookie("x-main", domain: "amazon.com"),
            cookie("tracker", domain: ".example.org"),
            cookie("lookalike", domain: ".notamazon.com"),
            cookie("session-id", domain: ".amazon.co.uk"),
        ]
        let kept = WebSignIn.sessionCookies(from: cookies, host: "www.amazon.com", now: now)
        #expect(kept.map(\.name) == ["session-id", "at-main", "x-main"])
        let uk = WebSignIn.sessionCookies(from: cookies, host: "www.amazon.co.uk", now: now)
        #expect(uk.map(\.domain) == [".amazon.co.uk"])
    }

    @Test func expiredAndUnusableCookiesAreDropped() {
        let cookies = [
            cookie("fresh", expires: now.timeIntervalSince1970 + 3600),
            cookie("stale", expires: now.timeIntervalSince1970 - 5),
            cookie("session-cookie"),
            cookie("bad;name"),
            cookie("bad-value", "a\nb"),
        ]
        let kept = WebSignIn.sessionCookies(from: cookies, host: "www.amazon.com", now: now)
        #expect(kept.map(\.name) == ["fresh", "session-cookie"])
    }

    @Test func aSignedInBrowserNeedsTheSessionIdAndASignInCookie() {
        #expect(!WebSignIn.looksSignedIn([], now: now))
        // A visitor who has not signed in has a session id only.
        #expect(!WebSignIn.looksSignedIn([cookie("session-id"), cookie("ubid-main")], now: now))
        #expect(!WebSignIn.looksSignedIn([cookie("at-main")], now: now))
        #expect(WebSignIn.looksSignedIn([cookie("session-id"), cookie("at-main")], now: now))
        #expect(WebSignIn.looksSignedIn([cookie("session-id"), cookie("sess-at-acbuk")], now: now))
        #expect(WebSignIn.looksSignedIn([cookie("session-id"), cookie("x-main")], now: now))
        // Empty and expired cookies do not count.
        #expect(!WebSignIn.looksSignedIn([cookie("session-id"), cookie("at-main", "")], now: now))
        #expect(!WebSignIn.looksSignedIn(
            [cookie("session-id"), cookie("at-main", expires: now.timeIntervalSince1970 - 1)], now: now))
    }

    // MARK: The live check

    @Test func verifySessionAcceptsAWorkingSessionAndRejectsOthers() async throws {
        let fx = try WebFixture()
        let client = try AmazonClient(
            session: fx.session, host: fx.host, configuration: fx.environment.sessionConfiguration(),
            timeouts: fx.timeouts)
        defer { client.invalidate() }
        let count = try await client.verifySession()
        #expect(count > 0)
        #expect(fx.listingRequests.count == 1)
        #expect(WebFixture.filter(of: fx.listingRequests[0]) == "kind:FILE AND status:AVAILABLE")

        let wrong = StoredSession(
            host: fx.host, cookies: [SessionCookie(name: "session-id", value: "not-the-id", domain: ".amazon.com")])
        let rejected = try AmazonClient(
            session: wrong, host: fx.host, configuration: fx.environment.sessionConfiguration(), timeouts: fx.timeouts)
        defer { rejected.invalidate() }
        await #expect(throws: DownloadError.sessionExpired) { _ = try await rejected.verifySession() }

        fx.answersWithSignInPage = true
        await #expect(throws: DownloadError.sessionExpired) { _ = try await client.verifySession() }
    }

    // MARK: Words and numbers on the panel

    @Test func speedAndTimeRemainingReadAsShortPhrases() {
        #expect(DisplayFormat.speed(bytesPerSecond: 14_200_000) == "14.2 MB/s")
        #expect(DisplayFormat.speed(bytesPerSecond: 0) == "0 KB/s")
        #expect(DisplayFormat.speed(bytesPerSecond: .nan) == "0 KB/s")
        #expect(DisplayFormat.timeRemaining(bytesLeft: 0, bytesPerSecond: 1_000_000) == nil)
        #expect(DisplayFormat.timeRemaining(bytesLeft: 1_000, bytesPerSecond: 0) == nil)
        #expect(DisplayFormat.timeRemaining(bytesLeft: 30_000_000, bytesPerSecond: 1_000_000) == "less than a minute left")
        #expect(DisplayFormat.timeRemaining(bytesLeft: 2_100_000_000, bytesPerSecond: 1_000_000) == "about 35 min left")
        #expect(DisplayFormat.timeRemaining(bytesLeft: 7_500_000_000, bytesPerSecond: 1_000_000) == "about 2 h 5 min left")
        #expect(DisplayFormat.timeRemaining(bytesLeft: 7_200_000_000, bytesPerSecond: 1_000_000) == "about 2 h left")
        #expect(DisplayFormat.timeRemaining(bytesLeft: 400_000_000_000, bytesPerSecond: 1_000_000) == "about 4 d left")
    }

    @Test func fileNamesForTheWindowLoseControlAndReorderingCharacters() {
        #expect(DisplayFormat.displayFileName("IMG_0001.jpg") == "IMG_0001.jpg")
        #expect(DisplayFormat.displayFileName("a\u{1B}[31mred\u{7}.jpg") == "a[31mred.jpg")
        // Right-to-left override and zero-width characters are removed.
        #expect(DisplayFormat.displayFileName("photo\u{202E}gpj.exe\u{200B}") == "photogpj.exe")
        let long = String(repeating: "x", count: 80) + ".heic"
        let shortened = DisplayFormat.displayFileName(long, maxLength: 40)
        #expect(shortened.count == 40)
        #expect(shortened.contains("…") && shortened.hasSuffix(".heic"))
    }
}
