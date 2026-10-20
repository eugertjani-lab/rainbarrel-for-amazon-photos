import Foundation
import Testing
@testable import RainbarrelCore

private func file(_ id: String, _ name: String, seed: UInt8 = 1, takenAt: Int64 = t2019) -> TestFile {
    TestFile(nodeId: id, name: name, data: bytes(3000, seed: seed), folder: "F-PHONE", takenAt: takenAt)
}

private func secs(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970) }

private let hour: TimeInterval = 3600
private let notAvailable = DownloadError.notAvailableYetMessage

private func storageRequests(_ fx: DownloadFixture) -> Int { fx.server.requests(host: fx.storageHost).count }

private func retryAfter(_ fx: DownloadFixture, _ nodeId: String) throws -> Int64? {
    try fx.store().database.scalarInt64("SELECT retry_after FROM download_jobs WHERE node_id = ?", [nodeId])
}

/// The cool-down was set within `cooldown` seconds of a moment between `start` and `end`.
private func expectCoolDown(_ stored: Int64?, from start: Date, to end: Date, _ cooldown: TimeInterval) {
    guard let stored else {
        Issue.record("the job has no retry_after")
        return
    }
    #expect(stored >= secs(start) + Int64(cooldown) && stored <= secs(end) + Int64(cooldown), "retry_after \(stored)")
}

@Suite("HTTP 404 is temporary: cool-downs, attempts and the retry queue")
struct DownloadRetryTests {
    // MARK: The policy

    @Test func theFirst404WaitsSixHoursAndLaterOnesWaitADay() {
        let now = noonOct16
        let old = secs(now) - 30 * 86_400
        let first = DownloadRetryPolicy.afterNotAvailable(attempts: 0, takenAt: old, now: now)
        #expect(first == .init(attempts: 1, retryAfter: now.addingTimeInterval(6 * hour)))
        for attempts in 1...4 {
            let later = DownloadRetryPolicy.afterNotAvailable(attempts: attempts, takenAt: old, now: now)
            #expect(later == .init(attempts: attempts + 1, retryAfter: now.addingTimeInterval(24 * hour)))
        }
    }

    @Test func aCaptureWithinTheLast48HoursUsesNoAttemptAndWaitsAnHour() {
        let now = noonOct16
        for age in [0.0, 3 * hour, 47 * hour + 59 * 60] {
            let decision = DownloadRetryPolicy.afterNotAvailable(attempts: 2, takenAt: secs(now) - Int64(age), now: now)
            #expect(decision == .init(attempts: 2, retryAfter: now.addingTimeInterval(hour)), "age \(age)")
        }
        // From 48 hours on it counts like any other file.
        let edge = DownloadRetryPolicy.afterNotAvailable(attempts: 0, takenAt: secs(now) - Int64(48 * hour), now: now)
        #expect(edge == .init(attempts: 1, retryAfter: now.addingTimeInterval(6 * hour)))
    }

    @Test func aCaptureDateFarInTheFutureGetsNoFreeRetries() {
        let now = noonOct16
        let soon = DownloadRetryPolicy.afterNotAvailable(attempts: 0, takenAt: secs(now) + Int64(5 * hour), now: now)
        #expect(soon.attempts == 0)  // a few hours ahead: a clock or time zone slip, still a new upload
        let wrong = DownloadRetryPolicy.afterNotAvailable(attempts: 0, takenAt: secs(now) + 30 * 86_400, now: now)
        #expect(wrong.attempts == 1)
    }

    // MARK: One file through the engine

    @Test func a404GivesACoolDownNotAPermanentFailure() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideStorage { _, _ in .body(Data(), status: 404) }
        let start = fx.clock.now
        let summary = try await fx.run()
        let end = fx.clock.now
        #expect(summary.filesFailed == 1 && summary.stopReason == nil)
        let job = try #require(try fx.job("N1"))
        #expect(job.status == .failed && job.attempts == 1 && job.lastError == notAvailable)
        expectCoolDown(try retryAfter(fx, "N1"), from: start, to: end, 6 * hour)
        #expect(fx.driveFiles().isEmpty)
    }

    @Test func theCoolDownIsRespectedAndTheFileIsTriedAgainAfterIt() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideStorage { _, _ in .body(Data(), status: 404) }
        _ = try await fx.run()
        #expect(storageRequests(fx) == 1)

        // Inside the cool-down a run leaves the file alone, and finds nothing to do.
        fx.clock.advance(5 * hour)
        let quiet = try await fx.run()
        #expect(quiet.filesFailed == 0 && quiet.filesDownloaded == 0 && quiet.stopReason == nil)
        #expect(storageRequests(fx) == 1)

        // After it the file is tried again; Amazon has processed it by now.
        fx.clock.advance(2 * hour)
        fx.overrideStorage { _, _ in nil }
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 1 && summary.filesFailed == 0)
        let job = try #require(try fx.job("N1"))
        #expect(job.status == .done && job.lastError == nil)
        #expect(try retryAfter(fx, "N1") == nil)
        #expect(fx.contents("Amazon Drive/Pictures/Phone/a.jpg") == file("N1", "a.jpg").data)
    }

    @Test func aSecond404WaitsADay() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideStorage { _, _ in .body(Data(), status: 404) }
        _ = try await fx.run()
        fx.clock.advance(6 * hour + 60)
        let start = fx.clock.now
        _ = try await fx.run()
        let end = fx.clock.now
        #expect(try fx.job("N1")?.attempts == 2)
        expectCoolDown(try retryAfter(fx, "N1"), from: start, to: end, 24 * hour)
    }

    @Test func theAttemptsRunOutAfterFiveTriesOverAboutFourDays() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideStorage { _, _ in .body(Data(), status: 404) }
        let first = fx.clock.now
        let cooldowns: [TimeInterval] = [6 * hour, 24 * hour, 24 * hour, 24 * hour, 24 * hour]
        for (index, cooldown) in cooldowns.enumerated() {
            let before = fx.clock.now
            let summary = try await fx.run()
            let after = fx.clock.now
            #expect(summary.filesFailed == 1, "try \(index + 1)")
            let job = try #require(try fx.job("N1"))
            #expect(job.status == .failed && job.attempts == index + 1, "try \(index + 1)")
            expectCoolDown(try retryAfter(fx, "N1"), from: before, to: after, cooldown)
            fx.clock.advance(cooldown + 60)
        }
        let spent = fx.clock.now.timeIntervalSince(first)
        #expect(spent > 3 * 86_400 && spent < 5 * 86_400)  // about four days
        // That was the fifth try: the file is out of attempts and no later run asks again.
        #expect(storageRequests(fx) == 5)
        fx.clock.advance(30 * 86_400)
        let after = try await fx.run()
        #expect(after.filesFailed == 0 && after.filesDownloaded == 0)
        #expect(storageRequests(fx) == 5)
        #expect(try fx.job("N1")?.attempts == 5)
    }

    @Test func aRecentCaptureUsesNoAttemptsAndWaitsOneHour() async throws {
        let captured = secs(noonOct16) - Int64(3 * hour)
        let fx = try DownloadFixture(files: [file("N1", "a.jpg", takenAt: captured)])
        fx.overrideStorage { _, _ in .body(Data(), status: 404) }
        for round in 1...7 {
            let before = fx.clock.now
            let summary = try await fx.run()
            let after = fx.clock.now
            #expect(summary.filesFailed == 1, "round \(round)")
            let job = try #require(try fx.job("N1"))
            #expect(job.status == .failed && job.attempts == 0 && job.lastError == notAvailable, "round \(round)")
            expectCoolDown(try retryAfter(fx, "N1"), from: before, to: after, hour)
            fx.clock.advance(hour + 60)
        }
        #expect(storageRequests(fx) == 7)
    }

    @Test func theRecentRuleEndsWhenTheCaptureIsOlderThan48Hours() async throws {
        let captured = secs(noonOct16) - Int64(47 * hour)
        let fx = try DownloadFixture(files: [file("N1", "a.jpg", takenAt: captured)])
        fx.overrideStorage { _, _ in .body(Data(), status: 404) }
        _ = try await fx.run()
        #expect(try fx.job("N1")?.attempts == 0)  // 47 hours old: still recent
        fx.clock.advance(2 * hour)
        let start = fx.clock.now
        _ = try await fx.run()
        let end = fx.clock.now
        #expect(try fx.job("N1")?.attempts == 1)  // 49 hours old: counts now, first 404 of an old file
        expectCoolDown(try retryAfter(fx, "N1"), from: start, to: end, 6 * hour)
    }

    @Test func otherStatusesStayPermanent() async throws {
        for status in [400, 410] {
            let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
            fx.overrideStorage { _, _ in .body(Data(), status: status) }
            let summary = try await fx.run()
            #expect(summary.filesFailed == 1)
            let job = try #require(try fx.job("N1"))
            #expect(job.status == .failed && job.attempts >= 5, "status \(status)")
            #expect(job.lastError == "Amazon answered HTTP \(status)")
            #expect(try retryAfter(fx, "N1") == nil)
            fx.clock.advance(30 * 86_400)
            _ = try await fx.run()
            #expect(storageRequests(fx) == 1, "status \(status)")
        }
    }

    @Test func aFailureOfAnotherKindClearsTheCoolDown() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideStorage { _, _ in .body(Data(), status: 404) }
        _ = try await fx.run()
        #expect(try retryAfter(fx, "N1") != nil)
        fx.clock.advance(7 * hour)
        fx.overrideStorage { _, _ in .body(Data(), status: 400) }
        _ = try await fx.run()
        let job = try #require(try fx.job("N1"))
        #expect(job.status == .failed && job.attempts >= 5)
        #expect(try retryAfter(fx, "N1") == nil)
    }

    @Test func aLiveVideoThatIsNotReadyYetIsRetriedWhileTheOthersDownload() async throws {
        let photo = file("P1", "IMG_1.jpg", seed: 1)
        let video = TestFile(
            nodeId: "V1", name: "IMG_1_lpv", data: bytes(3000, seed: 2), folder: "F-PHONE", takenAt: t2019,
            kind: .liveVideo, ext: "qt", parent: "P1")
        let fx = try DownloadFixture(files: [photo, video])
        fx.overrideStorage { id, _ in id == "V1" ? .body(Data(), status: 404) : nil }
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 1 && summary.filesFailed == 1)
        #expect(try fx.job("P1")?.status == .done)
        #expect(try fx.job("V1")?.status == .failed)
        fx.clock.advance(7 * hour)
        fx.overrideStorage { _, _ in nil }
        let again = try await fx.run()
        #expect(again.filesDownloaded == 1)
        #expect(try fx.job("V1")?.status == .done)
    }

    // MARK: Old data

    private func downgradeToTheOldSchema(_ store: StateStore) throws {
        try store.database.execute("""
            DROP TABLE download_jobs;
            CREATE TABLE download_jobs(
                node_id TEXT PRIMARY KEY, kind TEXT NOT NULL, md5 TEXT NOT NULL, size INTEGER NOT NULL,
                taken_at INTEGER NOT NULL DEFAULT 0, target_rel_path TEXT NOT NULL, status TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, updated_at INTEGER NOT NULL
            );
            """)
        try store.setMeta(MetaKey.schemaVersion, "1")
    }

    private func oldJob(_ store: StateStore, _ file: TestFile, status: String, attempts: Int, error: String?) throws {
        try store.database.run(
            """
            INSERT INTO download_jobs(node_id, kind, md5, size, taken_at, target_rel_path, status, attempts, last_error, updated_at)
            VALUES(?, 'file', ?, ?, ?, ?, ?, ?, ?, 100)
            """,
            [file.nodeId, file.md5, Int64(file.data.count), file.takenAt, "Amazon Drive/Pictures/Phone/\(file.name)", status,
             attempts, error])
    }

    @Test func theMigrationPutsOldPermanent404JobsBackIntoTheQueueOnce() async throws {
        let files = [file("N1", "a.jpg", seed: 1), file("N2", "b.jpg", seed: 2), file("N3", "c.jpg", seed: 3),
                     file("N4", "d.jpg", seed: 4), file("N5", "e.jpg", seed: 5)]
        let fx = try DownloadFixture(files: files)
        let old = try fx.store()
        try downgradeToTheOldSchema(old)
        try oldJob(old, files[0], status: "failed", attempts: 5, error: "Amazon answered HTTP 404")
        try oldJob(old, files[1], status: "failed", attempts: 5, error: "Amazon answered HTTP 410")
        try oldJob(old, files[2], status: "failed", attempts: 7, error: "Amazon answered HTTP 404")
        try oldJob(old, files[3], status: "failed", attempts: 2, error: "Amazon answered HTTP 404")
        try oldJob(old, files[4], status: "done", attempts: 1, error: nil)

        let now = fx.clock.now
        let migrated = try StateStore(path: fx.paths.stateURL.path, now: now)
        #expect(try migrated.getMeta(MetaKey.schemaVersion) == "2")
        let rows = try migrated.database.rows(
            "SELECT node_id, status, attempts, retry_after FROM download_jobs ORDER BY node_id"
        ) { "\($0.string(0) ?? "")|\($0.string(1) ?? "")|\($0.int(2))|\($0.isNull(3) ? "-" : String($0.int64(3)))" }
        #expect(rows == [
            "N1|failed|1|\(secs(now))",  // the old rule made it permanent: due now, with the new treatment
            "N2|failed|5|-",  // another status stays permanent
            "N3|failed|1|\(secs(now))",  // attempts beyond the limit are reset too
            "N4|failed|2|-",  // never was permanent
            "N5|done|1|-",
        ])

        // It runs once: a job that fails for good later is not taken back by the next start.
        try migrated.database.run("UPDATE download_jobs SET attempts = 5, retry_after = NULL WHERE node_id = 'N1'")
        let again = try StateStore(path: fx.paths.stateURL.path, now: now.addingTimeInterval(86_400))
        #expect(try again.database.scalarInt64("SELECT attempts FROM download_jobs WHERE node_id = 'N1'") == 5)
        #expect(try again.database.scalarInt64("SELECT retry_after FROM download_jobs WHERE node_id = 'N1'") == nil)
    }

    @Test func aNewDatabaseNeedsNoMigration() throws {
        let store = try makeStore()
        #expect(try store.getMeta(MetaKey.schemaVersion) == "2")
        let columns = try store.database.rows("PRAGMA table_info(download_jobs)", map: { $0.string(1) ?? "" })
        #expect(columns.contains("retry_after"))
    }

    @Test func migratedJobsAreRetriedByTheNextRun() async throws {
        let files = [file("N1", "a.jpg", seed: 1), file("N2", "b.jpg", seed: 2), file("N3", "c.jpg", seed: 3)]
        let fx = try DownloadFixture(files: files)
        let old = try fx.store()
        try downgradeToTheOldSchema(old)
        try oldJob(old, files[0], status: "failed", attempts: 5, error: "Amazon answered HTTP 404")
        try oldJob(old, files[1], status: "failed", attempts: 5, error: "Amazon answered HTTP 410")
        try oldJob(old, files[2], status: "pending", attempts: 0, error: nil)
        _ = try StateStore(path: fx.paths.stateURL.path, now: fx.clock.now)

        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 2 && summary.filesFailed == 0)
        #expect(try fx.job("N1")?.status == .done)
        #expect(try fx.job("N3")?.status == .done)
        #expect(try fx.job("N2")?.status == .failed)  // permanent for another reason
    }

    // MARK: --retry-failed

    @Test func retryFailedPutsEveryFailedJobBackWithFreshAttempts() async throws {
        let files = [file("A", "a.jpg", seed: 1), file("B", "b.jpg", seed: 2), file("C", "c.jpg", seed: 3)]
        let fx = try DownloadFixture(files: files)
        fx.overrideStorage { id, _ in
            switch id {
            case "A": return .body(Data(), status: 404)
            case "B": return .body(Data(), status: 400)
            default: return nil
            }
        }
        let first = try await fx.run()
        #expect(first.filesDownloaded == 1 && first.filesFailed == 2)
        #expect(try fx.job("A")?.status == .failed && fx.job("B")?.status == .failed)

        // Amazon has the files now, but without the option the waiting and the permanent ones stay put.
        fx.overrideStorage { _, _ in nil }
        let plain = try await fx.run()
        #expect(plain.filesDownloaded == 0)

        let summary = try await fx.run(DownloadOptions(retryFailed: true))
        #expect(summary.filesDownloaded == 2 && summary.filesFailed == 0)
        for id in ["A", "B", "C"] {
            let job = try #require(try fx.job(id))
            #expect(job.status == .done && job.lastError == nil, "job \(id)")
            #expect(try retryAfter(fx, id) == nil)
        }
        #expect(try fx.job("A")?.attempts == 0 && fx.job("B")?.attempts == 0)
    }

    @Test func retryFailedStartsWithFreshAttemptsAndCoolDown() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg")])
        fx.overrideStorage { _, _ in .body(Data(), status: 404) }
        for _ in 0..<3 {
            _ = try await fx.run()
            fx.clock.advance(25 * hour)
        }
        #expect(try fx.job("A")?.attempts == 3)
        // Still 404: with a reset the file counts as a first failure again (6 hours, one attempt).
        let start = fx.clock.now
        _ = try await fx.run(DownloadOptions(retryFailed: true))
        let end = fx.clock.now
        #expect(try fx.job("A")?.attempts == 1)
        expectCoolDown(try retryAfter(fx, "A"), from: start, to: end, 6 * hour)
    }

    @Test func aDryRunWithRetryFailedListsTheFailedFilesAndChangesNothing() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1), file("B", "b.jpg", seed: 2)])
        fx.overrideStorage { id, _ in id == "A" ? .body(Data(), status: 404) : nil }
        _ = try await fx.run()
        #expect(try fx.engine.plan(config: fx.config, options: DownloadOptions()).isEmpty)
        let plan = try fx.engine.plan(config: fx.config, options: DownloadOptions(retryFailed: true))
        #expect(plan.map(\.nodeId) == ["A"])
        let job = try #require(try fx.job("A"))
        #expect(job.status == .failed && job.attempts == 1)
    }

    // MARK: What a run would download

    private func seedFailedJobs(_ fx: DownloadFixture) throws -> DownloadJobTable {
        let store = try fx.store()
        let table = DownloadJobTable(source: store, queue: store, config: fx.config)
        _ = try table.sync(includeLiveVideos: true, now: fx.clock.now)
        let now = fx.clock.now
        // A waits for its cool-down, B is out of attempts, C's cool-down has passed, D failed an hour ago
        // without a cool-down (the old rule), E is pending.
        try table.setStatus(
            nodeId: "A", status: .failed, attempts: 1, lastError: .some(notAvailable),
            retryAfter: now.addingTimeInterval(6 * hour), now: now)
        try table.setStatus(
            nodeId: "B", status: .failed, attempts: 5, lastError: .some("Amazon answered HTTP 400"), now: now)
        try table.setStatus(
            nodeId: "C", status: .failed, attempts: 1, lastError: .some(notAvailable),
            retryAfter: now.addingTimeInterval(-60), now: now.addingTimeInterval(-7 * hour))
        try table.setStatus(
            nodeId: "D", status: .failed, attempts: 2, lastError: .some("Network problem: x"),
            now: now.addingTimeInterval(-hour))
        return table
    }

    private var fiveFiles: [TestFile] {
        ["A", "B", "C", "D", "E"].enumerated().map { file($1, "\($1.lowercased()).jpg", seed: UInt8($0 + 1)) }
    }

    @Test func theDownloadCountLeavesOutFilesThatWaitOrFailedForGood() async throws {
        let fx = try DownloadFixture(files: fiveFiles)
        let table = try seedFailedJobs(fx)
        let now = fx.clock.now

        let plan = try fx.engine.plan(config: fx.config, options: DownloadOptions())
        #expect(plan.map(\.nodeId).sorted() == ["C", "D", "E"])
        #expect(try table.totals(options: DownloadOptions(), runStartedAt: secs(now)).count == 3)

        // After the cool-down the file is part of the plan again.
        fx.clock.advance(6 * hour + 1)
        let later = try fx.engine.plan(config: fx.config, options: DownloadOptions())
        #expect(later.map(\.nodeId).sorted() == ["A", "C", "D", "E"])

        // With --retry-failed every failed file counts, the permanent one too.
        let all = try fx.engine.plan(config: fx.config, options: DownloadOptions(retryFailed: true))
        #expect(all.map(\.nodeId).sorted() == ["A", "B", "C", "D", "E"])
    }

    @Test func theCountIsWhatARunReallyDownloads() async throws {
        let fx = try DownloadFixture(files: fiveFiles)
        _ = try seedFailedJobs(fx)
        let plan = try fx.engine.plan(config: fx.config, options: DownloadOptions())
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == plan.count && plan.count == 3)
        #expect(try fx.job("A")?.status == .failed && fx.job("B")?.status == .failed)
        #expect(try fx.engine.plan(config: fx.config, options: DownloadOptions()).isEmpty)
    }

    @Test func failuresAreGroupedByReasonWithWaitingDueAndPermanentCounts() async throws {
        let fx = try DownloadFixture(files: fiveFiles)
        let table = try seedFailedJobs(fx)
        let now = fx.clock.now
        let summary = try table.failureSummary(maxAttempts: 5, now: now)
        #expect(summary.waiting == 1 && summary.due == 2 && summary.permanent == 1 && summary.total == 4)
        #expect(summary.blocked == 2)
        #expect(summary.nextRetryAt == Date(timeIntervalSince1970: TimeInterval(secs(now) + Int64(6 * hour))))
        #expect(summary.groups.map(\.reason) == [notAvailable, "Amazon answered HTTP 400", "Network problem: x"])
        let unavailable = summary.groups[0]
        #expect(unavailable.waiting == 1 && unavailable.due == 1 && unavailable.permanent == 0)
        #expect(summary.groups[1].permanent == 1 && summary.groups[1].nextRetryAt == nil)
        #expect(summary.groups[2].due == 1)
        let counts = try table.counts()
        #expect(counts.failed == 4 && counts.pending == 1)
    }

    @Test func theStatusReportShowsTheGroupsAndTheNextRetry() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1), file("B", "b.jpg", seed: 2)])
        fx.overrideStorage { _, _ in .body(Data(), status: 404) }
        _ = try await fx.run()
        let tools = RainbarrelTools(
            paths: fx.paths, sessionStore: MemorySessionStore(fx.session), downloadEnvironment: fx.environment)
        try tools.saveConfig(fx.config)
        let report = try tools.downloadStatus()
        #expect(report.queue.failed == 2)
        #expect(report.failureSummary.waiting == 2 && report.failureSummary.permanent == 0)
        #expect(report.failureSummary.groups.map(\.reason) == [notAvailable])
        #expect(report.failureSummary.nextRetryAt != nil)
        #expect(report.failures.allSatisfy { $0.reason == notAvailable && $0.retryAfter != nil })
        let again = try tools.downloadFailureSummary()
        #expect(again == report.failureSummary)
        // The JSON of the tool carries the groups.
        let outcome = RainbarrelToolRegistry(tools: tools).call(name: "download_status", arguments: nil)
        let decoded = try JSONDecoder.iso8601.decode(DownloadStatusReport.self, from: Data(outcome.text.utf8))
        #expect(decoded.failureSummary == report.failureSummary)
    }

    // MARK: The wording of the panel

    private func group(_ reason: String, waiting: Int = 0, due: Int = 0, permanent: Int = 0, next: Date? = nil)
        -> DownloadFailureGroup
    {
        DownloadFailureGroup(reason: reason, waiting: waiting, due: due, permanent: permanent, nextRetryAt: next)
    }

    @Test func thePanelNamesWaitingFilesWithTheNextTry() {
        let now = noonOct16
        let summary = DownloadFailureSummary(groups: [group(notAvailable, waiting: 2, next: now.addingTimeInterval(4.5 * hour))])
        #expect(summary.noticeLines(now: now) == ["2 files are not available from Amazon yet · next try in 5 h"])
        let one = DownloadFailureSummary(groups: [group(notAvailable, waiting: 1, next: now.addingTimeInterval(20 * 60))])
        #expect(one.noticeLines(now: now) == ["1 file is not available from Amazon yet · next try in 20 min"])
    }

    @Test func thePanelNamesPermanentFailuresWithTheReasonWhenThereIsOne() {
        let now = noonOct16
        let one = DownloadFailureSummary(groups: [group("Amazon refused this file (HTTP 401)", permanent: 3)])
        #expect(one.noticeLines(now: now) == ["3 files failed: Amazon refused this file (HTTP 401)"])
        let two = DownloadFailureSummary(groups: [group("one reason", permanent: 1), group("another", permanent: 2)])
        #expect(two.noticeLines(now: now) == ["3 files failed"])
        let both = DownloadFailureSummary(groups: [
            group(notAvailable, waiting: 2, next: now.addingTimeInterval(2 * hour)), group("boom", permanent: 1),
        ])
        #expect(both.noticeLines(now: now) == [
            "2 files are not available from Amazon yet · next try in 2 h", "1 file failed: boom",
        ])
    }

    @Test func dueFilesAreNotMentionedBecauseTheNextRunTakesThem() {
        let summary = DownloadFailureSummary(groups: [group("Network problem: x", due: 4)])
        #expect(summary.blocked == 0 && summary.noticeLines(now: noonOct16).isEmpty)
        #expect(DownloadFailureSummary().isEmpty)
    }

    @Test func timeUntilRoundsUp() {
        let now = noonOct16
        #expect(DisplayFormat.timeUntil(now.addingTimeInterval(-5), now: now) == "now")
        #expect(DisplayFormat.timeUntil(now.addingTimeInterval(10), now: now) == "in 1 min")
        #expect(DisplayFormat.timeUntil(now.addingTimeInterval(40 * 60), now: now) == "in 40 min")
        #expect(DisplayFormat.timeUntil(now.addingTimeInterval(hour), now: now) == "in 1 h")
        #expect(DisplayFormat.timeUntil(now.addingTimeInterval(5 * hour - 60), now: now) == "in 5 h")
        #expect(DisplayFormat.timeUntil(now.addingTimeInterval(24 * hour), now: now) == "in 24 h")
        #expect(DisplayFormat.timeUntil(now.addingTimeInterval(72 * hour), now: now) == "in 3 d")
    }
}
