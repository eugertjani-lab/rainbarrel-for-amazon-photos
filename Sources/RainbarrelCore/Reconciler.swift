import Foundation

/// Compares the cloud catalog with the drive index (both held in the `StateStore`) by MD5.
/// Only drive rows inside `scope` (the configured scan root) count.
public struct Reconciler {
    public let store: StateStore
    public let scope: DriveScope

    public init(store: StateStore, scope: DriveScope = .wholeDrive) {
        self.store = store
        self.scope = scope
    }

    private var database: SQLiteDatabase { store.database }

    /// Drive rows that count: inside the scope, aliased as `d`.
    private var driveScope: String { scope.sqlCondition(column: "d.rel_path") }
    private var backedUp: String {
        "EXISTS (SELECT 1 FROM drive_files d WHERE d.md5 = c.md5 AND \(driveScope))"
    }
    private var notBackedUp: String {
        "NOT EXISTS (SELECT 1 FROM drive_files d WHERE d.md5 = c.md5 AND \(driveScope))"
    }

    /// Build the full report.
    /// - Parameters:
    ///   - driveRoot: configured drive root, reported together with whether it currently exists.
    ///   - now: timestamp for `generatedAt`.
    public func report(driveRoot: String?, now: Date = Date()) throws -> SyncReport {
        func pair(_ sql: String) throws -> [String: CountBytes] {
            var result: [String: CountBytes] = [:]
            for (kind, value) in try database.rows(sql, map: { row in
                (row.string(0) ?? "", CountBytes(count: row.int(1), bytes: row.int64(2)))
            }) {
                result[kind] = value
            }
            return result
        }
        let file = CloudItemKind.file.rawValue
        let live = CloudItemKind.liveVideo.rawValue

        let totals = try pair("SELECT kind, COUNT(*), COALESCE(SUM(size), 0) FROM cloud_items GROUP BY kind")
        let backedUpTotals = try pair("""
            SELECT c.kind, COUNT(*), COALESCE(SUM(c.size), 0) FROM cloud_items c
            WHERE \(backedUp) GROUP BY c.kind
            """)
        let distinct = try database.scalarInt64(
            "SELECT COUNT(DISTINCT md5) FROM cloud_items WHERE kind = ?", [file]) ?? 0

        func minus(_ a: CountBytes?, _ b: CountBytes?) -> CountBytes {
            CountBytes(count: (a?.count ?? 0) - (b?.count ?? 0), bytes: (a?.bytes ?? 0) - (b?.bytes ?? 0))
        }

        // Duplicates in the cloud share one drive copy, so size each distinct MD5 once. A Live Photo
        // video that has the same MD5 as a photo is the same bytes too.
        let distinctBytes = try database.scalarInt64("""
            SELECT COALESCE(SUM(size), 0) FROM (
                SELECT MAX(c.size) AS size FROM cloud_items c WHERE \(notBackedUp) GROUP BY c.md5)
            """) ?? 0

        let driveOnly = try database.rows("""
            SELECT COUNT(*), COALESCE(SUM(d.size), 0) FROM drive_files d
            WHERE d.md5 IS NOT NULL AND \(driveScope)
              AND NOT EXISTS (SELECT 1 FROM cloud_items c WHERE c.md5 = d.md5)
            """) { CountBytes(count: $0.int(0), bytes: $0.int64(1)) }.first ?? CountBytes()
        let hashed = try database.scalarInt64(
            "SELECT COUNT(*) FROM drive_files d WHERE d.md5 IS NOT NULL AND \(driveScope)") ?? 0
        let unhashed = try database.scalarInt64(
            "SELECT COUNT(*) FROM drive_files d WHERE d.md5 IS NULL AND \(driveScope)") ?? 0
        let withErrors = try database.scalarInt64(
            "SELECT COUNT(*) FROM drive_files d WHERE d.last_error IS NOT NULL AND \(driveScope)") ?? 0

        let years = try database.rows("""
            SELECT CAST(strftime('%Y', c.taken_at, 'unixepoch') AS INTEGER) AS year,
                   COUNT(*),
                   COALESCE(SUM(CASE WHEN \(backedUp) THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(c.size), 0)
            FROM cloud_items c WHERE c.kind = ? GROUP BY year ORDER BY year
            """, [file]) { row in
            YearRow(
                year: row.int(0), cloudCount: row.int(1), inSync: row.int(2),
                onlineOnly: row.int(1) - row.int(2), cloudBytes: row.int64(3))
        }

        let mounted: Bool
        if let driveRoot, !driveRoot.isEmpty {
            var isDirectory: ObjCBool = false
            mounted = FileManager.default.fileExists(atPath: driveRoot, isDirectory: &isDirectory)
                && isDirectory.boolValue
        } else {
            mounted = false
        }

        return SyncReport(
            generatedAt: now,
            photosVideos: totals[file] ?? CountBytes(),
            distinctMD5: Int(distinct),
            inSync: backedUpTotals[file] ?? CountBytes(),
            onlineOnly: minus(totals[file], backedUpTotals[file]),
            onlineOnlyDistinctBytes: distinctBytes,
            liveVideos: totals[live] ?? CountBytes(),
            liveVideosInSync: backedUpTotals[live] ?? CountBytes(),
            liveVideosOnlineOnly: minus(totals[live], backedUpTotals[live]),
            driveOnly: driveOnly,
            driveHashedFiles: Int(hashed),
            driveUnhashedFiles: Int(unhashed),
            driveFilesWithErrors: Int(withErrors),
            years: years,
            catalogFreshness: try store.getMetaDate(MetaKey.catalogSourceModifiedAt),
            catalogRefreshedAt: try store.getMetaDate(MetaKey.catalogRefreshedAt),
            driveRoot: driveRoot,
            scanSubpath: scope.isWholeDrive ? nil : scope.directoryPath,
            driveMounted: mounted,
            lastScanAt: try store.lastScanTime(),
            driveSpace: mounted ? driveRoot.flatMap { DriveSpace.read(at: $0) } : nil
        )
    }

    // MARK: Listings

    private static func yearClause(_ year: Int?) -> String {
        year == nil ? "" : "AND CAST(strftime('%Y', c.taken_at, 'unixepoch') AS INTEGER) = ?"
    }

    /// Number of photos and videos without a copy on the drive (optionally in one year).
    public func onlineOnlyCount(year: Int? = nil) throws -> Int {
        let args: [any SQLiteBindable] = year.map { [$0] } ?? []
        return Int(try database.scalarInt64("""
            SELECT COUNT(*) FROM cloud_items c
            WHERE c.kind = 'file' AND \(notBackedUp) \(Self.yearClause(year))
            """, args) ?? 0)
    }

    /// Photos and videos that exist only in the cloud, oldest first.
    public func onlineOnly(year: Int? = nil, limit: Int, offset: Int = 0) throws -> [OnlineOnlyItem] {
        var args: [any SQLiteBindable] = []
        if let year { args.append(year) }
        args.append(limit)
        args.append(offset)
        return try database.rows("""
            SELECT c.node_id, c.name, c.md5, c.size, c.taken_at, c.ext, c.parent_id
            FROM cloud_items c
            WHERE c.kind = 'file' AND \(notBackedUp) \(Self.yearClause(year))
            ORDER BY c.taken_at, c.node_id LIMIT ? OFFSET ?
            """, args) { row in
            OnlineOnlyItem(
                nodeId: row.string(0) ?? "", name: row.string(1) ?? "", md5: row.string(2) ?? "",
                size: row.int64(3), takenAt: row.int64(4), ext: row.string(5), parentId: row.string(6))
        }
    }

    public func onlineOnlyPage(year: Int? = nil, limit: Int, offset: Int = 0) throws -> Page<OnlineOnlyItem> {
        Page(
            total: try onlineOnlyCount(year: year), offset: offset, limit: limit,
            items: try onlineOnly(year: year, limit: limit, offset: offset))
    }

    public func driveOnlyCount() throws -> Int {
        Int(try database.scalarInt64("""
            SELECT COUNT(*) FROM drive_files d WHERE d.md5 IS NOT NULL AND \(driveScope)
              AND NOT EXISTS (SELECT 1 FROM cloud_items c WHERE c.md5 = d.md5)
            """) ?? 0)
    }

    /// Hashed drive files whose MD5 is in neither cloud table, ordered by path.
    public func driveOnly(limit: Int, offset: Int = 0) throws -> [DriveOnlyItem] {
        try database.rows("""
            SELECT d.rel_path, d.md5, d.size, d.mtime FROM drive_files d
            WHERE d.md5 IS NOT NULL AND \(driveScope)
              AND NOT EXISTS (SELECT 1 FROM cloud_items c WHERE c.md5 = d.md5)
            ORDER BY d.rel_path LIMIT ? OFFSET ?
            """, [limit, offset]) { row in
            DriveOnlyItem(
                relPath: row.string(0) ?? "", md5: row.string(1) ?? "", size: row.int64(2), mtime: row.int64(3))
        }
    }

    public func driveOnlyPage(limit: Int, offset: Int = 0) throws -> Page<DriveOnlyItem> {
        Page(
            total: try driveOnlyCount(), offset: offset, limit: limit,
            items: try driveOnly(limit: limit, offset: offset))
    }
}
