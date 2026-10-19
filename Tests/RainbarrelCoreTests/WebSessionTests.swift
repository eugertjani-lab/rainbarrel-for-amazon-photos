import Foundation
import Testing
@testable import RainbarrelCore

@Suite("The web catalog and the Amazon session")
struct WebSessionTests {
    private func refreshedListing(count: Int = 5) -> StubServer.Reply {
        .body(
            Data(#"{"count":\#(count),"data":[]}"#.utf8),
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": "session-token=web-refreshed-0001; Domain=.amazon.com; Path=/; Secure",
            ])
    }

    @Test func a403TheSessionCheckClearsIsThrottlingAndKeepsTheCatalog() async throws {
        let fx = try WebFixture()
        let store = try fx.store()
        _ = try await fx.refresher(store).refresh(web: try fx.source())  // first, a working catalog
        fx.overrideChanges { _ in .body(Data(), status: 403) }  // the listing still works
        let error = await thrownError { try await fx.refresher(store).refresh(web: try fx.source()) }
        #expect(error as? DownloadError == .throttled(status: 403, retryAfter: nil))
        #expect(!fx.listingRequests.isEmpty)
        #expect(try store.cloudItemCount() == 5)
    }

    @Test func refreshedCookiesGoBackToTheSessionStoreWhenTheSourceIsDone() async throws {
        let fx = try WebFixture()
        fx.overrideNodes { _ in refreshedListing() }
        let sessions = MemorySessionStore(fx.session)
        let source = try WebAPICatalogSource.make(
            session: fx.session, config: fx.config, environment: fx.environment, sessionStore: sessions)
        defer { source.invalidate() }
        _ = try await fx.refresher(try fx.store()).refresh(web: source)
        source.invalidate()
        let stored = try #require(try sessions.load())
        #expect(stored.cookies.first { $0.name == "session-token" }?.value == "web-refreshed-0001")
        #expect(stored.cookies.first { $0.name == "session-id" }?.value == fx.sessionID)
        #expect(stored.savedAt == fx.session.savedAt && stored.host == fx.session.host)
    }

    @Test func aNewerSignInInTheStoreSurvivesTheRefresh() async throws {
        let fx = try WebFixture()
        fx.overrideNodes { _ in refreshedListing() }
        let newer = StoredSession(
            host: fx.host, cookies: [SessionCookie(name: "session-id", value: "newer-web-sign-in-1", domain: ".amazon.com")],
            savedAt: noonOct16.addingTimeInterval(900))
        let sessions = MemorySessionStore(newer)
        let source = try WebAPICatalogSource.make(
            session: fx.session, config: fx.config, environment: fx.environment, sessionStore: sessions)
        defer { source.invalidate() }
        _ = try await fx.refresher(try fx.store()).refresh(web: source)
        source.invalidate()
        #expect(try sessions.load() == newer)
    }

    @Test func withoutAStoreNothingIsWritten() async throws {
        let fx = try WebFixture()
        fx.overrideNodes { _ in refreshedListing() }
        let source = try WebAPICatalogSource.make(session: fx.session, config: fx.config, environment: fx.environment)
        defer { source.invalidate() }
        let outcome = try await fx.refresher(try fx.store()).refresh(web: source)
        #expect(outcome.result.itemCount == 5)
    }
}
