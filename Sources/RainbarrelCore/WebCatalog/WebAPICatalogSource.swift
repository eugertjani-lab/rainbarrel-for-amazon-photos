import Foundation

/// What a read of the change feed found.
enum WebChangeOutcome: Sendable, Equatable {
    /// The feed is drained: apply `changes`, then store `checkpoint`.
    case changes(CatalogChangeSet, checkpoint: String, nodesSeen: Int, skipped: Int)
    /// Amazon asks for a rebuild: the stored catalog cannot be brought up to date from the feed.
    case resetRequired
}

/// Reads the cloud catalog through Amazon's private `/drive/v1` web API with the stored session.
///
/// A full read drains the change feed from the beginning: every node of the account's history arrives
/// in order, a node that changed since it was first sent arrives again, and the last word about each
/// node wins. The checkpoint at the end of the drain is the position that later refreshes continue
/// from. Every request waits for the request limit of the throttle settings and backs off when Amazon
/// answers 429 or 5xx, honouring `Retry-After`. Activity hours and the daily limit apply to downloads only.
public struct WebAPICatalogSource: AsyncCloudCatalogSource, Sendable {
    /// Nodes asked for per change-feed call of an incremental refresh.
    static let feedMaxNodes = 1000
    /// Nodes asked for per change-feed call while the whole library is drained.
    static let drainMaxNodes = 10_000

    let client: AmazonClient
    let limiter: RateLimiter
    let gate: ThrottleGate
    let clock: DownloadClock
    /// Called after every answer of the change feed, from the task that reads.
    public var onProgress: (@Sendable (CatalogProgress) -> Void)?

    public var sourceName: String { "Amazon Photos web API" }
    public var host: String { client.host }

    init(
        client: AmazonClient, limiter: RateLimiter, gate: ThrottleGate, clock: DownloadClock,
        onProgress: (@Sendable (CatalogProgress) -> Void)? = nil
    ) {
        self.client = client
        self.limiter = limiter
        self.gate = gate
        self.clock = clock
        self.onProgress = onProgress
    }

    /// A source for the account of `session`, paced by the request limit in `config.throttle`. The
    /// session's credentials go only where `AmazonClient` sends them (the configured Amazon host).
    public static func make(
        session: StoredSession, config: Config, environment: DownloadEnvironment = .live,
        onProgress: (@Sendable (CatalogProgress) -> Void)? = nil
    ) throws -> WebAPICatalogSource {
        let client = try AmazonClient(
            session: session, host: config.effectiveAmazonHost, configuration: environment.sessionConfiguration(),
            timeouts: environment.timeouts)
        return WebAPICatalogSource(
            client: client,
            limiter: RateLimiter(requestsPerMinute: config.throttle.normalized.maxRequestsPerMinute, clock: environment.clock),
            gate: ThrottleGate(clock: environment.clock, random: environment.random),
            clock: environment.clock, onProgress: onProgress)
    }

    /// Cancel what is running and release the connection pool.
    public func invalidate() { client.invalidate() }

    var description: String { "Amazon Photos web API (\(client.host))" }

    // MARK: Full read

    /// Drain the change feed from scratch into `staging`, then compare the result with Amazon's file count.
    /// A checkpoint taken before the read would be an early position of the feed, and continuing from
    /// it would replay the whole library, so the checkpoint is the one the drain ends with.
    public func readCatalog(into staging: CloudCatalogStaging) async throws -> CatalogReadResult {
        let startedAt = clock.now()
        var cursor: String?
        var seen = 0
        var undecodable = 0
        // Nodes whose last word is "no MD5 or size": counted once each, and not at all once they are
        // trashed or complete.
        var skippedFiles = Set<String>()
        var skippedAssets = Set<String>()
        while true {
            let current = cursor
            let feed = try await paced {
                try await client.fetchChanges(checkpoint: current, maxNodes: Self.drainMaxNodes)
            }
            for chunk in feed.chunks {
                if chunk.reset {
                    // Amazon sends the whole library again: what was staged so far is obsolete.
                    try staging.removeAll()
                    skippedFiles.removeAll()
                    skippedAssets.removeAll()
                    undecodable = 0
                }
                for node in chunk.nodes {
                    switch WebNodeMapping.disposition(of: node) {
                    case .folder(let folder):
                        try staging.upsert(folder)
                    case .item(let item):
                        try staging.upsert(item)
                    case .skipped:
                        try staging.remove(node.id)
                        if node.kind?.uppercased() == "FILE" { skippedFiles.insert(node.id) } else { skippedAssets.insert(node.id) }
                        continue
                    case .removed, .ignored:
                        try staging.remove(node.id)
                    }
                    skippedFiles.remove(node.id)
                    skippedAssets.remove(node.id)
                }
                undecodable += chunk.undecodable
            }
            seen += feed.nodeCount
            onProgress?(CatalogProgress(phase: .library, nodes: seen))
            let last = feed.lastCheckpoint
            if let last { cursor = last }
            // An empty answer means the feed is drained.
            if feed.nodeCount == 0 { break }
            guard let last else {
                throw DownloadError.invalidResponse("the change feed sent nodes without a checkpoint")
            }
            guard last != current else {
                throw DownloadError.invalidResponse("the change feed did not move on")
            }
        }
        let counts = try staging.counts()
        let warnings = try await fileCountWarnings(built: counts.files, skippedFiles: skippedFiles.count)
        return CatalogReadResult(
            sourceDescription: description, sourceModifiedAt: startedAt, itemCount: counts.items,
            folderCount: counts.folders, skippedCount: skippedFiles.count + skippedAssets.count + undecodable,
            checkpoint: cursor.map { CatalogCheckpoint(source: .web, host: client.host, token: $0) },
            warnings: warnings)
    }

    /// A check on the drain: Amazon's count of available files should be the files the drain built plus
    /// the ones it left out. The catalog is kept either way, because uploads and deletions can land
    /// between the drain and the count, and a count that cannot be had is no reason to throw the drain away.
    private func fileCountWarnings(built: Int, skippedFiles: Int) async throws -> [String] {
        let live: Int
        do {
            live = try await paced { try await client.availableFileCount() }
        } catch let error as DownloadError {
            return ["Could not check the catalog against Amazon's file count: \(error.description)."]
        }
        guard live != built + skippedFiles else { return [] }
        let note = skippedFiles > 0 ? " (\(skippedFiles) more were left out for lacking an MD5 or size)" : ""
        return [
            "Amazon Photos counts \(live) photos and videos, but the change feed delivered \(built)\(note). "
                + "Uploads or deletions while the refresh ran can explain a small difference; refresh again if it stays."
        ]
    }

    // MARK: Change feed

    /// Everything that changed after `checkpoint`: the feed is read until it has nothing more, and the
    /// changes are merged so that the last word about each node wins. Nothing is written here.
    func collectChanges(since checkpoint: String) async throws -> WebChangeOutcome {
        var cursor = checkpoint
        var changes = CatalogChangeSet()
        var seen = 0
        var skipped = 0
        while true {
            let current = cursor
            let feed = try await paced {
                try await client.fetchChanges(checkpoint: current, maxNodes: Self.feedMaxNodes)
            }
            if feed.reset { return .resetRequired }
            for chunk in feed.chunks {
                for node in chunk.nodes {
                    switch WebNodeMapping.disposition(of: node) {
                    case .folder(let folder):
                        changes.upsert(folder)
                    case .item(let item):
                        changes.upsert(item)
                    case .skipped:
                        skipped += 1
                        changes.remove(node.id)
                    case .removed, .ignored:
                        changes.remove(node.id)
                    }
                }
                skipped += chunk.undecodable
            }
            seen += feed.nodeCount
            onProgress?(CatalogProgress(phase: .changes, nodes: seen))
            let last = feed.lastCheckpoint
            if let last { cursor = last }
            // An empty answer means the feed is drained.
            if feed.nodeCount == 0 { break }
            guard let last else {
                throw DownloadError.invalidResponse("the change feed sent nodes without a checkpoint")
            }
            guard last != current else {
                throw DownloadError.invalidResponse("the change feed did not move on")
            }
        }
        return .changes(changes, checkpoint: cursor, nodesSeen: seen, skipped: skipped)
    }

    // MARK: Pacing

    /// One request, within the request limit. Throttle answers (429, 5xx) and network trouble wait out
    /// the shared backoff and then repeat the request; five in a row end the read with that error, so
    /// that a refresh never sits through the 15-minute pause of a download run.
    private func paced<T>(_ work: () async throws -> T) async throws -> T {
        while true {
            try Task.checkCancellation()
            try await gate.waitUntilClear()
            try await limiter.acquire()
            do {
                let value = try await work()
                await gate.registerSuccess()
                return value
            } catch let error as DownloadError {
                let retryAfter: TimeInterval?
                switch error {
                case .throttled(_, let after): retryAfter = after
                case .network: retryAfter = nil
                default: throw error
                }
                let decision = await gate.registerThrottle(retryAfter: retryAfter)
                if decision.longPause { throw error }
            }
        }
    }
}
