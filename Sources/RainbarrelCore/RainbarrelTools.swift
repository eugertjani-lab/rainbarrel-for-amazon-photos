import Foundation

/// A failure that is meant to be shown to a person: the message is complete and human readable.
public struct ToolError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Counts reported after the cloud catalog was refreshed.
public struct CatalogRefreshSummary: Codable, Sendable, Equatable {
    public var photosVideos: CountBytes
    public var distinctMD5: Int
    public var liveVideos: CountBytes
    /// When the Amazon Photos app last changed its index (mtime of the `-wal` file).
    public var catalogFreshness: Date
    public var refreshedAt: Date
}

/// What a bounded or complete drive scan did, and what is left.
public struct ScanSummary: Codable, Sendable, Equatable {
    public var hashing: Bool
    public var filesSeen: Int
    public var filesHashed: Int
    public var bytesHashed: Int64
    /// Seed-imported hashes that were kept (only the modification time was filled in).
    public var filesAdopted: Int
    public var errors: Int
    /// Rows removed because the files are gone from the drive.
    public var pruned: Int
    public var removedSkipped: Int
    public var removedOutOfScope: Int
    /// True when the whole scan scope was walked. False means the scan stopped early (limit or
    /// cancellation) and files that were not visited yet may still need work.
    public var walkedEverything: Bool
    public var stoppedByLimit: Bool
    public var cancelled: Bool
    /// Drive files inside the scope that have no hash yet (including files that failed to read).
    public var unhashedRemaining: Int
    public var directoryErrors: [String]
    public var durationSeconds: Double
    public var message: String
}

/// The operations behind the MCP tools and the menu-bar app, as plain synchronous functions.
/// Each call opens its own state database connection, so calls are independent and may run on
/// any thread while other processes use the same files.
public struct RainbarrelTools: Sendable {
    public typealias CatalogSourceProvider = @Sendable (Config) throws -> any CloudCatalogSource

    public let paths: AppPaths
    private let catalogSource: CatalogSourceProvider

    public init(
        paths: AppPaths = .default(),
        catalogSource: @escaping CatalogSourceProvider = { config in
            try AmazonAppIndexSource.resolve(explicitPath: config.amazonIndexPath)
        }
    ) {
        self.paths = paths
        self.catalogSource = catalogSource
    }

    // MARK: Configuration and state

    public func loadConfig() throws -> Config {
        try ConfigStore(url: paths.configURL).load()
    }

    public func saveConfig(_ config: Config) throws {
        try ConfigStore(url: paths.configURL).save(config)
    }

    public func openStore() throws -> StateStore {
        try paths.ensureDataDirectory()
        return try StateStore(path: paths.stateURL.path)
    }

    private func reconciler(_ store: StateStore, _ config: Config) throws -> Reconciler {
        Reconciler(store: store, scope: try DriveScope(scanSubpath: config.scanSubpath))
    }

    // MARK: Catalog

    /// Re-snapshot the Amazon Photos app index and replace the cloud catalog.
    public func refreshCatalog() throws -> CatalogRefreshSummary {
        let config = try loadConfig()
        let store = try openStore()
        return try refreshCatalog(config: config, store: store)
    }

    private func refreshCatalog(config: Config, store: StateStore) throws -> CatalogRefreshSummary {
        let result: CatalogReadResult
        do {
            result = try CatalogRefresher(store: store).refresh(from: try catalogSource(config))
        } catch let error as CatalogError {
            throw ToolError("\(error). Open the Amazon Photos desktop app once, or point Rainbarrel at the index with `rainbarrel config set-index <path>`.")
        } catch let error as SQLiteError {
            throw ToolError("The Amazon Photos index could not be read: \(error.message)")
        }
        let report = try reconciler(store, config).report(driveRoot: config.driveRoot)
        return CatalogRefreshSummary(
            photosVideos: report.photosVideos, distinctMD5: report.distinctMD5,
            liveVideos: report.liveVideos, catalogFreshness: result.sourceModifiedAt,
            refreshedAt: report.catalogRefreshedAt ?? Date())
    }

    // MARK: Reports

    /// The full report.
    /// - Parameter refresh: true forces a catalog refresh (and fails if it cannot run), false never
    ///   refreshes, nil refreshes only when the last refresh is more than 10 minutes old (and then
    ///   falls back to the previous catalog if the refresh fails).
    public func syncStatus(refresh: Bool? = nil) throws -> SyncReport {
        let config = try loadConfig()
        let store = try openStore()
        switch refresh {
        case true?:
            _ = try refreshCatalog(config: config, store: store)
        case nil:
            if try CatalogRefresher(store: store).isStale() {
                do {
                    _ = try refreshCatalog(config: config, store: store)
                } catch {
                    if try store.cloudItemCount() == 0 { throw error }
                }
            }
        case false?:
            break
        }
        return try reconciler(store, config).report(driveRoot: config.driveRoot)
    }

    public func listOnlineOnly(year: Int? = nil, limit: Int = 50, offset: Int = 0) throws -> Page<OnlineOnlyItem> {
        let config = try loadConfig()
        let store = try openStore()
        return try reconciler(store, config).onlineOnlyPage(year: year, limit: limit, offset: offset)
    }

    public func listDriveOnly(limit: Int = 50, offset: Int = 0) throws -> Page<DriveOnlyItem> {
        let config = try loadConfig()
        let store = try openStore()
        return try reconciler(store, config).driveOnlyPage(limit: limit, offset: offset)
    }

    public func breakdownByYear() throws -> [YearRow] {
        try syncStatus(refresh: false).years
    }

    // MARK: Scanning

    /// Walk the drive (read-only) and index it.
    /// - Parameters:
    ///   - hash: compute MD5s for new or changed files.
    ///   - limit: stop after this many files needed work; nil walks everything.
    ///   - retry: pause schedule for flaky drives.
    ///   - progress: called while the scan runs, on the calling thread.
    ///   - isCancelled: polled between files; true stops the scan cleanly.
    public func scanDrive(
        hash: Bool = true,
        limit: Int? = nil,
        retry: RetryPolicy = .default,
        progress: ((ScanProgress) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ScanSummary {
        let config = try loadConfig()
        guard let driveRoot = config.driveRoot, !driveRoot.isEmpty else {
            throw ToolError("No backup drive is configured. Set it with `rainbarrel config set-drive <path>`.")
        }
        let scanRoot = config.scanRootPath ?? driveRoot
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scanRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError("The backup drive is not mounted: \(scanRoot) does not exist. Connect the drive and try again.")
        }
        let store = try openStore()
        let scanner = try DriveScanner(store: store, driveRoot: driveRoot, scanSubpath: config.scanSubpath)
        let result: ScanResult
        do {
            result = try scanner.scan(
                options: ScanOptions(hash: hash, limit: limit, retry: retry, isCancelled: isCancelled),
                progress: progress)
        } catch let error as DriveScanError {
            throw ToolError("\(error). The drive may have disconnected; try again when it is back.")
        }
        let scope = try DriveScope(scanSubpath: config.scanSubpath)
        let unhashed = try store.database.scalarInt64("""
            SELECT COUNT(*) FROM drive_files d WHERE d.md5 IS NULL AND \(scope.sqlCondition(column: "d.rel_path"))
            """) ?? 0
        let seconds = result.finishedAt.timeIntervalSince(result.startedAt)
        return ScanSummary(
            hashing: hash, filesSeen: result.filesSeen, filesHashed: result.filesHashed,
            bytesHashed: result.bytesHashed, filesAdopted: result.filesAdopted, errors: result.errors,
            pruned: result.pruned, removedSkipped: result.removedSkipped,
            removedOutOfScope: result.removedOutOfScope, walkedEverything: result.walkedEverything,
            stoppedByLimit: result.stoppedByLimit, cancelled: result.cancelled,
            unhashedRemaining: Int(unhashed), directoryErrors: result.directoryErrors,
            durationSeconds: seconds,
            message: Self.scanMessage(result, hashing: hash, unhashed: Int(unhashed)))
    }

    static func scanMessage(_ result: ScanResult, hashing: Bool, unhashed: Int) -> String {
        var parts: [String] = []
        if result.cancelled {
            parts.append("The scan was stopped early. Run it again to continue.")
        } else if result.stoppedByLimit {
            parts.append("The scan stopped at its file limit; more files may still need work. Call it again to continue.")
        } else {
            parts.append("The whole drive scope was scanned.")
        }
        if hashing, unhashed > 0 {
            parts.append("\(unhashed) known files still have no hash.")
        }
        if result.errors > 0 {
            parts.append("\(result.errors) errors were recorded; the next scan retries them.")
        }
        if result.pruned > 0 {
            parts.append("\(result.pruned) records of files that are gone from the drive were removed.")
        }
        return parts.joined(separator: " ")
    }
}
