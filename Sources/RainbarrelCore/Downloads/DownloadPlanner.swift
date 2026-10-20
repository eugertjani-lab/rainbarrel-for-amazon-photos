import Foundation

/// Works out where each online-only file belongs on the drive.
///
/// The target is `<scan subpath>/<cloud folder path>/<file name>`: the chain of cloud folder names
/// from the root (left out) down to the file's folder. When the chain cannot be followed the file
/// goes to `<scan subpath>/_Unsorted/<year>/<month>/`. A Live Photo video lands in its photo's
/// folder and is named `<photo name without extension>.MOV`, which is how Apple Photos pairs them.
final class TargetBuilder {
    static let unsortedFolder = "_Unsorted"

    private let scanComponents: [String]
    private var folders: [String: CloudFolder] = [:]
    private let photoLookup: SQLiteStatement
    private var gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    init(store: StateStore, scanSubpath: String?) throws {
        scanComponents = try DriveScope(scanSubpath: scanSubpath).components
        for folder in try store.database.rows(
            "SELECT node_id, name, parent_id FROM cloud_folders",
            map: { CloudFolder(nodeId: $0.string(0) ?? "", name: $0.string(1) ?? "", parentId: $0.string(2)) })
        {
            folders[folder.nodeId] = folder
        }
        photoLookup = try store.database.prepare(
            "SELECT name, parent_id, ext FROM cloud_items WHERE node_id = ? AND kind = 'file'")
    }

    /// Sanitised folder names from the root down to `folderId`, or nil if the chain is broken.
    func folderPath(startingAt folderId: String?) -> [String]? {
        guard var current = folderId, !current.isEmpty else { return nil }
        var names: [String] = []
        for _ in 0..<64 {
            guard let folder = folders[current] else { return nil }
            guard let parent = folder.parentId, !parent.isEmpty else {
                return names.reversed()  // `folder` is the root: left out
            }
            names.append(FileNameSanitizer.sanitize(folder.name))
            current = parent
        }
        return nil
    }

    /// `<YYYY>/<MM>` of the capture time (UTC), or `unknown-date` when the catalog has none.
    private func unsortedPath(takenAt: Int64) -> [String] {
        guard takenAt > 0 else { return [Self.unsortedFolder, "unknown-date"] }
        let parts = gregorianUTC.dateComponents([.year, .month], from: Date(timeIntervalSince1970: TimeInterval(takenAt)))
        return [
            Self.unsortedFolder, String(format: "%04d", parts.year ?? 0), String(format: "%02d", parts.month ?? 0),
        ]
    }

    /// File name from the cloud name; adds the catalog extension when the name has none.
    static func fileName(for item: CloudItem) -> String {
        var name = FileNameSanitizer.sanitize(item.name.isEmpty ? item.nodeId : item.name)
        let ext = (item.ext ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if !ext.isEmpty, FileNameSanitizer.split(name).ext.isEmpty {
            name = FileNameSanitizer.truncated(name + "." + FileNameSanitizer.sanitize(ext), maxBytes: 255)
        }
        return name
    }

    /// The path below the drive root for `item`, and whether the cloud folder chain was followed.
    func target(for item: CloudItem) -> (relPath: String, resolved: Bool) {
        var folderNames: [String]?
        var name: String
        switch item.kind {
        case .file:
            folderNames = folderPath(startingAt: item.parentId)
            name = Self.fileName(for: item)
        case .liveVideo:
            if let parent = item.parentId, let photo = lookupPhoto(parent) {
                folderNames = folderPath(startingAt: photo.parentId)
                let photoName = FileNameSanitizer.sanitize(photo.name.isEmpty ? parent : photo.name)
                name = FileNameSanitizer.truncated(FileNameSanitizer.split(photoName).stem, maxBytes: 250) + ".MOV"
            } else {
                folderNames = nil
                let own = FileNameSanitizer.sanitize(item.name.isEmpty ? item.nodeId : item.name)
                name = FileNameSanitizer.truncated(FileNameSanitizer.split(own).stem, maxBytes: 250) + ".MOV"
            }
        }
        let resolved = folderNames != nil
        let folderPart = folderNames ?? unsortedPath(takenAt: item.takenAt)
        return ((scanComponents + folderPart + [name]).joined(separator: "/"), resolved)
    }

    private func lookupPhoto(_ nodeId: String) -> (name: String, parentId: String?)? {
        photoLookup.reset()
        guard (try? photoLookup.bind([nodeId])) != nil, (try? photoLookup.step()) == true else { return nil }
        return (photoLookup.string(0) ?? "", photoLookup.string(1))
    }
}

/// One entry of a dry run.
public struct PlannedDownload: Codable, Sendable, Equatable {
    public var nodeId: String
    public var kind: CloudItemKind
    public var size: Int64
    public var takenAt: Int64
    /// The name a clean target would get.
    public var targetRelPath: String
    /// The name the file would really get now (differs when the target is taken).
    public var finalRelPath: String
    public var resolvedFolders: Bool
    /// A sentence about an existing file at the target, if any.
    public var note: String?
}

/// Reads the candidates of a download (online-only items) and builds the plan.
public struct DownloadPlanner {
    public let store: StateStore
    public let config: Config

    public init(store: StateStore, config: Config) {
        self.store = store
        self.config = config
    }

    /// Unix-second range of a calendar year in UTC, the same year reckoning as the reports.
    static func range(ofYear year: Int) -> (start: Int64, end: Int64) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? start
        return (Int64(start.timeIntervalSince1970), Int64(end.timeIntervalSince1970))
    }

    /// Call `body` for every cloud item without a copy on the drive (inside the scan scope), newest
    /// first. `body` returns false to stop. With `withoutBlockedFailures`, items whose job failed and
    /// is not due for a retry at `now` (a cool-down is running, or the attempts are used up) are
    /// left out: those are the items a download run would not touch.
    func forEachCandidate(
        includeLiveVideos: Bool, year: Int?, withoutBlockedFailures: (maxAttempts: Int, now: Int64)? = nil,
        _ body: (CloudItem) throws -> Bool
    ) throws {
        let scope = try DriveScope(scanSubpath: config.scanSubpath)
        let kinds = includeLiveVideos ? "c.kind IN ('file', 'live_video')" : "c.kind = 'file'"
        var args: [any SQLiteBindable] = []
        var yearClause = ""
        if let year {
            let range = Self.range(ofYear: year)
            yearClause = "AND c.taken_at >= ? AND c.taken_at < ?"
            args = [range.start, range.end]
        }
        var failureClause = ""
        if let blocked = withoutBlockedFailures {
            failureClause = """
                AND NOT EXISTS (SELECT 1 FROM download_jobs j
                                WHERE j.node_id = c.node_id AND j.status = 'failed'
                                  AND NOT \(DownloadJobTable.failedIsDue(alias: "j")))
                """
            args += DownloadJobTable.failedIsDueArguments(maxAttempts: blocked.maxAttempts, now: blocked.now)
        }
        let statement = try store.database.prepare("""
            SELECT c.node_id, c.kind, c.name, c.md5, c.size, c.taken_at, c.ext, c.parent_id
            FROM cloud_items c
            WHERE \(kinds) \(yearClause)
              AND NOT EXISTS (SELECT 1 FROM drive_files d
                              WHERE d.md5 = c.md5 AND d.size > 0 AND \(scope.sqlCondition(column: "d.rel_path")))
              \(failureClause)
            ORDER BY c.taken_at DESC, c.node_id
            """)
        try statement.bind(args)
        while try statement.step() {
            let item = CloudItem(
                nodeId: statement.string(0) ?? "",
                kind: statement.string(1) == "live_video" ? .liveVideo : .file,
                name: statement.string(2) ?? "", md5: statement.string(3) ?? "", size: statement.int64(4),
                takenAt: statement.int64(5), ext: statement.string(6), parentId: statement.string(7))
            if try !body(item) { break }
        }
    }

    /// The plan for a dry run: what the next `limit` downloads would write, without touching
    /// the network, the queue or the drive. Items with the same content count once. Items whose job
    /// failed and waits for a retry, or ran out of attempts, are not in it, because a run would not
    /// download them (unless `options.retryFailed` puts them back first). The same plan gives the
    /// count on the menu-bar app's Download button.
    public func plan(options: DownloadOptions, root: String?, now: Date = Date()) throws -> [PlannedDownload] {
        let builder = try TargetBuilder(store: store, scanSubpath: config.scanSubpath)
        var seenMD5 = Set<String>()
        var reserved = Set<String>()
        var planned: [PlannedDownload] = []
        let limit = options.limit ?? Int.max
        let blocked = options.retryFailed ? nil : (maxAttempts: options.maxAttempts, now: Int64(now.timeIntervalSince1970))
        try forEachCandidate(
            includeLiveVideos: options.includeLiveVideos, year: options.year, withoutBlockedFailures: blocked
        ) { item in
            // Empty files all share one MD5 but each one is created at its own path.
            guard item.size == 0 || seenMD5.insert(item.md5).inserted else { return true }
            let (relPath, resolved) = builder.target(for: item)
            var finalRel = relPath
            var note: String?
            for number in 1...9999 {
                let candidate = number == 1 ? relPath : Self.numbered(relPath, number)
                let key = candidate.lowercased()
                if reserved.contains(key) { continue }
                if let root, let absolute = try? PathGuard.resolve(root: root, relative: candidate),
                    let info = FileOps.regularFileInfo(absolute)
                {
                    if number == 1, info.size == item.size {
                        note = "a file of the same size exists; it is kept if its MD5 matches"
                        finalRel = candidate
                        reserved.insert(key)
                        break
                    }
                    continue
                } else if let root, let absolute = try? PathGuard.resolve(root: root, relative: candidate),
                    FileOps.exists(absolute)
                {
                    continue
                }
                finalRel = candidate
                reserved.insert(key)
                break
            }
            if finalRel != relPath, note == nil { note = "the target name is taken; a numbered name is used" }
            planned.append(PlannedDownload(
                nodeId: item.nodeId, kind: item.kind, size: item.size, takenAt: item.takenAt,
                targetRelPath: relPath, finalRelPath: finalRel, resolvedFolders: resolved, note: note))
            return planned.count < limit
        }
        return planned
    }

    /// `dir/name.ext` -> `dir/name (n).ext`.
    static func numbered(_ relPath: String, _ number: Int) -> String {
        guard let slash = relPath.lastIndex(of: "/") else { return FileNameSanitizer.numbered(relPath, number) }
        let directory = relPath[...slash]
        return directory + FileNameSanitizer.numbered(String(relPath[relPath.index(after: slash)...]), number)
    }
}

/// The `download_jobs` table: building the queue from the catalog, claiming and updating jobs.
/// Synchronous; `DownloadLedger` serialises its use during a run.
struct DownloadJobTable {
    let source: StateStore  // catalog and drive index
    let queue: StateStore   // download_jobs and meta (the same store, except in scratch runs)
    let config: Config

    struct SyncResult: Equatable {
        var candidates = 0
        var obsolete = 0
    }

    /// Target paths of the jobs a crashed run left `downloading`.
    func interruptedTargets() throws -> [String] {
        try queue.database.rows(
            "SELECT target_rel_path FROM download_jobs WHERE status = 'downloading'",
            map: { $0.string(0) ?? "" })
    }

    /// Jobs left `downloading` by a crashed run go back to pending.
    @discardableResult
    func recoverInterrupted(now: Date) throws -> Int {
        try queue.database.run(
            "UPDATE download_jobs SET status = 'pending', updated_at = ? WHERE status = 'downloading'",
            [Int64(now.timeIntervalSince1970)])
        return queue.database.changes
    }

    /// Bring the queue in line with the catalog: every online-only item gets a row (pending when
    /// new or when it was done/skipped before but is online-only again; failed rows keep their
    /// attempts), and rows of items that are on the drive now or gone from the catalog are skipped.
    func sync(includeLiveVideos: Bool, now: Date) throws -> SyncResult {
        let planner = DownloadPlanner(store: source, config: config)
        let builder = try TargetBuilder(store: source, scanSubpath: config.scanSubpath)
        let stamp = Int64(now.timeIntervalSince1970)
        var result = SyncResult()
        let database = queue.database
        try database.execute("DROP TABLE IF EXISTS temp.download_candidates")
        try database.execute("CREATE TEMP TABLE download_candidates(node_id TEXT PRIMARY KEY)")
        defer { try? database.execute("DROP TABLE IF EXISTS temp.download_candidates") }

        try database.transaction {
            let remember = try database.prepare("INSERT OR IGNORE INTO temp.download_candidates(node_id) VALUES(?)")
            let upsert = try database.prepare("""
                INSERT INTO download_jobs
                    (node_id, kind, md5, size, taken_at, target_rel_path, status, attempts, last_error, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, 'pending', 0, NULL, ?)
                ON CONFLICT(node_id) DO UPDATE SET
                    kind = excluded.kind, md5 = excluded.md5, size = excluded.size,
                    taken_at = excluded.taken_at, target_rel_path = excluded.target_rel_path,
                    status = CASE WHEN status IN ('done', 'skipped') THEN 'pending' ELSE status END,
                    attempts = CASE WHEN status IN ('done', 'skipped') THEN 0 ELSE attempts END,
                    last_error = CASE WHEN status IN ('done', 'skipped') THEN NULL ELSE last_error END,
                    updated_at = CASE WHEN status IN ('done', 'skipped') THEN excluded.updated_at ELSE updated_at END,
                    retry_after = CASE WHEN status IN ('done', 'skipped') THEN NULL ELSE retry_after END
                """)
            try planner.forEachCandidate(includeLiveVideos: includeLiveVideos, year: nil) { item in
                let (relPath, _) = builder.target(for: item)
                try upsert.run([item.nodeId, item.kind.rawValue, item.md5, item.size, item.takenAt, relPath, stamp])
                try remember.run([item.nodeId])
                result.candidates += 1
                return true
            }
            try database.run("""
                UPDATE download_jobs
                SET status = 'skipped', last_error = 'already on the drive, or no longer in the cloud catalog',
                    retry_after = NULL, updated_at = ?
                WHERE status IN ('pending', 'failed', 'downloading')
                  AND node_id NOT IN (SELECT node_id FROM temp.download_candidates)
                """, [stamp])
            result.obsolete = database.changes
        }
        return result
    }

    // MARK: Claiming

    private static let jobColumns = """
        node_id, kind, md5, size, taken_at, target_rel_path, status, attempts, last_error, updated_at
        """

    static func job(from row: SQLiteStatement) -> DownloadJob {
        DownloadJob(
            nodeId: row.string(0) ?? "", kind: row.string(1) == "live_video" ? .liveVideo : .file,
            md5: row.string(2) ?? "", size: row.int64(3), takenAt: row.int64(4),
            targetRelPath: row.string(5) ?? "", status: DownloadJobStatus(rawValue: row.string(6) ?? "") ?? .pending,
            attempts: row.int(7), lastError: row.string(8), updatedAt: row.int64(9))
    }

    /// A failed job is due when attempts are left and its time has come: `retry_after` has passed, or,
    /// for jobs without a cool-down, the job was not tried in this run. Arguments: see `failedIsDueArguments`.
    static func failedIsDue(alias: String? = nil) -> String {
        let p = alias.map { $0 + "." } ?? ""
        return """
            (\(p)attempts < ? AND \
            (\(p)retry_after IS NOT NULL AND \(p)retry_after <= ? OR \(p)retry_after IS NULL AND \(p)updated_at < ?))
            """
    }

    static func failedIsDueArguments(maxAttempts: Int, now: Int64) -> [any SQLiteBindable] {
        [maxAttempts, now, now]
    }

    /// The conditions of a run for which jobs it takes: the kind and the year, as an `AND` tail.
    private func runFilter(options: DownloadOptions) -> (sql: String, args: [any SQLiteBindable]) {
        var sql = ""
        var args: [any SQLiteBindable] = []
        if !options.includeLiveVideos { sql += " AND kind = 'file'" }
        if let year = options.year {
            let range = DownloadPlanner.range(ofYear: year)
            sql += " AND taken_at >= ? AND taken_at < ?"
            args += [range.start, range.end]
        }
        return (sql, args)
    }

    /// Number and total size of what the run would handle (at most `limit` jobs, before dedupe):
    /// pending jobs, plus failed ones that are due.
    func totals(options: DownloadOptions, runStartedAt: Int64) throws -> (count: Int, bytes: Int64) {
        let filter = runFilter(options: options)
        let limit = options.limit ?? Int(Int32.max)
        let failedArgs = Self.failedIsDueArguments(maxAttempts: options.maxAttempts, now: runStartedAt)
        let rows = try queue.database.rows("""
            SELECT COUNT(*), COALESCE(SUM(size), 0) FROM (
                SELECT size FROM download_jobs
                WHERE (status = 'pending' OR (status = 'failed' AND \(Self.failedIsDue()))) \(filter.sql)
                ORDER BY taken_at DESC LIMIT ?)
            """, failedArgs + filter.args + [limit]) { ($0.int(0), $0.int64(1)) }
        return rows.first ?? (0, 0)
    }

    /// The next eligible job in taken-at order, newest first (pending and due failures together).
    func nextEligible(options: DownloadOptions, runStartedAt: Int64) throws -> DownloadJob? {
        let filter = runFilter(options: options)
        // Each half uses the (status, taken_at) index, so the scan stops at the first match.
        func part(_ condition: String) -> String {
            "SELECT * FROM (SELECT \(Self.jobColumns) FROM download_jobs WHERE \(condition) \(filter.sql) ORDER BY taken_at DESC, node_id LIMIT 1)"
        }
        let failedArgs = Self.failedIsDueArguments(maxAttempts: options.maxAttempts, now: runStartedAt)
        let rows = try queue.database.rows("""
            \(part("status = 'pending'")) UNION ALL \(part("(status = 'failed' AND \(Self.failedIsDue()))"))
            ORDER BY taken_at DESC, node_id LIMIT 1
            """, filter.args + failedArgs + filter.args) { Self.job(from: $0) }
        return rows.first
    }

    /// Update a job. A job that is not `failed` has no cool-down; a failed one gets `retryAfter` (nil for none).
    func setStatus(
        nodeId: String, status: DownloadJobStatus, attempts: Int? = nil, lastError: String?? = nil,
        targetRelPath: String? = nil, retryAfter: Date? = nil, now: Date
    ) throws {
        var sets = ["status = ?", "updated_at = ?", "retry_after = ?"]
        var args: [any SQLiteBindable] = [
            status.rawValue, Int64(now.timeIntervalSince1970),
            status == .failed ? retryAfter.map { Int64($0.timeIntervalSince1970) } : nil,
        ]
        if let attempts { sets.append("attempts = ?"); args.append(attempts) }
        if let lastError { sets.append("last_error = ?"); args.append(lastError) }
        if let targetRelPath { sets.append("target_rel_path = ?"); args.append(targetRelPath) }
        args.append(nodeId)
        try queue.database.run("UPDATE download_jobs SET \(sets.joined(separator: ", ")) WHERE node_id = ?", args)
    }

    /// Put every failed job back to pending with no attempts and no cool-down. Returns how many.
    @discardableResult
    func resetFailed(now: Date) throws -> Int {
        try queue.database.run("""
            UPDATE download_jobs SET status = 'pending', attempts = 0, retry_after = NULL, updated_at = ?
            WHERE status = 'failed'
            """, [Int64(now.timeIntervalSince1970)])
        return queue.database.changes
    }

    func isOnDrive(md5: String) throws -> Bool {
        let scope = try DriveScope(scanSubpath: config.scanSubpath)
        return try source.database.scalarInt64("""
            SELECT 1 FROM drive_files d WHERE d.md5 = ? AND d.size > 0 AND \(scope.sqlCondition(column: "d.rel_path")) LIMIT 1
            """, [md5]) != nil
    }

    // MARK: Reporting

    func counts() throws -> DownloadQueueCounts {
        var counts = DownloadQueueCounts()
        for (status, count, bytes) in try queue.database.rows(
            "SELECT status, COUNT(*), COALESCE(SUM(size), 0) FROM download_jobs GROUP BY status",
            map: { ($0.string(0) ?? "", $0.int(1), $0.int64(2)) })
        {
            switch DownloadJobStatus(rawValue: status) {
            case .pending: counts.pending = count; counts.pendingBytes = bytes
            case .downloading: counts.downloading = count
            case .done: counts.done = count
            case .failed: counts.failed = count
            case .skipped: counts.skipped = count
            case nil: break
            }
        }
        let scope = try DriveScope(scanSubpath: config.scanSubpath)
        counts.notQueued = Int(try source.database.scalarInt64("""
            SELECT COUNT(*) FROM cloud_items c
            WHERE c.kind IN ('file', 'live_video')
              AND NOT EXISTS (SELECT 1 FROM drive_files d
                              WHERE d.md5 = c.md5 AND d.size > 0 AND \(scope.sqlCondition(column: "d.rel_path")))
              AND NOT EXISTS (SELECT 1 FROM download_jobs j WHERE j.node_id = c.node_id)
            """) ?? 0)
        return counts
    }

    /// Jobs being downloaded now and the bytes finished in the last `DownloadActivity.window` seconds.
    func recentActivity(now: Date = Date()) throws -> DownloadActivity {
        let since = Int64(now.timeIntervalSince1970 - DownloadActivity.window)
        var activity = DownloadActivity()
        for (status, count, bytes) in try queue.database.rows("""
            SELECT status, COUNT(*), COALESCE(SUM(size), 0) FROM download_jobs
            WHERE status = 'downloading' OR (status = 'done' AND updated_at >= ?)
            GROUP BY status
            """, [since], map: { ($0.string(0) ?? "", $0.int(1), $0.int64(2)) })
        {
            if status == DownloadJobStatus.downloading.rawValue { activity.downloading = count }
            if status == DownloadJobStatus.done.rawValue { activity.recentBytes = bytes }
        }
        return activity
    }

    func failures(limit: Int) throws -> [DownloadFailure] {
        try queue.database.rows("""
            SELECT node_id, target_rel_path, attempts, last_error, updated_at, retry_after FROM download_jobs
            WHERE status = 'failed' ORDER BY updated_at DESC, node_id LIMIT ?
            """, [limit]) {
            DownloadFailure(
                nodeId: $0.string(0) ?? "", targetRelPath: $0.string(1) ?? "", attempts: $0.int(2),
                reason: $0.string(3) ?? "unknown", updatedAt: Date(timeIntervalSince1970: TimeInterval($0.int64(4))),
                retryAfter: $0.isNull(5) ? nil : Date(timeIntervalSince1970: TimeInterval($0.int64(5))))
        }
    }

    /// The failed jobs grouped by reason: how many wait for a retry, how many a run takes next, how
    /// many are out of attempts. Largest group first.
    func failureSummary(maxAttempts: Int, now: Date) throws -> DownloadFailureSummary {
        let stamp = Int64(now.timeIntervalSince1970)
        let groups = try queue.database.rows("""
            SELECT COALESCE(last_error, 'unknown'),
                   SUM(CASE WHEN attempts >= ?1 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN attempts < ?1 AND retry_after > ?2 THEN 1 ELSE 0 END),
                   MIN(CASE WHEN attempts < ?1 AND retry_after > ?2 THEN retry_after END),
                   COUNT(*)
            FROM download_jobs WHERE status = 'failed'
            GROUP BY COALESCE(last_error, 'unknown')
            """, [maxAttempts, stamp]) { row -> DownloadFailureGroup in
            let permanent = row.int(1)
            let waiting = row.int(2)
            return DownloadFailureGroup(
                reason: row.string(0) ?? "unknown", waiting: waiting, due: row.int(4) - permanent - waiting,
                permanent: permanent,
                nextRetryAt: row.isNull(3) ? nil : Date(timeIntervalSince1970: TimeInterval(row.int64(3))))
        }
        return DownloadFailureSummary(groups: groups.sorted {
            ($0.total, $1.reason) > ($1.total, $0.reason)
        })
    }
}
