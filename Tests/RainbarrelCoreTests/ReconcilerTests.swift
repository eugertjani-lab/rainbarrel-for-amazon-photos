import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Reconciler")
struct ReconcilerTests {
    /// Cloud: five photos/videos (two share an MD5) and two Live Photo videos.
    /// Drive: copies of md5 1, 3 and 5, one file that is in no cloud table, and two unhashed files.
    private func makeScenario() throws -> (StateStore, Reconciler) {
        let store = try makeStore()
        let cloud = StaticCatalog(items: [
            CloudItem(nodeId: "A1", kind: .file, name: "IMG_0001.jpg", md5: md5("1"), size: 100, takenAt: t2019),
            CloudItem(nodeId: "A2", kind: .file, name: "IMG_0001 copy.jpg", md5: md5("1"), size: 100, takenAt: t2019),
            CloudItem(nodeId: "B", kind: .file, name: "IMG_0002.jpg", md5: md5("2"), size: 200, takenAt: t2015),
            CloudItem(nodeId: "C", kind: .file, name: "IMG_0003.jpg", md5: md5("3"), size: 300, takenAt: t2020),
            CloudItem(nodeId: "D", kind: .file, name: "IMG_0004.jpg", md5: md5("4"), size: 400, takenAt: t2020 + 3600),
            CloudItem(nodeId: "L1", kind: .liveVideo, name: "a_lpv", md5: md5("5"), size: 50, takenAt: t2019),
            CloudItem(nodeId: "L2", kind: .liveVideo, name: "b_lpv", md5: md5("6"), size: 60, takenAt: t2019),
        ])
        try CatalogRefresher(store: store).refresh(from: cloud, now: Date(timeIntervalSince1970: 1_800_000_000))
        // One drive copy of md5 1 satisfies both cloud nodes A1 and A2.
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/IMG_0001.jpg", size: 100, mtime: 1, md5: md5("1")))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/IMG_0003.jpg", size: 300, mtime: 1, md5: md5("3")))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/live/a.mov", size: 50, mtime: 1, md5: md5("5")))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/extra/only-here.jpg", size: 700, mtime: 1, md5: md5("e")))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/pending.jpg", size: 10, mtime: 1))
        try store.recordDriveFileError(relPath: "Backup/broken.jpg", size: 20, mtime: 1, message: "Input/output error")
        return (store, Reconciler(store: store))
    }

    @Test func totalsDuplicatesAndLiveVideos() throws {
        let (_, reconciler) = try makeScenario()
        let report = try reconciler.report(driveRoot: nil, now: Date(timeIntervalSince1970: 1_800_000_100))

        #expect(report.photosVideos == CountBytes(count: 5, bytes: 1100))
        #expect(report.distinctMD5 == 4)
        // A1 and A2 share md5 1 and one drive copy covers both.
        #expect(report.inSync == CountBytes(count: 3, bytes: 500))
        #expect(report.onlineOnly == CountBytes(count: 2, bytes: 600))
        #expect(report.photosVideos.count == report.inSync.count + report.onlineOnly.count)

        // Live Photo videos are split the same way but kept out of the photo/video totals.
        #expect(report.liveVideos == CountBytes(count: 2, bytes: 110))
        #expect(report.liveVideosInSync == CountBytes(count: 1, bytes: 50))
        #expect(report.liveVideosOnlineOnly == CountBytes(count: 1, bytes: 60))
        #expect(abs(try #require(report.inSyncFraction) - 0.6) < 1e-9)
    }

    @Test func distinctBytesCountEachMissingMD5Once() throws {
        let (_, reconciler) = try makeScenario()
        let report = try reconciler.report(driveRoot: nil)
        // Online only: B (md5 2, 200 bytes), D (md5 4, 400) and the Live Photo video L2 (md5 6, 60).
        #expect(report.onlineOnlyDistinctBytes == 660)
    }

    @Test func distinctBytesIgnoreDuplicatesAndAnythingAlreadyOnTheDrive() throws {
        let store = try makeStore()
        try CatalogRefresher(store: store).refresh(from: StaticCatalog(items: [
            // md5 a exists three times in the cloud (two photos and a Live Photo video): 100 bytes once.
            CloudItem(nodeId: "A1", kind: .file, name: "a.jpg", md5: md5("a"), size: 100, takenAt: t2019),
            CloudItem(nodeId: "A2", kind: .file, name: "a copy.jpg", md5: md5("a"), size: 100, takenAt: t2019),
            CloudItem(nodeId: "A3", kind: .liveVideo, name: "a_lpv", md5: md5("a"), size: 100, takenAt: t2019),
            // md5 b is a duplicated Live Photo video: 50 bytes once.
            CloudItem(nodeId: "B1", kind: .liveVideo, name: "b1_lpv", md5: md5("b"), size: 50, takenAt: t2019),
            CloudItem(nodeId: "B2", kind: .liveVideo, name: "b2_lpv", md5: md5("b"), size: 50, takenAt: t2019),
            // md5 c has a copy on the drive and does not count.
            CloudItem(nodeId: "C1", kind: .file, name: "c.jpg", md5: md5("c"), size: 900, takenAt: t2020),
            CloudItem(nodeId: "C2", kind: .file, name: "c copy.jpg", md5: md5("c"), size: 900, takenAt: t2020),
        ]), now: Date(timeIntervalSince1970: 1_800_000_000))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/c.jpg", size: 900, mtime: 1, md5: md5("c")))

        let report = try Reconciler(store: store).report(driveRoot: nil)
        #expect(report.onlineOnly.bytes == 200)
        #expect(report.liveVideosOnlineOnly.bytes == 200)
        #expect(report.onlineOnlyDistinctBytes == 150)
    }

    @Test func nothingMissingNeedsNoSpace() throws {
        let report = try Reconciler(store: makeStore()).report(driveRoot: nil)
        #expect(report.onlineOnlyDistinctBytes == 0)
        #expect(report.driveSpace == nil)
    }

    @Test func reportCarriesTheDriveCapacityOnlyWhileMounted() throws {
        let (_, reconciler) = try makeScenario()
        let dir = try TempDirectory()
        let missing = try reconciler.report(driveRoot: dir.path("missing"))
        #expect(missing.driveSpace == nil)
        #if os(macOS)
        let mounted = try reconciler.report(driveRoot: dir.path)
        #expect(mounted.driveMounted)
        #expect(try #require(mounted.driveSpace).totalBytes > 0)
        #endif
    }

    @Test func driveOnlyUnhashedAndErrorCounts() throws {
        let (_, reconciler) = try makeScenario()
        let report = try reconciler.report(driveRoot: nil)
        // The md5 5 copy matches a Live Photo video, so it is not drive-only.
        #expect(report.driveOnly == CountBytes(count: 1, bytes: 700))
        #expect(report.driveHashedFiles == 4)
        #expect(report.driveUnhashedFiles == 2)
        #expect(report.driveFilesWithErrors == 1)

        let page = try reconciler.driveOnlyPage(limit: 10)
        #expect(page.total == 1)
        #expect(page.items.map(\.relPath) == ["Backup/extra/only-here.jpg"])
        #expect(page.items.first?.md5 == md5("e"))
        #expect(try reconciler.driveOnly(limit: 10, offset: 1).isEmpty)
    }

    @Test func perYearRowsCoverPhotosAndVideosOnly() throws {
        let (_, reconciler) = try makeScenario()
        let years = try reconciler.report(driveRoot: nil).years
        #expect(years == [
            YearRow(year: 2015, cloudCount: 1, inSync: 0, onlineOnly: 1, cloudBytes: 200),
            YearRow(year: 2019, cloudCount: 2, inSync: 2, onlineOnly: 0, cloudBytes: 200),
            YearRow(year: 2020, cloudCount: 2, inSync: 1, onlineOnly: 1, cloudBytes: 700),
        ])
    }

    @Test func onlineOnlyListingFiltersByYearAndPages() throws {
        let (_, reconciler) = try makeScenario()
        let all = try reconciler.onlineOnly(limit: 10)
        #expect(all.map(\.nodeId) == ["B", "D"])  // oldest first
        #expect(all.first?.name == "IMG_0002.jpg")

        #expect(try reconciler.onlineOnly(year: 2020, limit: 10).map(\.nodeId) == ["D"])
        #expect(try reconciler.onlineOnly(year: 2019, limit: 10).isEmpty)
        #expect(try reconciler.onlineOnly(limit: 1, offset: 1).map(\.nodeId) == ["D"])

        let page = try reconciler.onlineOnlyPage(limit: 1, offset: 0)
        #expect(page.total == 2)
        #expect(page.items.count == 1)
        #expect(try reconciler.onlineOnlyCount(year: 2015) == 1)
    }

    @Test func contextFieldsAndDriveMounted() throws {
        let (store, reconciler) = try makeScenario()
        let scanId = try store.beginScan(startedAt: Date(timeIntervalSince1970: 1_800_000_050))
        try store.finishScan(id: scanId, finishedAt: Date(timeIntervalSince1970: 1_800_000_060),
                             filesSeen: 3, filesHashed: 1, errors: 0)
        let dir = try TempDirectory()

        let mounted = try reconciler.report(driveRoot: dir.path)
        #expect(mounted.driveMounted)
        #expect(mounted.driveRoot == dir.path)
        #expect(mounted.lastScanAt == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(mounted.catalogFreshness == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(mounted.catalogRefreshedAt == Date(timeIntervalSince1970: 1_800_000_000))

        #expect(try !reconciler.report(driveRoot: dir.path("missing")).driveMounted)
        #expect(try !reconciler.report(driveRoot: nil).driveMounted)
    }

    @Test func reportEncodesToJSONAndBack() throws {
        let (_, reconciler) = try makeScenario()
        let report = try reconciler.report(driveRoot: "/Volumes/MyBackupDrive", now: Date(timeIntervalSince1970: 1_800_000_100))
        let data = try SyncReport.makeEncoder().encode(report)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"driveOnly\""))
        #expect(text.contains("\"onlineOnlyDistinctBytes\" : 660"))
        #expect(text.contains("2027-01-15T08:01:40Z"))  // generatedAt as ISO 8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(SyncReport.self, from: data) == report)
    }

    @Test func emptyStoreProducesAnEmptyReport() throws {
        let report = try Reconciler(store: makeStore()).report(driveRoot: nil)
        #expect(report.photosVideos == CountBytes())
        #expect(report.years.isEmpty)
        #expect(report.inSyncFraction == nil)
        #expect(report.catalogFreshness == nil)
        #expect(report.lastScanAt == nil)
    }
}
