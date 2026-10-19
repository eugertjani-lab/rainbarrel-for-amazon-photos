import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Plans for the command line tool, the MCP tools and the app: creating and reading them, and running
/// apply and undo with a real Amazon session. Each call opens its own state database connection.
public struct PlanService: Sendable {
    public static let defaultStepSample = 20
    public static let maxStepSample = 200

    public let paths: AppPaths
    public let environment: DownloadEnvironment

    public init(paths: AppPaths, environment: DownloadEnvironment = .live) {
        self.paths = paths
        self.environment = environment
    }

    private func openStore() throws -> StateStore {
        try paths.ensureDataDirectory()
        return try StateStore(path: paths.stateURL.path)
    }

    // MARK: Making and reading plans

    /// Make a draft that trashes the empty files of the catalog. Returns nil when there are none.
    /// Reads the stored catalog only; nothing is sent to Amazon.
    public func createCleanupPlan() throws -> Plan? {
        let store = try openStore()
        if try store.cloudItemCount() == 0 {
            throw ToolError(
                "The catalog is empty, so there is nothing to plan from. Read it first with `rainbarrel catalog refresh`.")
        }
        return try PlanStore(store: store).createPlan(using: EmptyFileCleanupPlanner())
    }

    public func plans(limit: Int = 50) throws -> [Plan] {
        try PlanStore(store: try openStore()).plans(limit: limit)
    }

    /// - Throws: `PlanError.notFound` when there is no such plan.
    public func plan(id: Int64) throws -> Plan {
        guard let plan = try PlanStore(store: try openStore()).plan(id: id) else { throw PlanError.notFound(id) }
        return plan
    }

    public func steps(
        planId: Int64, filter: PlanStepFilter = PlanStepFilter(), limit: Int? = nil, offset: Int = 0
    ) throws -> [PlanStep] {
        try PlanStore(store: try openStore()).steps(planId: planId, filter: filter, limit: limit, offset: offset)
    }

    public func groups(planId: Int64) throws -> [PlanGroup] {
        try PlanStore(store: try openStore()).groups(planId: planId)
    }

    // MARK: Running plans

    /// Apply the ticked steps of a plan that are still to do (see `PlanApplier`).
    ///
    /// With a `sessionStore`, cookies that Amazon refreshes during the run are written back, never over
    /// a sign-in that was made in the meantime.
    public func apply(
        planId: Int64, config: Config, session: StoredSession, sessionStore: (any SessionStore)? = nil,
        refreshCatalog: @escaping () async throws -> Void = {}, isCancelled: () -> Bool = { false },
        progress: (PlanProgress) -> Void = { _ in }
    ) async throws -> PlanRunResult {
        guard session.isUsable() else { throw DownloadError.sessionExpired }
        let store = try openStore()
        return try await withClient(session: session, sessionStore: sessionStore, config: config) { client in
            try await PlanApplier(
                store: store, client: client, paths: paths, config: config, environment: environment,
                refreshCatalog: refreshCatalog
            ).apply(planId: planId, isCancelled: isCancelled, progress: progress)
        }
    }

    /// Reverse the steps of a plan that were done (see `PlanUndoer`).
    public func undo(
        planId: Int64, config: Config, session: StoredSession, sessionStore: (any SessionStore)? = nil,
        isCancelled: () -> Bool = { false }, progress: (PlanProgress) -> Void = { _ in }
    ) async throws -> PlanRunResult {
        guard session.isUsable() else { throw DownloadError.sessionExpired }
        let store = try openStore()
        return try await withClient(session: session, sessionStore: sessionStore, config: config) { client in
            try await PlanUndoer(
                store: store, client: client, paths: paths, config: config, environment: environment
            ).undo(planId: planId, isCancelled: isCancelled, progress: progress)
        }
    }

    private func withClient<T>(
        session: StoredSession, sessionStore: (any SessionStore)?, config: Config,
        _ body: (AmazonClient) async throws -> T
    ) async throws -> T {
        let client = try AmazonClient(
            session: session, host: config.effectiveAmazonHost, configuration: environment.sessionConfiguration(),
            timeouts: environment.timeouts)
        let clock = environment.clock
        let persister = sessionStore.map {
            SessionPersister(client: client, store: $0, baseline: session, now: { clock.now() })
        }
        defer {
            persister?.flush()
            client.invalidate()
        }
        return try await body(client)
    }
}
