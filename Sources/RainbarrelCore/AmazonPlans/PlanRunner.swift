import Foundation

/// How far a run of an apply or an undo is.
public struct PlanProgress: Sendable, Equatable {
    public var kind: PlanRunResult.Kind
    /// Steps dealt with so far in this run (done, skipped or failed).
    public var done: Int
    /// The most steps this run will deal with.
    public var total: Int
    /// The step being worked on, as a short line.
    public var current: String?
}

/// Why a run ended before it had dealt with every step.
public enum PlanStopReason: Codable, Sendable, Equatable {
    /// An apply performed `maxStepsPerApply` steps and left the rest for the next call.
    case stepLimit(Int)
    case sessionExpired
    /// Amazon refused a step, did not carry it out, or kept limiting requests. The text has no secrets.
    case failure(String)
    case cancelled
}

/// What one apply or undo call did.
public struct PlanRunResult: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case apply, undo }

    public var planId: Int64
    public var kind: Kind
    /// Steps this run performed (apply) or reversed (undo).
    public var succeeded: Int
    /// Apply: steps skipped because the item changed in Amazon since the plan was made. Undo: steps that
    /// could not be reversed because the item changed since the plan was applied.
    public var skipped: Int
    public var failed: Int
    /// Apply: ticked steps still to apply. Undo: done steps still to reverse.
    public var remaining: Int
    /// The plan's status after the run.
    public var status: PlanStatus
    public var stopReason: PlanStopReason?
    public var durationSeconds: Double
    /// A few sentences for a person, including what to do next.
    public var message: String
}

/// A step that cannot run because of its own data (for example a move without a destination).
struct PlanStepProblem: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Remembers, across the retries of one step, whether a write may have reached Amazon.
final class PlanStepProbe {
    var wrote = false
}

/// The machinery that apply and undo share: the request budget, the backoff, the drift check and the
/// follow-up of the local catalog.
final class PlanRunner {
    /// How often one step is retried after Amazon limited requests or the network failed.
    static let maxRetries = 4

    let store: StateStore
    let plans: PlanStore
    let client: AmazonClient
    let limiter: RateLimiter
    let gate: ThrottleGate
    let clock: DownloadClock
    let folderLookup: FolderLookupWait

    init(store: StateStore, client: AmazonClient, config: Config, environment: DownloadEnvironment) {
        self.store = store
        plans = PlanStore(store: store)
        self.client = client
        clock = environment.clock
        limiter = RateLimiter(requestsPerMinute: config.throttle.normalized.maxRequestsPerMinute, clock: environment.clock)
        gate = ThrottleGate(clock: environment.clock, random: environment.random)
        folderLookup = FolderLookupWait(delays: FolderLookupWait.standard.delays, sleep: environment.clock.sleep)
    }

    var catalog: LocalCatalog { LocalCatalog(database: store.database) }

    // MARK: Requests

    /// One request, under the request budget. A success ends any backoff in force.
    func request<T>(_ call: () async throws -> T) async throws -> T {
        try await limiter.acquire()
        let value = try await call()
        await gate.registerSuccess()
        return value
    }

    /// Run all requests of one step again from the start when Amazon limits requests or the network
    /// fails, after the wait that the gate computes, up to `maxRetries` times.
    func withBackoff<T>(_ body: () async throws -> T) async throws -> T {
        var retries = 0
        while true {
            try await gate.waitUntilClear()
            do {
                return try await body()
            } catch let error as DownloadError where error.isTransient {
                retries += 1
                if retries > Self.maxRetries { throw error }
                var retryAfter: TimeInterval?
                if case .throttled(_, let after) = error { retryAfter = after }
                _ = await gate.registerThrottle(retryAfter: retryAfter)
            }
        }
    }

    /// The text of an error for a person, without cookie values.
    func text(for error: Error) -> String {
        let raw: String
        switch error {
        case let error as DownloadError: raw = error.description
        case let error as AmazonWriteError: raw = error.description
        case let error as PlanStepProblem: raw = error.description
        case let error as ToolError: raw = error.message
        default: raw = "\(error)"
        }
        return client.redactor.redact(raw)
    }

    /// `text` as a sentence: with a full stop unless it ends in punctuation already.
    static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?".contains(last) ? text : text + "."
    }

    // MARK: The drift check

    /// Nil when `node` still matches `snapshot` (fields that are nil in the snapshot are not compared,
    /// and the MD5 only when `md5` is given); otherwise a short clause saying how it differs.
    static func difference(from snapshot: PlanSnapshot, in node: CloudNode, md5: String?) -> String? {
        if let status = snapshot.status, (node.status?.text ?? "").uppercased() != status.uppercased() {
            return "its status is now \(node.status?.text ?? "unknown") (it was \(status))"
        }
        if let parent = snapshot.parent, !node.parents.contains(parent) {
            return "it is in another folder now"
        }
        if let name = snapshot.name, (node.name ?? "") != name {
            return "it was renamed from \"\(name)\" to \"\(node.name ?? "")\""
        }
        if let md5, !md5.isEmpty, (node.md5 ?? "").lowercased() != md5.lowercased() {
            return node.md5 == nil ? "its content could not be confirmed" : "its content changed"
        }
        return nil
    }

    /// What `node` looks like as a snapshot. `preferredParent` is the parent that is recorded when the
    /// node has several.
    static func snapshot(of node: CloudNode, preferredParent: String?) -> PlanSnapshot {
        var parent = node.parents.first
        if let preferredParent, node.parents.contains(preferredParent) { parent = preferredParent }
        return PlanSnapshot(parent: parent, name: node.name, status: node.status?.text, md5: node.md5)
    }

    /// True when `node` already shows what `step` is meant to bring about.
    static func shows(result step: PlanStep, in node: CloudNode) -> Bool {
        switch step.operation {
        case .trash: return node.status == .trash
        case .restore: return node.status == .available
        case .rename: return step.toValue.map { node.name == $0 } ?? false
        case .describe: return (node.description ?? "") == (step.toValue ?? "")
        case .move:
            guard let destination = step.parentId, node.parents.contains(destination) else { return false }
            return !(step.before.parent.map { node.parents.contains($0) } ?? false) || step.before.parent == destination
        case .createFolder: return false
        }
    }

    /// True when `node` already shows what undoing `step` would bring about.
    static func shows(before step: PlanStep, in node: CloudNode) -> Bool {
        switch step.operation {
        case .trash: return node.status == .available
        case .restore: return node.status == .trash
        case .rename: return (step.inverseValue ?? step.before.name).map { node.name == $0 } ?? false
        case .describe: return (node.description ?? "") == (step.inverseValue ?? "")
        case .move:
            guard let old = step.inverseValue ?? step.before.parent, node.parents.contains(old) else { return false }
            return !(step.after?.parent.map { node.parents.contains($0) } ?? false) || step.after?.parent == old
        case .createFolder: return false
        }
    }
}

/// Changes to the local catalog (`cloud_items` and `cloud_folders`) that follow a change in Amazon, so
/// that reports stay right without waiting for the next refresh.
struct LocalCatalog {
    let database: SQLiteDatabase

    func item(_ nodeId: String) throws -> CloudItem? {
        try database.rows(
            "SELECT node_id, kind, name, md5, size, taken_at, ext, parent_id FROM cloud_items WHERE node_id = ?",
            [nodeId],
            map: { row in
                CloudItem(
                    nodeId: row.string(0) ?? "", kind: row.string(1) == "live_video" ? .liveVideo : .file,
                    name: row.string(2) ?? "", md5: row.string(3) ?? "", size: row.int64(4),
                    takenAt: row.int64(5), ext: row.string(6), parentId: row.string(7))
            }
        ).first
    }

    func removeItem(_ nodeId: String) throws {
        try database.run("DELETE FROM cloud_items WHERE node_id = ?", [nodeId])
    }

    func insertItem(_ item: CloudItem, seenAt: Date) throws {
        try database.run(
            """
            INSERT OR REPLACE INTO cloud_items(node_id, kind, name, md5, size, taken_at, ext, parent_id, seen_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [item.nodeId, item.kind.rawValue, item.name, item.md5, item.size, item.takenAt, item.ext, item.parentId,
             Int64(seenAt.timeIntervalSince1970)])
    }

    func setParent(_ nodeId: String, to parentId: String) throws {
        try database.run("UPDATE cloud_items SET parent_id = ? WHERE node_id = ?", [parentId, nodeId])
        try database.run("UPDATE cloud_folders SET parent_id = ? WHERE node_id = ?", [parentId, nodeId])
    }

    func setName(_ nodeId: String, to name: String) throws {
        try database.run("UPDATE cloud_items SET name = ? WHERE node_id = ?", [name, nodeId])
        try database.run("UPDATE cloud_folders SET name = ? WHERE node_id = ?", [name, nodeId])
    }

    func insertFolder(_ folder: CloudFolder) throws {
        try database.run(
            "INSERT OR REPLACE INTO cloud_folders(node_id, name, parent_id) VALUES(?, ?, ?)",
            [folder.nodeId, folder.name, folder.parentId])
    }

    func removeFolder(_ nodeId: String) throws {
        try database.run("DELETE FROM cloud_folders WHERE node_id = ?", [nodeId])
    }
}
