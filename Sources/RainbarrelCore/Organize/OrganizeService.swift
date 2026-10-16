import Foundation

/// Moves the files that are already on the backup drive into the folder layout the downloads use, so
/// a drive that was filled by a plain copy ends up as if Rainbarrel had downloaded it. Files are
/// matched to the cloud catalog by the MD5s in the drive index; nothing is hashed, copied or deleted,
/// and a file that matches nothing is never touched.
public struct OrganizeService: Sendable {
    public static let defaultSampleSize = 20
    public static let maxSampleSize = 200

    public let paths: AppPaths
    public let environment: OrganizeEnvironment

    public init(paths: AppPaths, environment: OrganizeEnvironment = .live) {
        self.paths = paths
        self.environment = environment
    }

    private func openStore() throws -> StateStore {
        try paths.ensureDataDirectory()
        return try StateStore(path: paths.stateURL.path)
    }

    /// Hold the lock that keeps downloads away, for as long as `body` runs. A download holds the same
    /// lock, so the two never overlap in either order.
    private func exclusively<T>(_ body: () throws -> T) throws -> T {
        try paths.ensureDataDirectory()
        guard let lock = try RunLock(path: paths.downloadLockURL.path) else { throw DownloadError.alreadyRunning }
        defer { lock.release() }
        return try body()
    }

    /// What a run would do. Reads the database and the drive, writes nothing.
    public func preview(config: Config, sample: Int = defaultSampleSize) throws -> OrganizePreview {
        let store = try openStore()
        let plan = try OrganizePlanner(store: store, config: config, environment: environment).plan()
        let count = min(max(sample, 0), Self.maxSampleSize)
        return OrganizePreview(
            summary: plan.summary, sample: plan.moves.prefix(count).map { plan.entry(for: $0) },
            duplicateSample: Array(plan.duplicates.prefix(count)), driveRoot: config.driveRoot,
            targetFolder: config.scanRootPath, driveWritable: DownloadEngine.driveLooksWritable(config: config))
    }

    /// Move the files. Refuses while a download runs and when the drive cannot be written to.
    public func apply(
        config: Config, options: OrganizeOptions = OrganizeOptions(),
        isCancelled: () -> Bool = { false }, progress: (OrganizeProgress) -> Void = { _ in }
    ) throws -> OrganizeRunResult {
        try exclusively {
            try DownloadEngine.prepareTarget(config: config)
            let root = try DownloadEngine.targetRoot(config: config, options: DownloadOptions())
            let scanFolder = try DownloadEngine.scanFolder(root: root, config: config)
            let store = try openStore()
            progress(OrganizeProgress(phase: .planning, done: 0, total: 0, currentPath: nil))
            let plan = try OrganizePlanner(store: store, config: config, environment: environment).plan()
            return try OrganizeExecutor(
                store: store, driveRoot: root, scanFolder: scanFolder, environment: environment
            ).apply(plan: plan, options: options, isCancelled: isCancelled, progress: progress)
        }
    }

    /// Reverse the last run. Entries whose file changed since stay where they are and are reported.
    public func undo(
        config: Config, isCancelled: () -> Bool = { false }, progress: (OrganizeProgress) -> Void = { _ in }
    ) throws -> OrganizeUndoResult {
        try exclusively {
            try DownloadEngine.prepareTarget(config: config)
            let root = try DownloadEngine.targetRoot(config: config, options: DownloadOptions())
            let scanFolder = try DownloadEngine.scanFolder(root: root, config: config)
            let store = try openStore()
            return try OrganizeExecutor(
                store: store, driveRoot: root, scanFolder: scanFolder, environment: environment
            ).undo(isCancelled: isCancelled, progress: progress)
        }
    }
}

extension RainbarrelTools {
    /// The dry run behind the `organize_preview` tool. Changes nothing.
    public func organizePreview(sample: Int = OrganizeService.defaultSampleSize) throws -> OrganizePreview {
        do {
            return try OrganizeService(paths: paths, environment: organizeEnvironment)
                .preview(config: try loadConfig(), sample: sample)
        } catch let error as DownloadError {
            throw ToolError(error.description)
        } catch let error as OrganizeError {
            throw ToolError(error.description)
        }
    }
}
