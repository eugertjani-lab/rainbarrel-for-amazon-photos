import Foundation

/// Carries a plan out against Amazon, one step at a time.
///
/// Before the first step the catalog is refreshed (through `refreshCatalog`), and the run takes the lock
/// that downloads and `organize` take, so it never runs next to them. For every ticked step that is
/// pending (or failed in an earlier run) the node is read from Amazon first. When its parent, name,
/// status or MD5 no longer match what the plan recorded, the step is skipped as changed meanwhile.
/// Otherwise the change is made (the write client reads the node back before it reports success), the
/// node's new state and what undo needs are stored with the step, and the local catalog is brought in
/// line. The run stops at the first answer it cannot judge and a later `apply` continues with the
/// steps that are left. At most `config.amazonWrites.maxStepsPerApply` steps are performed per call.
public struct PlanApplier {
    public let store: StateStore
    public let client: AmazonClient
    public let paths: AppPaths
    public let config: Config
    public let environment: DownloadEnvironment
    /// Runs before the lock is taken (the real refresh takes the lock itself), to bring the local
    /// catalog up to date. The default does nothing.
    public let refreshCatalog: () async throws -> Void

    public init(
        store: StateStore, client: AmazonClient, paths: AppPaths, config: Config,
        environment: DownloadEnvironment = .live, refreshCatalog: @escaping () async throws -> Void = {}
    ) {
        self.store = store
        self.client = client
        self.paths = paths
        self.config = config
        self.environment = environment
        self.refreshCatalog = refreshCatalog
    }

    /// Apply the ticked steps of plan `planId` that have not been done yet.
    /// - Parameters:
    ///   - isCancelled: polled between steps; true ends the run cleanly after the current step.
    ///   - progress: called before every step.
    /// - Throws: `PlanError` when the plan cannot be applied, `DownloadError.alreadyRunning` while a
    ///   download or organize run holds the lock, and whatever the catalog refresh throws. Trouble with
    ///   Amazon during the steps does not throw: it ends the run with a `stopReason`.
    public func apply(
        planId: Int64, isCancelled: () -> Bool = { false }, progress: (PlanProgress) -> Void = { _ in }
    ) async throws -> PlanRunResult {
        let plans = PlanStore(store: store)
        guard let first = try plans.plan(id: planId) else { throw PlanError.notFound(planId) }
        try Self.check(first)

        try await refreshCatalog()

        try paths.ensureDataDirectory()
        guard let lock = try RunLock(path: paths.downloadLockURL.path) else { throw DownloadError.alreadyRunning }
        defer { lock.release() }

        // The plan may have been changed (or applied by another process) while the catalog refreshed.
        guard let plan = try plans.plan(id: planId) else { throw PlanError.notFound(planId) }
        try Self.check(plan)
        let interrupted = plan.status == .applying

        let runner = PlanRunner(store: store, client: client, config: config, environment: environment)
        let startedAt = environment.clock.now()
        let limit = config.amazonWrites.stepLimit
        let todo = try plans.steps(planId: planId, filter: PlanStepFilter(included: true))
            .filter { $0.state == .pending || $0.state == .failed }

        try plans.setStatus(planId: planId, .applying)
        var performed = 0
        var skipped = 0
        var failed = 0
        var stop: PlanStopReason?
        var stoppedAt: PlanStep?
        do {
            for step in todo {
                if isCancelled() || Task.isCancelled {
                    stop = .cancelled
                    break
                }
                if let limit, performed >= limit {
                    stop = .stepLimit(limit)
                    break
                }
                progress(PlanProgress(
                    kind: .apply, done: performed + skipped + failed, total: todo.count, current: step.summaryLine))
                let probe = PlanStepProbe()
                let resumed = interrupted || step.state == .failed
                do {
                    let outcome = try await runner.withBackoff {
                        try await self.perform(step, runner: runner, mayHaveBeenWritten: resumed, probe: probe)
                    }
                    switch outcome {
                    case .done(let effect):
                        try record(effect, for: step, runner: runner)
                        performed += 1
                    case .skipped(let reason):
                        try plans.record(
                            planId: planId, position: step.position, state: .skippedChanged, result: reason,
                            now: environment.clock.now())
                        skipped += 1
                    }
                } catch is CancellationError {
                    if probe.wrote {
                        try plans.record(
                            planId: planId, position: step.position, state: .failed,
                            result: "Interrupted; the change may already have reached Amazon.",
                            now: environment.clock.now())
                        failed += 1
                        stoppedAt = step
                    }
                    stop = .cancelled
                    break
                } catch let error as SQLiteError {
                    throw error
                } catch {
                    let text = runner.text(for: error)
                    try plans.record(
                        planId: planId, position: step.position, state: .failed, result: text,
                        now: environment.clock.now())
                    failed += 1
                    stoppedAt = step
                    if case DownloadError.sessionExpired = error { stop = .sessionExpired } else { stop = .failure(text) }
                    break
                }
            }
        } catch {
            _ = try? finish(planId: planId, plans: plans, performed: performed)
            throw error
        }

        let status = try finish(planId: planId, plans: plans, performed: performed)
        let remaining = try plans.summary(planId: planId).remainingToApply
        return PlanRunResult(
            planId: planId, kind: .apply, succeeded: performed, skipped: skipped, failed: failed, remaining: remaining,
            status: status, stopReason: stop, durationSeconds: environment.clock.now().timeIntervalSince(startedAt),
            message: Self.message(
                performed: performed, skipped: skipped, remaining: remaining, stop: stop, stoppedAt: stoppedAt))
    }

    // MARK: Checks and the end of a run

    /// Whether `plan` can be applied now.
    /// - Throws: `PlanError` with the reason when it cannot.
    public static func check(_ plan: Plan) throws {
        switch plan.status {
        case .applied:
            throw PlanError.cannotApply(
                status: plan.status, reason: "Plan \(plan.id) has already been applied. `rainbarrel undo \(plan.id)` reverses it.")
        case .undone:
            throw PlanError.cannotApply(
                status: plan.status,
                reason: "Plan \(plan.id) was undone and cannot be applied again. Make a new plan instead.")
        case .draft, .applying, .partlyApplied:
            break
        }
        if plan.summary.states.undone > 0 {
            throw PlanError.cannotApply(
                status: plan.status,
                reason: "Plan \(plan.id) was undone in part and cannot be applied again. Make a new plan instead.")
        }
        // A plan that was cut off right after its last step still says `applying`; running it again only
        // closes it.
        if plan.summary.remainingToApply == 0 && plan.status != .applying {
            throw PlanError.nothingToDo(
                plan.summary.includedSteps == 0
                    ? "Every step of plan \(plan.id) is unticked, so there is nothing to apply."
                    : "Nothing to apply: every ticked step of plan \(plan.id) is already done or skipped.")
        }
    }

    /// Set the plan's status from what its steps look like now.
    @discardableResult
    private func finish(planId: Int64, plans: PlanStore, performed: Int) throws -> PlanStatus {
        let summary = try plans.summary(planId: planId)
        let touched = summary.states.done + summary.states.skippedChanged + summary.states.failed + summary.states.undone
        let status: PlanStatus
        if summary.remainingToApply == 0 {
            status = .applied
        } else if touched == 0 {
            status = .draft  // nothing reached Amazon
        } else {
            status = .partlyApplied
        }
        let now = environment.clock.now()
        try plans.setStatus(planId: planId, status, appliedAt: (status == .applied || performed > 0) ? now : nil)
        return status
    }

    static func message(
        performed: Int, skipped: Int, remaining: Int, stop: PlanStopReason?, stoppedAt: PlanStep?
    ) -> String {
        func steps(_ count: Int) -> String { "\(DisplayFormat.number(count)) \(count == 1 ? "step" : "steps")" }
        var parts: [String] = []
        var head = "Applied \(steps(performed))"
        if skipped > 0 {
            head += " and skipped \(steps(skipped)) because the item changed in Amazon since the plan was made"
        }
        parts.append(head + ".")
        switch stop {
        case .stepLimit(let limit)?:
            parts.append(
                "The limit is \(steps(limit)) per run, so \(steps(remaining)) remain: check the result on the Amazon Photos website, then run apply again to continue. `rainbarrel config set-writes --max-steps N` changes the limit (0 lifts it).")
        case .sessionExpired?:
            parts.append(
                "Stopped because the Amazon session expired\(position(stoppedAt)). \(steps(remaining).firstLetterUppercased) remain. Sign in again, then run apply again to resume.")
        case .failure(let text)?:
            parts.append(
                "Stopped\(position(stoppedAt)): \(PlanRunner.sentence(text)) \(steps(remaining).firstLetterUppercased) remain; run apply again to resume.")
        case .cancelled?:
            parts.append("Stopped on request. \(steps(remaining).firstLetterUppercased) remain; run apply again to continue.")
        case nil:
            if remaining > 0 { parts.append("\(steps(remaining).firstLetterUppercased) remain.") }
        }
        return parts.joined(separator: " ")
    }

    private static func position(_ step: PlanStep?) -> String {
        step.map { " at step \(DisplayFormat.number($0.position))" } ?? ""
    }

    // MARK: One step

    private enum Outcome {
        case done(Effect)
        case skipped(String)
    }

    /// What a step that was done leaves behind.
    private struct Effect {
        var result: String
        var after: PlanSnapshot
        var inverseValue: String?
        var createdNodeId: String?
        var reusedExisting: Bool?
        /// The catalog row that undo will put back.
        var catalogItem: CloudItem?
        var local: () throws -> Void
    }

    private func record(_ effect: Effect, for step: PlanStep, runner: PlanRunner) throws {
        let now = environment.clock.now()
        try store.database.transaction {
            try effect.local()
            try runner.plans.record(
                planId: step.planId, position: step.position, state: .done, result: effect.result,
                after: effect.after, inverseValue: effect.inverseValue, createdNodeId: effect.createdNodeId,
                reusedExisting: effect.reusedExisting, catalogItem: effect.catalogItem, now: now)
        }
    }

    /// Read the node, compare it with the plan and make the change. Runs again from the start after a
    /// backoff, so `mayHaveBeenWritten` (an earlier attempt may have reached Amazon) decides whether a
    /// node that already shows the result counts as done.
    private func perform(
        _ step: PlanStep, runner: PlanRunner, mayHaveBeenWritten: Bool, probe: PlanStepProbe
    ) async throws -> Outcome {
        let maybeApplied = mayHaveBeenWritten || probe.wrote
        if step.operation == .createFolder {
            return try await performCreateFolder(step, runner: runner, maybeApplied: maybeApplied, probe: probe)
        }
        guard let id = step.nodeId, !id.isEmpty else { throw PlanStepProblem("Step \(step.position) has no node.") }
        let client = runner.client

        let node: CloudNode
        do {
            node = try await runner.request { try await client.node(id) }
        } catch AmazonWriteError.notFound {
            return .skipped("No longer in Amazon.")
        }
        if maybeApplied, PlanRunner.shows(result: step, in: node) {
            return .done(effect(
                for: step, node: node, updated: node, inverse: Self.inverse(of: step, node: node, adopted: true),
                note: "Already done (found in place after an interrupted run)."))
        }
        if let difference = PlanRunner.difference(from: step.before, in: node, md5: step.before.md5) {
            return .skipped("Changed meanwhile: \(difference).")
        }

        let inverse = Self.inverse(of: step, node: node)
        let updated: CloudNode
        do {
            switch step.operation {
            case .trash:
                probe.wrote = true
                updated = try await runner.request { try await client.trash(id) }
            case .restore:
                probe.wrote = true
                updated = try await runner.request { try await client.restore(id) }
            case .rename:
                guard let name = step.toValue, !name.isEmpty else { throw PlanStepProblem("Step \(step.position) has no new name.") }
                probe.wrote = true
                updated = try await runner.request { try await client.rename(id, to: name) }
            case .describe:
                let text = step.toValue ?? ""
                probe.wrote = true
                updated = try await runner.request { try await client.setDescription(id, to: text) }
            case .move:
                guard let destination = step.parentId, !destination.isEmpty else {
                    throw PlanStepProblem("Step \(step.position) has no destination folder.")
                }
                guard let from = step.before.parent ?? node.parents.first else {
                    throw PlanStepProblem("Step \(step.position) has no folder to move out of.")
                }
                probe.wrote = true
                updated = try await runner.request { try await client.move(id, from: from, to: destination) }
            case .createFolder:
                throw PlanStepProblem("unreachable")
            }
        } catch AmazonWriteError.notFound {
            probe.wrote = false  // Amazon did not know the node or the target folder: nothing was written
            return .skipped("Changed meanwhile: Amazon no longer knows the item or the target folder.")
        }
        return .done(effect(for: step, node: node, updated: updated, inverse: inverse, note: Self.doneText(step)))
    }

    /// What undo restores: the name, the description or the folder the node was in before the step.
    /// `node` is the node as it was read; when `adopted` is true it already shows the step's result
    /// (an earlier run made the change), so the old values come from the plan instead.
    private static func inverse(of step: PlanStep, node: CloudNode, adopted: Bool = false) -> String? {
        switch step.operation {
        case .rename: return adopted ? (step.before.name ?? step.fromValue) : (node.name ?? step.before.name)
        case .describe: return adopted ? (step.fromValue ?? "") : (node.description ?? "")
        case .move: return step.before.parent ?? node.parents.first
        default: return nil
        }
    }

    private static func doneText(_ step: PlanStep) -> String {
        switch step.operation {
        case .createFolder: return "Folder created."
        case .move: return "Moved."
        case .rename: return "Renamed."
        case .describe: return "Description set."
        case .trash: return "Moved to Amazon's trash."
        case .restore: return "Restored from Amazon's trash."
        }
    }

    private func effect(for step: PlanStep, node: CloudNode, updated: CloudNode, inverse: String?, note: String) -> Effect {
        let catalog = LocalCatalog(database: store.database)
        let preferred = step.operation == .move ? step.parentId : step.before.parent
        var effect = Effect(
            result: note, after: PlanRunner.snapshot(of: updated, preferredParent: preferred), inverseValue: inverse,
            local: {})
        switch step.operation {
        case .trash:
            let id = step.nodeId ?? ""
            let row = (try? catalog.item(id)) ?? step.catalogItem
            effect.catalogItem = row ?? step.catalogItem
            effect.local = { try catalog.removeItem(id) }
        case .restore:
            if let item = step.catalogItem {
                let seen = environment.clock.now()
                effect.local = { try catalog.insertItem(item, seenAt: seen) }
            }
        case .move:
            if let id = step.nodeId, let destination = step.parentId {
                effect.local = { try catalog.setParent(id, to: destination) }
            }
        case .rename:
            if let id = step.nodeId, let name = step.toValue {
                effect.local = { try catalog.setName(id, to: name) }
            }
        case .describe, .createFolder:
            break
        }
        return effect
    }

    private func performCreateFolder(
        _ step: PlanStep, runner: PlanRunner, maybeApplied: Bool, probe: PlanStepProbe
    ) async throws -> Outcome {
        guard let parent = step.parentId, !parent.isEmpty, let name = step.toValue, !name.isEmpty else {
            throw PlanStepProblem("Step \(step.position) has no folder name or no parent folder.")
        }
        let client = runner.client
        let parentNode: CloudNode
        do {
            parentNode = try await runner.request { try await client.node(parent) }
        } catch AmazonWriteError.notFound {
            return .skipped("Changed meanwhile: the folder it should be created in is no longer in Amazon.")
        }
        if parentNode.status == .trash || parentNode.status == .purged {
            return .skipped("Changed meanwhile: the folder it should be created in is in the trash.")
        }
        probe.wrote = true
        let folder: CloudNode
        var reused = false
        do {
            folder = try await runner.request {
                try await client.createFolder(named: name, in: parent, lookup: runner.folderLookup)
            }
        } catch AmazonWriteError.folderAlreadyExists(let existing) {
            folder = existing
            // A folder that is already there on the first try was not made by this plan; after an
            // earlier try it most likely was.
            reused = !maybeApplied
        } catch AmazonWriteError.notFound {
            probe.wrote = false
            return .skipped("Changed meanwhile: the folder it should be created in is no longer in Amazon.")
        }
        let catalog = LocalCatalog(database: store.database)
        let created = CloudFolder(nodeId: folder.id, name: name, parentId: parent)
        return .done(Effect(
            result: reused ? "The folder was already there, so it was used." : "Folder created.",
            after: PlanSnapshot(parent: parent, name: name, status: folder.status?.text ?? CloudNode.Status.available.text),
            inverseValue: nil, createdNodeId: folder.id, reusedExisting: reused, catalogItem: nil,
            local: { try catalog.insertFolder(created) }))
    }
}

extension String {
    /// The text with its first letter in capitals.
    var firstLetterUppercased: String { prefix(1).uppercased() + dropFirst() }
}
