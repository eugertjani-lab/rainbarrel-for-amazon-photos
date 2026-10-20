import Foundation

/// The stored Amazon session as shown to people and tools. Never contains cookie values.
public struct SessionInfo: Codable, Sendable, Equatable {
    public var signedIn: Bool
    public var host: String?
    public var savedAt: Date?
    public var cookieCount: Int
    /// False when the session-id cookie is missing or past its expiry date.
    public var usable: Bool
    /// Where the session is kept, for example "macOS Keychain".
    public var storage: String
    /// Why the session cannot be read, if it cannot.
    public var problem: String?
}

/// Queue, last run, session, limits and drive state, for `download-status` and the `download_status` tool.
public struct DownloadStatusReport: Codable, Sendable, Equatable {
    public var queue: DownloadQueueCounts
    public var failures: [DownloadFailure]
    /// All failed jobs by reason: waiting for a retry (with the next retry time), due, and permanent.
    public var failureSummary: DownloadFailureSummary
    public var lastRun: DownloadRunRecord?
    public var session: SessionInfo
    public var throttle: ThrottleConfig
    public var amazonHost: String
    public var driveRoot: String?
    public var targetFolder: String?
    public var driveMounted: Bool
    /// Judged without writing: nil when the drive is not mounted.
    public var driveWritable: Bool?
}

extension RainbarrelTools {
    public static let maxBatchLimit = 50
    public static let defaultBatchLimit = 10

    public func sessionInfo() -> SessionInfo {
        let storage = sessionStore.location
        do {
            guard let session = try sessionStore.load() else {
                return SessionInfo(
                    signedIn: false, host: nil, savedAt: nil, cookieCount: 0, usable: false, storage: storage,
                    problem: nil)
            }
            return SessionInfo(
                signedIn: true, host: session.host, savedAt: session.savedAt, cookieCount: session.cookies.count,
                usable: session.isUsable(), storage: storage, problem: nil)
        } catch {
            return SessionInfo(
                signedIn: false, host: nil, savedAt: nil, cookieCount: 0, usable: false, storage: storage,
                problem: "\(error)")
        }
    }

    /// Whether any process is downloading right now, from the shared state database. Cheap enough to
    /// poll every few seconds.
    public func downloadActivity(now: Date = Date()) throws -> DownloadActivity {
        let config = try loadConfig()
        let store = try openStore()
        return try DownloadJobTable(source: store, queue: store, config: config).recentActivity(now: now)
    }

    /// The failed download jobs by reason and what happens to them next. Reads the state database
    /// only, so the menu-bar app can ask for it every time it looks at the queue.
    public func downloadFailureSummary(
        maxAttempts: Int = DownloadOptions.defaultMaxAttempts
    ) throws -> DownloadFailureSummary {
        let config = try loadConfig()
        let store = try openStore()
        return try DownloadJobTable(source: store, queue: store, config: config)
            .failureSummary(maxAttempts: maxAttempts, now: downloadEnvironment.clock.now())
    }

    public func downloadStatus(failureLimit: Int = 20) throws -> DownloadStatusReport {
        let config = try loadConfig()
        let store = try openStore()
        let table = DownloadJobTable(source: store, queue: store, config: config)
        var lastRun: DownloadRunRecord?
        if let text = try store.getMeta(MetaKey.downloadLastRun) {
            lastRun = try? JSONDecoder.iso8601.decode(DownloadRunRecord.self, from: Data(text.utf8))
        }
        let driveRoot = config.driveRoot
        let mounted = driveRoot.map { FileOps.isDirectory($0) } ?? false
        return DownloadStatusReport(
            queue: try table.counts(), failures: try table.failures(limit: failureLimit),
            failureSummary: try table.failureSummary(
                maxAttempts: DownloadOptions.defaultMaxAttempts, now: downloadEnvironment.clock.now()),
            lastRun: lastRun,
            session: sessionInfo(), throttle: config.throttle.normalized, amazonHost: config.effectiveAmazonHost,
            driveRoot: driveRoot, targetFolder: config.scanRootPath, driveMounted: mounted,
            driveWritable: mounted ? DownloadEngine.driveLooksWritable(config: config) : nil)
    }

    /// Download up to `limit` of the newest missing files and wait for the result. Refuses before
    /// any network call when the drive cannot be written to; refuses when there is no usable session.
    public func downloadBatch(limit: Int, year: Int?) async throws -> DownloadSummary {
        let config = try loadConfig()
        guard config.driveRoot?.isEmpty == false else { throw ToolError(DownloadError.noDriveConfigured.description) }
        do { try DownloadEngine.prepareTarget(config: config) } catch let error as DownloadError {
            throw ToolError(error.description)
        }
        let session: StoredSession
        do {
            guard let stored = try sessionStore.load() else { throw ToolError(DownloadError.notSignedIn.description) }
            session = stored
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError("\(error)")
        }
        guard session.isUsable() else { throw ToolError(DownloadError.sessionExpired.description) }

        let store = try openStore()
        if try store.cloudFolderCount() == 0 {
            do { _ = try await refreshCatalog(config: config, store: store) } catch {
                if try store.cloudItemCount() == 0 { throw error }
            }
        }

        let engine = DownloadEngine(paths: paths, environment: downloadEnvironment)
        let options = DownloadOptions(year: year, limit: limit, hoursPolicy: .exit, maxLongPauses: 0)
        let summary: DownloadSummary
        do {
            summary = try await engine.run(config: config, session: session, options: options, sessionStore: sessionStore)
        } catch let error as DownloadError {
            throw ToolError(error.description)
        }
        switch summary.stopReason {
        case .sessionExpired?, .driveUnavailable?, .outsideActiveHours?:
            throw ToolError(summary.stopReason?.description ?? "The download stopped.")
        default:
            return summary
        }
    }
}
