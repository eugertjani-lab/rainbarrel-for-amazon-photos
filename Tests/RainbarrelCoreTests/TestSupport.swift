import Foundation
@testable import RainbarrelCore

/// A scratch directory removed when the object goes away.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rainbarrel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path }

    func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }

    @discardableResult
    func write(_ relative: String, _ contents: String, modified: Date? = nil) throws -> String {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        return target.path
    }

    /// Sorted "relative/path size mtime" lines for every file and folder below the directory.
    func listing() throws -> [String] {
        var lines: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: path)
        while let relative = enumerator?.nextObject() as? String {
            let attributes = try FileManager.default.attributesOfItem(atPath: path(relative))
            let size = (attributes[.size] as? UInt64) ?? 0
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            lines.append("\(relative) \(size) \(mtime)")
        }
        return lines.sorted()
    }
}

/// .NET ticks for a Unix timestamp.
func ticks(unix: Int64) -> Int64 {
    unix * DotNetTicks.ticksPerSecond + DotNetTicks.unixEpochTicks
}

// Unix timestamps used across the tests (all UTC).
let t2009 = Int64(1_246_701_600)  // 2009-07-04T10:00:00Z
let t2015 = Int64(1_425_211_200)  // 2015-03-01T12:00:00Z
let t2019 = Int64(1_560_830_577)  // 2019-06-18T04:02:57Z
let t2020 = Int64(1_577_836_800)  // 2020-01-01T00:00:00Z

/// 32 hex characters built from one repeated digit, for readable fixtures.
func md5(_ digit: Character) -> String { String(repeating: digit, count: 32) }

/// Builds a small fake `cloud.db` with the Amazon Photos app's `nodes` schema.
struct CloudFixture {
    let directory: TempDirectory
    let database: SQLiteDatabase
    var path: String { directory.path("cloud.db") }

    init(walMode: Bool = false) throws {
        directory = try TempDirectory()
        database = try SQLiteDatabase(path: directory.path("cloud.db"), mode: .readWriteCreate)
        if walMode {
            try database.execute("PRAGMA journal_mode = WAL")
            try database.execute("PRAGMA wal_autocheckpoint = 0")
        }
        try database.execute("""
            CREATE TABLE "nodes" (
            "id" varchar primary key not null ,
            "name" varchar ,
            "kind" varchar ,
            "parents" varchar ,
            "labels" varchar ,
            "childAssetTypeInfo" varchar ,
            "assetType" varchar ,
            "createdDate" bigint ,
            "modifiedDate" bigint ,
            "isRoot" integer ,
            "isShared" integer ,
            "restricted" integer ,
            "createdBy" varchar ,
            "description" varchar ,
            "eTagResponse" varchar ,
            "status" varchar ,
            "purge_reason" varchar ,
            "protectedFolder" integer ,
            "version" integer ,
            "content_date" bigint ,
            "content_type" varchar ,
            "content_extension" varchar ,
            "content_md5" varchar ,
            "content_size" integer ,
            "content_version" integer ,
            "client_dateCreated" bigint ,
            "client_dateUpdated" bigint ,
            "hidden" integer );
            CREATE INDEX "ix_node_by_name_and_parent" on "nodes"("id", "name", "status");
            CREATE INDEX "IX_md5" on "nodes"("content_md5");
            CREATE TABLE node_parents(composite_id varchar, node_id varchar, node_parent_id varchar);
            CREATE TABLE node_image(node_id varchar primary key);
            CREATE TABLE node_video(node_id varchar primary key);
            CREATE TABLE node_covers(node_id varchar primary key);
            CREATE TABLE settings(key varchar primary key, value varchar);
            """)
    }

    func insert(
        id: String, name: String, kind: String = "FILE", assetType: String? = nil,
        parent: String = "FOLDER1", status: String = "AVAILABLE", md5: String?,
        size: Int64? = 1000, contentDate: Int64? = nil, createdDate: Int64? = nil,
        ext: String = "jpg"
    ) throws {
        try database.run("""
            INSERT INTO nodes(id, name, kind, parents, assetType, createdDate, status,
                              content_date, content_extension, content_md5, content_size)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [id, name, kind, "[\"\(parent)\"]", assetType, createdDate, status, contentDate, ext, md5, size])
    }

    /// A catalog that exercises every filter.
    static func standard(walMode: Bool = false) throws -> CloudFixture {
        let fixture = try CloudFixture(walMode: walMode)
        // Included: photos and videos
        try fixture.insert(id: "F1", name: "IMG_0001.jpg", md5: md5("1"), size: 1000, contentDate: ticks(unix: t2019))
        try fixture.insert(id: "F2", name: "IMG_0001 copy.jpg", md5: md5("1"), size: 1000, contentDate: ticks(unix: t2019))
        try fixture.insert(id: "F3", name: "IMG_0002.jpg", md5: md5("2"), size: 2000,
                           contentDate: 0, createdDate: ticks(unix: t2015))
        try fixture.insert(id: "F4", name: "VID_0003.mov", md5: md5("3"), size: 5000,
                           contentDate: nil, createdDate: ticks(unix: t2020), ext: "mov")
        try fixture.insert(id: "F5", name: "IMG_0004.heic", md5: md5("4").uppercased(), size: 3000,
                           contentDate: ticks(unix: t2009), ext: "heic")
        // Included: Live Photo videos
        try fixture.insert(id: "L1", name: "2009-07-04_10-00-00_001_lpv", kind: "ASSET", assetType: "LIVE_VIDEO",
                           parent: "F5", md5: md5("5"), size: 300, contentDate: ticks(unix: t2009), ext: "qt")
        try fixture.insert(id: "L2", name: "2019-06-18_04-02-57_002_lpv", kind: "ASSET", assetType: "LIVE_VIDEO",
                           parent: "F1", md5: md5("6"), size: 400, contentDate: ticks(unix: t2019), ext: "qt")
        // Ignored rows
        try fixture.insert(id: "X1", name: "purged.jpg", status: "PURGED", md5: md5("7"))
        try fixture.insert(id: "X2", name: "trashed.jpg", status: "TRASH", md5: md5("8"))
        try fixture.insert(id: "X3", name: "empty-md5.jpg", md5: "")
        try fixture.insert(id: "X4", name: "null-md5.jpg", md5: nil)
        try fixture.insert(id: "X5", name: "Folder", kind: "FOLDER", md5: md5("9"))
        try fixture.insert(id: "X6", name: "resource.bin", kind: "RESOURCE_FILE", md5: md5("a"))
        try fixture.insert(id: "X7", name: "thumb", kind: "ASSET", assetType: "THUMBNAIL", md5: md5("b"))
        try fixture.insert(id: "X8", name: "purged-live", kind: "ASSET", assetType: "LIVE_VIDEO",
                           status: "PURGED", md5: md5("c"))
        return fixture
    }
}

/// An in-memory catalog for tests that do not need the SQLite fixture.
struct StaticCatalog: CloudCatalogSource {
    var items: [CloudItem]
    var sourceName: String { "static" }

    func readCatalog(_ body: (CloudItem) throws -> Void) throws -> CatalogReadResult {
        for item in items { try body(item) }
        return CatalogReadResult(
            sourceDescription: "static", sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            itemCount: items.count)
    }
}

func makeStore() throws -> StateStore { try StateStore(path: ":memory:") }

/// A data folder and configuration inside a temporary directory, for tests of `RainbarrelTools`.
struct ToolsFixture {
    let home: TempDirectory
    let drive: TempDirectory
    let tools: RainbarrelTools

    init(
        driveSubpath: String? = nil, configureDrive: Bool = true,
        catalog: [CloudItem] = [],
        catalogError: (any Error)? = nil
    ) throws {
        home = try TempDirectory()
        drive = try TempDirectory()
        let paths = AppPaths(dataDirectory: home.url.appendingPathComponent("data", isDirectory: true))
        let source = StaticCatalog(items: catalog)
        tools = RainbarrelTools(paths: paths) { _ in
            if let catalogError { throw catalogError }
            return source
        }
        if configureDrive {
            try tools.saveConfig(Config(driveRoot: drive.path, scanSubpath: driveSubpath))
        }
    }
}
