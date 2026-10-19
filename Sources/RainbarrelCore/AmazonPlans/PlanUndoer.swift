import Foundation

/// Reverses the steps of a plan that were done, last step first.
///
/// It takes the same lock as downloads, `organize` and `apply`, works under the same request budget, and
/// checks every node against the snapshot taken right after the plan changed it, so a change made in
/// Amazon after the plan is never overwritten. A step that cannot be reversed stays `done`, with the
/// reason in its result, and a later `undo` tries it again. Nothing is ever purged: undoing a trash
/// restores the item, and undoing a created folder trashes it.
public struct PlanUndoer {
    public let store: StateStore
    public let client: AmazonClient
    public let paths: AppPaths
    public let config: Config
    public let environment: DownloadEnvironment

    public init(
        store: StateStore, client: AmazonClient, paths: AppPaths, config: Config,
        environment: DownloadEnvironment = .live
    ) {
        self.store = store
        self.client = client
        self.paths = paths
        self.config = config
        self.environment = environment
    }

    /// Reverse the done steps of plan `planId`.
    /// - Throws: `PlanError` when there is nothing to undo, and `DownloadError.alreadyRunning` while a
    ///   download, organize or apply run holds the lock. Trouble with Amazon during the steps does not
    ///   throw: it ends the run with a `stopReason`.
    public func undo(
        planId: Int64, isCancelled: () -> Bool = { false }, progress: (PlanProgress) -> Void = { _ in }
    ) async throws -> PlanRunResult {
        let plans = PlanStore(store: store)
        guard let first = try plans.plan(id: planId) else { throw PlanError.notFound(planId) }
        try Self.check(first)

        try paths.ensureDataDirectory()
        guard let lock = try RunLock(path: paths.downloadLockURL.path) else { throw DownloadError.alreadyRunning }
        defer { lock.release() }

        guard let plan = try plans.plan(id: planId) else { throw PlanError.notFound(planId) }
        try Self.check(plan)

        let runner = PlanRunner(store: store, client: client, config: config, environment: environment)
        let startedAt = environment.clock.now()
        let todo = try plans.steps(planId: planId, filter: PlanStepFilter(state: .done)).reversed()
        var reversed = 0
        var skipped = 0
        var failed = 0
        var stop: PlanStopReason?
        var stoppedAt: PlanStep?
        var leftBehind = false  // a later step stays done, so a folder may still hold files

        do {
            for step in todo {
                if isCancelled() || Task.isCancelled {
                    stop = .cancelled
                    break
                }
                progress(PlanProgress(
                    kind: .undo, done: reversed + skipped + failed, total: todo.count, current: step.summaryLine))
                let probe = PlanStepProbe()
                do {
                    let outcome = try await runner.withBackoff {
                        try await self.reverse(step, runner: runner, probe: probe, laterStepsLeft: leftBehind)
                    }
                    switch outcome {
                    case .undone(let effect):
                        try record(effect, for: step, runner: runner)
                        reversed += 1
                    case .cannot(let reason):
                        try plans.record(
                            planId: planId, position: step.position, state: .done, result: reason,
                            now: environment.clock.now())
                        skipped += 1
                        leftBehind = true
                    }
                } catch is CancellationError {
                    stop = .cancelled
                    break
                } catch let error as SQLiteError {
                    throw error
                } catch {
                    let text = runner.text(for: error)
                    try plans.record(
                        planId: planId, position: step.position, state: .done,
                        result: "Not undone: \(text)", now: environment.clock.now())
                    failed += 1
                    stoppedAt = step
                    if case DownloadError.sessionExpired = error { stop = .sessionExpired } else { stop = .failure(text) }
                    break
                }
            }
        } catch {
            _ = try? finish(planId: planId, plans: plans)
            throw error
        }

        let status = try finish(planId: planId, plans: plans)
        let remaining = try plans.summary(planId: planId).reversible
        return PlanRunResult(
            planId: planId, kind: .undo, succeeded: reversed, skipped: skipped, failed: failed, remaining: remaining,
            status: status, stopReason: stop, durationSeconds: environment.clock.now().timeIntervalSince(startedAt),
            message: Self.message(reversed: reversed, skipped: skipped, remaining: remaining, stop: stop, stoppedAt: stoppedAt))
    }

    // MARK: Checks and the end of a run

    /// Whether `plan` can be undone now.
    /// - Throws: `PlanError` with the reason when it cannot.
    public static func check(_ plan: Plan) throws {
        if plan.status == .draft || plan.status == .undone || plan.summary.reversible == 0 {
            let reason: String
            switch plan.status {
            case .draft: reason = "Plan \(plan.id) was never applied, so there is nothing to undo."
            case .undone: reason = "Plan \(plan.id) has already been undone."
            default: reason = "No step of plan \(plan.id) is done, so there is nothing to undo."
            }
            throw PlanError.cannotUndo(status: plan.status, reason: reason)
        }
    }

    @discardableResult
    private func finish(planId: Int64, plans: PlanStore) throws -> PlanStatus {
        let summary = try plans.summary(planId: planId)
        let now = environment.clock.now()
        if summary.reversible == 0 {
            try plans.setStatus(planId: planId, .undone, undoneAt: now)
            return .undone
        }
        try plans.setStatus(planId: planId, .partlyApplied)
        return .partlyApplied
    }

    static func message(reversed: Int, skipped: Int, remaining: Int, stop: PlanStopReason?, stoppedAt: PlanStep?) -> String {
        func steps(_ count: Int) -> String { "\(DisplayFormat.number(count)) \(count == 1 ? "step" : "steps")" }
        var parts = ["Reversed \(steps(reversed))."]
        if skipped > 0 {
            parts.append(
                "\(steps(skipped).firstLetterUppercased) could not be reversed because the item changed in Amazon since the plan was applied; the reason is in each step.")
        }
        switch stop {
        case .sessionExpired?:
            parts.append(
                "Stopped because the Amazon session expired\(stoppedAt.map { " at step \($0.position)" } ?? ""). Sign in again, then run undo again.")
        case .failure(let text)?:
            parts.append("Stopped\(stoppedAt.map { " at step \($0.position)" } ?? ""): \(PlanRunner.sentence(text)) Run undo again to continue.")
        case .cancelled?:
            parts.append("Stopped on request. Run undo again to continue.")
        default:
            break
        }
        if remaining > 0, stop == nil { parts.append("\(steps(remaining)) stay done. Run undo again once the cause is gone.") }
        return parts.joined(separator: " ")
    }

    // MARK: One step

    private enum Outcome {
        case undone(Effect)
        case cannot(String)
    }

    private struct Effect {
        var result: String
        var local: () throws -> Void
    }

    private func record(_ effect: Effect, for step: PlanStep, runner: PlanRunner) throws {
        let now = environment.clock.now()
        try store.database.transaction {
            try effect.local()
            try runner.plans.record(
                planId: step.planId, position: step.position, state: .undone, result: effect.result, now: now)
        }
    }

    private func reverse(
        _ step: PlanStep, runner: PlanRunner, probe: PlanStepProbe, laterStepsLeft: Bool
    ) async throws -> Outcome {
        if step.operation == .createFolder {
            return try await reverseCreateFolder(step, runner: runner, probe: probe, laterStepsLeft: laterStepsLeft)
        }
        guard let id = step.nodeId, !id.isEmpty else { throw PlanStepProblem("Step \(step.position) has no node.") }
        let client = runner.client
        let catalog = LocalCatalog(database: store.database)

        let node: CloudNode
        do {
            node = try await runner.request { try await client.node(id) }
        } catch AmazonWriteError.notFound {
            return .cannot("Not undone: it is no longer in Amazon.")
        }
        if PlanRunner.shows(before: step, in: node) {
            return .undone(Effect(result: "Already back as before.", local: localUndo(step, catalog)))
        }
        // The node must still look like it did right after the plan changed it.
        if let difference = PlanRunner.difference(
            from: step.after ?? PlanSnapshot(), in: node, md5: step.before.md5)
        {
            return .cannot("Not undone: it changed since the plan was applied: \(difference).")
        }
        if step.operation == .describe, (node.description ?? "") != (step.toValue ?? "") {
            return .cannot("Not undone: its description changed since the plan was applied.")
        }

        do {
            switch step.operation {
            case .trash:
                probe.wrote = true
                _ = try await runner.request { try await client.restore(id) }
            case .restore:
                probe.wrote = true
                _ = try await runner.request { try await client.trash(id) }
            case .rename:
                guard let old = step.inverseValue ?? step.before.name, !old.isEmpty else {
                    throw PlanStepProblem("Step \(step.position) does not know the old name.")
                }
                probe.wrote = true
                _ = try await runner.request { try await client.rename(id, to: old) }
            case .describe:
                let old = step.inverseValue ?? ""
                probe.wrote = true
                _ = try await runner.request { try await client.setDescription(id, to: old) }
            case .move:
                guard let old = step.inverseValue ?? step.before.parent, let current = step.after?.parent else {
                    throw PlanStepProblem("Step \(step.position) does not know the folder it came from.")
                }
                probe.wrote = true
                _ = try await runner.request { try await client.move(id, from: current, to: old) }
            case .createFolder:
                throw PlanStepProblem("unreachable")
            }
        } catch AmazonWriteError.notFound {
            return .cannot("Not undone: Amazon no longer knows the item or the folder it came from.")
        }
        return .undone(Effect(result: Self.undoneText(step), local: localUndo(step, catalog)))
    }

    private static func undoneText(_ step: PlanStep) -> String {
        switch step.operation {
        case .createFolder: return "Folder moved to Amazon's trash."
        case .move: return "Moved back."
        case .rename: return "Name put back."
        case .describe: return "Description put back."
        case .trash: return "Restored from Amazon's trash."
        case .restore: return "Moved to Amazon's trash again."
        }
    }

    /// The change to the local catalog that undoes the one the step made.
    private func localUndo(_ step: PlanStep, _ catalog: LocalCatalog) -> () throws -> Void {
        let seen = environment.clock.now()
        switch step.operation {
        case .trash:
            guard let item = step.catalogItem else { return {} }
            return { try catalog.insertItem(item, seenAt: seen) }
        case .restore:
            guard let id = step.nodeId else { return {} }
            return { try catalog.removeItem(id) }
        case .move:
            guard let id = step.nodeId, let old = step.inverseValue ?? step.before.parent else { return {} }
            return { try catalog.setParent(id, to: old) }
        case .rename:
            guard let id = step.nodeId, let old = step.inverseValue ?? step.before.name else { return {} }
            return { try catalog.setName(id, to: old) }
        case .createFolder:
            guard let id = step.createdNodeId else { return {} }
            return { try catalog.removeFolder(id) }
        case .describe:
            return {}
        }
    }

    private func reverseCreateFolder(
        _ step: PlanStep, runner: PlanRunner, probe: PlanStepProbe, laterStepsLeft: Bool
    ) async throws -> Outcome {
        guard let id = step.createdNodeId, !id.isEmpty else {
            return .undone(Effect(result: "No folder was created, so there is nothing to undo.", local: {}))
        }
        if step.reusedExisting {
            return .undone(Effect(result: "The folder was there before the plan, so it stays.", local: {}))
        }
        if laterStepsLeft {
            return .cannot(
                "Not undone: a later step of the plan could not be undone, so the folder may still hold files.")
        }
        let client = runner.client
        let catalog = LocalCatalog(database: store.database)
        let node: CloudNode
        do {
            node = try await runner.request { try await client.node(id) }
        } catch AmazonWriteError.notFound {
            return .undone(Effect(result: "The folder is already gone.", local: localUndo(step, catalog)))
        }
        if node.status == .trash || node.status == .purged {
            return .undone(Effect(result: "The folder is already in the trash.", local: localUndo(step, catalog)))
        }
        if let difference = PlanRunner.difference(from: step.after ?? PlanSnapshot(), in: node, md5: nil) {
            return .cannot("Not undone: the folder changed since the plan was applied: \(difference).")
        }
        do {
            probe.wrote = true
            _ = try await runner.request { try await client.trash(id) }
        } catch AmazonWriteError.notFound {
            return .undone(Effect(result: "The folder is already gone.", local: localUndo(step, catalog)))
        }
        return .undone(Effect(result: Self.undoneText(step), local: localUndo(step, catalog)))
    }
}
