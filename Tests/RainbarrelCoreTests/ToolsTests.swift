import Foundation
import Testing
@testable import RainbarrelCore

@Suite("RainbarrelTools and the MCP tool registry")
struct ToolsTests {
    private let catalog = [
        CloudItem(nodeId: "A1", kind: .file, name: "IMG_0001.jpg", md5: md5("1"), size: 5, takenAt: t2019),
        CloudItem(nodeId: "B", kind: .file, name: "IMG_0002.jpg", md5: md5("2"), size: 200, takenAt: t2015),
        CloudItem(nodeId: "L1", kind: .liveVideo, name: "a_lpv", md5: md5("5"), size: 50, takenAt: t2019),
    ]
    private let helloMD5 = "5d41402abc4b2a76b9719d911017c592"

    private func decode<T: Decodable>(_ type: T.Type, _ outcome: ToolCallOutcome) throws -> T {
        #expect(!outcome.isError, "\(outcome.text)")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(outcome.text.utf8))
    }

    // MARK: RainbarrelTools

    @Test func refreshCatalogStoresTheCatalogAndReturnsCounts() async throws {
        let fixture = try ToolsFixture(catalog: catalog)
        let summary = try await fixture.tools.refreshCatalog()
        #expect(summary.photosVideos == CountBytes(count: 2, bytes: 205))
        #expect(summary.distinctMD5 == 2)
        #expect(summary.liveVideos == CountBytes(count: 1, bytes: 50))
    }

    @Test func syncStatusRefreshModes() async throws {
        let fixture = try ToolsFixture(catalog: catalog)
        // refresh: false never touches the catalog.
        #expect(try await fixture.tools.syncStatus(refresh: false).photosVideos.count == 0)
        // nil refreshes because the catalog was never refreshed.
        #expect(try await fixture.tools.syncStatus(refresh: nil).photosVideos.count == 2)
        // Fresh now: nil does not refresh again, even though the source would now fail.
        let failing = RainbarrelTools(paths: fixture.tools.paths) { _ in throw CatalogError.indexNotFound("gone") }
        #expect(try await failing.syncStatus(refresh: nil).photosVideos.count == 2)
        // true forces a refresh and reports its failure.
        await #expect(throws: ToolError.self) { try await failing.syncStatus(refresh: true) }
    }

    @Test func implicitRefreshFailureFallsBackToTheStoredCatalogButNeverFromNothing() async throws {
        let broken = try ToolsFixture(catalogError: CatalogError.indexNotFound("no index"))
        await #expect(throws: (any Error).self) { try await broken.tools.syncStatus(refresh: nil) }

        let fixture = try ToolsFixture(catalog: catalog)
        _ = try await fixture.tools.refreshCatalog()
        // Make the stored refresh look old, then break the source.
        let store = try fixture.tools.openStore()
        try store.setMetaDate(MetaKey.catalogRefreshedAt, Date(timeIntervalSinceNow: -3600))
        let failing = RainbarrelTools(paths: fixture.tools.paths) { _ in throw CatalogError.indexNotFound("gone") }
        #expect(try await failing.syncStatus(refresh: nil).photosVideos.count == 2)
    }

    @Test func missingAmazonIndexBecomesAHumanReadableError() async throws {
        let fixture = try ToolsFixture(catalogError: CatalogError.indexNotFound("no amzn1.account.*-cloud.db in /somewhere"))
        do {
            _ = try await fixture.tools.refreshCatalog()
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("Amazon Photos app index not found"))
            #expect(error.message.contains("config set-index"))
        }
    }

    @Test func scanDriveRequiresAMountedConfiguredDrive() throws {
        let unconfigured = try ToolsFixture(configureDrive: false)
        do {
            _ = try unconfigured.tools.scanDrive()
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("No backup drive is configured"))
        }

        let fixture = try ToolsFixture()
        try fixture.tools.saveConfig(Config(driveRoot: fixture.drive.path("not-mounted")))
        do {
            _ = try fixture.tools.scanDrive()
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("not mounted"))
        }
    }

    @Test func scanDriveIndexesTheDriveAndReportsWhatRemains() async throws {
        let fixture = try ToolsFixture(driveSubpath: "Backup", catalog: catalog)
        try fixture.drive.write("Backup/IMG_0001.jpg", "hello")
        try fixture.drive.write("Backup/IMG_0002.jpg", "world")
        try fixture.drive.write("Elsewhere/ignored.jpg", "nope")
        _ = try await fixture.tools.refreshCatalog()

        let limited = try fixture.tools.scanDrive(limit: 1, retry: .none)
        #expect(limited.filesHashed == 1)
        #expect(limited.stoppedByLimit)
        #expect(!limited.walkedEverything)
        #expect(limited.message.contains("Call it again"))

        let rest = try fixture.tools.scanDrive(limit: 100, retry: .none)
        #expect(rest.walkedEverything)
        #expect(rest.filesHashed == 1)
        #expect(rest.unhashedRemaining == 0)

        let metadataOnly = try fixture.tools.scanDrive(hash: false, retry: .none)
        #expect(metadataOnly.hashing == false)
        #expect(metadataOnly.filesHashed == 0)

        let report = try await fixture.tools.syncStatus(refresh: false)
        #expect(report.scanSubpath == "Backup")
        #expect(report.driveHashedFiles == 2)
        #expect(report.driveMounted)
        #expect(report.lastScanAt != nil)
    }

    @Test func listingFunctionsFollowTheConfiguredScope() async throws {
        let fixture = try ToolsFixture(driveSubpath: "Backup", catalog: catalog)
        try fixture.drive.write("Backup/IMG_0001.jpg", "hello")  // md5 of "hello" is not in the catalog
        _ = try await fixture.tools.refreshCatalog()
        _ = try fixture.tools.scanDrive(retry: .none)

        let driveOnly = try fixture.tools.listDriveOnly(limit: 10)
        #expect(driveOnly.total == 1)
        #expect(driveOnly.items.first?.relPath == "Backup/IMG_0001.jpg")
        #expect(driveOnly.items.first?.md5 == helloMD5)

        let online = try fixture.tools.listOnlineOnly(year: 2015, limit: 10)
        #expect(online.items.map(\.nodeId) == ["B"])
        #expect(try fixture.tools.breakdownByYear().map(\.year) == [2015, 2019])
    }

    // MARK: Registry

    @Test func definitionsDescribeTheNineToolsWithObjectSchemas() {
        let names = RainbarrelToolRegistry.definitions.map(\.name)
        #expect(names == [
            "sync_status", "list_online_only", "list_drive_only", "breakdown_by_year", "refresh_catalog", "scan_drive",
            "download_status", "download_batch", "organize_preview",
        ])
        for definition in RainbarrelToolRegistry.definitions {
            #expect(!definition.description.isEmpty)
            guard case .object(let schema) = definition.inputSchema,
                  case .string("object")? = schema["type"],
                  case .object(let properties)? = schema["properties"] else {
                Issue.record("schema of \(definition.name) is not an object schema")
                continue
            }
            #expect(schema["additionalProperties"] == .bool(false))
            #expect(properties.count <= 3)
        }
        let scan = RainbarrelToolRegistry.definitions.first { $0.name == "scan_drive" }
        guard case .object(let schema)? = scan?.inputSchema, case .object(let properties)? = schema["properties"],
              case .object(let limit)? = properties["limit"] else {
            Issue.record("scan_drive has no limit property")
            return
        }
        #expect(limit["maximum"] == .int(5000))
        #expect(limit["default"] == .int(500))
        // The schema must survive JSON encoding, because that is how it reaches clients.
        #expect((try? JSONEncoder().encode(scan?.inputSchema)) != nil)
    }

    @Test func registryRunsEveryToolWithoutATransport() async throws {
        let fixture = try ToolsFixture(catalog: catalog)
        try fixture.drive.write("IMG_0001.jpg", "hello")
        let registry = RainbarrelToolRegistry(tools: fixture.tools)

        let refreshed = try decode(CatalogRefreshSummary.self, await registry.callAsync(name: "refresh_catalog", arguments: nil))
        #expect(refreshed.photosVideos.count == 2)

        let status = try decode(SyncReport.self, await registry.callAsync(name: "sync_status", arguments: ["refresh": .bool(false)]))
        #expect(status.photosVideos.count == 2)
        #expect(status.onlineOnly.count == 2)

        let scan = try decode(ScanSummary.self, registry.call(name: "scan_drive", arguments: ["limit": .int(10)]))
        #expect(scan.filesHashed == 1)
        #expect(scan.walkedEverything)

        let online = try decode(Page<OnlineOnlyItem>.self, registry.call(name: "list_online_only", arguments: ["year": .int(2019)]))
        #expect(online.total == 1)
        #expect(online.limit == 50)
        let driveOnly = try decode(Page<DriveOnlyItem>.self, registry.call(name: "list_drive_only", arguments: ["limit": .int(5), "offset": .int(0)]))
        #expect(driveOnly.total == 1)
        let years = try decode([YearRow].self, registry.call(name: "breakdown_by_year", arguments: [:]))
        #expect(years.map(\.year) == [2015, 2019])
    }

    @Test func registryClampsLimitsAndAcceptsWholeDoubles() async throws {
        let fixture = try ToolsFixture(catalog: catalog)
        _ = try await fixture.tools.refreshCatalog()
        let registry = RainbarrelToolRegistry(tools: fixture.tools)
        let big = try decode(Page<OnlineOnlyItem>.self, registry.call(name: "list_online_only", arguments: ["limit": .int(100_000)]))
        #expect(big.limit == 500)
        let small = try decode(Page<OnlineOnlyItem>.self, registry.call(name: "list_online_only", arguments: ["limit": .double(1.0)]))
        #expect(small.limit == 1)
        #expect(small.items.count == 1)
    }

    @Test func registryReportsBadInputAndFailuresAsToolErrors() async throws {
        let fixture = try ToolsFixture(catalogError: CatalogError.indexNotFound("no index here"))
        let registry = RainbarrelToolRegistry(tools: fixture.tools)

        let unknown = registry.call(name: "no_such_tool", arguments: nil)
        #expect(unknown.isError)
        #expect(unknown.text.contains("Unknown tool"))

        let badType = registry.call(name: "list_online_only", arguments: ["limit": .string("many")])
        #expect(badType.isError)
        #expect(badType.text.contains("`limit`"))
        let badOffset = registry.call(name: "list_drive_only", arguments: ["offset": .int(-1)])
        #expect(badOffset.isError)
        let badYear = registry.call(name: "list_online_only", arguments: ["year": .int(0)])
        #expect(badYear.isError)
        let badFlag = registry.call(name: "scan_drive", arguments: ["hash": .string("yes")])
        #expect(badFlag.isError)

        // Amazon index missing: a readable message, not a crash.
        let refresh = await registry.callAsync(name: "refresh_catalog", arguments: nil)
        #expect(refresh.isError)
        #expect(refresh.text.contains("Amazon Photos app index not found"))
        let status = await registry.callAsync(name: "sync_status", arguments: ["refresh": .bool(true)])
        #expect(status.isError)

        // Drive not mounted.
        try fixture.tools.saveConfig(Config(driveRoot: fixture.drive.path("unplugged")))
        let scan = registry.call(name: "scan_drive", arguments: nil)
        #expect(scan.isError)
        #expect(scan.text.contains("not mounted"))
    }

    @Test func jsonValueRoundTripsAndConvertsNumbers() throws {
        let value = JSONValue.object(["a": .int(1), "b": .array([.string("x"), .null, .bool(true), .double(1.5)])])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(JSONValue.double(3.0).intValue == 3)
        #expect(JSONValue.double(3.5).intValue == nil)
        #expect(JSONValue.string("3").intValue == nil)
    }
}
