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
    public static let catalogFolderCount = "catalog_folder_count"
    /// `app` or `web`: the source that produced the stored catalog (see `CatalogOrigin`).
    public static let catalogOrigin = "catalog_origin"
    /// JSON of the change-feed position of the stored web catalog (see `CatalogCheckpoint`).
    public static let catalogCheckpoint = "catalog_checkpoint"
    /// JSON of the last download run (see `DownloadRunRecord`).
    public static let downloadLastRun = "download_last_run"
    /// Prefix of the per-day counters of downloaded bytes; the local date (yyyy-MM-dd) follows.
    public static let downloadBytesPrefix = "download_bytes_"
}

/// The tool's own database (`state.sqlite`): the cloud catalog, the drive index, metadata and scan history.
public final class StateStore {
    /// 2 added `download_jobs.retry_after`.
    public static let schemaVersion = 2

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

    /// Open (and create when missing) the state database at `path`. Use ":memory:" for tests. `now`
    /// is the time a schema migration stamps on the rows it changes.
    public init(path: String, now: Date = Date()) throws {
        database = try SQLiteDatabase(path: path, mode: .readWriteCreate)
        // The CLI, the MCP server and the menu-bar app may use the same file at the same time:
        // WAL lets readers and one writer overlap, and writers wait up to 5 s for each other.
        try database.execute("PRAGMA busy_timeout = 5000")
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try createSchema()
        try migrate(now: now)
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
            CREATE TABLE IF NOT EXISTS cloud_folders(
                node_id   TEXT PRIMARY KEY,
                name      TEXT NOT NULL,
                parent_id TEXT
            );
            CREATE TABLE IF NOT EXISTS download_jobs(
                node_id         TEXT PRIMARY KEY,
                kind            TEXT NOT NULL,
                md5             TEXT NOT NULL,
                size            INTEGER NOT NULL,
                taken_at        INTEGER NOT NULL DEFAULT 0,
                target_rel_path TEXT NOT NULL,
                status          TEXT NOT NULL,
                attempts        INTEGER NOT NULL DEFAULT 0,
                last_error      TEXT,
                updated_at      INTEGER NOT NULL,
                retry_after     INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_download_jobs_queue ON download_jobs(status, taken_at);
            CREATE INDEX IF NOT EXISTS idx_download_jobs_md5 ON download_jobs(md5);
            CREATE TABLE IF NOT EXISTS drive_files(
                rel_path   TEXT PRIMARY KEY,
                size       INTEGER NOT NULL,
                mtime      INTEGER NOT NULL,
                md5        TEXT,
                hashed_at  INTEGER,
                last_error TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_drive_files_md5 ON drive_files(md5);
            CREATE TABLE IF NOT EXISTS organize_moves(
                run_id    INTEGER NOT NULL,
                from_path TEXT NOT NULL,
                to_path   TEXT NOT NULL,
                moved_at  INTEGER NOT NULL,
                size      INTEGER,
                mtime     INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_organize_moves_run ON organize_moves(run_id);
            CREATE TABLE IF NOT EXISTS organize_dirs(
                run_id INTEGER NOT NULL,
                path   TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_organize_dirs_run ON organize_dirs(run_id);
            CREATE TABLE IF NOT EXISTS meta(
                key   TEXT PRIMARY KEY,
                value TEXT
            );
            CREATE TABLE IF NOT EXISTS amazon_plans(
                id                   INTEGER PRIMARY KEY AUTOINCREMENT,
                planner              TEXT NOT NULL,
                title                TEXT NOT NULL,
                created_at           INTEGER NOT NULL,
                catalog_refreshed_at INTEGER,
                status               TEXT NOT NULL,
                applied_at           INTEGER,
                undone_at            INTEGER
            );
            CREATE TABLE IF NOT EXISTS amazon_plan_steps(
                plan_id         INTEGER NOT NULL,
                position        INTEGER NOT NULL,
                operation       TEXT NOT NULL,
                node_id         TEXT,
                parent_id       TEXT,
                from_value      TEXT,
                to_value        TEXT,
                reason          TEXT NOT NULL,
                group_label     TEXT,
                size            INTEGER NOT NULL DEFAULT 0,
                included        INTEGER NOT NULL DEFAULT 1,
                before_parent   TEXT,
                before_name     TEXT,
                before_status   TEXT,
                before_md5      TEXT,
                state           TEXT NOT NULL DEFAULT 'pending',
                result          TEXT,
                after_parent    TEXT,
                after_name      TEXT,
                after_status    TEXT,
                inverse_value   TEXT,
                created_node_id TEXT,
                reused          INTEGER NOT NULL DEFAULT 0,
                catalog_item    TEXT,
                updated_at      INTEGER,
                PRIMARY KEY(plan_id, position)
            );
            CREATE INDEX IF NOT EXISTS idx_amazon_plan_steps_state ON amazon_plan_steps(plan_id, state);
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

    /// Bring a database made by an earlier version up to date. A database that is current is only
    /// read. Otherwise the check is repeated inside a write transaction, so a step runs once even when
    /// two processes open the old file together.
    private func migrate(now: Date) throws {
        guard try !hasColumn("retry_after", in: "download_jobs") else { return }
        try database.transaction {
            guard try !hasColumn("retry_after", in: "download_jobs") else { return }
            // Version 2: `retry_after`. Jobs that the old rule made permanent after an HTTP 404 (it used
            // up all attempts at once) go back to failed with one attempt and are due now, so the next
            // run treats them as temporary failures, as the new rule does.
            try database.execute("ALTER TABLE download_jobs ADD COLUMN retry_after INTEGER")
            try database.run(
                """
                UPDATE download_jobs SET attempts = 1, retry_after = ?
                WHERE status = 'failed' AND last_error = ? AND attempts >= ?
                """,
                [Int64(now.timeIntervalSince1970), Self.legacyNotFoundReason, DownloadOptions.defaultMaxAttempts])
            try setMeta(MetaKey.schemaVersion, String(Self.schemaVersion))
        }
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        try database.rows("PRAGMA table_info(\(table))", map: { $0.string(1) ?? "" }).contains(column)
    }

    /// What the stored reason of a file said before HTTP 404 became `DownloadError.notAvailableYet`.
    static let legacyNotFoundReason = "Amazon answered HTTP 404"

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
    /// Sink for the folder tree; call it once per folder.
    public typealias CloudFolderSink = (CloudFolder) throws -> Void

    /// Replace the whole `cloud_items` table in one transaction. `fill` receives a sink and
    /// returns the read result; when it throws, the previous catalog is left untouched.
    /// The folder tree (`cloud_folders`) is not changed.
    ///
    /// The catalog is staged in a temporary table first, so reading the (slow) source holds no lock
    /// on the state database; only the final swap is a short write transaction.
    @discardableResult
    public func replaceCloudItems(
        seenAt: Date = Date(),
        fill: (CloudItemSink) throws -> CatalogReadResult
    ) throws -> CatalogReadResult {
        try replaceCatalog(seenAt: seenAt, replaceFolders: false, origin: nil) { items, _ in
            try withoutActuallyEscaping(items) { try fill($0) }
        }
    }

    /// Like `replaceCloudItems`, and also replaces `cloud_folders` with the folders passed to the
    /// second sink. With an `origin`, the swap also records where the catalog came from and replaces
    /// the stored change-feed checkpoint with `result.checkpoint` (none clears it).
    @discardableResult
    public func replaceCloudCatalog(
        seenAt: Date = Date(), origin: CatalogOrigin? = nil,
        fill: (CloudItemSink, CloudFolderSink) throws -> CatalogReadResult
    ) throws -> CatalogReadResult {
        try replaceCatalog(seenAt: seenAt, replaceFolders: true, origin: origin, fill: fill)
    }

    /// `replaceCloudCatalog` for a source that suspends while it reads (the web API). `fill` gets the
    /// staging area itself, so it can also take back a node it staged before. The staging transaction
    /// stays open across the suspensions, so nothing else may use this store meanwhile. When `fill`
    /// throws or the task is cancelled, the previous catalog is left untouched.
    @discardableResult
    public func replaceCloudCatalogAsync(
        seenAt: Date = Date(), origin: CatalogOrigin? = nil,
        fill: (CloudCatalogStaging) async throws -> CatalogReadResult
    ) async throws -> CatalogReadResult {
        try createStagingTables()
        defer { dropStagingTables() }
        let result: CatalogReadResult = try await database.transactionAsync(immediate: false) {
            try await fill(try CloudCatalogStaging(database: database, seenAt: seenAt))
        }
        try swapStaging(seenAt: seenAt, replaceFolders: true, origin: origin, result: result)
        return result
    }

    private func replaceCatalog(
        seenAt: Date, replaceFolders: Bool, origin: CatalogOrigin?,
        fill: (CloudItemSink, CloudFolderSink) throws -> CatalogReadResult
    ) throws -> CatalogReadResult {
        try createStagingTables()
        defer { dropStagingTables() }
        let result: CatalogReadResult = try database.transaction(immediate: false) {
            let staging = try CloudCatalogStaging(database: database, seenAt: seenAt)
            return try fill({ try staging.upsert($0) }, { try staging.upsert($0) })
        }
        try swapStaging(seenAt: seenAt, replaceFolders: replaceFolders, origin: origin, result: result)
        return result
    }

    private func createStagingTables() throws {
        try dropStagingTablesThrowing()
        try database.execute("""
            CREATE TEMP TABLE cloud_items_staging(
                node_id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT, md5 TEXT NOT NULL,
                size INTEGER NOT NULL, taken_at INTEGER NOT NULL, ext TEXT, parent_id TEXT,
                seen_at INTEGER NOT NULL);
            CREATE TEMP TABLE cloud_folders_staging(
                node_id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT)
            """)
    }

    private func dropStagingTablesThrowing() throws {
        try database.execute("DROP TABLE IF EXISTS temp.cloud_items_staging")
        try database.execute("DROP TABLE IF EXISTS temp.cloud_folders_staging")
    }

    private func dropStagingTables() {
        try? dropStagingTablesThrowing()
    }

    private func swapStaging(
        seenAt: Date, replaceFolders: Bool, origin: CatalogOrigin?, result: CatalogReadResult
    ) throws {
        try database.transaction {
            try database.execute("DELETE FROM cloud_items")
            try database.execute("INSERT INTO cloud_items SELECT * FROM temp.cloud_items_staging")
            if replaceFolders {
                try database.execute("DELETE FROM cloud_folders")
                try database.execute("INSERT INTO cloud_folders SELECT * FROM temp.cloud_folders_staging")
                try setMeta(MetaKey.catalogFolderCount, String(result.folderCount))
            }
            try dropNodesTrashedByPlans(now: seenAt)
            try setMetaDate(MetaKey.catalogRefreshedAt, seenAt)
            try setMetaDate(MetaKey.catalogSourceModifiedAt, result.sourceModifiedAt)
            try setMeta(MetaKey.catalogItemCount, String(result.itemCount))
            try setMeta(MetaKey.catalogSource, result.sourceDescription)
            if let origin {
                try setMeta(MetaKey.catalogOrigin, origin.rawValue)
                try setCatalogCheckpoint(result.checkpoint)
            }
        }
    }

    /// How long a node that an applied plan trashed stays out of a refreshed catalog although the
    /// source still lists it. The Amazon Photos app's local index learns about a trash only when the
    /// app syncs, which can take days; after this window the source is trusted again, so a file that
    /// was restored on the Amazon Photos website comes back.
    public static let planTrashGracePeriod: TimeInterval = 14 * 24 * 3600

    /// Remove from the catalog every node that a plan step trashed within `planTrashGracePeriod` and
    /// that was not undone since. Runs inside the transaction that installs a refreshed catalog.
    private func dropNodesTrashedByPlans(now: Date) throws {
        let since = Int64(now.timeIntervalSince1970 - Self.planTrashGracePeriod)
        let trashed = """
            SELECT node_id FROM amazon_plan_steps
            WHERE operation = '\(PlanOperation.trash.rawValue)' AND state = '\(PlanStepState.done.rawValue)'
              AND node_id IS NOT NULL AND updated_at >= ?
            """
        try database.run("DELETE FROM cloud_items WHERE node_id IN (\(trashed))", [since])
        try database.run("DELETE FROM cloud_folders WHERE node_id IN (\(trashed))", [since])
    }

    /// Apply the changes of Amazon's change feed to the stored catalog and move the checkpoint, in one
    /// transaction. Returns the number of items and folders in the catalog afterwards.
    @discardableResult
    public func applyCatalogChanges(
        _ changes: CatalogChangeSet, seenAt: Date, sourceModifiedAt: Date, sourceDescription: String,
        origin: CatalogOrigin, checkpoint: CatalogCheckpoint?
    ) throws -> (items: Int, folders: Int) {
        let seenAtSeconds = Int64(seenAt.timeIntervalSince1970)
        return try database.transaction {
            let deleteItem = try database.prepare("DELETE FROM cloud_items WHERE node_id = ?")
            let deleteFolder = try database.prepare("DELETE FROM cloud_folders WHERE node_id = ?")
            for nodeId in changes.removed {
                try deleteItem.run([nodeId])
                try deleteFolder.run([nodeId])
            }
            let upsertItem = try database.prepare("""
                INSERT OR REPLACE INTO cloud_items
                    (node_id, kind, name, md5, size, taken_at, ext, parent_id, seen_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for item in changes.items.values {
                try upsertItem.run([
                    item.nodeId, item.kind.rawValue, item.name, item.md5, item.size,
                    item.takenAt, item.ext, item.parentId, seenAtSeconds,
                ])
            }
            let upsertFolder = try database.prepare(
                "INSERT OR REPLACE INTO cloud_folders(node_id, name, parent_id) VALUES(?, ?, ?)")
            for folder in changes.folders.values {
                try upsertFolder.run([folder.nodeId, folder.name, folder.parentId])
            }
            let itemCount = try cloudItemCount()
            let folderCount = try cloudFolderCount()
            try setMeta(MetaKey.catalogFolderCount, String(folderCount))
            try setMetaDate(MetaKey.catalogRefreshedAt, seenAt)
            try setMetaDate(MetaKey.catalogSourceModifiedAt, sourceModifiedAt)
            try setMeta(MetaKey.catalogItemCount, String(itemCount))
            try setMeta(MetaKey.catalogSource, sourceDescription)
            try setMeta(MetaKey.catalogOrigin, origin.rawValue)
            try setCatalogCheckpoint(checkpoint)
            return (itemCount, folderCount)
        }
    }

    // MARK: catalog origin and checkpoint

    /// Which source produced the stored catalog; nil for a catalog that was never refreshed.
    public func catalogOrigin() throws -> CatalogOrigin? {
        try getMeta(MetaKey.catalogOrigin).flatMap { CatalogOrigin(rawValue: $0) }
    }

    /// The stored change-feed checkpoint; nil when there is none or it cannot be read.
    public func catalogCheckpoint() throws -> CatalogCheckpoint? {
        guard let text = try getMeta(MetaKey.catalogCheckpoint) else { return nil }
        return try? JSONDecoder().decode(CatalogCheckpoint.self, from: Data(text.utf8))
    }

    /// Store a checkpoint, or clear it with nil.
    public func setCatalogCheckpoint(_ checkpoint: CatalogCheckpoint?) throws {
        guard let checkpoint else {
            try setMeta(MetaKey.catalogCheckpoint, nil)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try setMeta(MetaKey.catalogCheckpoint, String(decoding: try encoder.encode(checkpoint), as: UTF8.self))
    }

    public func cloudFolderCount() throws -> Int {
        Int(try database.scalarInt64("SELECT COUNT(*) FROM cloud_folders") ?? 0)
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

/// The temporary tables a catalog replacement is built in. A node id has at most one row and the
/// last call about it wins, so a source may hand over a node every time it sees it. The stored
/// catalog is not touched until the replacement swaps the tables in.
public struct CloudCatalogStaging {
    private let database: SQLiteDatabase
    private let insertItem: SQLiteStatement
    private let insertFolder: SQLiteStatement
    private let deleteItem: SQLiteStatement
    private let deleteFolder: SQLiteStatement
    private let seenAt: Int64

    init(database: SQLiteDatabase, seenAt: Date) throws {
        self.database = database
        self.seenAt = Int64(seenAt.timeIntervalSince1970)
        insertItem = try database.prepare("""
            INSERT OR REPLACE INTO temp.cloud_items_staging
                (node_id, kind, name, md5, size, taken_at, ext, parent_id, seen_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        insertFolder = try database.prepare("""
            INSERT OR REPLACE INTO temp.cloud_folders_staging(node_id, name, parent_id)
            VALUES(?, ?, ?)
            """)
        deleteItem = try database.prepare("DELETE FROM temp.cloud_items_staging WHERE node_id = ?")
        deleteFolder = try database.prepare("DELETE FROM temp.cloud_folders_staging WHERE node_id = ?")
    }

    public func upsert(_ item: CloudItem) throws {
        try insertItem.run([
            item.nodeId, item.kind.rawValue, item.name, item.md5, item.size, item.takenAt, item.ext,
            item.parentId, seenAt,
        ])
    }

    public func upsert(_ folder: CloudFolder) throws {
        try insertFolder.run([folder.nodeId, folder.name, folder.parentId])
    }

    /// Forget a node that was staged earlier (it was trashed or purged since).
    public func remove(_ nodeId: String) throws {
        try deleteItem.run([nodeId])
        try deleteFolder.run([nodeId])
    }

    /// Forget everything staged so far.
    public func removeAll() throws {
        try database.execute("DELETE FROM temp.cloud_items_staging")
        try database.execute("DELETE FROM temp.cloud_folders_staging")
    }

    /// What is staged right now: all items, the folders, and the items that are photo and video files.
    public func counts() throws -> (items: Int, folders: Int, files: Int) {
        let items = try database.scalarInt64("SELECT COUNT(*) FROM temp.cloud_items_staging") ?? 0
        let folders = try database.scalarInt64("SELECT COUNT(*) FROM temp.cloud_folders_staging") ?? 0
        let files = try database.scalarInt64(
            "SELECT COUNT(*) FROM temp.cloud_items_staging WHERE kind = ?", [CloudItemKind.file.rawValue]) ?? 0
        return (Int(items), Int(folders), Int(files))
    }
}
