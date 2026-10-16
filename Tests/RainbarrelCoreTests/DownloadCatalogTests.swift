import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Download queue: folder import, queue building and the dry-run plan")
struct DownloadCatalogTests {
    private func seed(_ store: StateStore, items: [CloudItem], folders: [CloudFolder] = testFolders) throws {
        try store.replaceCloudCatalog { itemSink, folderSink in
            for folder in folders { try folderSink(folder) }
            for item in items { try itemSink(item) }
            return CatalogReadResult(sourceDescription: "t", sourceModifiedAt: Date(), itemCount: items.count, folderCount: folders.count)
        }
    }

    private func item(_ id: String, _ name: String, _ digit: Character, takenAt: Int64 = t2019, size: Int64 = 100,
                      kind: CloudItemKind = .file, parent: String? = "F-PHONE") -> CloudItem {
        CloudItem(nodeId: id, kind: kind, name: name, md5: md5(digit), size: size, takenAt: takenAt, parentId: parent)
    }

    private let config = Config(driveRoot: "/Volumes/X", scanSubpath: "Amazon Drive")

    // MARK: Folder import

    @Test func appIndexFoldersAreImportedWithTheirParents() throws {
        let fixture = try CloudFixture()
        try fixture.insertFolder(id: "ROOT", name: "", parent: nil)
        try fixture.insertFolder(id: "PICS", name: "Pictures", parent: "ROOT")
        try fixture.insertFolder(id: "PHONE", name: "Phone", parent: "PICS")
        try fixture.insertFolder(id: "GONE", name: "Purged folder", parent: "ROOT", status: "PURGED")
        try fixture.insertFolder(id: "BIN", name: "Trashed folder", parent: "ROOT", status: "TRASH")
        try fixture.insert(id: "P1", name: "IMG_1.HEIC", parent: "PHONE", md5: md5("1"), ext: "heic")
        try fixture.insert(id: "L1", name: "x_lpv", kind: "ASSET", assetType: "LIVE_VIDEO", parent: "P1", md5: md5("2"), ext: "qt")

        let store = try makeStore()
        let result = try CatalogRefresher(store: store).refresh(from: AmazonAppIndexSource(indexPath: fixture.path))
        #expect(result.folderCount == 3)
        #expect(result.itemCount == 2)
        let rows = try store.database.rows("SELECT node_id, name, parent_id FROM cloud_folders ORDER BY node_id") {
            "\($0.string(0) ?? "")|\($0.string(1) ?? "")|\($0.string(2) ?? "-")"
        }
        #expect(rows == ["PHONE|Phone|PICS", "PICS|Pictures|ROOT", "ROOT||-"])
        #expect(try store.cloudFolderCount() == 3)
        #expect(try store.getMeta(MetaKey.catalogFolderCount) == "3")
        // Files keep their folder as parent; the Live Photo video points at its photo.
        let parents = try store.database.rows("SELECT node_id, parent_id FROM cloud_items ORDER BY node_id") {
            "\($0.string(0) ?? "")>\($0.string(1) ?? "-")"
        }
        #expect(parents == ["L1>P1", "P1>PHONE"])
    }

    @Test func replacingTheCatalogReplacesFoldersAndAFailureKeepsTheOldOnes() throws {
        let store = try makeStore()
        try seed(store, items: [item("A", "a.jpg", "1")])
        #expect(try store.cloudFolderCount() == 4)

        // Items only: folders stay as they are.
        try store.replaceCloudItems { sink in
            try sink(item("B", "b.jpg", "2"))
            return CatalogReadResult(sourceDescription: "t", sourceModifiedAt: Date(), itemCount: 1)
        }
        #expect(try store.cloudFolderCount() == 4)
        #expect(try store.cloudItemCount() == 1)

        // A failing read changes nothing.
        #expect(throws: CatalogError.self) {
            try store.replaceCloudCatalog { _, folders in
                try folders(CloudFolder(nodeId: "NEW", name: "New"))
                throw CatalogError.snapshotFailed("boom")
            }
        }
        #expect(try store.cloudFolderCount() == 4)

        try store.replaceCloudCatalog { items, folders in
            try folders(CloudFolder(nodeId: "ONLY", name: "Only"))
            try items(item("C", "c.jpg", "3"))
            return CatalogReadResult(sourceDescription: "t", sourceModifiedAt: Date(), itemCount: 1, folderCount: 1)
        }
        #expect(try store.cloudFolderCount() == 1)
    }

    @Test func sourcesWithoutAFolderTreeKeepWorking() throws {
        let store = try makeStore()
        try CatalogRefresher(store: store).refresh(from: StaticCatalog(items: [item("A", "a.jpg", "1")]))
        #expect(try store.cloudItemCount() == 1)
        #expect(try store.cloudFolderCount() == 0)
    }

    // MARK: Queue

    @Test func syncQueuesEveryOnlineOnlyItemWithItsTarget() throws {
        let store = try makeStore()
        try seed(store, items: [
            item("A", "a.jpg", "1", takenAt: t2015), item("B", "b.jpg", "2", takenAt: t2019),
            item("L", "b_lpv", "3", takenAt: t2019, kind: .liveVideo, parent: "B"),
        ])
        // "C" is on the drive already and must not be queued.
        try seed(store, items: [
            item("A", "a.jpg", "1", takenAt: t2015), item("B", "b.jpg", "2", takenAt: t2019),
            item("L", "b_lpv", "3", takenAt: t2019, kind: .liveVideo, parent: "B"),
            item("C", "c.jpg", "4"),
        ])
        try store.upsertDriveFile(DriveFileRecord(relPath: "Amazon Drive/c.jpg", size: 100, mtime: 1, md5: md5("4"), hashedAt: 1))
        let table = DownloadJobTable(source: store, queue: store, config: config)
        let result = try table.sync(includeLiveVideos: true, now: Date(timeIntervalSince1970: 1000))
        #expect(result.candidates == 3)
        let rows = try store.database.rows("SELECT node_id, kind, status, target_rel_path FROM download_jobs ORDER BY node_id") {
            "\($0.string(0) ?? "")|\($0.string(1) ?? "")|\($0.string(2) ?? "")|\($0.string(3) ?? "")"
        }
        #expect(rows == [
            "A|file|pending|Amazon Drive/Pictures/Phone/a.jpg",
            "B|file|pending|Amazon Drive/Pictures/Phone/b.jpg",
            "L|live_video|pending|Amazon Drive/Pictures/Phone/b.MOV",
        ])
        let counts = try table.counts()
        #expect(counts.pending == 3)
        #expect(counts.notQueued == 0)
        #expect(counts.pendingBytes == 300)
    }

    @Test func syncMarksItemsThatAreOnTheDriveNowAndKeepsHistoryOtherwise() throws {
        let store = try makeStore()
        try seed(store, items: [item("A", "a.jpg", "1"), item("B", "b.jpg", "2"), item("D", "d.jpg", "5"), item("E", "e.jpg", "6")])
        let table = DownloadJobTable(source: store, queue: store, config: config)
        _ = try table.sync(includeLiveVideos: true, now: Date(timeIntervalSince1970: 1000))
        // B arrives on the drive by other means; D failed twice; E was finished earlier but is online-only again.
        try store.upsertDriveFile(DriveFileRecord(relPath: "Amazon Drive/anything.jpg", size: 100, mtime: 1, md5: md5("2"), hashedAt: 1))
        try table.setStatus(nodeId: "D", status: .failed, attempts: 2, lastError: .some("boom"), now: Date(timeIntervalSince1970: 1500))
        try table.setStatus(nodeId: "E", status: .done, attempts: 1, lastError: .some(nil), now: Date(timeIntervalSince1970: 1500))
        let result = try table.sync(includeLiveVideos: true, now: Date(timeIntervalSince1970: 2000))
        #expect(result.candidates == 3)  // A, D, E
        func row(_ id: String) throws -> DownloadJob { try #require(try store.database.rows(
            "SELECT node_id, kind, md5, size, taken_at, target_rel_path, status, attempts, last_error, updated_at FROM download_jobs WHERE node_id = ?",
            [id], map: { DownloadJobTable.job(from: $0) }).first) }
        #expect(try row("A").status == .pending)
        #expect(try row("B").status == .skipped)
        #expect(try row("B").lastError == "already on the drive, or no longer in the cloud catalog")
        #expect(try row("D").status == .failed)
        #expect(try row("D").attempts == 2)
        #expect(try row("D").lastError == "boom")
        #expect(try row("E").status == .pending)
        #expect(try row("E").attempts == 0)
    }

    @Test func interruptedJobsGoBackToPending() throws {
        let store = try makeStore()
        try seed(store, items: [item("A", "a.jpg", "1")])
        let table = DownloadJobTable(source: store, queue: store, config: config)
        _ = try table.sync(includeLiveVideos: true, now: Date(timeIntervalSince1970: 1000))
        try table.setStatus(nodeId: "A", status: .downloading, now: Date(timeIntervalSince1970: 1100))
        #expect(try table.counts().downloading == 1)
        #expect(try table.recoverInterrupted(now: Date(timeIntervalSince1970: 1200)) == 1)
        let counts = try table.counts()
        #expect(counts.downloading == 0 && counts.pending == 1)
    }

    @Test func claimOrderIsNewestFirstAndFailuresWaitForTheNextRun() throws {
        let store = try makeStore()
        try seed(store, items: [
            item("OLD", "old.jpg", "1", takenAt: t2009), item("MID", "mid.jpg", "2", takenAt: t2015),
            item("NEW", "new.jpg", "3", takenAt: t2020), item("LIVE", "n_lpv", "4", takenAt: t2019, kind: .liveVideo, parent: "NEW"),
        ])
        let table = DownloadJobTable(source: store, queue: store, config: config)
        _ = try table.sync(includeLiveVideos: true, now: Date(timeIntervalSince1970: 1000))
        let options = DownloadOptions()
        func order(_ options: DownloadOptions, runStartedAt: Int64) throws -> [String] {
            var ids: [String] = []
            while let job = try table.nextEligible(options: options, runStartedAt: runStartedAt) {
                ids.append(job.nodeId)
                try table.setStatus(nodeId: job.nodeId, status: .done, now: Date(timeIntervalSince1970: 1100))
            }
            return ids
        }
        #expect(try order(options, runStartedAt: 5000) == ["NEW", "LIVE", "MID", "OLD"])

        // Year filter and the switch for Live Photo videos.
        _ = try table.sync(includeLiveVideos: true, now: Date(timeIntervalSince1970: 2000))
        #expect(try order(DownloadOptions(year: 2015), runStartedAt: 5000) == ["MID"])
        _ = try table.sync(includeLiveVideos: true, now: Date(timeIntervalSince1970: 2100))
        #expect(try order(DownloadOptions(includeLiveVideos: false), runStartedAt: 5000) == ["NEW", "MID", "OLD"])

        // A failed job is tried again only in a later run and only while attempts are left.
        try table.setStatus(nodeId: "MID", status: .failed, attempts: 2, lastError: .some("x"), now: Date(timeIntervalSince1970: 3000))
        try table.setStatus(nodeId: "OLD", status: .failed, attempts: 5, lastError: .some("x"), now: Date(timeIntervalSince1970: 3000))
        #expect(try order(options, runStartedAt: 3000) == ["LIVE"])   // the failures above happened in this very run: not retried
        #expect(try table.totals(options: options, runStartedAt: 3001).count == 1)  // MID only; OLD used all 5 attempts
        #expect(try order(options, runStartedAt: 3001) == ["MID"])
    }

    @Test func totalsRespectTheLimit() throws {
        let store = try makeStore()
        try seed(store, items: (1...5).map { item("N\($0)", "n\($0).jpg", Character(String($0)), takenAt: Int64(1_500_000_000 + $0), size: 10) })
        let table = DownloadJobTable(source: store, queue: store, config: config)
        _ = try table.sync(includeLiveVideos: true, now: Date())
        #expect(try table.totals(options: DownloadOptions(), runStartedAt: 0) == (5, 50))
        #expect(try table.totals(options: DownloadOptions(limit: 2), runStartedAt: 0) == (2, 20))
    }

    @Test func notQueuedCountsOnlineOnlyItemsWithoutARow() throws {
        let store = try makeStore()
        try seed(store, items: [item("A", "a.jpg", "1"), item("B", "b.jpg", "2")])
        let table = DownloadJobTable(source: store, queue: store, config: config)
        #expect(try table.counts().notQueued == 2)
        _ = try table.sync(includeLiveVideos: true, now: Date())
        #expect(try table.counts().notQueued == 0)
    }

    // MARK: Dry run

    @Test func dryRunPlansNewestFirstWithoutDuplicatesAndStaysReadOnly() throws {
        let store = try makeStore()
        try seed(store, items: [
            item("A", "a.jpg", "1", takenAt: t2015), item("B", "b.jpg", "2", takenAt: t2019),
            item("B2", "b copy.jpg", "2", takenAt: t2019 - 5),  // same content as B
            item("C", "c.jpg", "3", takenAt: t2020, parent: "NOWHERE"),
        ])
        let planner = DownloadPlanner(store: store, config: config)
        let plan = try planner.plan(options: DownloadOptions(), root: nil)
        #expect(plan.map(\.nodeId) == ["C", "B", "A"])
        #expect(plan[0].targetRelPath == "Amazon Drive/_Unsorted/2020/01/c.jpg")
        #expect(!plan[0].resolvedFolders)
        #expect(plan[1].targetRelPath == "Amazon Drive/Pictures/Phone/b.jpg")
        #expect(try planner.plan(options: DownloadOptions(limit: 2), root: nil).map(\.nodeId) == ["C", "B"])
        #expect(try planner.plan(options: DownloadOptions(year: 2015), root: nil).map(\.nodeId) == ["A"])
        // Nothing was written to the queue.
        #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM download_jobs") == 0)
    }

    @Test func dryRunShowsExistingAndNumberedTargets() throws {
        let store = try makeStore()
        try seed(store, items: [
            item("A", "same.jpg", "1", takenAt: t2020, size: 5), item("B", "other.jpg", "2", takenAt: t2019, size: 5),
            item("C", "other.jpg", "3", takenAt: t2015, size: 5),
        ])
        let drive = try TempDirectory()
        try drive.write("Amazon Drive/Pictures/Phone/same.jpg", "12345")      // same size: would be verified
        try drive.write("Amazon Drive/Pictures/Phone/other.jpg", "differs")   // different size: name is taken
        let plan = try DownloadPlanner(store: store, config: config).plan(options: DownloadOptions(), root: drive.path)
        #expect(plan.map(\.finalRelPath) == [
            "Amazon Drive/Pictures/Phone/same.jpg",
            "Amazon Drive/Pictures/Phone/other (2).jpg",
            "Amazon Drive/Pictures/Phone/other (3).jpg",  // the plan itself keeps names apart
        ])
        #expect(plan[0].note?.contains("same size") == true)
        #expect(plan[1].note?.contains("numbered") == true)
    }

    @Test func dryRunLeavesOutWhatIsOnTheDriveAndLivePhotoVideosOnRequest() throws {
        let store = try makeStore()
        try seed(store, items: [
            item("A", "a.jpg", "1"), item("B", "b.jpg", "2", takenAt: t2015),
            item("L", "b_lpv", "3", takenAt: t2015, kind: .liveVideo, parent: "B"),
        ])
        try store.upsertDriveFile(DriveFileRecord(relPath: "Amazon Drive/a.jpg", size: 100, mtime: 1, md5: md5("1"), hashedAt: 1))
        // A copy outside the scan folder does not count as a backup.
        try store.upsertDriveFile(DriveFileRecord(relPath: "Elsewhere/b.jpg", size: 100, mtime: 1, md5: md5("2"), hashedAt: 1))
        let planner = DownloadPlanner(store: store, config: config)
        #expect(try planner.plan(options: DownloadOptions(), root: nil).map(\.nodeId) == ["B", "L"])
        #expect(try planner.plan(options: DownloadOptions(includeLiveVideos: false), root: nil).map(\.nodeId) == ["B"])
    }
}
