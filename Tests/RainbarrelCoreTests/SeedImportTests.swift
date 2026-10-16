import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Hash seed import")
struct SeedImportTests {
    private let csv = """
        path,size,md5,result
        IMG_0001.jpg,100,\(md5("a")),IN CLOUD
        "Trip, 2019/IMG_0002.jpg",200,\(md5("B")),NOT IN CLOUD
        "Album ""Best""/IMG_0003.jpg",300,\(md5("c")),IN CLOUD
        broken/IMG_0004.jpg,-1,,READ ERROR: Operation not permitted
        empty/IMG_0005.jpg,50,,
        short-row.jpg
        bad/IMG_0006.jpg,60,not-a-hash,IN CLOUD

        """

    @Test func importsRowsWithQuotedCommasAndRecordsErrors() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try HashSeedImporter.importCSV(
            bytes: Array(csv.utf8), prefix: "Backup", into: store, now: now)

        #expect(result == SeedImportResult(
            rows: 7, imported: 3, errorRows: 3, skipped: 1, excluded: 0, removedExisting: 0))

        let plain = try #require(try store.driveFile(relPath: "Backup/IMG_0001.jpg"))
        #expect(plain == DriveFileRecord(
            relPath: "Backup/IMG_0001.jpg", size: 100, mtime: 0, md5: md5("a"),
            hashedAt: 1_800_000_000, lastError: nil))

        // A comma inside a quoted path stays part of the path; MD5 is lowercased.
        let comma = try #require(try store.driveFile(relPath: "Backup/Trip, 2019/IMG_0002.jpg"))
        #expect(comma.md5 == md5("b"))
        #expect(comma.size == 200)
        #expect(comma.mtime == 0)

        // Doubled quotes unescape.
        #expect(try store.driveFile(relPath: "Backup/Album \"Best\"/IMG_0003.jpg")?.md5 == md5("c"))

        // Rows with size -1, an empty MD5 or an invalid MD5 keep their error text and have no hash.
        let readError = try #require(try store.driveFile(relPath: "Backup/broken/IMG_0004.jpg"))
        #expect(readError.md5 == nil)
        #expect(readError.lastError == "READ ERROR: Operation not permitted")
        #expect(try store.driveFile(relPath: "Backup/empty/IMG_0005.jpg")?.lastError == "seed row has no MD5")
        #expect(try store.driveFile(relPath: "Backup/bad/IMG_0006.jpg")?.md5 == nil)
        #expect(try store.driveFile(relPath: "Backup/bad/IMG_0006.jpg")?.lastError == "IN CLOUD")
        #expect(try store.driveFile(relPath: "Backup/short-row.jpg") == nil)
        #expect(try store.driveFileCount() == 6)
    }

    @Test func prefixSlashesAreTrimmedAndEmptyPrefixIsAllowed() throws {
        let store = try makeStore()
        let text = "path,size,md5,result\nIMG_0001.jpg,1,\(md5("a")),IN CLOUD\n"
        _ = try HashSeedImporter.importCSV(bytes: Array(text.utf8), prefix: "/Backup/", into: store)
        #expect(try store.driveFile(relPath: "Backup/IMG_0001.jpg") != nil)
        _ = try HashSeedImporter.importCSV(bytes: Array(text.utf8), prefix: "", into: store)
        #expect(try store.driveFile(relPath: "IMG_0001.jpg") != nil)
    }

    @Test func importedErrorRowDoesNotOverwriteAnExistingHash() throws {
        let store = try makeStore()
        try store.upsertDriveFile(DriveFileRecord(
            relPath: "Backup/broken/IMG_0004.jpg", size: 10, mtime: 99, md5: md5("f"), hashedAt: 5))
        _ = try HashSeedImporter.importCSV(bytes: Array(csv.utf8), prefix: "Backup", into: store)
        let record = try #require(try store.driveFile(relPath: "Backup/broken/IMG_0004.jpg"))
        #expect(record.md5 == md5("f"))
        #expect(record.mtime == 99)
    }

    @Test func importIsRepeatable() throws {
        let store = try makeStore()
        _ = try HashSeedImporter.importCSV(bytes: Array(csv.utf8), prefix: "Backup", into: store)
        _ = try HashSeedImporter.importCSV(bytes: Array(csv.utf8), prefix: "Backup", into: store)
        #expect(try store.driveFileCount() == 6)
    }

    @Test func missingHeaderColumnsAreRejected() throws {
        let store = try makeStore()
        #expect(throws: SeedImportError.self) {
            try HashSeedImporter.importCSV(bytes: Array("name,hash\na,b\n".utf8), prefix: "", into: store)
        }
        #expect(throws: SeedImportError.self) {
            try HashSeedImporter.importCSV(bytes: [], prefix: "", into: store)
        }
        #expect(try store.driveFileCount() == 0)
    }

    @Test func importFromFileUsingCRLFAndBOM() throws {
        let dir = try TempDirectory()
        let text = "\u{FEFF}path,size,md5,result\r\nIMG_0001.jpg,100,\(md5("a")),IN CLOUD\r\n"
        try dir.write("seed.csv", text)
        let store = try makeStore()
        let result = try HashSeedImporter.importCSV(at: dir.url.appendingPathComponent("seed.csv"), prefix: "Backup", into: store)
        #expect(result.imported == 1)
        #expect(try store.driveFile(relPath: "Backup/IMG_0001.jpg")?.md5 == md5("a"))
    }
}
