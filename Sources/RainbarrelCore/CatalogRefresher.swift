import Foundation

/// What a catalog refresh did.
public struct CatalogRefreshOutcome: Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        /// The whole catalog was read and replaced.
        case full
        /// Only the changes since the last refresh were applied.
        case incremental
    }

    public var origin: CatalogOrigin
    public var mode: Mode
    /// What was read; `itemCount` and `folderCount` are the totals of the stored catalog afterwards.
    public var result: CatalogReadResult
    /// Items and folders added or changed by an incremental refresh (0 for a full one).
    public var changed: Int
    /// Items and folders removed by an incremental refresh (0 for a full one).
    public var removed: Int
}

/// Copies a cloud catalog into the state store.
public struct CatalogRefresher {
    public let store: StateStore
    /// The file that a running download holds with `flock`. A refresh from the web API refuses to
    /// replace the catalog while it is held. Nil skips the check.
    public let downloadLockPath: String?

    public init(store: StateStore, downloadLockPath: String? = nil) {
        self.store = store
        self.downloadLockPath = downloadLockPath
    }

    /// Replace `cloud_items` and `cloud_folders` with the current catalog of `source`, in one transaction.
    @discardableResult
    public func refresh(
        from source: CloudCatalogSource, origin: CatalogOrigin = .app, now: Date = Date()
    ) throws -> CatalogReadResult {
        try store.replaceCloudCatalog(seenAt: now, origin: origin) { itemSink, folderSink in
            try source.readCatalog(folders: folderSink, items: itemSink)
        }
    }

    /// Replace the catalog with what `source` reads, in one transaction that stays open while the
    /// source waits for the network. If the read fails (a rejected session, a network error, an
    /// answer that is not JSON, a cancellation), the transaction is rolled back and the previous
    /// catalog stays as it was.
    @discardableResult
    public func refresh(
        from source: some AsyncCloudCatalogSource, origin: CatalogOrigin = .web, now: Date = Date()
    ) async throws -> CatalogReadResult {
        try await store.replaceCloudCatalogAsync(seenAt: now, origin: origin) { staging in
            try await source.readCatalog(into: staging)
        }
    }

    /// Bring the catalog up to date from the web API: apply the change feed since the stored
    /// checkpoint, or read everything when there is none (or `full` is set, or the feed asks for a
    /// rebuild). Fails with `CatalogError.downloadInProgress` while a download run holds its lock.
    public func refresh(
        web source: WebAPICatalogSource, full: Bool = false, now: Date = Date()
    ) async throws -> CatalogRefreshOutcome {
        let lock = try acquireDownloadLock()
        defer { lock?.release() }

        if !full, let checkpoint = try usableCheckpoint(for: source) {
            switch try await source.collectChanges(since: checkpoint.token) {
            case .changes(let changes, let token, _, let skipped):
                let counts = try store.applyCatalogChanges(
                    changes, seenAt: now, sourceModifiedAt: now, sourceDescription: source.description,
                    origin: .web, checkpoint: CatalogCheckpoint(source: .web, host: source.host, token: token))
                let result = CatalogReadResult(
                    sourceDescription: source.description, sourceModifiedAt: now, itemCount: counts.items,
                    folderCount: counts.folders, skippedCount: skipped,
                    checkpoint: CatalogCheckpoint(source: .web, host: source.host, token: token))
                return CatalogRefreshOutcome(
                    origin: .web, mode: .incremental, result: result,
                    changed: changes.upsertCount, removed: changes.removed.count)
            case .resetRequired:
                break  // the feed no longer describes the changes: read everything
            }
        }
        let result = try await refresh(from: source, origin: .web, now: now)
        return CatalogRefreshOutcome(origin: .web, mode: .full, result: result, changed: 0, removed: 0)
    }

    /// The stored checkpoint when it belongs to the web catalog that is stored, on this Amazon host.
    private func usableCheckpoint(for source: WebAPICatalogSource) throws -> CatalogCheckpoint? {
        guard try store.catalogOrigin() == .web, let checkpoint = try store.catalogCheckpoint(),
            checkpoint.source == .web, checkpoint.host == source.host, !checkpoint.token.isEmpty
        else { return nil }
        return checkpoint
    }

    private func acquireDownloadLock() throws -> RunLock? {
        guard let downloadLockPath else { return nil }
        do {
            guard let lock = try RunLock(path: downloadLockPath) else { throw CatalogError.downloadInProgress }
            return lock
        } catch let error as DownloadError {
            throw ToolError("Cannot check for a running download: \(error.description)")
        }
    }

    /// True when the catalog was never refreshed or the last refresh is older than `maxAge` seconds.
    public func isStale(maxAge: TimeInterval = 600, now: Date = Date()) throws -> Bool {
        guard let last = try store.getMetaDate(MetaKey.catalogRefreshedAt) else { return true }
        return now.timeIntervalSince(last) > maxAge
    }
}
