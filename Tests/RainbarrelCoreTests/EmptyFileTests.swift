import Foundation
import Testing
@testable import RainbarrelCore

/// Every empty file has the same MD5, so an empty drive file proves nothing about an empty cloud item.
@Suite("Empty files never match")
struct EmptyFileTests {
    private let t = "Amazon Drive"
    private let emptyMD5 = "d41d8cd98f00b204e9800998ecf8427e"

    @Test func anEmptyDriveFileIsNeitherACopyNorDriveOnly() throws {
        let store = try makeStore()
        let cloud = StaticCatalog(items: [
            CloudItem(nodeId: "E", kind: .file, name: "broken.jpg", md5: emptyMD5, size: 0, takenAt: t2019),
            CloudItem(nodeId: "A", kind: .file, name: "IMG_0001.jpg", md5: md5("1"), size: 100, takenAt: t2019),
        ])
        try CatalogRefresher(store: store).refresh(from: cloud, now: Date(timeIntervalSince1970: 1_800_000_000))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/Rubbish/tmp/lock", size: 0, mtime: 1, md5: emptyMD5))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/.nomedia", size: 0, mtime: 1, md5: emptyMD5))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/IMG_0001.jpg", size: 100, mtime: 1, md5: md5("1")))

        let reconciler = Reconciler(store: store)
        let report = try reconciler.report(driveRoot: nil)
        #expect(report.inSync == CountBytes(count: 1, bytes: 100))
        #expect(report.onlineOnly == CountBytes(count: 1, bytes: 0))
        #expect(report.driveOnly == CountBytes())
        #expect(try reconciler.driveOnlyCount() == 0)
        #expect(try reconciler.driveOnly(limit: 10).isEmpty)
        #expect(try reconciler.onlineOnly(year: nil, limit: 10, offset: 0).map(\.nodeId) == ["E"])
    }

    @Test func organizeLeavesAnEmptyDriveFileInPlaceAndReportsIt() throws {
        let broken = TestFile(nodeId: "E", name: "url-1.png", data: Data(), folder: "F-PHONE")
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [broken, a])
        try fx.put("\(t)/Rubbish/tmp/lock", Data())
        try fx.put("\(t)/stuff/a.jpg", a.data)
        try fx.scan()

        let preview = try fx.service.preview(config: fx.config)
        let s = preview.summary
        #expect(s.toMove == 1)
        #expect(preview.sample.map(\.from) == ["\(t)/stuff/a.jpg"])
        #expect(s.emptyUntouched == 1)
        #expect(s.driveOnlyUntouched == 0 && s.duplicatesLeft == 0 && s.unhashedUntouched == 0)
        #expect(s.skippedTotal == 0)
        #expect(s.onlineOnly == 1)  // the empty cloud item has no real copy

        _ = try fx.service.apply(config: fx.config)
        #expect(fx.exists("\(t)/Rubbish/tmp/lock"))
        #expect(!fx.exists("\(t)/Pictures/Phone/url-1.png"))
        #expect(fx.exists("\(t)/Pictures/Phone/IMG_0001.jpg"))
    }

    @Test func theDownloadPlannerQueuesAnEmptyCloudItemEvenWhenAnEmptyFileSitsOnTheDrive() throws {
        let store = try makeStore()
        let config = Config(driveRoot: "/Volumes/X", scanSubpath: "Amazon Drive")
        try store.replaceCloudCatalog { itemSink, folderSink in
            for folder in testFolders { try folderSink(folder) }
            try itemSink(CloudItem(nodeId: "E1", kind: .file, name: "a.png", md5: emptyMD5, size: 0, takenAt: t2019, parentId: "F-PHONE"))
            try itemSink(CloudItem(nodeId: "E2", kind: .file, name: "b.png", md5: emptyMD5, size: 0, takenAt: t2019 - 5, parentId: "F-PHONE"))
            return CatalogReadResult(sourceDescription: "t", sourceModifiedAt: Date(), itemCount: 2, folderCount: testFolders.count)
        }
        try store.upsertDriveFile(DriveFileRecord(relPath: "\(t)/Rubbish/tmp/lock", size: 0, mtime: 1, md5: emptyMD5))

        let planner = DownloadPlanner(store: store, config: config)
        // Each empty item is created at its own path, so the shared MD5 does not collapse them.
        #expect(try planner.plan(options: DownloadOptions(), root: nil).map(\.nodeId) == ["E1", "E2"])
        let table = DownloadJobTable(source: store, queue: store, config: config)
        #expect(try table.sync(includeLiveVideos: false, now: Date()).candidates == 2)
        #expect(try table.isOnDrive(md5: emptyMD5) == false)
        #expect(try table.counts().notQueued == 0)
    }

    @Test func emptyCloudItemsAreDownloadedAsEmptyFilesAtTheirOwnPaths() async throws {
        let e1 = TestFile(nodeId: "E1", name: "a.png", data: Data(), folder: "F-PHONE", takenAt: t2019)
        let e2 = TestFile(nodeId: "E2", name: "b.png", data: Data(), folder: "F-PHONE", takenAt: t2019 - 5)
        let fx = try DownloadFixture(files: [e1, e2])
        let summary = try await fx.run()
        #expect(summary.filesDownloaded == 2 && summary.filesFailed == 0)
        let phone = "Amazon Drive/Pictures/Phone"
        #expect(fx.contents("\(phone)/a.png") == Data())
        #expect(fx.contents("\(phone)/b.png") == Data())
        #expect(fx.driveFiles() == ["\(phone)/a.png", "\(phone)/b.png"])

        // A second run finds both files at their exact targets and adopts them without any download.
        let again = try await fx.run()
        #expect(again.filesDownloaded == 0 && again.filesFailed == 0)
        #expect(fx.driveFiles() == ["\(phone)/a.png", "\(phone)/b.png"])
    }
}
