import Foundation
import Testing
@testable import MirrorCore

@Suite("Drive scanner")
struct ScannerTests {
    private let helloMD5 = "5d41402abc4b2a76b9719d911017c592"
    private let worldMD5 = "7d793037a0760186574b0282f2f435e7"
    private let oldDate = Date(timeIntervalSince1970: 1_500_000_000)

    private func scan(
        _ drive: TempDirectory, _ store: StateStore, subpath: String? = nil,
        hash: Bool = true, limit: Int? = nil
    ) throws -> ScanResult {
        let scanner = try DriveScanner(store: store, driveRoot: drive.path, scanSubpath: subpath)
        return try scanner.scan(options: ScanOptions(hash: hash, limit: limit, retry: .immediate(retries: 2)))
    }

    private func relPaths(_ store: StateStore) throws -> [String] {
        try store.database.rows("SELECT rel_path FROM drive_files ORDER BY rel_path") { $0.string(0) ?? "" }
    }

    @Test func skipsHousekeepingFilesAndFolders() throws {
        let drive = try TempDirectory()
        try drive.write("Photos/IMG_0001.jpg", "hello")
        try drive.write("Photos/.hidden-but-real.jpg", "hello")
        try drive.write("Photos/.DS_Store", "x")
        try drive.write("Photos/._IMG_0001.jpg", "x")
        try drive.write("Photos/Thumbs.db", "x")
        try drive.write("Photos/desktop.ini", "x")
        try drive.write("$RECYCLE.BIN/deleted.jpg", "x")
        try drive.write("System Volume Information/tracking.log", "x")
        try drive.write(".Spotlight-V100/store", "x")
        try drive.write(".fseventsd/log", "x")
        try drive.write(".Trashes/501/old.jpg", "x")
        try drive.write("Photos/.TemporaryItems/folders/tmp", "x")
        let store = try makeStore()

        let result = try scan(drive, store)
        #expect(try relPaths(store) == ["Photos/.hidden-but-real.jpg", "Photos/IMG_0001.jpg"])
        #expect(result.filesSeen == 2)
        #expect(result.filesHashed == 2)
        #expect(result.errors == 0)
        #expect(!result.stoppedByLimit)
        #expect(try store.driveFile(relPath: "Photos/IMG_0001.jpg")?.md5 == helloMD5)
    }

    @Test func recordsSizeMTimeAndHash() throws {
        let drive = try TempDirectory()
        try drive.write("a.jpg", "hello", modified: oldDate)
        let store = try makeStore()
        _ = try scan(drive, store)
        let record = try #require(try store.driveFile(relPath: "a.jpg"))
        #expect(record.size == 5)
        #expect(record.mtime == 1_500_000_000)
        #expect(record.md5 == helloMD5)
        #expect(record.hashedAt != nil)
        #expect(record.lastError == nil)
    }

    @Test func rehashesOnlyWhenSizeOrMTimeChanges() throws {
        let drive = try TempDirectory()
        try drive.write("a.jpg", "hello", modified: oldDate)
        try drive.write("b.jpg", "world", modified: oldDate)
        let store = try makeStore()

        #expect(try scan(drive, store).filesHashed == 2)
        // Nothing changed: nothing is hashed.
        let unchanged = try scan(drive, store)
        #expect(unchanged.filesSeen == 2)
        #expect(unchanged.filesHashed == 0)

        // Changed content and size.
        try drive.write("a.jpg", "hello!!", modified: oldDate)
        let sizeChange = try scan(drive, store)
        #expect(sizeChange.filesHashed == 1)
        #expect(try store.driveFile(relPath: "a.jpg")?.md5 == MD5Hasher.hexDigest(of: Array("hello!!".utf8)))
        #expect(try store.driveFile(relPath: "b.jpg")?.md5 == worldMD5)

        // Same size, newer mtime.
        try drive.write("b.jpg", "WORLD", modified: oldDate.addingTimeInterval(60))
        #expect(try scan(drive, store).filesHashed == 1)
        #expect(try store.driveFile(relPath: "b.jpg")?.md5 == MD5Hasher.hexDigest(of: Array("WORLD".utf8)))

        // New file.
        try drive.write("sub/c.jpg", "hello")
        let added = try scan(drive, store)
        #expect(added.filesHashed == 1)
        #expect(added.filesSeen == 3)
    }

    @Test func seedHashWithMTimeZeroIsAdoptedWithoutRehashing() throws {
        let drive = try TempDirectory()
        try drive.write("Backup/Trip, 2019/IMG_0001.jpg", "hello", modified: oldDate)
        try drive.write("Backup/IMG_0002.jpg", "world", modified: oldDate)
        let store = try makeStore()
        // The seed MD5s are deliberately wrong so a rehash would be visible.
        let seed = """
            path,size,md5,result
            "Trip, 2019/IMG_0001.jpg",5,\(md5("a")),IN CLOUD
            IMG_0002.jpg,999,\(md5("b")),IN CLOUD
            """
        _ = try HashSeedImporter.importCSV(bytes: Array(seed.utf8), prefix: "Backup", into: store)

        let result = try scan(drive, store)
        #expect(result.filesAdopted == 1)
        #expect(result.filesHashed == 1)  // only the file whose size no longer matches the seed

        let adopted = try #require(try store.driveFile(relPath: "Backup/Trip, 2019/IMG_0001.jpg"))
        #expect(adopted.md5 == md5("a"))  // seed hash kept
        #expect(adopted.mtime == 1_500_000_000)  // real mtime adopted
        let mismatched = try #require(try store.driveFile(relPath: "Backup/IMG_0002.jpg"))
        #expect(mismatched.md5 == worldMD5)  // size differed, so it was hashed
        #expect(mismatched.size == 5)

        // A second scan has nothing left to do.
        let again = try scan(drive, store)
        #expect(again.filesAdopted == 0)
        #expect(again.filesHashed == 0)
    }

    @Test func noHashRecordsMetadataOnlyAndALaterScanHashes() throws {
        let drive = try TempDirectory()
        try drive.write("a.jpg", "hello", modified: oldDate)
        let store = try makeStore()

        let metadataOnly = try scan(drive, store, hash: false)
        #expect(metadataOnly.filesSeen == 1)
        #expect(metadataOnly.filesHashed == 0)
        let pending = try #require(try store.driveFile(relPath: "a.jpg"))
        #expect(pending.md5 == nil)
        #expect(pending.size == 5)
        #expect(pending.mtime == 1_500_000_000)

        // A no-hash rescan does no further work; a hashing scan fills in the missing hash.
        #expect(try scan(drive, store, hash: false).filesHashed == 0)
        #expect(try scan(drive, store).filesHashed == 1)
        #expect(try store.driveFile(relPath: "a.jpg")?.md5 == helloMD5)
    }

    @Test func limitCapsWorkAndLaterRunsContinue() throws {
        let drive = try TempDirectory()
        for name in ["a", "b", "c", "d", "e"] { try drive.write("\(name).jpg", name) }
        let store = try makeStore()

        let first = try scan(drive, store, limit: 2)
        #expect(first.stoppedByLimit)
        #expect(first.filesHashed == 2)
        #expect(try relPaths(store) == ["a.jpg", "b.jpg"])

        // Up-to-date files do not use up the limit, so the next run gets further.
        let second = try scan(drive, store, limit: 2)
        #expect(second.stoppedByLimit)
        #expect(try relPaths(store) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])

        let third = try scan(drive, store, limit: 2)
        #expect(!third.stoppedByLimit)
        #expect(try relPaths(store).count == 5)
    }

    @Test func scanSubpathRestrictsTheWalkButKeepsDriveRelativePaths() throws {
        let drive = try TempDirectory()
        try drive.write("Backup/IMG_0001.jpg", "hello")
        try drive.write("Other/IMG_0002.jpg", "world")
        let store = try makeStore()
        _ = try scan(drive, store, subpath: "Backup")
        #expect(try relPaths(store) == ["Backup/IMG_0001.jpg"])
    }

    @Test func unreadableFileIsRecordedWithAnErrorAndTheScanContinues() throws {
        try #require(getuid() != 0, "permissions are not enforced for root")
        let drive = try TempDirectory()
        try drive.write("a-good.jpg", "hello")
        let bad = try drive.write("b-bad.jpg", "world")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: bad)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bad) }
        let store = try makeStore()

        let result = try scan(drive, store)
        #expect(result.errors == 1)
        #expect(result.filesHashed == 1)
        let record = try #require(try store.driveFile(relPath: "b-bad.jpg"))
        #expect(record.md5 == nil)
        #expect(record.lastError?.contains("errno 13") == true)
        #expect(try store.driveFile(relPath: "a-good.jpg")?.md5 == helloMD5)

        // Once readable again the next scan retries it.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bad)
        let retry = try scan(drive, store)
        #expect(retry.filesHashed == 1)
        #expect(retry.errors == 0)
        let fixed = try #require(try store.driveFile(relPath: "b-bad.jpg"))
        #expect(fixed.md5 == worldMD5)
        #expect(fixed.lastError == nil)
    }

    @Test func missingRootThrowsAndIsLoggedAsAScan() throws {
        let drive = try TempDirectory()
        let store = try makeStore()
        let scanner = try DriveScanner(store: store, driveRoot: drive.path("not-mounted"))
        #expect(throws: DriveScanError.self) {
            try scanner.scan(options: ScanOptions(retry: .immediate(retries: 2)))
        }
        #expect(try store.scans().count == 1)
    }

    @Test func scanNeverModifiesTheDrive() throws {
        let drive = try TempDirectory()
        try drive.write("Photos/IMG_0001.jpg", "hello", modified: oldDate)
        try drive.write("Photos/Thumbs.db", "x", modified: oldDate)
        try drive.write("$RECYCLE.BIN/x", "x", modified: oldDate)
        let store = try makeStore()
        let before = try drive.listing()
        _ = try scan(drive, store)
        _ = try scan(drive, store, hash: false)
        #expect(try drive.listing() == before)
    }

    @Test func scanHistoryAndProgressCallbackAreReported() throws {
        let drive = try TempDirectory()
        try drive.write("a.jpg", "hello")
        try drive.write("b.jpg", "world")
        let store = try makeStore()
        var last: ScanProgress?
        let scanner = try DriveScanner(store: store, driveRoot: drive.path)
        let result = try scanner.scan(options: ScanOptions(retry: .none)) { last = $0 }

        let progress = try #require(last)
        #expect(progress.filesSeen == 2)
        #expect(progress.filesHashed == 2)
        #expect(progress.bytesHashed == 10)
        #expect(result.bytesHashed == 10)

        let history = try store.scans()
        #expect(history.count == 1)
        #expect(history[0].filesSeen == 2)
        #expect(history[0].filesHashed == 2)
        #expect(history[0].finishedAt != nil)
        #expect(try store.lastScanTime() != nil)
    }

    @Test func invalidSubpathIsRejected() throws {
        let store = try makeStore()
        #expect(throws: DriveScanError.self) {
            try DriveScanner(store: store, driveRoot: "/tmp", scanSubpath: "../escape")
        }
    }
}
