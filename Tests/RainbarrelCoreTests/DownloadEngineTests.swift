import Foundation
import Testing
@testable import RainbarrelCore

private func file(_ id: String, _ name: String, size: Int = 3000, seed: UInt8 = 1, folder: String? = "F-PHONE",
                  takenAt: Int64 = t2019, kind: CloudItemKind = .file, parent: String? = nil, ext: String? = nil) -> TestFile {
    TestFile(nodeId: id, name: name, data: bytes(size, seed: seed), folder: folder, takenAt: takenAt, kind: kind, ext: ext, parent: parent)
}

private let phone = "Amazon Drive/Pictures/Phone"

/// Wait (in real time) until `condition` holds.
private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@Suite("Download engine against a stubbed Amazon")
struct DownloadEngineTests {
    private func contentRequests(_ fx: DownloadFixture) -> [StubServer.Request] {
        fx.server.requests(host: fx.host).filter { $0.url.path.hasSuffix("/contentRedirection") }
    }

    // MARK: The good path

    @Test func downloadsThroughTheRedirectVerifiesAndRecordsTheFile() async throws {
        let item = file("N1", "IMG_0001.jpg", size: 50_000)
        let fx = try DownloadFixture(files: [item])
        let log = ProgressLog()
        let summary = try await fx.engine.run(config: fx.config, session: fx.session, options: DownloadOptions()) { log.add($0) }
        #expect(summary.filesDownloaded == 1)
        #expect(summary.filesFailed == 0)
        #expect(summary.bytesDownloaded == 50_000)
        #expect(summary.stopReason == nil)
        #expect(fx.contents("\(phone)/IMG_0001.jpg") == item.data)
        #expect(fx.driveFiles() == ["\(phone)/IMG_0001.jpg"])  // no temporary files left

        // The reconciler now counts it as backed up.
        let store = try fx.store()
        let row = try #require(try store.driveFile(relPath: "\(phone)/IMG_0001.jpg"))
        #expect(row.md5 == item.md5 && row.size == 50_000 && row.hashedAt != nil && row.mtime > 0)
        let report = try Reconciler(store: store, scope: try DriveScope(scanSubpath: "Amazon Drive")).report(driveRoot: fx.drive.path)
        #expect(report.inSync.count == 1 && report.onlineOnly.count == 0)

        let job = try #require(try fx.job("N1"))
        #expect(job.status == .done && job.targetRelPath == "\(phone)/IMG_0001.jpg" && job.lastError == nil)
        let last = try #require(log.snapshots.last)
        #expect(last.state == .finished)
        #expect(last.filesDone == 1 && last.filesTotal == 1 && last.bytesDone == 50_000 && last.bytesTotal == 50_000)
        // A second run finds nothing to do.
        let again = try await fx.run()
        #expect(again.filesDownloaded == 0 && again.stopReason == nil)
        #expect(contentRequests(fx).count == 1)
    }

    @Test func credentialsGoOnlyToTheAmazonHost() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        try await fx.run()
        let api = fx.server.requests(host: fx.host)
        #expect(api.count == 2)  // the session check and the download request
        for request in api {
            #expect(request.header("x-amzn-sessionid") == fx.sessionID)
            let cookie = request.header("Cookie") ?? ""
            #expect(cookie.contains("session-id=\(fx.sessionID)") && cookie.contains("session-token=\(fx.secretToken)"))
            #expect(!cookie.contains("other-site"))
            #expect(request.header("User-Agent")?.hasPrefix("Rainbarrel/") == true)
        }
        #expect(api[0].url.absoluteString == "https://\(fx.host)/drive/v1/nodes/N1?resourceVersion=V2&ContentType=JSON")
        #expect(api[1].url.absoluteString == "https://\(fx.host)/drive/v1/nodes/N1/contentRedirection?querySuffix=%3Fdownload%3Dtrue")
        let storage = fx.server.requests(host: fx.storageHost)
        #expect(storage.count == 1)
        #expect(storage[0].header("Cookie") == nil && storage[0].header("x-amzn-sessionid") == nil)
    }

    @Test func limitAndYearPickTheNewestMatchingFiles() async throws {
        let files = [
            file("A", "a.jpg", seed: 1, takenAt: t2009), file("B", "b.jpg", seed: 2, takenAt: t2015),
            file("C", "c.jpg", seed: 3, takenAt: t2019), file("D", "d.jpg", seed: 4, takenAt: t2020),
        ]
        let fx = try DownloadFixture(files: files)
        let limited = try await fx.run(DownloadOptions(limit: 2))
        #expect(limited.filesDownloaded == 2)
        #expect(fx.driveFiles() == ["\(phone)/c.jpg", "\(phone)/d.jpg"])
        let year = try await fx.run(DownloadOptions(year: 2009))
        #expect(year.filesDownloaded == 1)
        #expect(fx.driveFiles().contains("\(phone)/a.jpg"))
        #expect(!fx.driveFiles().contains("\(phone)/b.jpg"))
    }

    // MARK: Integrity

    @Test func aWrongChecksumIsRetriedAndThenSucceeds() async throws {
        let item = file("N1", "a.jpg", size: 4000)
        let fx = try DownloadFixture(files: [item])
        let wrong = bytes(4000, seed: 99)
        fx.overrideStorage { _, count in count == 0 ? .body(wrong) : nil }
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 1 && summary.filesFailed == 0)
        #expect(fx.contents("\(phone)/a.jpg") == item.data)
        #expect(fx.server.requests(host: fx.storageHost).count == 2)
        #expect(try fx.job("N1")?.attempts == 1)
        // The bytes of the bad try do not count as downloaded.
        #expect(summary.bytesDownloaded == 4000)
    }

    @Test func aChecksumThatNeverMatchesFailsWithoutLeavingAFile() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg", size: 4000)])
        let wrong = bytes(4000, seed: 99)
        fx.overrideStorage { _, _ in .body(wrong) }
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 0 && summary.filesFailed == 1)
        #expect(fx.server.requests(host: fx.storageHost).count == 3)  // three tries in one run
        #expect(fx.driveFiles().isEmpty)  // not the target, not a .rainbarrel-part file
        let job = try #require(try fx.job("N1"))
        #expect(job.status == .failed && job.attempts == 3)
        #expect(job.lastError?.hasPrefix("MD5 mismatch: expected ") == true)
        // Not recorded as backed up.
        #expect(try fx.store().driveFileCount() == 0)
        #expect(summary.results.first?.outcome == .failed)
        // The next run tries again (attempts are left), and only up to the maximum.
        fx.clock.advance(60)
        let second = try await fx.run()
        #expect(second.filesFailed == 1)
        #expect(try fx.job("N1")?.attempts == 5)
        fx.clock.advance(60)
        let third = try await fx.run()
        #expect(third.filesFailed == 0 && third.filesDownloaded == 0)
        #expect(fx.server.requests(host: fx.storageHost).count == 5)
    }

    @Test func aWrongSizeFailsEvenWhenTheDataIsTruncated() async throws {
        let fx = try DownloadFixture(files: [file("N1", "short.jpg", size: 4000), file("N2", "long.jpg", size: 4000, seed: 2)])
        fx.overrideStorage { id, _ in
            id == "N1" ? .body(bytes(3999, seed: 1)) : .body(bytes(4000, seed: 2) + Data([7]))
        }
        let summary = try await fx.run()
        #expect(summary.filesFailed == 2 && summary.filesDownloaded == 0)
        #expect(fx.driveFiles().isEmpty)
        #expect(try fx.job("N1")?.lastError == "Size mismatch: expected 4000 bytes, received 3999")
        // A body that grows past the expected size is cut off, so a runaway answer cannot fill the drive.
        #expect(try fx.job("N2")?.lastError?.hasPrefix("Size mismatch: expected 4000 bytes, received ") == true)
    }

    @Test func aSignInPageWithStatus200IsNotTakenForTheFile() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideStorage { _, _ in .body(Data("<html>sign in</html>".utf8), headers: ["Content-Type": "text/html; charset=utf-8"]) }
        // The session check is refused too, so the page really was a sign-in page.
        fx.overrideListing { _ in .body(Data(), status: 401) }
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.stopReason == .sessionExpired)
        #expect(fx.driveFiles().isEmpty)
        #expect(try fx.job("N1")?.status == .pending)
    }

    @Test func aWebPageForOneFileFailsThatFileAfterASessionCheckAndTheRunGoesOn() async throws {
        let fx = try DownloadFixture(files: [
            file("N1", "a.jpg", seed: 1, takenAt: t2020), file("N2", "b.jpg", seed: 2, takenAt: t2019),
            file("N3", "c.jpg", seed: 3, takenAt: t2015),
        ])
        fx.overrideStorage { id, _ in
            id == "N2" ? .body(Data("<html>nothing here</html>".utf8), headers: ["Content-Type": "text/html"]) : nil
        }
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.stopReason == nil)
        #expect(summary.filesDownloaded == 2 && summary.filesFailed == 1)
        #expect(fx.listingRequests.count == 1)
        let job = try #require(try fx.job("N2"))
        #expect(job.lastError == "Amazon answered with a web page instead of the file")
        #expect(job.attempts == 1)
        #expect(try fx.job("N1")?.status == .done && fx.job("N3")?.status == .done)
        #expect(fx.driveFiles().count == 2)
    }

    @Test func a401ForOneFileFailsThatFileAfterASessionCheckAndTheRunGoesOn() async throws {
        let fx = try DownloadFixture(files: [
            file("N1", "a.jpg", seed: 1, takenAt: t2020), file("N2", "b.jpg", seed: 2, takenAt: t2019),
            file("N3", "c.jpg", seed: 3, takenAt: t2015),
        ])
        fx.overrideContent { id, _ in id == "N2" ? .body(Data(), status: 401) : nil }
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.stopReason == nil)
        #expect(summary.filesDownloaded == 2 && summary.filesFailed == 1)
        let job = try #require(try fx.job("N2"))
        #expect(job.lastError == "Amazon refused this file (HTTP 401)")
        #expect(job.attempts == 1)
        #expect(try fx.job("N1")?.status == .done && fx.job("N3")?.status == .done)
    }

    @Test func aFileWhoseContentIsHTMLDownloadsEvenWithoutAnHTMLName() async throws {
        let page = TestFile(nodeId: "H1", name: "catalog.pdf", data: Data("<html>telerilevamento</html>".utf8), folder: "F-DOCS")
        let fx = try DownloadFixture(files: [page])
        fx.overrideStorage { _, _ in .body(page.data, headers: ["Content-Type": "text/html; charset=utf-8"]) }
        let summary = try await fx.run()
        #expect(summary.stopReason == nil && summary.filesDownloaded == 1 && summary.filesFailed == 0)
        #expect(fx.contents("Amazon Drive/Docs/catalog.pdf") == page.data)
        #expect(fx.listingRequests.isEmpty)
    }

    @Test func anHTMLFileMayLegitimatelyComeAsHTML() async throws {
        let page = TestFile(nodeId: "H1", name: "notes.html", data: Data("<html>notes</html>".utf8), folder: "F-DOCS")
        let fx = try DownloadFixture(files: [page])
        fx.overrideStorage { _, _ in .body(page.data, headers: ["Content-Type": "text/html"]) }
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 1)
        #expect(fx.contents("Amazon Drive/Docs/notes.html") == page.data)
    }

    @Test func aMissingFileOnAmazonFailsForGoodAndIsNotRetried() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideStorage { _, _ in .body(Data(), status: 404) }
        let summary = try await fx.run()
        #expect(summary.filesFailed == 1)
        let job = try #require(try fx.job("N1"))
        #expect(job.status == .failed && job.attempts >= 5 && job.lastError == "Amazon answered HTTP 404")
        fx.clock.advance(60)
        _ = try await fx.run()
        #expect(fx.server.requests(host: fx.storageHost).count == 1)
    }

    // MARK: Session

    @Test func anExpiredSessionStopsTheRunAndIsNeverRetried() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg", seed: 1, takenAt: t2020), file("N2", "b.jpg", seed: 2)])
        fx.overrideContent { _, _ in .body(Data(#"{"message":"No Auth Method Provided"}"#.utf8), status: 401) }
        fx.overrideListing { _ in .body(Data(), status: 401) }  // the session check agrees
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.stopReason == .sessionExpired)
        #expect(summary.stopReason?.description == "Amazon session expired: sign in again")
        #expect(contentRequests(fx).count == 1)  // one request, no retry, the second file is not tried
        #expect(fx.driveFiles().isEmpty)
        let jobs = try fx.jobs()
        #expect(jobs.map(\.status) == [.pending, .pending] && jobs.map(\.attempts) == [0, 0])
    }

    @Test func a403CountsAsAnExpiredSessionWhenTheSessionCheckIsRefusedToo() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideContent { _, _ in .body(Data(), status: 403) }
        fx.overrideListing { _ in .body(Data(), status: 403) }
        #expect(try await fx.run().stopReason == .sessionExpired)
    }

    @Test func aSessionThatFailsTheFirstCheckStopsBeforeAnyDownload() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        let stale = StoredSession(host: fx.host, cookies: [SessionCookie(name: "session-id", value: "old-session-value", domain: ".amazon.com")])
        await #expect(throws: DownloadError.sessionExpired) { try await fx.run(session: stale) }
        #expect(contentRequests(fx).isEmpty)
        #expect(try fx.job("N1")?.status == .pending)
    }

    @Test func aSessionWithoutSessionIdCannotStart() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        let bad = StoredSession(host: fx.host, cookies: [SessionCookie(name: "other", value: "abcdefgh", domain: ".amazon.com")])
        await #expect(throws: DownloadError.self) { try await fx.run(session: bad) }
        #expect(fx.server.requests.isEmpty)
    }

    // MARK: Backoff

    @Test func tooManyRequestsWaitForRetryAfterOnTheInjectedClock() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideContent { _, count in count == 0 ? .body(Data(), status: 429, headers: ["Retry-After": "30"]) : nil }
        let started = Date()
        let summary = try await fx.run()
        #expect(Date().timeIntervalSince(started) < 5)  // the 30 seconds were not really waited
        #expect(summary.filesDownloaded == 1 && summary.filesFailed == 0)
        #expect(fx.clock.sleeps.contains { abs($0 - 30) < 0.001 })
        #expect(fx.clock.now.timeIntervalSince(noonOct16) >= 30)
        #expect(try fx.job("N1")?.attempts == 0)  // throttling does not use up a try
    }

    @Test func fiveThrottleAnswersInARowPauseTheRunForFifteenMinutes() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideContent { _, count in count < 5 ? .body(Data(), status: 503) : nil }
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.filesDownloaded == 1)
        let waits = fx.clock.sleeps.filter { $0 > 4 }
        #expect(waits == [5, 10, 20, 40, 900])
        #expect(contentRequests(fx).count == 6)
    }

    @Test func aBatchStopsInsteadOfPausingWhenAskedTo() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideContent { _, _ in .body(Data(), status: 503) }
        let summary = try await fx.run(DownloadOptions(concurrency: 1, maxLongPauses: 0))
        #expect(summary.stopReason == .throttled)
        #expect(try fx.job("N1")?.status == .pending)
        #expect(!fx.clock.sleeps.contains(900))  // it stops where it would have waited a quarter of an hour
    }

    @Test func networkErrorsBackOffAndThenSucceed() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        fx.overrideStorage { _, count in count < 2 ? .fail(.networkConnectionLost) : nil }
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.filesDownloaded == 1)
        #expect(fx.clock.sleeps.filter { $0 > 4 } == [5, 10])
        #expect(try fx.job("N1")?.attempts == 0)
    }

    @Test func requestsAreSpacedByTheRateLimit() async throws {
        var throttle = ThrottleConfig(maxConcurrentDownloads: 1, maxRequestsPerMinute: 6, minFreeSpaceGB: 0)
        throttle.pauseBetweenFilesMs = 0
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1), file("B", "b.jpg", seed: 2), file("C", "c.jpg", seed: 3)], throttle: throttle)
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 3)
        // Four calls (the session check and three downloads) at one call per ten seconds, burst of one.
        #expect(abs(fx.clock.now.timeIntervalSince(noonOct16) - 30) < 0.5)
    }

    @Test func thePauseBetweenFilesIsTaken() async throws {
        let throttle = ThrottleConfig(maxConcurrentDownloads: 1, pauseBetweenFilesMs: 250, minFreeSpaceGB: 0)
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1), file("B", "b.jpg", seed: 2)], throttle: throttle)
        _ = try await fx.run()
        #expect(fx.clock.sleeps.filter { abs($0 - 0.25) < 0.001 }.count == 2)
    }

    // MARK: Existing files

    @Test func anIdenticalExistingFileIsAdoptedNotDownloadedAgain() async throws {
        let item = file("N1", "IMG_0001.jpg", size: 4000)
        let fx = try DownloadFixture(files: [item])
        let path = fx.driveFile("\(phone)/IMG_0001.jpg")
        try FileManager.default.createDirectory(atPath: fx.driveFile(phone), withIntermediateDirectories: true)
        try item.data.write(to: URL(fileURLWithPath: path))
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let summary = try await fx.run()
        #expect(summary.filesAdopted == 1 && summary.filesDownloaded == 0)
        #expect(contentRequests(fx).isEmpty)
        #expect(fx.driveFiles() == ["\(phone)/IMG_0001.jpg"])
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == before)
        let row = try #require(try fx.store().driveFile(relPath: "\(phone)/IMG_0001.jpg"))
        #expect(row.md5 == item.md5)
        #expect(try fx.job("N1")?.status == .done)
        #expect(summary.results.first?.outcome == .adopted)
    }

    @Test func aDifferentExistingFileIsKeptAndTheNewOneGetsANumberedName() async throws {
        let item = file("N1", "IMG_0001.jpg", size: 4000)
        let fx = try DownloadFixture(files: [item])
        let existing = bytes(4000, seed: 77)  // same size, other content
        try FileManager.default.createDirectory(atPath: fx.driveFile(phone), withIntermediateDirectories: true)
        try existing.write(to: URL(fileURLWithPath: fx.driveFile("\(phone)/IMG_0001.jpg")))
        try Data("x".utf8).write(to: URL(fileURLWithPath: fx.driveFile("\(phone)/IMG_0001 (2).jpg")))
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 1)
        #expect(fx.contents("\(phone)/IMG_0001.jpg") == existing)       // untouched
        #expect(fx.contents("\(phone)/IMG_0001 (2).jpg") == Data("x".utf8))  // untouched
        #expect(fx.contents("\(phone)/IMG_0001 (3).jpg") == item.data)
        #expect(try fx.job("N1")?.targetRelPath == "\(phone)/IMG_0001 (3).jpg")
        #expect(try fx.store().driveFile(relPath: "\(phone)/IMG_0001 (3).jpg")?.md5 == item.md5)
    }

    @Test func twoCloudFilesWithTheSameNameNeverOverwriteEachOther() async throws {
        let a = file("A", "IMG_0001.jpg", size: 5000, seed: 1)
        let b = file("B", "IMG_0001.jpg", size: 5000, seed: 2)
        let fx = try DownloadFixture(files: [a, b])
        fx.server.responseDelay = 0.05  // both downloads are in flight together
        let summary = try await fx.run(DownloadOptions(concurrency: 2))
        #expect(summary.filesDownloaded == 2)
        let one = fx.contents("\(phone)/IMG_0001.jpg")
        let two = fx.contents("\(phone)/IMG_0001 (2).jpg")
        #expect(Set([one, two].compactMap { $0 }) == Set([a.data, b.data]))
        #expect(fx.driveFiles().count == 2)
        #expect(fx.server.maxConcurrentRequests == 2)
    }

    @Test func nothingIsEverDeletedExceptOurOwnTemporaryFiles() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        try FileManager.default.createDirectory(atPath: fx.driveFile(phone), withIntermediateDirectories: true)
        let keepers = ["keep.txt", ".hidden", "notes.rainbarrel-part.txt", ".x.rainbarrel-part.bak", "a (2).jpg"]
        for name in keepers { try Data(name.utf8).write(to: URL(fileURLWithPath: fx.driveFile("\(phone)/\(name)"))) }
        try Data("old".utf8).write(to: URL(fileURLWithPath: fx.driveFile("Amazon Drive/readme.txt")))
        _ = try await fx.run()
        for name in keepers { #expect(fx.contents("\(phone)/\(name)") == Data(name.utf8), "\(name)") }
        #expect(fx.contents("Amazon Drive/readme.txt") == Data("old".utf8))
    }

    // MARK: Crash recovery

    @Test func leftoverTemporaryFilesAreCleanedAndInterruptedJobsRunAgain() async throws {
        let crashed = file("N1", "IMG_0001.jpg", takenAt: t2019)
        let other = file("N2", "doc.pdf", seed: 5, folder: "F-DOCS", takenAt: t2015)
        let fx = try DownloadFixture(files: [crashed, other])
        // Simulate a crash: N1 was downloading, its temporary file is left behind, as is an old one elsewhere.
        let table = DownloadJobTable(source: try fx.store(), queue: try fx.store(), config: fx.config)
        _ = try table.sync(includeLiveVideos: true, now: Date())
        try table.setStatus(nodeId: "N1", status: .downloading, attempts: 1, now: Date())
        try FileManager.default.createDirectory(atPath: fx.driveFile(phone), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: fx.driveFile("Amazon Drive/Pictures/Elsewhere"), withIntermediateDirectories: true)
        try Data("half".utf8).write(to: URL(fileURLWithPath: fx.driveFile("\(phone)/.IMG_0001.jpg.rainbarrel-part")))
        try Data("old".utf8).write(to: URL(fileURLWithPath: fx.driveFile("Amazon Drive/Pictures/Elsewhere/.zzz.rainbarrel-part")))
        try Data("mine".utf8).write(to: URL(fileURLWithPath: fx.driveFile("\(phone)/keep.txt")))

        // A run that does not even reach N1 (other year) still clears the folder where it was writing.
        let first = try await fx.run(DownloadOptions(year: 2015))
        #expect(first.filesDownloaded == 1)
        #expect(fx.contents("\(phone)/.IMG_0001.jpg.rainbarrel-part") == nil)
        #expect(fx.contents("Amazon Drive/Pictures/Elsewhere/.zzz.rainbarrel-part") != nil)  // not a folder this run used
        #expect(try fx.job("N1")?.status == .pending)  // the interrupted job is waiting again

        let second = try await fx.run()
        #expect(second.filesDownloaded == 1)
        #expect(fx.contents("\(phone)/IMG_0001.jpg") == crashed.data)
        #expect(fx.contents("\(phone)/keep.txt") == Data("mine".utf8))
        #expect(try fx.job("N1")?.status == .done)
    }

    @Test func aTemporaryFileInTheFolderOfAFileThatIsDownloadedIsRemovedFirst() async throws {
        let fx = try DownloadFixture(files: [file("N1", "IMG_0001.jpg")])
        try FileManager.default.createDirectory(atPath: fx.driveFile(phone), withIntermediateDirectories: true)
        try Data("half".utf8).write(to: URL(fileURLWithPath: fx.driveFile("\(phone)/.IMG_0001.jpg.rainbarrel-part")))
        try Data("half".utf8).write(to: URL(fileURLWithPath: fx.driveFile("\(phone)/.unrelated.rainbarrel-part")))
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 1)
        #expect(fx.driveFiles() == ["\(phone)/IMG_0001.jpg"])
    }

    // MARK: Paths

    @Test func hostileCloudNamesCannotWriteOutsideTheDriveFolder() async throws {
        let folders = testFolders + [
            CloudFolder(nodeId: "F-DOTS", name: "..", parentId: "ROOT"),
            CloudFolder(nodeId: "F-SLASH", name: "../../x/y", parentId: "F-DOTS"),
        ]
        let evil = file("N1", "../../evil.jpg", folder: "F-SLASH")
        let fx = try DownloadFixture(files: [evil], folders: folders)
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 1)
        let written = fx.driveFiles()
        #expect(written.count == 1)
        #expect(written[0].hasPrefix("Amazon Drive/"))
        #expect(!written[0].contains(".."+"/") && !written[0].split(separator: "/").contains(".."))
        // Nothing appeared next to the drive folder.
        let parent = fx.drive.url.deletingLastPathComponent().path
        #expect(!FileManager.default.fileExists(atPath: parent + "/evil.jpg"))
        #expect(!FileManager.default.fileExists(atPath: parent + "/x"))
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: fx.drive.path)) == ["Amazon Drive"])
    }

    @Test func aLivePhotoVideoLandsBesideItsPhotoWithAnUnusedName() async throws {
        let photo = file("P1", "IMG_0004.HEIC", seed: 4, ext: "heic")
        let video = file("L1", "2019-06-18_04-02-57_002_lpv", seed: 5, kind: .liveVideo, parent: "P1", ext: "qt")
        let fx = try DownloadFixture(files: [photo, video])
        try FileManager.default.createDirectory(atPath: fx.driveFile(phone), withIntermediateDirectories: true)
        try Data("another clip".utf8).write(to: URL(fileURLWithPath: fx.driveFile("\(phone)/IMG_0004.MOV")))
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 2)
        #expect(fx.contents("\(phone)/IMG_0004.HEIC") == photo.data)
        #expect(fx.contents("\(phone)/IMG_0004.MOV") == Data("another clip".utf8))
        #expect(fx.contents("\(phone)/IMG_0004 (2).MOV") == video.data)
    }

    @Test func liveVideosCanBeLeftOut() async throws {
        let photo = file("P1", "IMG_0004.HEIC", seed: 4)
        let video = file("L1", "x_lpv", seed: 5, kind: .liveVideo, parent: "P1")
        let fx = try DownloadFixture(files: [photo, video])
        let summary = try await fx.run(DownloadOptions(includeLiveVideos: false))
        #expect(summary.filesDownloaded == 1)
        #expect(fx.driveFiles() == ["\(phone)/IMG_0004.HEIC"])
    }

    @Test func filesWithoutAFolderGoToUnsorted() async throws {
        let fx = try DownloadFixture(files: [file("N1", "lost.jpg", folder: "NO-SUCH-FOLDER", takenAt: t2015)])
        _ = try await fx.run()
        #expect(fx.driveFiles() == ["Amazon Drive/_Unsorted/2015/03/lost.jpg"])
    }

    // MARK: Dedupe

    @Test func identicalContentIsDownloadedOnce() async throws {
        let one = file("A", "a.jpg", seed: 9)
        let fx = try DownloadFixture(files: [
            one, file("B", "b.jpg", seed: 9, folder: "F-DOCS", takenAt: t2015), file("C", "c.jpg", seed: 9, folder: "F-PICS", takenAt: t2009),
            file("D", "d.jpg", seed: 3, takenAt: t2020),
        ])
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.filesDownloaded == 2)  // D and one of the three identical files (the newest, A)
        #expect(summary.filesSkipped == 2)
        #expect(fx.driveFiles() == ["\(phone)/a.jpg", "\(phone)/d.jpg"])
        #expect(contentRequests(fx).count == 2)
        let statuses = Dictionary(uniqueKeysWithValues: try fx.jobs().map { ($0.nodeId, $0.status) })
        #expect(statuses == ["A": .done, "B": .skipped, "C": .skipped, "D": .done])
        // Once the content is on the drive, the duplicates are not candidates any more.
        #expect(try await fx.run().filesDownloaded == 0)
    }

    @Test func contentThatIsAlreadyOnTheDriveIsNotDownloaded() async throws {
        let item = file("A", "a.jpg", seed: 9)
        let fx = try DownloadFixture(files: [item])
        try fx.store().upsertDriveFile(DriveFileRecord(relPath: "Amazon Drive/other name.jpg", size: 3000, mtime: 1, md5: item.md5, hashedAt: 1))
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 0)
        #expect(fx.server.requests.isEmpty)
    }

    // MARK: Target checks

    @Test(.enabled(if: getuid() != 0, "file permissions are not enforced for root, e.g. in CI containers"))
    func aReadOnlyTargetIsRefusedBeforeAnyNetworkCall() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        let folder = fx.driveFile("Amazon Drive")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        do {
            _ = try await fx.run()
            Issue.record("a read-only target was accepted")
        } catch let error as DownloadError {
            guard case .targetNotWritable(_, let detail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(detail == nil)
            #expect(error.description == "The backup drive is read-only (for example NTFS on macOS). Reformat it as APFS or exFAT, or choose another folder.")
        }
        #expect(fx.server.requests.isEmpty)
        #expect(fx.driveFiles().isEmpty)  // not even the probe file is left
        #expect(try fx.store().database.scalarInt64("SELECT COUNT(*) FROM download_jobs") == 0)
    }

    @Test func theReadOnlyAndOtherErrorMessagesAreWordedForPeople() {
        let readOnly = DownloadError.targetNotWritable(path: "/Volumes/X/Amazon Drive", detail: nil)
        #expect(readOnly.description == "The backup drive is read-only (for example NTFS on macOS). Reformat it as APFS or exFAT, or choose another folder.")
        #expect(DownloadError.targetNotWritable(path: "/x", detail: "No space left on device").description == "Cannot write to /x: No space left on device")
        #expect(DownloadError.driveNotMounted("/Volumes/X").description.hasPrefix("The backup drive is not mounted: /Volumes/X"))
        #expect(DownloadError.notSignedIn.description.contains("rainbarrel auth import"))
        #expect(DownloadError.sessionExpired.description == "Amazon session expired: sign in again")
    }

    @Test func aMissingDriveIsReportedAsNotMounted() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        var config = fx.config
        config.driveRoot = fx.home.path("no-such-drive")
        await #expect(throws: DownloadError.self) {
            try await fx.engine.run(config: config, session: fx.session, options: DownloadOptions())
        }
        #expect(fx.server.requests.isEmpty)
        var none = fx.config
        none.driveRoot = nil
        await #expect(throws: DownloadError.noDriveConfigured) {
            try await fx.engine.run(config: none, session: fx.session, options: DownloadOptions())
        }
    }

    @Test func theProbeFileIsRemoved() throws {
        let fx = try DownloadFixture(files: [])
        try DownloadEngine.prepareTarget(config: fx.config)
        #expect(fx.driveFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fx.driveFile("Amazon Drive")))
    }

    @Test func theScanFolderIsCreatedWhenTheDriveIsThere() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        try FileManager.default.removeItem(atPath: fx.driveFile("Amazon Drive"))
        _ = try await fx.run()
        #expect(fx.driveFiles() == ["\(phone)/a.jpg"])
    }

    @Test func driveDisappearingMidRunStopsCleanlyAndKeepsTheJobPending() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1, takenAt: t2020), file("B", "b.jpg", seed: 2)])
        let drivePath = fx.drive.path
        fx.overrideStorage { _, count in
            if count == 0 { try? FileManager.default.removeItem(atPath: drivePath) }  // the drive is pulled out
            return nil
        }
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.stopReason == .driveUnavailable)
        #expect(summary.filesFailed == 0 && summary.filesDownloaded == 0)
        let jobs = try fx.jobs()
        #expect(jobs.map(\.status) == [.pending, .pending] && jobs.map(\.attempts) == [0, 0])
    }

    @Test func aRunLockKeepsTwoRunsApart() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")])
        let lock = try #require(try RunLock(path: fx.paths.downloadLockURL.path))
        await #expect(throws: DownloadError.alreadyRunning) { try await fx.run() }
        #expect(fx.server.requests.isEmpty)
        lock.release()
        #expect(try await fx.run().filesDownloaded == 1)
    }

    // MARK: Limits

    @Test func aFileThatWouldLeaveTooLittleSpaceIsNotStarted() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg", size: 5000)])
        fx.freeSpace = { _ in 4_000 }
        let summary = try await fx.run()
        #expect(summary.stopReason == .lowDiskSpace)
        #expect(contentRequests(fx).isEmpty)
        #expect(try fx.job("N1")?.status == .pending)

        // With a reserve: 1,000,000 free minus a 200,000 file leaves 800,000, below the 900,000 to keep.
        var throttle = ThrottleConfig(minFreeSpaceGB: 0.0009)
        throttle.maxConcurrentDownloads = 1
        let strict = try DownloadFixture(files: [file("N1", "a.jpg", size: 200_000)], throttle: throttle)
        strict.freeSpace = { _ in 1_000_000 }
        #expect(try await strict.run().stopReason == .lowDiskSpace)
        strict.freeSpace = { _ in 2_000_000 }
        #expect(try await strict.run().filesDownloaded == 1)
    }

    @Test func spaceIsReservedForFilesThatAreStillComingIn() async throws {
        let throttle = ThrottleConfig(maxConcurrentDownloads: 2, minFreeSpaceGB: 0)
        let fx = try DownloadFixture(files: [file("A", "a.jpg", size: 6000, seed: 1), file("B", "b.jpg", size: 6000, seed: 2)], throttle: throttle)
        fx.freeSpace = { _ in 10_000 }  // room for one of them
        fx.server.responseDelay = 0.05
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 1)
        #expect(summary.stopReason == .lowDiskSpace)
    }

    @Test func theDailyLimitStopsTheRunAndResetsAtMidnight() async throws {
        var throttle = ThrottleConfig(maxConcurrentDownloads: 1, dailyLimitGB: 0.00001, minFreeSpaceGB: 0)  // 10,000 bytes
        throttle.pauseBetweenFilesMs = 0
        let files = (1...3).map { file("N\($0)", "f\($0).jpg", size: 4096, seed: UInt8($0), takenAt: t2019 + Int64($0)) }
        let fx = try DownloadFixture(files: files, throttle: throttle)
        let first = try await fx.run()
        #expect(first.filesDownloaded == 2)
        #expect(first.stopReason == .dailyLimitReached)
        #expect(try fx.store().getMeta(MetaKey.downloadBytesPrefix + "2026-10-16") == "8192")
        #expect(try fx.jobs().filter { $0.status == .pending }.count == 1)

        fx.clock.advance(24 * 3600)  // the next day
        let second = try await fx.run()
        #expect(second.filesDownloaded == 1 && second.stopReason == nil)
        #expect(try fx.store().getMeta(MetaKey.downloadBytesPrefix + "2026-10-17") == "4096")
    }

    @Test func downloadsRespectTheConcurrencyCap() async throws {
        let files = (1...8).map { file("N\($0)", "f\($0).jpg", size: 2000, seed: UInt8($0), takenAt: t2019 + Int64($0)) }
        let fx = try DownloadFixture(files: files)  // default throttle: 2 at a time
        fx.server.responseDelay = 0.05
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 8)
        #expect(fx.server.maxConcurrentRequests == 2)

        let single = try DownloadFixture(files: files)
        single.server.responseDelay = 0.03
        _ = try await single.run(DownloadOptions(concurrency: 1))
        #expect(single.server.maxConcurrentRequests == 1)

        let wide = try DownloadFixture(files: files, throttle: ThrottleConfig(maxConcurrentDownloads: 4, minFreeSpaceGB: 0))
        wide.server.responseDelay = 0.05
        _ = try await wide.run()
        #expect((3...4).contains(wide.server.maxConcurrentRequests))
        // Values outside 1...8 in the file are forced into range.
        let crazy = try DownloadFixture(files: files, throttle: ThrottleConfig(maxConcurrentDownloads: 100, minFreeSpaceGB: 0))
        crazy.server.responseDelay = 0.05
        _ = try await crazy.run()
        #expect(crazy.server.maxConcurrentRequests <= 8)
    }

    // MARK: Active hours

    @Test func outsideTheActiveHoursARunCanStopImmediately() async throws {
        let throttle = ThrottleConfig(activeHours: "22:00-06:00", minFreeSpaceGB: 0)
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")], throttle: throttle)
        let summary = try await fx.run(DownloadOptions(hoursPolicy: .exit))
        #expect(summary.stopReason == .outsideActiveHours)
        #expect(fx.server.requests.isEmpty && fx.driveFiles().isEmpty)
    }

    @Test func outsideTheActiveHoursARunWaitsForTheWindow() async throws {
        let throttle = ThrottleConfig(activeHours: "22:00-06:00", minFreeSpaceGB: 0)
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")], throttle: throttle)
        let summary = try await fx.run()  // noon: ten hours until the window opens
        #expect(summary.filesDownloaded == 1)
        let opens = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 22))!
        #expect(fx.clock.now >= opens && fx.clock.now < opens.addingTimeInterval(120))
        #expect(fx.clock.sleeps.allSatisfy { $0 <= 60 })  // re-checked at least every minute
        #expect(fx.clock.sleeps.reduce(0, +) >= 10 * 3600 - 1)
    }

    @Test func ignoringTheHoursDownloadsAtOnce() async throws {
        let throttle = ThrottleConfig(activeHours: "22:00-06:00", minFreeSpaceGB: 0)
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")], throttle: throttle)
        let summary = try await fx.run(DownloadOptions(hoursPolicy: .ignore))
        #expect(summary.filesDownloaded == 1)
        #expect(fx.clock.now == noonOct16)
    }

    @Test func insideTheWindowThingsRunNormallyAcrossMidnight() async throws {
        let throttle = ThrottleConfig(activeHours: "22:00-06:00", minFreeSpaceGB: 0)
        let fx = try DownloadFixture(files: [file("N1", "a.jpg")], throttle: throttle)
        fx.clock.advance(11 * 3600 + 30 * 60)  // 23:30
        #expect(try await fx.run(DownloadOptions(hoursPolicy: .exit)).filesDownloaded == 1)
        let early = try DownloadFixture(files: [file("N1", "a.jpg")], throttle: throttle)
        early.clock.advance(14 * 3600 + 30 * 60)  // 02:30 the next day
        #expect(try await early.run(DownloadOptions(hoursPolicy: .exit)).filesDownloaded == 1)
    }

    // MARK: Redirects and secrecy

    @Test func aRedirectToAnotherHostIsRefusedAndNothingIsSentThere() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1), file("B", "b.jpg", seed: 2)])
        let evilHost = "evil-\(fx.host.replacingOccurrences(of: ".amazon.com", with: "")).example.org"
        let evil = StubServer(hosts: [evilHost])
        evil.handler = { _ in .body(bytes(3000, seed: 1)) }
        fx.overrideContent { id, _ in
            id == "A" ? .redirect(to: "https://\(evilHost)/files/A") : .redirect(to: "http://\(fx.storageHost)/files/B")
        }
        let summary = try await fx.run(DownloadOptions(concurrency: 1))
        #expect(summary.filesFailed == 2 && summary.filesDownloaded == 0)
        #expect(evil.requests.isEmpty)
        #expect(fx.server.requests(host: fx.storageHost).isEmpty)
        #expect(try fx.job("A")?.lastError == "Refused a redirect to \(evilHost), which is not an Amazon host")
        #expect(try fx.job("B")?.lastError == "Refused a redirect to a non-https address, which is not an Amazon host")
        #expect(fx.driveFiles().isEmpty)
    }

    @Test func secretsNeverAppearInResultsStoredErrorsOrProgress() async throws {
        let files = [
            file("MD5", "a.jpg", size: 3000, seed: 1), file("SIZE", "b.jpg", size: 3000, seed: 2),
            file("NET", "c.jpg", size: 3000, seed: 3), file("GONE", "d.jpg", size: 3000, seed: 4),
            file("REDIR", "e.jpg", size: 3000, seed: 5),
        ]
        let fx = try DownloadFixture(files: files)
        let leak = NSError(domain: "leak", code: 7, userInfo: [NSLocalizedDescriptionKey: "failed with \(fx.secretToken) and \(fx.sessionID)"])
        fx.overrideStorage { id, _ in
            switch id {
            case "MD5": return .body(bytes(3000, seed: 90))
            case "SIZE": return .body(bytes(10, seed: 1))
            case "NET": return .failWith(leak)
            case "GONE": return .body(Data(), status: 404)
            default: return nil
            }
        }
        fx.overrideContent { id, _ in id == "REDIR" ? .redirect(to: "https://elsewhere.example.org/x?token=\(fx.secretToken)") : nil }
        let log = ProgressLog()
        let summary = try await fx.engine.run(config: fx.config, session: fx.session, options: DownloadOptions(concurrency: 1)) { log.add($0) }
        #expect(summary.filesFailed == 5)
        var everything = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        everything += String(decoding: try JSONEncoder().encode(log.snapshots), as: UTF8.self)
        for job in try fx.jobs() { everything += "\(job.lastError ?? "")\n" }
        everything += "\(summary)\n\(fx.session)\n\(fx.session.cookies)"
        for error in [DownloadError.network("transport error"), .sessionExpired, .redirectRefused(host: "h"), .throttled(status: 429, retryAfter: 3)] {
            everything += error.description
        }
        #expect(!everything.contains(fx.secretToken))
        #expect(!everything.contains(fx.sessionID))
        #expect(!everything.contains("other-site-secret-9999"))
        #expect(try fx.job("NET")?.lastError?.hasPrefix("Network problem") == true)
    }

    // MARK: Cancellation and scratch runs

    @Test func cancellingStopsCleanlyAndKeepsTheQueue() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1, takenAt: t2020), file("B", "b.jpg", seed: 2)])
        fx.overrideStorage { _, _ in .hang }
        let log = ProgressLog()
        let engine = fx.engine
        let (config, session) = (fx.config, fx.session)
        let task = Task { try await engine.run(config: config, session: session, options: DownloadOptions(concurrency: 1)) { log.add($0) } }
        let started = await waitUntil { !fx.server.requests(host: fx.storageHost).isEmpty }
        #expect(started)
        task.cancel()
        let summary = try await task.value
        #expect(summary.stopReason == .cancelled)
        #expect(log.snapshots.last?.state == .paused)
        #expect(fx.driveFiles().isEmpty)  // the partial file is gone
        let jobs = try fx.jobs()
        #expect(jobs.map(\.status) == [.pending, .pending] && jobs.map(\.attempts) == [0, 0])
        // And the next run simply continues.
        fx.overrideStorage { _, _ in nil }
        #expect(try await fx.run().filesDownloaded == 2)
    }

    @Test func aScratchRunWritesElsewhereAndRecordsNothing() async throws {
        let item = file("N1", "a.jpg")
        let fx = try DownloadFixture(files: [item])
        let scratch = try TempDirectory()
        let summary = try await fx.run(DownloadOptions(targetRoot: scratch.path))
        #expect(summary.filesDownloaded == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.path("\(phone)/a.jpg"))) == item.data)
        #expect(fx.driveFiles().isEmpty)
        let store = try fx.store()
        #expect(try store.driveFileCount() == 0)
        #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM download_jobs") == 0)
        #expect(try store.getMeta(MetaKey.downloadLastRun) == nil)
        #expect(!FileManager.default.fileExists(atPath: fx.paths.downloadLockURL.path))
        // Still online-only as far as the reconciler is concerned.
        let report = try Reconciler(store: store, scope: try DriveScope(scanSubpath: "Amazon Drive")).report(driveRoot: fx.drive.path)
        #expect(report.onlineOnly.count == 1)
    }

    @Test func theLastRunIsStoredForTheStatusCommand() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg", size: 1234)])
        _ = try await fx.run()
        let text = try #require(try fx.store().getMeta(MetaKey.downloadLastRun))
        let record = try JSONDecoder.iso8601.decode(DownloadRunRecord.self, from: Data(text.utf8))
        #expect(record.summary.filesDownloaded == 1 && record.summary.bytesDownloaded == 1234)
        #expect(record.summary.results.isEmpty)
    }
}
