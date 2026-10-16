import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Download tools: status and batch")
struct DownloadToolsTests {
    private func file(_ id: String, _ name: String, seed: UInt8, takenAt: Int64 = t2019, folder: String? = "F-PHONE") -> TestFile {
        TestFile(nodeId: id, name: name, data: bytes(2000, seed: seed), folder: folder, takenAt: takenAt)
    }

    private func tools(_ fx: DownloadFixture, session: StoredSession?, catalog: StaticCatalog? = nil) throws -> RainbarrelTools {
        let source = catalog ?? StaticCatalog(items: [])
        let tools = RainbarrelTools(
            paths: fx.paths, catalogSource: { _ in source }, sessionStore: MemorySessionStore(session),
            downloadEnvironment: fx.environment)
        try tools.saveConfig(fx.config)
        return tools
    }

    private func decode<T: Decodable>(_ type: T.Type, _ outcome: ToolCallOutcome) throws -> T {
        #expect(!outcome.isError, "\(outcome.text)")
        return try JSONDecoder.iso8601.decode(T.self, from: Data(outcome.text.utf8))
    }

    // MARK: Definitions

    @Test func toolDefinitionsDescribeTheDownloadTools() throws {
        let status = try #require(RainbarrelToolRegistry.definitions.first { $0.name == "download_status" })
        let batch = try #require(RainbarrelToolRegistry.definitions.first { $0.name == "download_batch" })
        #expect(status.readOnly && !batch.readOnly)
        guard case .object(let schema) = batch.inputSchema, case .object(let properties)? = schema["properties"],
              case .object(let limit)? = properties["limit"] else {
            Issue.record("download_batch has no limit property")
            return
        }
        #expect(limit["maximum"] == .int(50) && limit["default"] == .int(10) && limit["minimum"] == .int(1))
        #expect(Set(properties.keys) == ["limit", "year"])
        #expect(schema["additionalProperties"] == .bool(false))
        let sync = try #require(RainbarrelToolRegistry.definitions.first { $0.name == "sync_status" })
        #expect(sync.description.contains("download_batch"))
        #expect((try? JSONEncoder().encode(batch.inputSchema)) != nil)
    }

    // MARK: download_status

    @Test func statusOfAFreshSetupIsReadableAndChangesNothing() throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1)])
        let tools = try tools(fx, session: nil)
        let registry = RainbarrelToolRegistry(tools: tools)
        let report = try decode(DownloadStatusReport.self, registry.call(name: "download_status", arguments: nil))
        #expect(report.queue.pending == 0 && report.queue.notQueued == 1)
        #expect(!report.session.signedIn && report.session.cookieCount == 0 && report.session.storage == "memory")
        #expect(report.throttle == ThrottleConfig(minFreeSpaceGB: 0))
        #expect(report.amazonHost == fx.host)
        #expect(report.driveMounted && report.driveWritable == true)
        #expect(report.targetFolder == fx.drive.path + "/Amazon Drive")
        #expect(report.lastRun == nil && report.failures.isEmpty)
        #expect(fx.driveFiles().isEmpty)  // no probe file: the check does not write
        #expect(fx.server.requests.isEmpty)
    }

    @Test func statusShowsTheSessionWithoutItsValues() throws {
        let fx = try DownloadFixture(files: [])
        let tools = try tools(fx, session: fx.session)
        let outcome = RainbarrelToolRegistry(tools: tools).call(name: "download_status", arguments: nil)
        let report = try decode(DownloadStatusReport.self, outcome)
        #expect(report.session.signedIn && report.session.usable && report.session.cookieCount == 3)
        #expect(report.session.host == fx.host)
        #expect(!outcome.text.contains(fx.sessionID) && !outcome.text.contains(fx.secretToken))
    }

    @Test func statusNotesAnUnusableSessionAndAnUnreadableOne() throws {
        let fx = try DownloadFixture(files: [])
        let expired = StoredSession(host: fx.host, cookies: [SessionCookie(name: "session-id", value: "abc-123456", domain: ".amazon.com", expiresAt: Date(timeIntervalSince1970: 1000))])
        #expect(try tools(fx, session: expired).sessionInfo().usable == false)
        // A session file that others can read is reported as a problem, not used.
        let insecure = RainbarrelTools(
            paths: fx.paths, catalogSource: { _ in StaticCatalog(items: []) },
            sessionStore: FileSessionStore(url: fx.paths.sessionURL), downloadEnvironment: fx.environment)
        try FileSessionStore(url: fx.paths.sessionURL).save(fx.session)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fx.paths.sessionURL.path)
        let info = insecure.sessionInfo()
        #expect(!info.signedIn && info.problem?.contains("permissions") == true)
    }

    @Test func statusReportsTheQueueAndTheLastBatch() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1), file("B", "b.jpg", seed: 2)])
        fx.overrideStorage { id, _ in id == "B" ? .body(Data(), status: 404) : nil }
        let tools = try tools(fx, session: fx.session)
        let outcome = await RainbarrelToolRegistry(tools: tools).callAsync(name: "download_batch", arguments: nil)
        #expect(!outcome.isError, "\(outcome.text)")
        let report = try tools.downloadStatus()
        #expect(report.queue.done == 1 && report.queue.failed == 1 && report.queue.pending == 0)
        #expect(report.failures.map(\.nodeId) == ["B"] && report.failures[0].reason == "Amazon answered HTTP 404")
        let last = try #require(report.lastRun)
        #expect(last.summary.filesDownloaded == 1 && last.summary.filesFailed == 1)
    }

    // MARK: download_batch

    @Test func aBatchDownloadsAndReturnsOneEntryPerFile() async throws {
        let files = [file("A", "a.jpg", seed: 1, takenAt: t2020), file("B", "b.jpg", seed: 2, takenAt: t2019), file("C", "c.jpg", seed: 3, takenAt: t2015)]
        let fx = try DownloadFixture(files: files)
        let tools = try tools(fx, session: fx.session)
        let registry = RainbarrelToolRegistry(tools: tools)
        let outcome = await registry.callAsync(name: "download_batch", arguments: ["limit": .int(2)])
        let summary = try decode(DownloadSummary.self, outcome)
        #expect(summary.filesDownloaded == 2 && summary.stopReason == nil)
        #expect(summary.results.map(\.path).sorted() == ["Amazon Drive/Pictures/Phone/a.jpg", "Amazon Drive/Pictures/Phone/b.jpg"])  // the newest two
        #expect(fx.driveFiles().count == 2)
        // The year argument and the default limit work too.
        let year = await registry.callAsync(name: "download_batch", arguments: ["year": .int(2015)])
        #expect(try decode(DownloadSummary.self, year).filesDownloaded == 1)
    }

    @Test func aBatchWithoutASessionExplainsHowToSignIn() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1)])
        let outcome = await RainbarrelToolRegistry(tools: try tools(fx, session: nil)).callAsync(name: "download_batch", arguments: nil)
        #expect(outcome.isError)
        #expect(outcome.text.contains("Not signed in") && outcome.text.contains("rainbarrel auth import"))
        #expect(fx.server.requests.isEmpty)
    }

    @Test func aBatchWithAnExpiredSessionSaysSo() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1)])
        let expired = StoredSession(host: fx.host, cookies: [SessionCookie(name: "session-id", value: "abc-123456", domain: ".amazon.com", expiresAt: Date(timeIntervalSince1970: 1000))])
        let local = try tools(fx, session: expired)
        let outcome = await RainbarrelToolRegistry(tools: local).callAsync(name: "download_batch", arguments: nil)
        #expect(outcome.isError && outcome.text == "Amazon session expired: sign in again")
        // A session that Amazon rejects at the first request gives the same message.
        let rejected = StoredSession(host: fx.host, cookies: [SessionCookie(name: "session-id", value: "old-session-value", domain: ".amazon.com")])
        let outcome2 = await RainbarrelToolRegistry(tools: try tools(fx, session: rejected)).callAsync(name: "download_batch", arguments: nil)
        #expect(outcome2.isError && outcome2.text == "Amazon session expired: sign in again")
        #expect(fx.driveFiles().isEmpty)
    }

    @Test(.enabled(if: getuid() != 0, "file permissions are not enforced for root, e.g. in CI containers"))
    func aBatchOnAReadOnlyDriveIsRefusedWithoutNetworkAccess() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1)])
        let folder = fx.driveFile("Amazon Drive")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        let local = try tools(fx, session: fx.session)
        let outcome = await RainbarrelToolRegistry(tools: local).callAsync(name: "download_batch", arguments: nil)
        #expect(outcome.isError)
        #expect(outcome.text == "The backup drive is read-only (for example NTFS on macOS). Reformat it as APFS or exFAT, or choose another folder.")
        #expect(fx.server.requests.isEmpty)
        let status = try local.downloadStatus()
        #expect(status.driveWritable == false)
    }

    @Test func aBatchOutsideTheActiveHoursDoesNotWait() async throws {
        let throttle = ThrottleConfig(activeHours: "22:00-06:00", minFreeSpaceGB: 0)
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1)], throttle: throttle)
        let outcome = await RainbarrelToolRegistry(tools: try tools(fx, session: fx.session)).callAsync(name: "download_batch", arguments: nil)
        #expect(outcome.isError && outcome.text.contains("active hours"))
        #expect(fx.server.requests.isEmpty)
    }

    @Test func aBatchReadsTheFolderTreeFirstWhenTheCatalogHasNone() async throws {
        let item = file("A", "a.jpg", seed: 1)
        let fx = try DownloadFixture(files: [item], folders: [])  // an older catalog without folders
        let catalog = StaticCatalog(items: [item.item], folders: testFolders)
        let local = try tools(fx, session: fx.session, catalog: catalog)
        let outcome = await RainbarrelToolRegistry(tools: local).callAsync(name: "download_batch", arguments: nil)
        #expect(try decode(DownloadSummary.self, outcome).filesDownloaded == 1)
        #expect(fx.driveFiles() == ["Amazon Drive/Pictures/Phone/a.jpg"])
    }

    @Test func theSynchronousEntryPointWorksFromAThread() async throws {
        let fx = try DownloadFixture(files: [file("A", "a.jpg", seed: 1)])
        let registry = RainbarrelToolRegistry(tools: try tools(fx, session: fx.session))
        let outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: registry.call(name: "download_batch", arguments: nil))
            }
        }
        #expect(try decode(DownloadSummary.self, outcome).filesDownloaded == 1)
    }

    @Test func badArgumentsAreReported() async throws {
        let fx = try DownloadFixture(files: [])
        let registry = RainbarrelToolRegistry(tools: try tools(fx, session: fx.session))
        let outcome = await registry.callAsync(name: "download_batch", arguments: ["year": .string("soon")])
        #expect(outcome.isError && outcome.text.contains("year"))
        let range = await registry.callAsync(name: "download_batch", arguments: ["year": .int(0)])
        #expect(range.isError)
    }

    // MARK: HTTP client

    @Test func theClientReadsNodeMetadata() async throws {
        let item = file("N1", "a.jpg", seed: 1)
        let fx = try DownloadFixture(files: [item])
        let client = try AmazonClient(session: fx.session, host: fx.host, configuration: fx.environment.sessionConfiguration(), timeouts: fx.timeouts)
        defer { client.invalidate() }
        let metadata = try await client.fetchMetadata(nodeId: "N1")
        #expect(metadata.md5 == item.md5 && metadata.size == 2000)
        await #expect(throws: DownloadError.httpStatus(404)) { _ = try await client.fetchMetadata(nodeId: "missing") }
        let wrong = StoredSession(host: fx.host, cookies: [SessionCookie(name: "session-id", value: "not-the-id", domain: ".amazon.com")])
        let rejected = try AmazonClient(session: wrong, host: fx.host, configuration: fx.environment.sessionConfiguration(), timeouts: fx.timeouts)
        defer { rejected.invalidate() }
        await #expect(throws: DownloadError.sessionExpired) { _ = try await rejected.fetchMetadata(nodeId: "N1") }
    }

    @Test func aServerThatNeverAnswersTimesOut() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg", seed: 1)])
        fx.overrideContent { _, _ in .hang }
        let client = try AmazonClient(
            session: fx.session, host: fx.host, configuration: fx.environment.sessionConfiguration(),
            timeouts: AmazonClient.Timeouts(request: 0.4, stall: 0.4))
        defer { client.invalidate() }
        let started = Date()
        do {
            try await client.downloadContent(nodeId: "N1") { _ in 0 }
            Issue.record("a hanging request returned")
        } catch let error as DownloadError {
            guard case .network = error else {
            Issue.record("unexpected error \(error)")
            return
        }
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func cancellingARequestEndsItAtOnce() async throws {
        let fx = try DownloadFixture(files: [file("N1", "a.jpg", seed: 1)])
        fx.overrideContent { _, _ in .hang }
        let client = try AmazonClient(session: fx.session, host: fx.host, configuration: fx.environment.sessionConfiguration(), timeouts: AmazonClient.Timeouts(request: 30, stall: 30))
        defer { client.invalidate() }
        let task = Task { try await client.downloadContent(nodeId: "N1") { _ in 0 } }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func theClientRefusesBadHostsAndOtherSchemes() throws {
        let session = StoredSession(host: "x", cookies: [SessionCookie(name: "session-id", value: "abc-123456", domain: ".amazon.com")])
        #expect(throws: DownloadError.self) { _ = try AmazonClient(session: session, host: "localhost") }
        #expect(throws: DownloadError.self) { _ = try AmazonClient(session: session, host: "evil.com/path") }
        #expect(throws: DownloadError.self) { _ = try AmazonClient(session: StoredSession(host: "x", cookies: []), host: "www.amazon.com") }
    }
}
