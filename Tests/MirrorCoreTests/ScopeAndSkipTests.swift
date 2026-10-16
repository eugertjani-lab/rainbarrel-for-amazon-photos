import Foundation
import Testing
@testable import MirrorCore

@Suite("Skip rules, scope and seed exclusions")
struct ScopeAndSkipTests {
    @Test func skipRulesMatchFilesAndFoldersAnywhereInThePath() {
        #expect(SkipRules.shouldSkip(relPath: "Backup/desktop.ini"))
        #expect(SkipRules.shouldSkip(relPath: "Backup/Sub/Thumbs.db"))
        #expect(SkipRules.shouldSkip(relPath: "Backup/THUMBS.DB"))
        #expect(SkipRules.shouldSkip(relPath: "Backup/.DS_Store"))
        #expect(SkipRules.shouldSkip(relPath: "Backup/._IMG_0001.jpg"))
        #expect(SkipRules.shouldSkip(relPath: "$RECYCLE.BIN/S-1-5/x.jpg"))
        #expect(SkipRules.shouldSkip(relPath: "Backup/System Volume Information/tracking.log"))
        #expect(SkipRules.shouldSkip(relPath: "Backup/.Spotlight-V100/Store-V2/x"))
        #expect(SkipRules.shouldSkip(relPath: "Backup/.fseventsd/000"))
        #expect(SkipRules.shouldSkip(relPath: "Backup/.Trashes/501/x"))
        #expect(SkipRules.shouldSkip(relPath: "Backup/.TemporaryItems/x"))

        #expect(!SkipRules.shouldSkip(relPath: "Backup/IMG_0001.jpg"))
        #expect(!SkipRules.shouldSkip(relPath: "Backup/.hidden.jpg"))
        #expect(!SkipRules.shouldSkip(relPath: "Backup/desktop.ini.jpg"))
        #expect(!SkipRules.shouldSkip(relPath: "Backup/My Thumbs.db folder/IMG.jpg"))
        #expect(!SkipRules.shouldSkip(relPath: ""))
    }

    @Test func seedImportIgnoresHousekeepingFilesAndRemovesExistingRows() throws {
        let store = try makeStore()
        // Rows that an older import stored before the rules applied.
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/desktop.ini", size: 5, mtime: 0, md5: md5("a")))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/old/Thumbs.db", size: 5, mtime: 0, md5: md5("b")))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/keep.jpg", size: 5, mtime: 0, md5: md5("c")))

        let csv = """
            path,size,md5,result
            IMG_0001.jpg,10,\(md5("1")),IN CLOUD
            desktop.ini,192,\(md5("2")),NOT IN CLOUD
            sub/Thumbs.db,20,\(md5("3")),NOT IN CLOUD
            sub/._IMG_0002.jpg,4096,\(md5("4")),NOT IN CLOUD
            $RECYCLE.BIN/x/file.jpg,30,\(md5("5")),NOT IN CLOUD
            """
        let result = try HashSeedImporter.importCSV(bytes: Array(csv.utf8), prefix: "Backup", into: store)
        #expect(result.imported == 1)
        #expect(result.excluded == 4)
        #expect(result.removedExisting == 2)
        let paths = try store.database.rows("SELECT rel_path FROM drive_files ORDER BY rel_path") { $0.string(0) ?? "" }
        #expect(paths == ["Backup/IMG_0001.jpg", "Backup/keep.jpg"])
    }

    @Test func scopeBoundariesAreByteExactAndQuotesAreEscaped() throws {
        let store = try makeStore()
        let inside = ["Photo Backup/a.jpg", "Photo Backup/sub/b.jpg", "Photo Backup/it's/c.jpg"]
        let outside = ["Photo Backup2/x.jpg", "Photo Backup-old/y.jpg", "Photo Backup0/z.jpg", "Photo Backup", "Other/w.jpg", "a.jpg"]
        for path in inside + outside {
            try store.upsertDriveFile(DriveFileRecord(relPath: path, size: 1, mtime: 1, md5: md5("1")))
        }
        let scope = try DriveScope(scanSubpath: "Photo Backup")
        for path in inside { #expect(scope.contains(path), "\(path)") }
        for path in outside { #expect(!scope.contains(path), "\(path)") }

        var matched: [String] = []
        try store.forEachDriveFilePath(in: scope) { matched.append($0) }
        #expect(matched == inside.sorted())

        let quoted = try DriveScope(scanSubpath: "Photo Backup/it's")
        var quotedMatches: [String] = []
        try store.forEachDriveFilePath(in: quoted) { quotedMatches.append($0) }
        #expect(quotedMatches == ["Photo Backup/it's/c.jpg"])

        #expect(try store.removeDriveFiles(outside: scope) == outside.count)
        #expect(try store.driveFileCount() == inside.count)
        #expect(try store.removeDriveFiles(outside: .wholeDrive) == 0)
    }

    @Test func scopeNormalisesSlashesAndRejectsParentReferences() throws {
        #expect(try DriveScope(scanSubpath: "/A//B/./").components == ["A", "B"])
        #expect(try DriveScope(scanSubpath: nil).isWholeDrive)
        #expect(try DriveScope(scanSubpath: "").isWholeDrive)
        #expect(throws: DriveScanError.self) { try DriveScope(scanSubpath: "A/../B") }
    }

    @Test func reconcilerCountsOnlyRowsInsideTheScope() throws {
        let store = try makeStore()
        try CatalogRefresher(store: store).refresh(from: StaticCatalog(items: [
            CloudItem(nodeId: "A", kind: .file, name: "IMG_0001.jpg", md5: md5("1"), size: 100, takenAt: t2019),
            CloudItem(nodeId: "B", kind: .file, name: "IMG_0002.jpg", md5: md5("2"), size: 200, takenAt: t2019),
        ]))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/IMG_0001.jpg", size: 100, mtime: 1, md5: md5("1")))
        // Outside the scope: would make B "in sync", add a drive-only file and an unhashed file.
        try store.upsertDriveFile(DriveFileRecord(relPath: "Other/IMG_0002.jpg", size: 200, mtime: 1, md5: md5("2")))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Other/extra.jpg", size: 50, mtime: 1, md5: md5("e")))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Autorun.inf", size: 5, mtime: 1))

        let everything = try Reconciler(store: store).report(driveRoot: nil)
        #expect(everything.inSync.count == 2)
        #expect(everything.driveOnly.count == 1)
        #expect(everything.driveUnhashedFiles == 1)

        let scoped = Reconciler(store: store, scope: try DriveScope(scanSubpath: "Backup"))
        let report = try scoped.report(driveRoot: "/Volumes/MyBackupDrive")
        #expect(report.scanSubpath == "Backup")
        #expect(report.inSync == CountBytes(count: 1, bytes: 100))
        #expect(report.onlineOnly == CountBytes(count: 1, bytes: 200))
        #expect(report.driveHashedFiles == 1)
        #expect(report.driveOnly == CountBytes())
        #expect(report.driveUnhashedFiles == 0)
        #expect(try scoped.onlineOnly(limit: 10).map(\.nodeId) == ["B"])
        #expect(try scoped.driveOnly(limit: 10).isEmpty)
        #expect(try scoped.driveOnlyCount() == 0)
        #expect(report.years.first?.inSync == 1)
    }

    @Test func compactCountsAreShort() {
        #expect(DisplayFormat.compactCount(0) == "0")
        #expect(DisplayFormat.compactCount(950) == "950")
        #expect(DisplayFormat.compactCount(1000) == "1k")
        #expect(DisplayFormat.compactCount(1500) == "1.5k")
        #expect(DisplayFormat.compactCount(147_351) == "147k")
        #expect(DisplayFormat.compactCount(1_250_000) == "1.2M")
        #expect(DisplayFormat.compactCount(12_000_000) == "12M")
    }
}
