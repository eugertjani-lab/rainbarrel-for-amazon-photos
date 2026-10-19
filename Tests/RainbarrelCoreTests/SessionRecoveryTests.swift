import Foundation
import Testing
@testable import RainbarrelCore

private func item(_ id: String, _ name: String, size: Int = 2000, seed: UInt8 = 1, takenAt: Int64 = t2019) -> TestFile {
    TestFile(nodeId: id, name: name, data: bytes(size, seed: seed), takenAt: takenAt)
}

/// A session store in memory that counts the writes and can be told to fail them.
private final class CountingStore: SessionStore, @unchecked Sendable {
    private let inner: MemorySessionStore
    private let lock = NSLock()
    private var saved = 0
    private var failing = false
    var location: String { "counting memory" }

    init(_ session: StoredSession?) {
        inner = MemorySessionStore(session)
    }

    var saves: Int { lock.withLock { saved } }

    var failsSaves: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func load() throws -> StoredSession? { try inner.load() }

    func save(_ session: StoredSession) throws {
        if lock.withLock({ failing }) { throw SessionStoreError.io("disk full") }
        try inner.save(session)
        lock.withLock { saved += 1 }
    }

    func delete() throws { try inner.delete() }
}

private func newerSignIn(of fx: DownloadFixture, id: String = "newer-sign-in-id-555", after seconds: TimeInterval = 600) -> StoredSession {
    StoredSession(
        host: fx.host,
        cookies: [
            SessionCookie(name: "session-id", value: id, domain: ".amazon.com"),
            SessionCookie(name: "session-token", value: "newer-sign-in-token-555", domain: ".amazon.com"),
        ],
        savedAt: noonOct16.addingTimeInterval(seconds))
}

/// A token that differs on every API answer, so that each answer changes the cookies.
private let rotatingToken: @Sendable (Int) -> [String: String] = { index in
    ["Set-Cookie": "session-token=rotating-token-\(String(format: "%04d", index)); Domain=.amazon.com; Path=/; Secure"]
}

private func makeClient(_ fx: DownloadFixture, session: StoredSession? = nil) throws -> AmazonClient {
    try AmazonClient(
        session: session ?? fx.session, host: fx.host, configuration: fx.environment.sessionConfiguration(),
        timeouts: fx.timeouts)
}

// MARK: A 403 and the session check

@Suite("A 403 is checked before the session counts as expired")
struct ForbiddenAnswerTests {
    private func fixture() throws -> DownloadFixture {
        let fx = try DownloadFixture(files: [item("N1", "a.jpg")])
        fx.overrideContent { _, _ in .body(Data(), status: 403) }
        return fx
    }

    @Test func aWorkingSessionMakesA403ThrottlingNotExpiry() async throws {
        let fx = try fixture()
        let client = try makeClient(fx)
        defer { client.invalidate() }
        await #expect(throws: DownloadError.throttled(status: 403, retryAfter: nil)) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
        #expect(fx.listingRequests.count == 1)
    }

    @Test func aRefusedCheckMakesItExpiry() async throws {
        let fx = try fixture()
        fx.overrideListing { _ in .body(Data(), status: 403) }
        let client = try makeClient(fx)
        defer { client.invalidate() }
        await #expect(throws: DownloadError.sessionExpired) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
        #expect(fx.listingRequests.count == 1)  // the check does not check itself
    }

    @Test func aSignInPageAsAnswerToTheCheckMakesItExpiry() async throws {
        let fx = try fixture()
        fx.overrideListing { _ in .body(Data("<html>Sign in</html>".utf8), headers: ["Content-Type": "text/html"]) }
        let client = try makeClient(fx)
        defer { client.invalidate() }
        await #expect(throws: DownloadError.sessionExpired) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
    }

    @Test func a401IsExpiryWhenTheSessionCheckIsRefusedToo() async throws {
        let fx = try DownloadFixture(files: [item("N1", "a.jpg")])
        fx.overrideContent { _, _ in .body(Data(), status: 401) }
        fx.overrideListing { _ in .body(Data(), status: 401) }
        let client = try makeClient(fx)
        defer { client.invalidate() }
        await #expect(throws: DownloadError.sessionExpired) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
        #expect(fx.listingRequests.count == 1)
    }

    @Test func a401IsOnlyThatFilesRefusalWhenTheSessionCheckPasses() async throws {
        let fx = try DownloadFixture(files: [item("N1", "a.jpg")])
        fx.overrideContent { _, _ in .body(Data(), status: 401) }
        let client = try makeClient(fx)
        defer { client.invalidate() }
        await #expect(throws: DownloadError.refusedFile("Amazon refused this file (HTTP 401)")) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
        #expect(fx.listingRequests.count == 1)
    }

    @Test func verifySessionTreatsA403AsFinal() async throws {
        let fx = try fixture()
        fx.overrideListing { _ in .body(Data(), status: 403) }
        let client = try makeClient(fx)
        defer { client.invalidate() }
        await #expect(throws: DownloadError.sessionExpired) { _ = try await client.verifySession() }
        #expect(fx.listingRequests.count == 1)  // no check of the check
    }

    @Test func troubleWithTheCheckItselfIsMoreThrottling() async throws {
        let fx = try fixture()
        let client = try makeClient(fx)
        defer { client.invalidate() }
        // Throttle and network answers are passed on as they are.
        fx.overrideListing { _ in .body(Data(), status: 429, headers: ["Retry-After": "7"]) }
        await #expect(throws: DownloadError.throttled(status: 429, retryAfter: 7)) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
        fx.overrideListing { _ in .fail(.notConnectedToInternet) }
        await #expect(throws: DownloadError.network("no internet connection")) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
        // Anything else is not evidence that the sign-in is gone.
        fx.overrideListing { _ in .body(Data(), status: 404) }
        await #expect(throws: DownloadError.throttled(status: 403, retryAfter: nil)) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
    }

    @Test func requestsThatFailTogetherShareOneCheck() async throws {
        let fx = try fixture()
        fx.server.responseDelay = 0.3
        let client = try makeClient(fx)
        defer { client.invalidate() }
        let outcomes = await withTaskGroup(of: DownloadError?.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do {
                        try await client.downloadContent(nodeId: "N1") { _ in 0 }
                        return nil
                    } catch {
                        return error as? DownloadError
                    }
                }
            }
            var all: [DownloadError?] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        #expect(outcomes.count == 4 && outcomes.allSatisfy { $0 == .throttled(status: 403, retryAfter: nil) })
        #expect(fx.listingRequests.count == 1)
    }

    @Test func aGoodCheckHoldsForThirtySeconds() async throws {
        let fx = try fixture()
        let client = try makeClient(fx)
        defer { client.invalidate() }
        #expect(client.forbiddenCheck.cacheDuration == 30)
        for _ in 0..<3 {
            await #expect(throws: DownloadError.throttled(status: 403, retryAfter: nil)) {
                try await client.downloadContent(nodeId: "N1") { _ in 0 }
            }
        }
        #expect(fx.listingRequests.count == 1)
    }

    @Test func onceTheGoodAnswerIsOldTheNext403IsCheckedAgain() async throws {
        let fx = try fixture()
        let client = try makeClient(fx)
        defer { client.invalidate() }
        client.forbiddenCheck.cacheDuration = 0
        for _ in 0..<2 {
            await #expect(throws: DownloadError.throttled(status: 403, retryAfter: nil)) {
                try await client.downloadContent(nodeId: "N1") { _ in 0 }
            }
        }
        #expect(fx.listingRequests.count == 2)
    }

    @Test func aRefusalIsNeverKept() async throws {
        let fx = try fixture()
        fx.overrideListing { count in count == 0 ? .body(Data(), status: 403) : nil }
        let client = try makeClient(fx)
        defer { client.invalidate() }
        await #expect(throws: DownloadError.sessionExpired) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
        // The next 403 asks again, and may find the session working.
        await #expect(throws: DownloadError.throttled(status: 403, retryAfter: nil)) {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
        }
        #expect(fx.listingRequests.count == 2)
    }
}

// MARK: Keeping the store in step

@Suite("Writing refreshed cookies back to the session store")
struct SessionPersisterTests {
    /// A client whose cookies change with every API answer, and a store that holds `stored` (by default
    /// the sign-in the client started with).
    private struct Setup {
        let fx: DownloadFixture
        let client: AmazonClient
        let store: CountingStore
        let persister: SessionPersister
        let time: FakeClock

        func refreshCookies() async throws { _ = try await client.fetchMetadata(nodeId: "N1") }
    }

    private func setup(stored: ((DownloadFixture) -> StoredSession?)? = nil) throws -> Setup {
        let fx = try DownloadFixture(files: [item("N1", "a.jpg")])
        fx.overrideAPIHeaders(rotatingToken)
        let client = try makeClient(fx)
        let store = CountingStore(stored.map { $0(fx) } ?? fx.session)
        let time = FakeClock(start: noonOct16)
        let persister = SessionPersister(client: client, store: store, baseline: fx.session, now: { time.now })
        return Setup(fx: fx, client: client, store: store, persister: persister, time: time)
    }

    @Test func refreshedCookiesAreSavedWithTheOldSignInTime() async throws {
        let s = try setup()
        defer { s.client.invalidate() }
        #expect(s.persister.saveIfDue() == .unchanged)  // nothing refreshed yet
        try await s.refreshCookies()
        #expect(s.persister.saveIfDue() == .saved)
        let stored = try #require(try s.store.load())
        #expect(stored.savedAt == s.fx.session.savedAt && stored.host == s.fx.session.host)
        #expect(stored.cookies.first { $0.name == "session-token" }?.value == "rotating-token-0000")
        #expect(stored.cookies.first { $0.name == "session-id" }?.value == s.fx.sessionID)
        #expect(s.persister.saveIfDue() == .unchanged)
        #expect(s.store.saves == 1)
    }

    @Test func anotherSignInInTheStoreIsNeverOverwritten() async throws {
        let others: [(String, @Sendable (DownloadFixture) -> StoredSession?)] = [
            ("newer", { fx in newerSignIn(of: fx) }),
            ("older", { fx in newerSignIn(of: fx, after: -100) }),
            ("other host", { fx in
                var other = fx.session
                other.host = "other.amazon.com"
                return other
            }),
        ]
        for (label, held) in others {
            let s = try setup(stored: held)
            defer { s.client.invalidate() }
            let before = try #require(try s.store.load())
            let writes = s.store.saves
            try await s.refreshCookies()
            #expect(s.persister.saveIfDue() == .storeHoldsAnotherSession, "\(label)")
            #expect(s.persister.flush() == .storeHoldsAnotherSession, "\(label)")
            #expect(try s.store.load() == before && s.store.saves == writes, "\(label)")
        }
    }

    @Test func aSessionThatWasSignedOutIsNotBroughtBack() async throws {
        let s = try setup()
        defer { s.client.invalidate() }
        try s.store.delete()
        try await s.refreshCookies()
        #expect(s.persister.flush() == .storeHoldsAnotherSession)
        #expect(try s.store.load() == nil && s.store.saves == 0)
    }

    @Test func writesComeAtMostOncePerMinuteAndTheEndWritesTheRest() async throws {
        let s = try setup()
        defer { s.client.invalidate() }
        try await s.refreshCookies()
        #expect(s.persister.saveIfDue() == .saved)
        try await s.refreshCookies()
        #expect(s.persister.saveIfDue() == .waiting)
        s.time.advance(59)
        #expect(s.persister.saveIfDue() == .waiting)
        s.time.advance(2)
        #expect(s.persister.saveIfDue() == .saved)
        #expect(s.store.saves == 2)
        try await s.refreshCookies()
        #expect(s.persister.saveIfDue() == .waiting)
        // The end of the run writes whatever is left, however recent the last write.
        #expect(s.persister.flush() == .saved)
        #expect(s.persister.flush() == .unchanged)
        #expect(s.store.saves == 3)
        let stored = try #require(try s.store.load())
        #expect(stored.cookies.first { $0.name == "session-token" }?.value == "rotating-token-0002")
    }

    @Test func aStoreThatFailsNeverStopsTheRunAndIsTriedAgain() async throws {
        let s = try setup()
        defer { s.client.invalidate() }
        try await s.refreshCookies()
        s.store.failsSaves = true
        #expect(s.persister.flush() == .failed)
        s.store.failsSaves = false
        #expect(s.persister.flush() == .saved)
    }

    // MARK: Taking over a newer sign-in

    @Test func aNewerUsableSignInIsTakenOverOnce() async throws {
        let s = try setup()
        defer { s.client.invalidate() }
        let epoch = s.client.sessionEpoch
        // Nothing new in the store: the refusal stands.
        #expect(!s.persister.recoverFromRefusal(attemptEpoch: epoch))
        #expect(s.client.sessionEpoch == epoch)

        let newer = newerSignIn(of: s.fx)
        try s.store.save(newer)
        #expect(s.persister.recoverFromRefusal(attemptEpoch: epoch))
        #expect(s.client.sessionEpoch == epoch + 1)
        #expect(s.client.currentSession == newer)
        // A request that began before the switch is simply tried again, without another switch.
        #expect(s.persister.recoverFromRefusal(attemptEpoch: epoch))
        #expect(s.client.sessionEpoch == epoch + 1)
        // A request that used the new sign-in and was refused ends the run: the store holds nothing newer.
        #expect(!s.persister.recoverFromRefusal(attemptEpoch: epoch + 1))
    }

    @Test func aSignInThatIsOldUnusableForeignOrAlreadyUsedIsNotTakenOver() async throws {
        let s = try setup()
        defer { s.client.invalidate() }
        let epoch = s.client.sessionEpoch
        let noID = StoredSession(
            host: s.fx.host, cookies: [SessionCookie(name: "session-token", value: "no-id-here-000", domain: ".amazon.com")],
            savedAt: noonOct16.addingTimeInterval(100))
        let expired = StoredSession(
            host: s.fx.host,
            cookies: [SessionCookie(name: "session-id", value: "expired-id-0001", domain: ".amazon.com", expiresAt: Date(timeIntervalSince1970: 1_000))],
            savedAt: noonOct16.addingTimeInterval(100))
        var foreign = newerSignIn(of: s.fx)
        foreign.host = "other.amazon.com"
        for held in [noID, expired, foreign, s.fx.session] {
            try s.store.save(held)
            #expect(!s.persister.recoverFromRefusal(attemptEpoch: epoch))
        }
        #expect(s.client.sessionEpoch == epoch)

        // Taken over once; when the store later shows the first one again, it is not used a second time.
        let second = newerSignIn(of: s.fx, id: "second-sign-in-id-1", after: 100)
        let third = newerSignIn(of: s.fx, id: "third-sign-in-id-22", after: 200)
        try s.store.save(second)
        #expect(s.persister.recoverFromRefusal(attemptEpoch: epoch))
        try s.store.save(third)
        #expect(s.persister.recoverFromRefusal(attemptEpoch: epoch + 1))
        try s.store.save(second)
        #expect(!s.persister.recoverFromRefusal(attemptEpoch: epoch + 2))
        try s.store.save(s.fx.session)
        #expect(!s.persister.recoverFromRefusal(attemptEpoch: epoch + 2))
        #expect(s.client.currentSession == third)
    }

    @Test func afterTakingOverTheNewSignInIsTheOneThatMayBeOverwritten() async throws {
        let s = try setup()
        defer { s.client.invalidate() }
        let newer = newerSignIn(of: s.fx)
        s.fx.accept(sessionID: "newer-sign-in-id-555")
        try s.store.save(newer)
        #expect(s.persister.recoverFromRefusal(attemptEpoch: s.client.sessionEpoch))
        #expect(s.persister.flush() == .unchanged)  // the switch itself is nothing to write
        try await s.refreshCookies()
        #expect(s.persister.flush() == .saved)
        let stored = try #require(try s.store.load())
        #expect(stored.savedAt == newer.savedAt)
        #expect(stored.cookies.first { $0.name == "session-token" }?.value == "rotating-token-0000")
    }
}

// MARK: In a run

@Suite("Downloads that keep the session alive")
struct SessionRecoveryEngineTests {
    private func contentRequests(_ fx: DownloadFixture) -> [StubServer.Request] {
        fx.server.requests(host: fx.host).filter { $0.url.path.hasSuffix("/contentRedirection") }
    }

    // MARK: 403

    @Test func a403TheSessionCheckClearsIsBackedOffAndTheRunGoesOn() async throws {
        let fx = try DownloadFixture(files: [item("N1", "a.jpg", seed: 1), item("N2", "b.jpg", seed: 2)])
        // Every file is refused once with a 403, as heavy downloading can provoke.
        fx.overrideContent { _, count in count == 0 ? .body(Data(), status: 403) : nil }
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.stopReason == nil)
        #expect(summary.filesDownloaded == 2 && summary.filesFailed == 0)
        #expect(fx.listingRequests.count >= 1)
        #expect(contentRequests(fx).count == 4)
        // The existing backoff applied: the run waited on the clock before it tried again.
        #expect(fx.clock.sleeps.contains { $0 > 0 })
        #expect(try fx.jobs().allSatisfy { $0.status == .done })
    }

    @Test func a403TheSessionCheckConfirmsStopsTheRunWithoutSpendingTries() async throws {
        let fx = try DownloadFixture(files: [item("N1", "a.jpg", seed: 1), item("N2", "b.jpg", seed: 2)])
        fx.overrideContent { _, _ in .body(Data(), status: 403) }
        fx.overrideListing { _ in .body(Data(), status: 403) }
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.stopReason == .sessionExpired)
        #expect(fx.driveFiles().isEmpty)
        #expect(contentRequests(fx).count == 1)
        #expect(fx.listingRequests.count == 1)
        let jobs = try fx.jobs()
        #expect(jobs.map(\.status) == [.pending, .pending] && jobs.map(\.attempts) == [0, 0])
    }

    // MARK: A newer sign-in

    @Test func aNewerSignInInTheStoreIsPickedUpAndTheRunGoesOn() async throws {
        let fx = try DownloadFixture(files: [
            item("N1", "a.jpg", seed: 1, takenAt: t2015), item("N2", "b.jpg", seed: 2, takenAt: t2019),
            item("N3", "c.jpg", seed: 3, takenAt: t2020),
        ])
        let store = CountingStore(fx.session)
        let newer = newerSignIn(of: fx)
        // During the first file the person signs in again: the old session ends, the store holds the new one.
        let signedInAgain = Once()
        fx.overrideContent { _, _ in
            if signedInAgain.first() {
                fx.accept(sessionID: "newer-sign-in-id-555")
                fx.reject(sessionID: fx.sessionID)
                try? store.save(newer)
            }
            return nil
        }
        let summary = try await fx.run(DownloadOptions(concurrency: 1), sessionStore: store)
        #expect(summary.stopReason == nil)
        #expect(summary.filesDownloaded == 3 && summary.filesFailed == 0)
        let ids = contentRequests(fx).compactMap { $0.header("x-amzn-sessionid") }
        #expect(ids.first == fx.sessionID)
        #expect(ids.contains("newer-sign-in-id-555"))
        // Nothing but the refused request used the old session after the switch, and the run took no
        // detour through a stop: every file is done.
        #expect(try fx.jobs().allSatisfy { $0.status == .done && $0.attempts == 0 })
        // The sign-in in the store is still the new one, untouched.
        #expect(try store.load() == newer)
    }

    @Test func aNewerSignInThatIsRefusedToEndsTheRunInsteadOfLooping() async throws {
        let fx = try DownloadFixture(files: [item("N1", "a.jpg", seed: 1), item("N2", "b.jpg", seed: 2)])
        let store = CountingStore(fx.session)
        let signedInAgain = Once()
        fx.overrideContent { _, _ in
            if signedInAgain.first() {
                fx.reject(sessionID: fx.sessionID)
                try? store.save(newerSignIn(of: fx))  // its id is not accepted either
            }
            return nil
        }
        let summary = try await fx.run(DownloadOptions(concurrency: 1), sessionStore: store)
        #expect(summary.stopReason == .sessionExpired)
        // The file that began after the switch was asked for twice: with the old session, then the new one.
        let ids = contentRequests(fx).compactMap { $0.header("x-amzn-sessionid") }
        #expect(ids == [fx.sessionID, fx.sessionID, "newer-sign-in-id-555"])
        #expect(try fx.jobs().filter { $0.status == .done }.count == 1)
    }

    @Test func withoutANewerSignInTheRunStopsAsBefore() async throws {
        let fx = try DownloadFixture(files: [item("N1", "a.jpg"), item("N2", "b.jpg", seed: 2)])
        fx.overrideContent { _, _ in .body(Data(), status: 401) }
        fx.overrideListing { _ in .body(Data(), status: 401) }
        let store = CountingStore(fx.session)
        let summary = try await fx.run(DownloadOptions(concurrency: 1), sessionStore: store)
        #expect(summary.stopReason == .sessionExpired)
        #expect(contentRequests(fx).count == 1)
        let jobs = try fx.jobs()
        #expect(jobs.map(\.status) == [.pending, .pending] && jobs.map(\.attempts) == [0, 0])
    }

    // MARK: Saving

    @Test func refreshedCookiesAreWrittenBackAtMostOnceAMinuteAndAtTheEnd() async throws {
        let files = (1...5).map { item("N\($0)", "f\($0).jpg", seed: UInt8($0)) }
        let fx = try DownloadFixture(files: files)
        fx.overrideAPIHeaders(rotatingToken)
        let store = CountingStore(fx.session)
        let summary = try await fx.run(DownloadOptions(concurrency: 1), sessionStore: store)
        #expect(summary.filesDownloaded == 5)
        // The fake clock stood still: one write after the first file, one at the end.
        #expect(store.saves == 2)
        let stored = try #require(try store.load())
        #expect(stored.savedAt == fx.session.savedAt && stored.host == fx.session.host)
        let answers = fx.server.requests(host: fx.host).count
        #expect(stored.cookies.first { $0.name == "session-token" }?.value == "rotating-token-\(String(format: "%04d", answers - 1))")
        #expect(stored.cookies.first { $0.name == "session-id" }?.value == fx.sessionID)
    }

    @Test func aSignInMadeDuringARunIsNotOverwrittenByTheRunsCookies() async throws {
        let fx = try DownloadFixture(files: [item("N1", "a.jpg"), item("N2", "b.jpg", seed: 2)])
        fx.overrideAPIHeaders(rotatingToken)
        let store = CountingStore(fx.session)
        let newer = newerSignIn(of: fx)
        let signedInAgain = Once()
        // The old session still works, so the run has no reason to switch.
        fx.overrideContent { _, _ in
            if signedInAgain.first() { try? store.save(newer) }
            return nil
        }
        let summary = try await fx.run(DownloadOptions(concurrency: 1), sessionStore: store)
        #expect(summary.stopReason == nil && summary.filesDownloaded == 2)
        #expect(try store.load() == newer)
        #expect(store.saves == 1)  // only the test's own write
    }

    @Test func aRunWithoutAStoreWorksAsBefore() async throws {
        let fx = try DownloadFixture(files: [item("N1", "a.jpg")])
        fx.overrideAPIHeaders(rotatingToken)
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 1)
    }
}

/// True the first time it is asked, false afterwards.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func first() -> Bool {
        lock.withLock {
            defer { used = true }
            return !used
        }
    }
}
