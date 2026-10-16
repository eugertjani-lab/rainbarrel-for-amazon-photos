import Foundation
import Testing
@testable import MirrorCore

@Suite("Amazon app index source and state store")
struct CatalogTests {
    private func read(_ fixture: CloudFixture) throws -> [CloudItem] {
        var items: [CloudItem] = []
        _ = try AmazonAppIndexSource(indexPath: fixture.path).readCatalog { items.append($0) }
        return items.sorted { $0.nodeId < $1.nodeId }
    }

    @Test func importKeepsOnlyAvailableFilesAndLiveVideosWithMD5() throws {
        let fixture = try CloudFixture.standard()
        let items = try read(fixture)
        #expect(items.map(\.nodeId) == ["F1", "F2", "F3", "F4", "F5", "L1", "L2"])
        #expect(items.filter { $0.kind == .file }.count == 5)
        #expect(items.filter { $0.kind == .liveVideo }.count == 2)
    }

    @Test func importMapsFieldsDatesAndParents() throws {
        let fixture = try CloudFixture.standard()
        let byId = Dictionary(uniqueKeysWithValues: try read(fixture).map { ($0.nodeId, $0) })

        let f1 = try #require(byId["F1"])
        #expect(f1.name == "IMG_0001.jpg")
        #expect(f1.md5 == md5("1"))
        #expect(f1.size == 1000)
        #expect(f1.takenAt == t2019)
        #expect(f1.ext == "jpg")
        #expect(f1.parentId == "FOLDER1")

        // content_date = 0 and content_date = NULL both fall back to createdDate.
        #expect(byId["F3"]?.takenAt == t2015)
        #expect(byId["F4"]?.takenAt == t2020)
        // MD5 is normalised to lowercase.
        #expect(byId["F5"]?.md5 == md5("4"))
        // Live Photo videos point at the still image they belong to.
        #expect(byId["L1"]?.parentId == "F5")
        #expect(byId["L2"]?.parentId == "F1")
    }

    @Test func freshnessIsWalMtimeWhenPresentElseDatabaseMtime() throws {
        let fixture = try CloudFixture.standard()
        let database = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: database], ofItemAtPath: fixture.path)
        let plain = try AmazonAppIndexSource(indexPath: fixture.path).readCatalog { _ in }
        #expect(plain.sourceModifiedAt == database)

        let walDate = Date(timeIntervalSince1970: 1_800_000_000)
        try Data().write(to: URL(fileURLWithPath: fixture.path + "-wal"))
        try FileManager.default.setAttributes([.modificationDate: walDate], ofItemAtPath: fixture.path + "-wal")
        #expect(AmazonAppIndexSource.modificationDate(ofIndexAt: fixture.path) == walDate)
    }

    @Test func snapshotReadsRowsThatExistOnlyInTheWalAndLeavesTheOriginalAlone() throws {
        // The fixture connection stays open with auto-checkpointing off, like the Amazon app.
        let fixture = try CloudFixture.standard(walMode: true)
        try fixture.insert(id: "W1", name: "IMG_0100.jpg", md5: md5("d"), contentDate: ticks(unix: t2019))
        #expect(FileManager.default.fileExists(atPath: fixture.path + "-wal"))

        let before = try fixture.directory.listing()
        let items = try read(fixture)
        #expect(items.map(\.nodeId).contains("W1"))
        #expect(items.count == 8)
        let after = try fixture.directory.listing()
        #expect(before == after)
    }

    @Test func missingIndexThrows() {
        #expect(throws: CatalogError.self) {
            try AmazonAppIndexSource(indexPath: "/nonexistent/photomirror-cloud.db").readCatalog { _ in }
        }
    }

    @Test func locateIndexPicksTheNewestMatch() throws {
        let dir = try TempDirectory()
        try dir.write("amzn1.account.OLD-cloud.db", "x", modified: Date(timeIntervalSince1970: 1_000_000))
        try dir.write("amzn1.account.NEW-cloud.db", "x", modified: Date(timeIntervalSince1970: 2_000_000))
        try dir.write("amzn1.account.NEW-download.db", "x", modified: Date(timeIntervalSince1970: 3_000_000))
        #expect(try AmazonAppIndexSource.locateIndex(in: dir.url).hasSuffix("amzn1.account.NEW-cloud.db"))

        // A newer -wal file makes its database the most recently modified one.
        try dir.write("amzn1.account.OLD-cloud.db-wal", "x", modified: Date(timeIntervalSince1970: 5_000_000))
        #expect(try AmazonAppIndexSource.locateIndex(in: dir.url).hasSuffix("amzn1.account.OLD-cloud.db"))

        let empty = try TempDirectory()
        #expect(throws: CatalogError.self) { try AmazonAppIndexSource.locateIndex(in: empty.url) }
    }

    @Test func refreshReplacesCloudItemsInOneTransaction() throws {
        let store = try makeStore()
        let refresher = CatalogRefresher(store: store)
        let first = StaticCatalog(items: [
            CloudItem(nodeId: "A", kind: .file, name: "IMG_0001.jpg", md5: md5("1"), size: 10, takenAt: t2019),
            CloudItem(nodeId: "B", kind: .file, name: "IMG_0002.jpg", md5: md5("2"), size: 20, takenAt: t2019),
        ])
        try refresher.refresh(from: first)
        #expect(try store.cloudItemCount() == 2)

        // A second refresh replaces the catalog rather than adding to it.
        let second = StaticCatalog(items: [
            CloudItem(nodeId: "C", kind: .liveVideo, name: "x_lpv", md5: md5("3"), size: 5, takenAt: t2019),
        ])
        try refresher.refresh(from: second)
        #expect(try store.cloudItemCount() == 1)
        #expect(try store.getMeta(MetaKey.catalogItemCount) == "1")

        // A failing source leaves the previous catalog intact.
        struct Failing: CloudCatalogSource {
            var sourceName: String { "failing" }
            func readCatalog(_ body: (CloudItem) throws -> Void) throws -> CatalogReadResult {
                try body(CloudItem(nodeId: "Z", kind: .file, name: "z", md5: md5("9"), size: 1, takenAt: 0))
                throw CatalogError.snapshotFailed("boom")
            }
        }
        #expect(throws: CatalogError.self) { try refresher.refresh(from: Failing()) }
        #expect(try store.cloudItemCount() == 1)
        #expect(try store.database.scalarString("SELECT node_id FROM cloud_items") == "C")
    }

    @Test func staleDetectionUsesTenMinutes() throws {
        let store = try makeStore()
        let refresher = CatalogRefresher(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try refresher.isStale(now: now))  // never refreshed
        try refresher.refresh(from: StaticCatalog(items: []), now: now)
        #expect(try !refresher.isStale(now: now.addingTimeInterval(599)))
        #expect(try refresher.isStale(now: now.addingTimeInterval(601)))
    }

    @Test func stateStoreHasTheDocumentedTablesAndIndexes() throws {
        let store = try makeStore()
        let names = try store.database.rows("SELECT name FROM sqlite_master ORDER BY name") { $0.string(0) ?? "" }
        for expected in ["cloud_items", "drive_files", "meta", "scans", "idx_cloud_items_md5", "idx_drive_files_md5"] {
            #expect(names.contains(expected))
        }
    }

    @Test func endToEndFromFixtureIndexIntoStateStore() throws {
        let fixture = try CloudFixture.standard()
        let store = try makeStore()
        let result = try CatalogRefresher(store: store).refresh(from: AmazonAppIndexSource(indexPath: fixture.path))
        #expect(result.itemCount == 7)
        #expect(try store.cloudItemCount() == 7)
        #expect(try store.database.scalarInt64("SELECT COUNT(DISTINCT md5) FROM cloud_items WHERE kind = 'file'") == 4)
    }
}
