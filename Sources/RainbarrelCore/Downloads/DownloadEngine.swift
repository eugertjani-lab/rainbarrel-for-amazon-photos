import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif

/// Everything a run takes from its surroundings, so tests can replace the clock, the randomness,
/// the free-space reading and the network.
public struct DownloadEnvironment: Sendable {
    public var clock: DownloadClock
    public var random: @Sendable () -> Double
    public var freeSpace: @Sendable (String) -> Int64?
    public var sessionConfiguration: @Sendable () -> URLSessionConfiguration
    public var timeouts: AmazonClient.Timeouts
    public var calendar: Calendar

    public init(
        clock: DownloadClock = .system,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        freeSpace: @escaping @Sendable (String) -> Int64? = { DownloadEnvironment.systemFreeSpace(atPath: $0) },
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { AmazonClient.defaultConfiguration() },
        timeouts: AmazonClient.Timeouts = .default,
        calendar: Calendar = .current
    ) {
        self.clock = clock
        self.random = random
        self.freeSpace = freeSpace
        self.sessionConfiguration = sessionConfiguration
        self.timeouts = timeouts
        self.calendar = calendar
    }

    public static let live = DownloadEnvironment()

    /// Bytes that can still be written to the volume holding `path`; nil when unknown.
    @Sendable public static func systemFreeSpace(atPath path: String) -> Int64? {
        FileOps.availableBytes(atPath: path)
    }
}

/// Run a blocking piece of work on a dispatch thread, so that disk I/O never ties up the threads
/// that Swift concurrency uses.
func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// Writes the body of a download to the temporary file and computes its MD5 on the way.
final class PartWriter: @unchecked Sendable {
    private var descriptor: Int32
    private var hasher = Insecure.MD5()
    private let expectedSize: Int64
    private(set) var count: Int64 = 0

    init(path: String, expectedSize: Int64) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw DownloadError.fileSystem(FileOps.errnoMessage()) }
        descriptor = fd
        self.expectedSize = expectedSize
    }

    deinit { closeFile() }

    func append(_ data: Data) throws {
        count += Int64(data.count)
        // A body larger than the catalog says is wrong; stop before it fills the drive.
        if count > expectedSize { throw DownloadError.sizeMismatch(expected: expectedSize, actual: count) }
        hasher.update(data: data)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw DownloadError.fileSystem(FileOps.errnoMessage())
                }
                offset += written
            }
        }
    }

    /// Flush to disk and close; returns the MD5 of everything written.
    func finish() throws -> (size: Int64, md5: String) {
        guard descriptor >= 0 else { throw DownloadError.fileSystem("the file was already closed") }
        if fsync(descriptor) != 0 { throw DownloadError.fileSystem(FileOps.errnoMessage()) }
        closeFile()
        let digest = hasher.finalize()
        let hex = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        for byte in digest {
            output.append(hex[Int(byte >> 4)])
            output.append(hex[Int(byte & 0x0F)])
        }
        return (count, String(decoding: output, as: UTF8.self))
    }

    func closeFile() {
        guard descriptor >= 0 else { return }
        _ = close(descriptor)
        descriptor = -1
    }
}

/// Chooses the final path of a file: never an existing file, never a name another worker of this
/// run has taken, and an identical existing file is recognised so it can be adopted.
actor TargetAllocator {
    enum Allocation: Sendable {
        case write(rel: String, abs: String, number: Int)
        case adopt(rel: String, abs: String, size: Int64, mtime: Int64)
    }

    private let root: String
    private var reserved = Set<String>()
    private var preparedDirectories = Set<String>()
    private(set) var staleFilesRemoved = 0

    init(root: String) {
        self.root = root
    }

    /// Create the folder when missing and, the first time a folder is used in this run, remove the
    /// `.rainbarrel-part` files that an earlier crashed run left in it. Runs without suspending, so
    /// no worker can create a temporary file in the folder while it is cleaned.
    private func prepareDirectory(_ directory: String) throws {
        guard preparedDirectories.insert(directory).inserted else { return }
        if !FileOps.isDirectory(directory) { try FileOps.makeDirectories(directory) }
        staleFilesRemoved += FileOps.removeStalePartFiles(inDirectory: directory)
    }

    /// Remove leftover temporary files from the folders that jobs of an earlier, crashed run were
    /// writing to. Only these folders (and later the ones this run uses) are looked at, never the whole tree.
    func cleanStaleFiles(inFoldersOf relativePaths: [String]) {
        for relative in relativePaths {
            guard let absolute = try? PathGuard.resolve(root: root, relative: relative) else { continue }
            let directory = PathGuard.parent(of: absolute)
            guard preparedDirectories.insert(directory).inserted else { continue }
            if FileOps.isDirectory(directory) { staleFilesRemoved += FileOps.removeStalePartFiles(inDirectory: directory) }
        }
    }

    func allocate(_ job: DownloadJob, startingAt first: Int = 1, allowAdopt: Bool = true) async throws -> Allocation {
        for number in first...(first + 998) {
            let rel = number == 1 ? job.targetRelPath : DownloadPlanner.numbered(job.targetRelPath, number)
            let key = rel.lowercased()
            if reserved.contains(key) { continue }
            let absolute = try PathGuard.resolve(root: root, relative: rel)
            reserved.insert(key)  // taken from here on, whether it ends up used or not
            if let info = FileOps.regularFileInfo(absolute) {
                if allowAdopt, info.size == job.size {
                    let digest = try await blocking { try MD5Hasher.hexDigest(ofFileAtPath: absolute) }
                    if digest == job.md5 { return .adopt(rel: rel, abs: absolute, size: info.size, mtime: info.mtime) }
                }
                continue
            }
            if FileOps.exists(absolute) { continue }
            try prepareDirectory(PathGuard.parent(of: absolute))
            return .write(rel: rel, abs: absolute, number: number)
        }
        throw DownloadError.fileSystem("too many files with the same name")
    }

    /// Move the finished temporary file to its final name without replacing anything. When the name
    /// was taken in the meantime by something outside this run, the next free numbered name is used.
    func commit(part: String, allocation: (rel: String, abs: String, number: Int), job: DownloadJob) async throws
        -> (rel: String, abs: String)
    {
        var current = allocation
        for _ in 0..<50 {
            let target = current.abs
            let renamed = try await blocking { try FileOps.renameWithoutReplacing(part, to: target) }
            if renamed {
                let directory = PathGuard.parent(of: target)
                await Task.detached { FileOps.syncDirectory(directory) }.value
                return (current.rel, current.abs)
            }
            guard case .write(let rel, let abs, let number) = try await allocate(
                job, startingAt: current.number + 1, allowAdopt: false)
            else { break }
            current = (rel, abs, number)
        }
        throw DownloadError.fileSystem("could not find a free name for the finished file")
    }
}

/// State shared by the workers of one run.
actor RunCoordinator {
    private(set) var stopReason: DownloadStopReason?
    private(set) var finished = false
    private var filesTotal: Int
    private let bytesTotal: Int64
    private var downloaded = 0
    private var adopted = 0
    private var skipped = 0
    private var failed = 0
    private var bytesDownloaded: Int64 = 0
    private var reservedBytes: Int64 = 0
    private var current: [String: String] = [:]  // node id -> name
    private var results: [DownloadFileResult] = []
    private var message: String?
    private var messageUntil: Date?
    private var windowUntil: Date?
    private var verificationFailuresInARow = 0

    init(filesTotal: Int, bytesTotal: Int64) {
        self.filesTotal = filesTotal
        self.bytesTotal = bytesTotal
    }

    var shouldStop: Bool { stopReason != nil }
    var reserved: Int64 { reservedBytes }

    /// The first reason wins.
    func requestStop(_ reason: DownloadStopReason) {
        if stopReason == nil { stopReason = reason }
    }

    func markFinished() { finished = true }

    func begin(_ job: DownloadJob) { current[job.nodeId] = job.fileName }

    /// Reserve `size` bytes for a file about to start, unless a limit forbids it.
    func tryReserve(
        size: Int64, usedToday: Int64, dailyLimit: Int64, freeSpace: Int64?, minFree: Int64
    ) -> DownloadStopReason? {
        if dailyLimit > 0, usedToday + reservedBytes + size > dailyLimit { return .dailyLimitReached }
        if let freeSpace, freeSpace - reservedBytes - size < minFree {
            return .lowDiskSpace
        }
        reservedBytes += size
        return nil
    }

    func unreserve(_ size: Int64) { reservedBytes = max(reservedBytes - size, 0) }

    func end(_ job: DownloadJob) { current.removeValue(forKey: job.nodeId) }

    func countSkipped(_ jobs: [DownloadJob]) {
        for job in jobs {
            skipped += 1
            filesTotal = max(filesTotal - 1, 0)
            addResult(job, path: job.targetRelPath, outcome: .skipped, bytes: 0, detail: "same content already handled")
        }
    }

    func countDownloaded(_ job: DownloadJob, path: String, bytes: Int64) {
        downloaded += 1
        bytesDownloaded += bytes
        verificationFailuresInARow = 0
        addResult(job, path: path, outcome: .downloaded, bytes: bytes, detail: nil)
    }

    func countAdopted(_ job: DownloadJob, path: String) {
        adopted += 1
        verificationFailuresInARow = 0
        addResult(job, path: path, outcome: .adopted, bytes: 0, detail: "already on the drive, content verified")
    }

    func countFailed(_ job: DownloadJob, error: String, verification: Bool) {
        failed += 1
        verificationFailuresInARow = verification ? verificationFailuresInARow + 1 : 0
        addResult(job, path: job.targetRelPath, outcome: .failed, bytes: 0, detail: error)
        if verificationFailuresInARow >= 5 {
            requestStop(.failure(
                "Five files in a row failed verification. Amazon may be returning error pages; try again later or sign in again."))
        }
    }

    private func addResult(_ job: DownloadJob, path: String, outcome: DownloadFileResult.Outcome, bytes: Int64, detail: String?) {
        guard results.count < DownloadSummary.maxResults else { return }
        results.append(DownloadFileResult(nodeId: job.nodeId, path: path, outcome: outcome, bytes: bytes, detail: detail))
    }

    func setMessage(_ text: String, until: Date) {
        message = text
        messageUntil = until
    }

    func setWindow(until: Date?) { windowUntil = until }

    func snapshot(now: Date, metrics: RunMetrics, backoffUntil: Date?) -> DownloadProgress {
        var state = DownloadRunState.running
        if finished {
            switch stopReason {
            case nil: state = .finished
            case .cancelled?: state = .paused
            case let reason?: state = .stopped(reason)
            }
        } else if let windowUntil, windowUntil > now {
            state = .waitingForWindow(until: windowUntil)
        } else if let backoffUntil, backoffUntil > now {
            state = .backingOff(until: backoffUntil)
        }
        var text: String?
        if let message, let messageUntil, messageUntil > now { text = message }
        return DownloadProgress(
            filesDone: downloaded + adopted, filesFailed: failed, filesTotal: filesTotal,
            bytesDone: metrics.bytes, bytesTotal: bytesTotal,
            bytesPerSecond: metrics.bytesPerSecond(at: now), currentFiles: current.values.sorted(),
            state: state, message: text)
    }

    func summary(duration: TimeInterval) -> DownloadSummary {
        DownloadSummary(
            filesDownloaded: downloaded, filesAdopted: adopted, filesSkipped: skipped, filesFailed: failed,
            bytesDownloaded: bytesDownloaded, durationSeconds: duration, stopReason: stopReason, results: results)
    }
}

/// Byte counters that the network callbacks update without suspending.
final class RunMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    private let rolling: RollingRate

    init(startedAt: Date) {
        rolling = RollingRate(startedAt: startedAt)
    }

    var bytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func add(_ count: Int, at date: Date) {
        lock.lock()
        total += Int64(count)
        lock.unlock()
        rolling.record(bytes: count, at: date)
    }

    /// Take back bytes of an attempt that did not count.
    func subtract(_ count: Int64) {
        lock.lock()
        total = max(total - count, 0)
        lock.unlock()
    }

    func bytesPerSecond(at date: Date) -> Double { rolling.bytesPerSecond(at: date) }
}

/// Downloads the files that are missing from the backup drive and verifies each one by MD5.
public struct DownloadEngine: Sendable {
    public let paths: AppPaths
    public let environment: DownloadEnvironment

    public init(paths: AppPaths, environment: DownloadEnvironment = .live) {
        self.paths = paths
        self.environment = environment
    }

    /// Which folder the run writes to: the drive root, or the `--to` folder.
    static func targetRoot(config: Config, options: DownloadOptions) throws -> String {
        guard let driveRoot = config.driveRoot, !driveRoot.isEmpty else { throw DownloadError.noDriveConfigured }
        let chosen = options.targetRoot.flatMap { $0.isEmpty ? nil : $0 } ?? driveRoot
        return URL(fileURLWithPath: PathUtilities.expandingTilde(chosen)).standardized.path
    }

    /// The scan folder inside `root` that downloads go to.
    static func scanFolder(root: String, config: Config) throws -> String {
        let scope = try DriveScope(scanSubpath: config.scanSubpath)
        return scope.isWholeDrive ? root : root + "/" + scope.directoryPath
    }

    /// Check that the target exists and can be written to: creates the scan folder when the drive is
    /// there but the folder is not, then writes and removes a probe file. Touches no network.
    public static func prepareTarget(config: Config, options: DownloadOptions = DownloadOptions()) throws {
        let root = try targetRoot(config: config, options: options)
        guard FileOps.isDirectory(root) else { throw DownloadError.driveNotMounted(root) }
        let folder = try scanFolder(root: root, config: config)
        if !FileOps.isDirectory(folder) {
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            } catch {
                if FileOps.isMountedReadOnly(path: root) {
                    throw DownloadError.targetNotWritable(path: folder, detail: nil)
                }
                throw DownloadError.targetNotWritable(path: folder, detail: error.localizedDescription)
            }
        }
        try FileOps.probeWritable(directory: folder)
    }

    /// Whether the drive can be written to, judged without writing (for status displays).
    public static func driveLooksWritable(config: Config) -> Bool? {
        guard let driveRoot = config.driveRoot, FileOps.isDirectory(driveRoot) else { return nil }
        let folder = (try? scanFolder(root: driveRoot, config: config)) ?? driveRoot
        let probePath = FileOps.isDirectory(folder) ? folder : driveRoot
        if FileOps.isMountedReadOnly(path: probePath) { return false }
        return access(probePath, W_OK) == 0
    }

    // MARK: Dry run

    /// What the next downloads would write. No network, no queue changes, no writes.
    public func plan(config: Config, options: DownloadOptions) throws -> [PlannedDownload] {
        let root = try? Self.targetRoot(config: config, options: options)
        let store = try StateStore(path: paths.stateURL.path)
        return try DownloadPlanner(store: store, config: config)
            .plan(options: options, root: root.flatMap { FileOps.isDirectory($0) ? $0 : nil })
    }

    // MARK: Run

    /// Run the downloads. Throws for problems that prevent the run from starting (no drive, drive
    /// read-only, another run active, session rejected at the first request); everything that
    /// happens later ends the run with a `stopReason` in the summary.
    public func run(
        config: Config, session: StoredSession, options: DownloadOptions,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> DownloadSummary {
        let clock = environment.clock
        let startedAt = clock.now()

        // 1. The target, before anything that needs a session or the network.
        let root = try Self.targetRoot(config: config, options: options)
        try Self.prepareTarget(config: config, options: options)
        let scanFolder = try Self.scanFolder(root: root, config: config)

        var throttle = config.throttle.normalized
        if let concurrency = options.concurrency { throttle.maxConcurrentDownloads = min(max(concurrency, 1), 8) }
        if let mbps = options.maxMBps, mbps.isFinite { throttle.maxBandwidthMBps = max(mbps, 0) }

        let hours = throttle.parsedActiveHours
        if options.hoursPolicy == .exit, let hours, !hours.contains(startedAt, calendar: environment.calendar) {
            return DownloadSummary(
                filesDownloaded: 0, filesAdopted: 0, filesSkipped: 0, filesFailed: 0, bytesDownloaded: 0,
                durationSeconds: 0, stopReason: .outsideActiveHours, results: [])
        }

        // 2. One run at a time on the real drive.
        let scratch = options.targetRoot != nil
            && root != URL(fileURLWithPath: config.driveRoot ?? "").standardized.path
        var lock: RunLock?
        if !scratch {
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            lock = try RunLock(path: paths.downloadLockURL.path)
            if lock == nil { throw DownloadError.alreadyRunning }
        }
        defer { lock?.release() }

        // 3. The queue.
        let scratchQueue = scratch
            ? FileManager.default.temporaryDirectory.appendingPathComponent("rainbarrel-scratch-\(UUID().uuidString).sqlite").path
            : nil
        let ledger = try DownloadLedger(
            databasePath: paths.stateURL.path, scratchQueuePath: scratchQueue, config: config, options: options,
            runStartedAt: startedAt)
        do {
            let summary = try await execute(
                ledger: ledger, config: config, session: session, options: options, throttle: throttle,
                hours: hours, root: root, scanFolder: scanFolder, startedAt: startedAt,
                progress: progress)
            await ledger.discardScratch()
            return summary
        } catch {
            await ledger.discardScratch()
            throw error
        }
    }

    private func execute(
        ledger: DownloadLedger, config: Config, session: StoredSession, options: DownloadOptions,
        throttle: ThrottleConfig, hours: ActiveHours?, root: String, scanFolder: String,
        startedAt: Date, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadSummary {
        let clock = environment.clock
        let totals = try await ledger.prepare(now: startedAt)
        let allocator = TargetAllocator(root: root)
        await allocator.cleanStaleFiles(inFoldersOf: totals.interruptedTargets)

        let client = try AmazonClient(
            session: session, host: config.effectiveAmazonHost, configuration: environment.sessionConfiguration(),
            timeouts: environment.timeouts)
        defer { client.invalidate() }

        let coordinator = RunCoordinator(filesTotal: totals.count, bytesTotal: totals.bytes)
        guard totals.count > 0 else {
            await coordinator.markFinished()
            let summary = await coordinator.summary(duration: 0)
            await ledger.saveLastRun(DownloadRunRecord(finishedAt: clock.now(), summary: summary.withoutResults))
            progress(DownloadProgress(state: .finished))
            return summary
        }

        let limiter = RateLimiter(requestsPerMinute: throttle.maxRequestsPerMinute, clock: clock)

        // 4. Is the session good? One request on a known node.
        if let nodeId = try await ledger.peekNodeId() {
            try await limiter.acquire()
            do {
                _ = try await client.fetchMetadata(nodeId: nodeId)
            } catch DownloadError.sessionExpired {
                throw DownloadError.sessionExpired
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Other trouble (throttling, one missing node, the network) is handled per file below.
            }
        }

        // 5. Work.
        let metrics = RunMetrics(startedAt: startedAt)
        let context = RunContext(
            engine: self, options: options, throttle: throttle, hours: hours, root: root,
            scanFolder: scanFolder, ledger: ledger, client: client, limiter: limiter,
            gate: ThrottleGate(clock: clock, random: environment.random),
            pacer: BandwidthPacer(bytesPerSecond: throttle.bytesPerSecondLimit),
            coordinator: coordinator, metrics: metrics, allocator: allocator,
            redactor: SecretRedactor(session: session))

        let workers = max(1, min(throttle.maxConcurrentDownloads, totals.count))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await context.tickProgress(progress) }
            group.addTask {
                await withTaskGroup(of: Void.self) { workersGroup in
                    for _ in 0..<workers { workersGroup.addTask { await context.worker() } }
                }
                if Task.isCancelled { await coordinator.requestStop(.cancelled) }
                await coordinator.markFinished()
            }
        }

        let summary = await coordinator.summary(duration: clock.now().timeIntervalSince(startedAt))
        progress(await context.currentProgress())
        await ledger.saveLastRun(DownloadRunRecord(finishedAt: clock.now(), summary: summary.withoutResults))
        return summary
    }
}

extension DownloadSummary {
    /// The summary without the per-file list, small enough to keep in the database.
    var withoutResults: DownloadSummary {
        var copy = self
        copy.results = []
        return copy
    }
}

/// The parts of one run, and the per-file logic.
final class RunContext: @unchecked Sendable {
    let engine: DownloadEngine
    let options: DownloadOptions
    let throttle: ThrottleConfig
    let hours: ActiveHours?
    let root: String
    let scanFolder: String
    let ledger: DownloadLedger
    let client: AmazonClient
    let limiter: RateLimiter
    let gate: ThrottleGate
    let pacer: BandwidthPacer
    let coordinator: RunCoordinator
    let metrics: RunMetrics
    let allocator: TargetAllocator
    let redactor: SecretRedactor

    private var clock: DownloadClock { engine.environment.clock }

    init(
        engine: DownloadEngine, options: DownloadOptions, throttle: ThrottleConfig,
        hours: ActiveHours?, root: String, scanFolder: String, ledger: DownloadLedger,
        client: AmazonClient, limiter: RateLimiter, gate: ThrottleGate, pacer: BandwidthPacer,
        coordinator: RunCoordinator, metrics: RunMetrics, allocator: TargetAllocator, redactor: SecretRedactor
    ) {
        self.engine = engine
        self.options = options
        self.throttle = throttle
        self.hours = hours
        self.root = root
        self.scanFolder = scanFolder
        self.ledger = ledger
        self.client = client
        self.limiter = limiter
        self.gate = gate
        self.pacer = pacer
        self.coordinator = coordinator
        self.metrics = metrics
        self.allocator = allocator
        self.redactor = redactor
    }

    // MARK: Progress

    func currentProgress() async -> DownloadProgress {
        await coordinator.snapshot(
            now: clock.now(), metrics: metrics, backoffUntil: await gate.blockedUntilDate)
    }

    func tickProgress(_ report: @Sendable (DownloadProgress) -> Void) async {
        while !(await coordinator.finished) {
            report(await currentProgress())
            guard (try? await Task.sleep(nanoseconds: 250_000_000)) != nil else { break }
        }
    }

    // MARK: Workers

    func worker() async {
        while !Task.isCancelled {
            if await coordinator.shouldStop { return }
            guard await waitForWindow() else { return }
            do { try await gate.waitUntilClear() } catch { return }
            let claimed: (job: DownloadJob?, skippedDuplicates: [DownloadJob])
            do {
                claimed = try await ledger.claimNext(now: clock.now())
            } catch {
                await coordinator.requestStop(.failure("The download queue could not be read: \(redactor.redact("\(error)"))"))
                return
            }
            await coordinator.countSkipped(claimed.skippedDuplicates)
            guard let job = claimed.job else { return }
            await process(job)
            if throttle.pauseBetweenFilesMs > 0 {
                try? await clock.sleep(Double(throttle.pauseBetweenFilesMs) / 1000)
            }
        }
    }

    /// Wait until new files may be started. Returns false when the run should end instead.
    private func waitForWindow() async -> Bool {
        guard let hours, options.hoursPolicy != .ignore else { return true }
        let calendar = engine.environment.calendar
        while true {
            let now = clock.now()
            if hours.contains(now, calendar: calendar) {
                await coordinator.setWindow(until: nil)
                return true
            }
            if options.hoursPolicy == .exit {
                await coordinator.requestStop(.outsideActiveHours)
                return false
            }
            let wait = hours.secondsUntilOpen(from: now, calendar: calendar)
            await coordinator.setWindow(until: now.addingTimeInterval(wait))
            do { try await clock.sleep(min(wait, 60)) } catch { return false }
            if await coordinator.shouldStop { return false }
        }
    }

    private func dayKey() -> String {
        let parts = engine.environment.calendar.dateComponents([.year, .month, .day], from: clock.now())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func isDriveGone() -> Bool { !FileOps.isDirectory(root) }

    // MARK: One file

    private func process(_ job: DownloadJob) async {
        await coordinator.begin(job)
        let resources = FileResources()
        await runJob(job, resources: resources)
        if let part = resources.partPath { unlink(part) }
        if let size = resources.reservedSize { await coordinator.unreserve(size) }
        await coordinator.end(job)
    }

    /// Temporary file and reserved space of the file in progress, cleaned up when it ends.
    private final class FileResources: @unchecked Sendable {
        var partPath: String?
        var reservedSize: Int64?
    }

    private func runJob(_ job: DownloadJob, resources: FileResources) async {
        var job = job
        if isDriveGone() {
            await ledger.release(job, now: clock.now())
            await coordinator.requestStop(.driveUnavailable)
            return
        }

        // Limits first: a file that would break one is not started.
        let dailyLimit = throttle.dailyLimitBytes
        let usedToday = dailyLimit > 0 ? await ledger.dailyBytes(dayKey: dayKey()) : 0
        let free = engine.environment.freeSpace(scanFolder)
        if let reason = await coordinator.tryReserve(
            size: job.size, usedToday: usedToday, dailyLimit: dailyLimit, freeSpace: free,
            minFree: throttle.minFreeSpaceBytes)
        {
            await ledger.release(job, now: clock.now())
            await coordinator.requestStop(reason)
            return
        }
        resources.reservedSize = job.size

        // Where does it go?
        let allocation: TargetAllocator.Allocation
        do {
            allocation = try await allocator.allocate(job)
        } catch is CancellationError {
            await ledger.release(job, now: clock.now())
            return
        } catch {
            await fail(job, error: error, verification: false, permanent: false)
            return
        }
        switch allocation {
        case .adopt(let rel, _, let size, let mtime):
            do {
                try await ledger.markDone(
                    job, relPath: rel, size: size, mtime: mtime, md5: job.md5, downloadedBytes: 0,
                    dayKey: dayKey(), now: clock.now())
                await coordinator.countAdopted(job, path: rel)
            } catch {
                await fail(job, error: error, verification: false, permanent: false)
            }
        case .write(let rel, let absolute, let number):
            let name = absolute.split(separator: "/").last.map(String.init) ?? "file"
            let partAbsolute = PathGuard.parent(of: absolute) + "/" + FileNameSanitizer.partName(for: name, tag: job.md5)
            resources.partPath = partAbsolute
            await download(&job, rel: rel, absolute: absolute, number: number, part: partAbsolute)
        }
    }

    /// The tries for one file: verification failures retry (up to three times per run), throttling
    /// waits and retries without using up a try.
    private func download(
        _ job: inout DownloadJob, rel: String, absolute: String, number: Int, part: String
    ) async {
        var triesThisRun = 0
        var throttleRetries = 0
        while true {
            if Task.isCancelled {
                await ledger.release(job, now: clock.now())
                return
            }
            do {
                try await gate.waitUntilClear()
                try await limiter.acquire()
                let attemptBytes = AttemptBytes()
                let received: (size: Int64, md5: String)
                do {
                    received = try await receive(job, into: part, counting: attemptBytes)
                } catch {
                    metrics.subtract(attemptBytes.value)
                    throw error
                }
                guard received.size == job.size else {
                    metrics.subtract(received.size)
                    throw DownloadError.sizeMismatch(expected: job.size, actual: received.size)
                }
                guard received.md5 == job.md5 else {
                    metrics.subtract(received.size)
                    throw DownloadError.md5Mismatch(expected: job.md5, actual: received.md5)
                }
                let final = try await allocator.commit(
                    part: part, allocation: (rel, absolute, number), job: job)
                let info = FileOps.regularFileInfo(final.abs)
                try await ledger.markDone(
                    job, relPath: final.rel, size: info?.size ?? received.size,
                    mtime: info?.mtime ?? Int64(clock.now().timeIntervalSince1970), md5: received.md5,
                    downloadedBytes: received.size, dayKey: dayKey(), now: clock.now())
                await gate.registerSuccess()
                await coordinator.countDownloaded(job, path: final.rel, bytes: received.size)
                return
            } catch is CancellationError {
                await ledger.release(job, now: clock.now())
                return
            } catch let error as DownloadError {
                switch error {
                case .sessionExpired:
                    await ledger.release(job, now: clock.now())
                    await coordinator.requestStop(.sessionExpired)
                    return
                case .throttled(_, let retryAfter):
                    if await backOff(retryAfter: retryAfter) == false {
                        await ledger.release(job, now: clock.now())
                        return
                    }
                    throttleRetries += 1
                case .network:
                    if await backOff(retryAfter: nil) == false {
                        await ledger.release(job, now: clock.now())
                        return
                    }
                    throttleRetries += 1
                case .sizeMismatch, .md5Mismatch:
                    triesThisRun += 1
                    job.attempts += 1
                    unlink(part)
                    if triesThisRun >= 3 || job.attempts >= options.maxAttempts {
                        await fail(job, error: error, verification: true, permanent: false)
                        return
                    }
                    await ledger.recordAttempt(
                        job, attempts: job.attempts, error: redactor.redact(error.description), now: clock.now())
                case .httpStatus, .redirectRefused, .invalidResponse, .invalidNodeId, .insecureURL, .invalidHost:
                    await fail(job, error: error, verification: false, permanent: true)
                    return
                case .fileSystem, .targetNotWritable, .pathEscapesRoot:
                    if isDriveGone() {
                        await ledger.release(job, now: clock.now())
                        await coordinator.requestStop(.driveUnavailable)
                        return
                    }
                    await fail(job, error: error, verification: false, permanent: false)
                    return
                default:
                    await fail(job, error: error, verification: false, permanent: false)
                    return
                }
                if throttleRetries > 10 {
                    await fail(job, error: error, verification: false, permanent: false)
                    return
                }
            } catch {
                if isDriveGone() {
                    await ledger.release(job, now: clock.now())
                    await coordinator.requestStop(.driveUnavailable)
                    return
                }
                await fail(job, error: error, verification: false, permanent: false)
                return
            }
        }
    }

    /// Download into the temporary file. Returns size and MD5 of what arrived.
    private func receive(
        _ job: DownloadJob, into part: String, counting attemptBytes: AttemptBytes
    ) async throws -> (size: Int64, md5: String) {
        let writer = try await blocking { try PartWriter(path: part, expectedSize: job.size) }
        defer { writer.closeFile() }
        let metrics = metrics
        let pacer = pacer
        let expectsHTML = ["html", "htm", "xhtml"].contains(
            FileNameSanitizer.split(job.fileName).ext.dropFirst().lowercased())
        try await client.downloadContent(nodeId: job.nodeId, expectsHTML: expectsHTML) { data in
            try writer.append(data)
            attemptBytes.add(data.count)
            let now = Date()
            metrics.add(data.count, at: now)
            return pacer.pause(afterBytes: data.count, now: now)
        }
        return try await blocking { try writer.finish() }
    }

    /// Register a throttle answer and wait it out. Returns false when the run should stop instead.
    private func backOff(retryAfter: TimeInterval?) async -> Bool {
        let decision = await gate.registerThrottle(retryAfter: retryAfter)
        if decision.longPause {
            if let maxPauses = options.maxLongPauses, await gate.longPauses > maxPauses {
                await coordinator.requestStop(.throttled)
                return false
            }
            await coordinator.setMessage(
                "Amazon keeps limiting requests. Pausing for 15 minutes.", until: decision.until)
        }
        return !(await coordinator.shouldStop)
    }

    /// Record a final failure. `permanent` uses up the remaining attempts.
    private func fail(_ job: DownloadJob, error: Error, verification: Bool, permanent: Bool) async {
        let text = redactor.redact((error as? DownloadError)?.description ?? "\(error)")
        let attempts = permanent ? max(options.maxAttempts, job.attempts + 1) : job.attempts + (verification ? 0 : 1)
        await ledger.markFailed(job, attempts: attempts, error: text, now: clock.now())
        await coordinator.countFailed(job, error: text, verification: verification)
    }
}

/// Bytes received by one attempt, counted from the network callback.
final class AttemptBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func add(_ count: Int) {
        lock.lock()
        total += Int64(count)
        lock.unlock()
    }
}
