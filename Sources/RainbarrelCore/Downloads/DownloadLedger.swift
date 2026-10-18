import Foundation

/// The queue and the drive index during a run. One actor owns the database connections, so the
/// download workers never touch SQLite directly.
///
/// A scratch run (`--to <folder>`) reads the catalog and the drive index from the real database
/// but keeps its queue, counters and results in a throw-away database: nothing it does is
/// recorded as being on the backup drive.
actor DownloadLedger {
    private let main: StateStore
    private let queue: StateStore
    private let table: DownloadJobTable
    private let persistsToDriveIndex: Bool
    private let scratchPath: String?
    private let options: DownloadOptions
    private let runStartedAt: Int64
    private var started = 0
    private var runMD5s = Set<String>()

    /// - Parameters:
    ///   - databasePath: the real `state.sqlite`.
    ///   - scratchQueuePath: path for the throw-away queue database of a scratch run; nil for a normal run.
    init(
        databasePath: String, scratchQueuePath: String?, config: Config, options: DownloadOptions, runStartedAt: Date
    ) throws {
        let main = try StateStore(path: databasePath)
        let queue = try scratchQueuePath.map { try StateStore(path: $0) } ?? main
        self.main = main
        self.queue = queue
        table = DownloadJobTable(source: main, queue: queue, config: config)
        persistsToDriveIndex = scratchQueuePath == nil
        scratchPath = scratchQueuePath
        self.options = options
        self.runStartedAt = Int64(runStartedAt.timeIntervalSince1970)
    }

    /// Delete the throw-away queue database of a scratch run.
    func discardScratch() {
        guard let scratchPath else { return }
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: scratchPath + suffix) }
    }

    /// Recover interrupted jobs, bring the queue in line with the catalog, and report how much work
    /// there is (at most `limit` jobs).
    /// - Returns: the amount of work, and the folders in which interrupted jobs were writing.
    func prepare(now: Date) throws -> (count: Int, bytes: Int64, interruptedTargets: [String]) {
        let interrupted = try table.interruptedTargets()
        try table.recoverInterrupted(now: now)
        _ = try table.sync(includeLiveVideos: options.includeLiveVideos, now: now)
        let totals = try table.totals(options: options, runStartedAt: runStartedAt)
        return (totals.count, totals.bytes, interrupted)
    }

    /// Node id of the job that would run first, for the session check before the run starts.
    func peekNodeId() throws -> String? {
        try table.nextEligible(options: options, runStartedAt: runStartedAt)?.nodeId
    }

    /// Take the next job: newest first, skipping content that is already on the drive or being
    /// handled by this run. Returns nil when the queue is empty or the file limit is reached.
    func claimNext(now: Date) throws -> (job: DownloadJob?, skippedDuplicates: [DownloadJob]) {
        if let limit = options.limit, started >= limit { return (nil, []) }
        var skipped: [DownloadJob] = []
        while true {
            guard var job = try table.nextEligible(options: options, runStartedAt: runStartedAt) else {
                return (nil, skipped)
            }
            // Empty files all share one MD5 but each one is created at its own path.
            if job.size > 0, runMD5s.contains(job.md5) {
                try table.setStatus(
                    nodeId: job.nodeId, status: .skipped,
                    lastError: .some("same content is downloaded once in this run"), now: now)
                skipped.append(job)
                continue
            }
            if try table.isOnDrive(md5: job.md5) {
                try table.setStatus(
                    nodeId: job.nodeId, status: .skipped, lastError: .some("already on the drive"), now: now)
                skipped.append(job)
                continue
            }
            if job.size > 0 { runMD5s.insert(job.md5) }
            started += 1
            try table.setStatus(nodeId: job.nodeId, status: .downloading, now: now)
            job.status = .downloading
            return (job, skipped)
        }
    }

    /// Put a claimed job back (cancelled, drive gone, session expired, limits).
    func release(_ job: DownloadJob, now: Date) {
        try? table.setStatus(nodeId: job.nodeId, status: .pending, now: now)
        if job.size > 0 { runMD5s.remove(job.md5) }
        started = max(started - 1, 0)
    }

    /// Count a verification failure or another try without changing the status.
    func recordAttempt(_ job: DownloadJob, attempts: Int, error: String, now: Date) {
        try? table.setStatus(
            nodeId: job.nodeId, status: .downloading, attempts: attempts, lastError: .some(error), now: now)
    }

    func markFailed(_ job: DownloadJob, attempts: Int, error: String, now: Date) {
        try? table.setStatus(
            nodeId: job.nodeId, status: .failed, attempts: attempts, lastError: .some(error), now: now)
    }

    /// Record a finished file: the drive index row (so the reconciler counts it as in sync) and the
    /// job, in one transaction.
    func markDone(
        _ job: DownloadJob, relPath: String, size: Int64, mtime: Int64, md5: String, downloadedBytes: Int64,
        dayKey: String, now: Date
    ) throws {
        let stamp = Int64(now.timeIntervalSince1970)
        try queue.database.transaction {
            if persistsToDriveIndex {
                try main.upsertDriveFile(DriveFileRecord(
                    relPath: relPath, size: size, mtime: mtime, md5: md5, hashedAt: stamp))
            }
            if downloadedBytes > 0 {
                let key = MetaKey.downloadBytesPrefix + dayKey
                let today = Int64(try queue.getMeta(key) ?? "0") ?? 0
                try queue.setMeta(key, String(today + downloadedBytes))
            }
            try table.setStatus(
                nodeId: job.nodeId, status: .done, attempts: job.attempts, lastError: .some(nil),
                targetRelPath: relPath, now: now)
        }
    }

    func dailyBytes(dayKey: String) -> Int64 {
        Int64((try? queue.getMeta(MetaKey.downloadBytesPrefix + dayKey)) ?? "0") ?? 0
    }

    func saveLastRun(_ record: DownloadRunRecord) {
        guard let data = try? JSONEncoder.iso8601.encode(record) else { return }
        try? queue.setMeta(MetaKey.downloadLastRun, String(decoding: data, as: UTF8.self))
    }
}

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
