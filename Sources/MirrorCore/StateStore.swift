import Foundation

/// One file of the backup drive as recorded in `drive_files`.
public struct DriveFileRecord: Codable, Sendable, Equatable {
    /// Path relative to the drive root, with `/` separators.
    public var relPath: String
    public var size: Int64
    /// Modification time in Unix seconds. 0 marks a row that came from a seed import.
    public var mtime: Int64
    public var md5: String?
    public var hashedAt: Int64?
    public var lastError: String?

    public init(
        relPath: String, size: Int64, mtime: Int64, md5: String? = nil,
        hashedAt: Int64? = nil, lastError: String? = nil
    ) {
        self.relPath = relPath
        self.size = size
        self.mtime = mtime
        self.md5 = md5
        self.hashedAt = hashedAt
        self.lastError = lastError
    }
}

/// One row of the `scans` table.
public struct ScanRecord: Codable, Sendable, Equatable {
    public var id: Int64
    public var startedAt: Date
    public var finishedAt: Date?
    public var filesSeen: Int
    public var filesHashed: Int
    public var errors: Int
}

/// Well-known keys of the `meta` table.
public enum MetaKey {
    public static let schemaVersion = "schema_version"
    public static let catalogRefreshedAt = "catalog_refreshed_at"
    public static let catalogSourceModifiedAt = "catalog_source_modified_at"
    public static let catalogItemCount = "catalog_item_count"
    public static let catalogSource = "catalog_source"
}

/// The tool's own database (`state.sqlite`): the cloud catalog, the drive index, metadata and scan history.
public final class StateStore {
    public static let schemaVersion = 1

    public let database: SQLiteDatabase

    private lazy var selectDriveFile = try! database.prepare(
        "SELECT rel_path, size, mtime, md5, hashed_at, last_error FROM drive_files WHERE rel_path = ?")
    private lazy var upsertDriveFileStatement = try! database.prepare("""
        INSERT INTO drive_files(rel_path, size, mtime, md5, hashed_at, last_error)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(rel_path) DO UPDATE SET
            size = excluded.size, mtime = excluded.mtime, md5 = excluded.md5,
            hashed_at = excluded.hashed_at, last_error = excluded.last_error
        """)

    /// Open (and create when missing) the state database at `path`. Use ":memory:" for tests.
    public init(path: String) throws {
        database = try SQLiteDatabase(path: path, mode: .readWriteCreate)
        // The CLI, the MCP server and the menu-bar app may use the same file at the same time:
        // WAL lets readers and one writer overlap, and writers wait up to 5 s for each other.
        try database.execute("PRAGMA busy_timeout = 5000")
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try createSchema()
    }

    private func createSchema() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS cloud_items(
                node_id   TEXT PRIMARY KEY,
                kind      TEXT NOT NULL,
                name      TEXT,
                md5       TEXT NOT NULL,
                size      INTEGER NOT NULL,
                taken_at  INTEGER NOT NULL,
                ext       TEXT,
                parent_id TEXT,
                seen_at   INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_cloud_items_md5 ON cloud_items(md5);
            CREATE TABLE IF NOT EXISTS drive_files(
                rel_path   TEXT PRIMARY KEY,
                size       INTEGER NOT NULL,
                mtime      INTEGER NOT NULL,
                md5        TEXT,
                hashed_at  INTEGER,
                last_error TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_drive_files_md5 ON drive_files(md5);
            CREATE TABLE IF NOT EXISTS meta(
                key   TEXT PRIMARY KEY,
                value TEXT
            );
            CREATE TABLE IF NOT EXISTS scans(
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at   INTEGER NOT NULL,
                finished_at  INTEGER,
                files_seen   INTEGER NOT NULL DEFAULT 0,
                files_hashed INTEGER NOT NULL DEFAULT 0,
                errors       INTEGER NOT NULL DEFAULT 0
            );
            """)
        if try getMeta(MetaKey.schemaVersion) == nil {
            try setMeta(MetaKey.schemaVersion, String(Self.schemaVersion))
        }
    }

    // MARK: meta

    public func getMeta(_ key: String) throws -> String? {
        try database.scalarString("SELECT value FROM meta WHERE key = ?", [key])
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        try database.run(
            "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value])
    }

    public func getMetaDate(_ key: String) throws -> Date? {
        guard let text = try getMeta(key), let seconds = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func setMetaDate(_ key: String, _ date: Date) throws {
        try setMeta(key, String(Int64(date.timeIntervalSince1970)))
    }

    // MARK: cloud_items

    /// Sink handed to the catalog fill closure; call it once per item.
    public typealias CloudItemSink = (CloudItem) throws -> Void

    /// Replace the whole `cloud_items` table in one transaction. `fill` receives a sink and
    /// returns the read result; when it throws, the previous catalog is left untouched.
    ///
    /// The catalog is staged in a temporary table first, so reading the (slow) source holds no lock
    /// on the state database; only the final swap is a short write transaction.
    @discardableResult
    public func replaceCloudItems(
        seenAt: Date = Date(),
        fill: (CloudItemSink) throws -> CatalogReadResult
    ) throws -> CatalogReadResult {
        try database.execute("DROP TABLE IF EXISTS temp.cloud_items_staging")
        try database.execute("""
            CREATE TEMP TABLE cloud_items_staging(
                node_id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT, md5 TEXT NOT NULL,
                size INTEGER NOT NULL, taken_at INTEGER NOT NULL, ext TEXT, parent_id TEXT,
                seen_at INTEGER NOT NULL)
            """)
        defer { try? database.execute("DROP TABLE IF EXISTS temp.cloud_items_staging") }

        let seenAtSeconds = Int64(seenAt.timeIntervalSince1970)
        let result: CatalogReadResult = try database.transaction(immediate: false) {
            let insert = try database.prepare("""
                INSERT OR REPLACE INTO temp.cloud_items_staging
                    (node_id, kind, name, md5, size, taken_at, ext, parent_id, seen_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            return try fill { item in
                try insert.run([
                    item.nodeId, item.kind.rawValue, item.name, item.md5, item.size,
                    item.takenAt, item.ext, item.parentId, seenAtSeconds,
                ])
            }
        }

        try database.transaction {
            try database.execute("DELETE FROM cloud_items")
            try database.execute("INSERT INTO cloud_items SELECT * FROM temp.cloud_items_staging")
            try setMetaDate(MetaKey.catalogRefreshedAt, seenAt)
            try setMetaDate(MetaKey.catalogSourceModifiedAt, result.sourceModifiedAt)
            try setMeta(MetaKey.catalogItemCount, String(result.itemCount))
            try setMeta(MetaKey.catalogSource, result.sourceDescription)
        }
        return result
    }

    public func cloudItemCount() throws -> Int {
        Int(try database.scalarInt64("SELECT COUNT(*) FROM cloud_items") ?? 0)
    }

    // MARK: drive_files

    public func driveFile(relPath: String) throws -> DriveFileRecord? {
        selectDriveFile.reset()
        try selectDriveFile.bind([relPath])
        guard try selectDriveFile.step() else { return nil }
        return Self.driveFileRecord(from: selectDriveFile)
    }

    static func driveFileRecord(from row: SQLiteStatement) -> DriveFileRecord {
        DriveFileRecord(
            relPath: row.string(0) ?? "",
            size: row.int64(1),
            mtime: row.int64(2),
            md5: row.string(3),
            hashedAt: row.isNull(4) ? nil : row.int64(4),
            lastError: row.string(5)
        )
    }

    /// Insert or replace a drive file row.
    public func upsertDriveFile(_ record: DriveFileRecord) throws {
        try upsertDriveFileStatement.run([
            record.relPath, record.size, record.mtime, record.md5, record.hashedAt, record.lastError,
        ])
    }

    /// Record a failure for a path without disturbing a hash that is already stored.
    /// Creates the row when missing.
    public func recordDriveFileError(relPath: String, size: Int64, mtime: Int64, message: String) throws {
        try database.run("""
            INSERT INTO drive_files(rel_path, size, mtime, md5, hashed_at, last_error)
            VALUES(?, ?, ?, NULL, NULL, ?)
            ON CONFLICT(rel_path) DO UPDATE SET last_error = excluded.last_error
            """, [relPath, size, mtime, message])
    }

    /// Update only the mtime of a row (used when adopting seed-imported hashes).
    public func updateDriveFileMTime(relPath: String, mtime: Int64) throws {
        try database.run("UPDATE drive_files SET mtime = ? WHERE rel_path = ?", [mtime, relPath])
    }

    /// Delete rows by path in one short transaction. Returns the number of rows removed.
    @discardableResult
    public func deleteDriveFiles(_ relPaths: [String]) throws -> Int {
        guard !relPaths.isEmpty else { return 0 }
        return try database.transaction {
            let delete = try database.prepare("DELETE FROM drive_files WHERE rel_path = ?")
            var removed = 0
            for path in relPaths {
                try delete.run([path])
                removed += database.changes
            }
            return removed
        }
    }

    /// Paths of every row inside `scope`, in path order.
    public func forEachDriveFilePath(in scope: DriveScope, _ body: (String) throws -> Void) throws {
        let statement = try database.prepare("""
            SELECT rel_path FROM drive_files WHERE \(scope.sqlCondition(column: "rel_path")) ORDER BY rel_path
            """)
        while try statement.step() {
            if let path = statement.string(0) { try body(path) }
        }
    }

    /// Remove rows for housekeeping files (see `SkipRules`), such as ones imported before the
    /// rules existed. Returns the number of rows removed.
    @discardableResult
    public func removeSkippedDriveFiles() throws -> Int {
        var doomed: [String] = []
        try forEachDriveFilePath(in: .wholeDrive) { path in
            if SkipRules.shouldSkip(relPath: path) { doomed.append(path) }
        }
        return try deleteDriveFiles(doomed)
    }

    /// Remove rows that lie outside `scope`. Returns the number of rows removed.
    @discardableResult
    public func removeDriveFiles(outside scope: DriveScope) throws -> Int {
        guard !scope.isWholeDrive else { return 0 }
        return try database.transaction {
            try database.run("DELETE FROM drive_files WHERE NOT \(scope.sqlCondition(column: "rel_path"))")
            return database.changes
        }
    }

    public func driveFileCount() throws -> Int {
        Int(try database.scalarInt64("SELECT COUNT(*) FROM drive_files") ?? 0)
    }

    // MARK: scans

    public func beginScan(startedAt: Date = Date()) throws -> Int64 {
        try database.run(
            "INSERT INTO scans(started_at) VALUES(?)", [Int64(startedAt.timeIntervalSince1970)])
        return database.lastInsertRowID
    }

    public func finishScan(
        id: Int64, finishedAt: Date = Date(), filesSeen: Int, filesHashed: Int, errors: Int
    ) throws {
        try database.run(
            "UPDATE scans SET finished_at = ?, files_seen = ?, files_hashed = ?, errors = ? WHERE id = ?",
            [Int64(finishedAt.timeIntervalSince1970), filesSeen, filesHashed, errors, id])
    }

    public func scans(limit: Int = 20) throws -> [ScanRecord] {
        try database.rows(
            "SELECT id, started_at, finished_at, files_seen, files_hashed, errors FROM scans ORDER BY id DESC LIMIT ?",
            [limit]
        ) { row in
            ScanRecord(
                id: row.int64(0),
                startedAt: Date(timeIntervalSince1970: TimeInterval(row.int64(1))),
                finishedAt: row.isNull(2) ? nil : Date(timeIntervalSince1970: TimeInterval(row.int64(2))),
                filesSeen: row.int(3), filesHashed: row.int(4), errors: row.int(5))
        }
    }

    /// Time of the most recent scan (finish time, or start time when it never finished).
    public func lastScanTime() throws -> Date? {
        guard let seconds = try database.scalarInt64(
            "SELECT MAX(COALESCE(finished_at, started_at)) FROM scans") else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
