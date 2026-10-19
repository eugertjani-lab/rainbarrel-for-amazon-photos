import ArgumentParser
import Dispatch
import Foundation
import RainbarrelCore

// The plan commands. `plan` makes and shows plans and sends nothing to Amazon; `apply` and `undo` are
// the only commands that change the Amazon library, and both ask first unless --yes is given.

struct PlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Make and review plans for changing your Amazon Photos library.",
        discussion: """
            A plan is a list of changes, for example moving every empty file to Amazon's trash. Making or \
            showing a plan sends nothing to Amazon. Review it with `rainbarrel plan show <id> --steps`, then \
            run `rainbarrel apply <id>`. Every step is checked against Amazon again right before it runs, so a \
            file that changed since the plan was made is skipped, and `rainbarrel undo <id>` reverses an \
            applied plan. Rainbarrel never empties Amazon's trash.
            """,
        subcommands: [CleanupEmpty.self, List.self, Show.self]
    )

    struct CleanupEmpty: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cleanup-empty",
            abstract: "Make a plan that moves the files that were uploaded empty (0 bytes) to Amazon's trash.",
            discussion: """
                Reads the cloud catalog (refreshing it when it is more than ten minutes old) and writes a draft \
                plan to Rainbarrel's own database. Nothing is sent to Amazon.
                """)

        func run() async throws {
            let context = try AppContext.open()
            try await context.refreshCatalogIfStale()
            let service = PlanService(paths: context.paths)
            let plan: Plan?
            do { plan = try service.createCleanupPlan() } catch let error as ToolError { throw CLIError(error.message) }
            guard let plan else {
                print("The catalog holds no empty file. No plan was made.")
                return
            }
            PlanPrinter.summary(plan)
            print("\nThis is a draft: nothing was sent to Amazon.")
            print("Review it with `rainbarrel plan show \(plan.id) --steps`, then apply it with `rainbarrel apply \(plan.id)`.")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the plans, newest first.")

        @Option(help: "Show at most this many plans.")
        var limit = 20

        func validate() throws {
            if limit < 1 { throw ValidationError("--limit must be at least 1.") }
        }

        func run() throws {
            let service = PlanService(paths: AppPaths.forCLI())
            let plans = try service.plans(limit: limit)
            guard !plans.isEmpty else {
                print("There are no plans yet. `rainbarrel plan cleanup-empty` makes one.")
                return
            }
            for plan in plans {
                let states = plan.summary.states
                print("\(String(plan.id).padding(toLength: 5, withPad: " ", startingAt: 0))"
                    + "\(plan.status.text.padding(toLength: 15, withPad: " ", startingAt: 0))"
                    + "\(Format.dateTime(plan.createdAt))  "
                    + "\(plan.title.sanitizedForTerminal)  "
                    + "(\(plan.summary.headline); \(states.done) of \(plan.summary.includedSteps) done)")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show one plan: its summary, its groups and, with --steps, its steps.")

        @Argument(help: "The plan id, as `rainbarrel plan list` shows it.")
        var id: Int64

        @Flag(help: "List the steps too.")
        var steps = false

        @Option(help: "With --steps, show at most this many steps.")
        var limit = 50

        @Option(help: "With --steps, skip this many steps first.")
        var offset = 0

        func validate() throws {
            if limit < 1 { throw ValidationError("--limit must be at least 1.") }
            if offset < 0 { throw ValidationError("--offset cannot be negative.") }
        }

        func run() throws {
            let service = PlanService(paths: AppPaths.forCLI())
            let plan: Plan
            do { plan = try service.plan(id: id) } catch let error as PlanError { throw CLIError(error.description) }
            PlanPrinter.summary(plan)
            let groups = try service.groups(planId: id)
            if !groups.isEmpty {
                print("\nGroups (largest first):")
                for group in groups.prefix(10) {
                    let ticked = group.excluded > 0 ? "\(group.included) ticked, \(group.excluded) unticked" : "\(group.included)"
                    print("  \(group.operation.verb)  \((group.label ?? "(none)").sanitizedForTerminal)  \(ticked)")
                }
                if groups.count > 10 { print("  ... and \(groups.count - 10) more") }
            }
            guard steps else {
                print("\n`rainbarrel plan show \(id) --steps` lists the steps.")
                return
            }
            let shown = try service.steps(planId: id, limit: limit, offset: offset)
            print("\nSteps \(offset + 1) to \(offset + shown.count) of \(plan.summary.totalSteps):")
            PlanPrinter.steps(shown)
        }
    }
}

/// Plain-text output of plans, shared by the commands.
enum PlanPrinter {
    static func summary(_ plan: Plan) {
        let s = plan.summary
        print("Plan \(plan.id): \(plan.title.sanitizedForTerminal)")
        print("  Status:   \(plan.status.text)")
        print("  Changes:  \(s.headline)")
        var made = "  Made:     \(Format.dateTime(plan.createdAt))"
        if let refreshed = plan.catalogRefreshedAt { made += " from the catalog of \(Format.dateTime(refreshed))" }
        print(made)
        var states: [String] = []
        if s.states.pending > 0 { states.append("\(Format.number(s.states.pending)) pending") }
        if s.states.done > 0 { states.append("\(Format.number(s.states.done)) done") }
        if s.states.skippedChanged > 0 { states.append("\(Format.number(s.states.skippedChanged)) skipped (changed meanwhile)") }
        if s.states.failed > 0 { states.append("\(Format.number(s.states.failed)) failed") }
        if s.states.undone > 0 { states.append("\(Format.number(s.states.undone)) undone") }
        print("  Steps:    \(Format.number(s.totalSteps))" + (states.isEmpty ? "" : " (" + states.joined(separator: ", ") + ")"))
        if s.excludedSteps > 0 {
            print("  Unticked: \(Format.number(s.excludedSteps)) steps are left out and will not be applied")
        }
    }

    static func steps(_ steps: [PlanStep]) {
        for step in steps {
            var line = "  \(String(step.position).padding(toLength: 6, withPad: " ", startingAt: 0))"
            line += step.included ? "" : "(unticked) "
            line += "[\(step.state.text)] \(step.summaryLine)"
            print(line.sanitizedForTerminal)
            print("        because: \(step.reason)".sanitizedForTerminal)
            if let result = step.result { print("        result:  \(result)".sanitizedForTerminal) }
        }
    }
}

/// Asks a yes or no question on the terminal. The answer is no unless it is y or yes.
private enum Confirmation {
    static func ask(_ question: String) -> Bool {
        print(question + " [y/N] ", terminator: "")
        // fflush(nil) flushes every stream; naming `stdout` is refused on Linux, where it is a mutable global.
        fflush(nil)
        guard let line = readLine() else { return false }
        return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// Set by the first Ctrl-C; the run looks at it between two steps.
private final class PlanInterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    /// Returns true for the first call.
    func raise() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { raised = true }
        return !raised
    }

    /// Install a SIGINT handler: the first Ctrl-C stops after the step in progress, the second quits.
    func install() -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
        source.setEventHandler { [self] in
            if raise() {
                printError("\nStopping after the step in progress (press Ctrl-C again to quit at once)...")
            } else {
                Foundation.exit(130)
            }
        }
        source.resume()
        return source
    }
}

/// One updating progress line on stderr (or a line every 30 seconds when stderr is not a terminal).
private final class PlanProgressPrinter: @unchecked Sendable {
    private let interactive = isatty(STDERR_FILENO) != 0
    private let lock = NSLock()
    private var lastPrint = Date.distantPast
    private var printedInteractive = false

    func update(_ progress: PlanProgress) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastPrint) >= (interactive ? 0.25 : 30) else { return }
        lastPrint = now
        let label = progress.kind == .apply ? "Applying" : "Undoing"
        var line = "\(label) \(Format.number(progress.done))/\(Format.number(progress.total))"
        if let current = progress.current {
            let width = max(40, Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 100)
            let room = width - line.count - 3
            if room > 8 { line += "  " + (current.count > room ? current.prefix(room - 3) + "..." : current) }
        }
        line = line.sanitizedForTerminal
        if interactive {
            FileHandle.standardError.write(Data(("\r" + line + "\u{1B}[K").utf8))
            printedInteractive = true
        } else {
            printError(line)
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if printedInteractive { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    }
}

/// The stored Amazon session, or an error that tells the person what to do.
private func usableSession(_ paths: AppPaths) throws -> (session: StoredSession, store: any SessionStore) {
    let store = SessionStoreFactory.make(paths: paths)
    let session: StoredSession
    do {
        guard let stored = try store.load() else { throw CLIError(DownloadError.notSignedIn.description) }
        session = stored
    } catch let error as CLIError {
        throw error
    } catch {
        throw CLIError("\(error)")
    }
    guard session.isUsable() else { throw CLIError(DownloadError.sessionExpired.description) }
    return (session, store)
}

private func loadPlan(_ service: PlanService, _ id: Int64) throws -> Plan {
    do { return try service.plan(id: id) } catch let error as PlanError { throw CLIError(error.description) }
}

/// What a run printed and how it ends the command.
private func report(_ result: PlanRunResult, service: PlanService) throws {
    print(result.message)
    // The steps the run could not do: skipped ones after an apply, steps that stay done after an undo.
    let listed = result.kind == .apply ? result.skipped > 0 : (result.skipped > 0 || result.failed > 0)
    if listed {
        let state: PlanStepState = result.kind == .apply ? .skippedChanged : .done
        let prefix = result.kind == .apply ? "Changed meanwhile" : "Not undone"
        if let steps = try? service.steps(planId: result.planId, filter: PlanStepFilter(state: state), limit: 1000) {
            let matching = steps.filter { $0.result?.hasPrefix(prefix) ?? false }
            if !matching.isEmpty {
                print("\(result.kind == .apply ? "Skipped" : "Not undone") (first \(min(matching.count, 10)) of \(matching.count)):")
                PlanPrinter.steps(Array(matching.prefix(10)))
            }
        }
    }
    print("Plan \(result.planId) is now \(result.status.text).")
    switch result.stopReason {
    case .cancelled?: throw ExitCode(130)
    case .sessionExpired?, .failure?: throw ExitCode(1)
    case .stepLimit?, nil: break
    }
}

struct ApplyPlan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a reviewed plan to your Amazon Photos library.",
        discussion: """
            This changes your Amazon account. It shows the plan and asks before it starts, unless --yes is \
            given. Rainbarrel refreshes the catalog, takes the same lock as downloads, and checks every item \
            against Amazon right before it changes it; an item that changed since the plan was made is \
            skipped. One run performs at most 50 steps (`rainbarrel config set-writes --max-steps N` changes \
            that, 0 lifts it), so a first run can be checked on the Amazon Photos website; run apply again \
            to continue, also after an error. `rainbarrel undo <id>` reverses an applied plan. Nothing is \
            ever purged and Amazon's trash is never emptied.
            """)

    @Argument(help: "The plan id, as `rainbarrel plan list` shows it.")
    var id: Int64

    @Flag(name: [.customShort("y"), .customLong("yes")], help: "Do not ask for confirmation.")
    var yes = false

    func run() async throws {
        let context = try AppContext.open()
        let service = PlanService(paths: context.paths)
        let plan = try loadPlan(service, id)
        do { try PlanApplier.check(plan) } catch let error as PlanError { throw CLIError(error.description) }
        PlanPrinter.summary(plan)

        let limit = context.config.amazonWrites.stepLimit
        let thisRun = limit.map { min($0, plan.summary.remainingToApply) } ?? plan.summary.remainingToApply
        print("\nThis run applies up to \(Format.number(thisRun)) of \(Format.number(plan.summary.remainingToApply)) steps to your Amazon Photos library.")
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else {
                throw CLIError("Apply asks for confirmation, and there is no terminal to ask on. Add --yes to go ahead.")
            }
            guard Confirmation.ask("Apply plan \(plan.id) now?") else {
                print("Nothing was changed.")
                return
            }
        }

        let (session, store) = try usableSession(context.paths)
        let flag = PlanInterruptFlag()
        let interrupt = flag.install()
        defer { interrupt.cancel() }
        let printer = PlanProgressPrinter()
        let result: PlanRunResult
        do {
            result = try await service.apply(
                planId: id, config: context.config, session: session, sessionStore: store,
                refreshCatalog: { _ = try await context.refreshCatalog() },
                isCancelled: { flag.isRaised }, progress: { printer.update($0) })
        } catch let error as PlanError {
            printer.finish()
            throw CLIError(error.description)
        } catch let error as DownloadError {
            printer.finish()
            throw CLIError(error.description)
        }
        printer.finish()
        try report(result, service: service)
    }
}

struct UndoPlan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Reverse the steps of an applied plan.",
        discussion: """
            Runs the opposite of every step that was done, last step first: trashed items are restored, \
            moved items go back, names and descriptions are put back, and folders that the plan made are \
            moved to the trash. An item that was changed in Amazon after the plan was applied is left alone \
            and reported. It shows the plan and asks first, unless --yes is given.
            """)

    @Argument(help: "The plan id, as `rainbarrel plan list` shows it.")
    var id: Int64

    @Flag(name: [.customShort("y"), .customLong("yes")], help: "Do not ask for confirmation.")
    var yes = false

    func run() async throws {
        let context = try AppContext.open()
        let service = PlanService(paths: context.paths)
        let plan = try loadPlan(service, id)
        do { try PlanUndoer.check(plan) } catch let error as PlanError { throw CLIError(error.description) }
        PlanPrinter.summary(plan)
        print("\nThis run reverses \(Format.number(plan.summary.reversible)) done steps in your Amazon Photos library.")
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else {
                throw CLIError("Undo asks for confirmation, and there is no terminal to ask on. Add --yes to go ahead.")
            }
            guard Confirmation.ask("Undo plan \(plan.id) now?") else {
                print("Nothing was changed.")
                return
            }
        }

        let (session, store) = try usableSession(context.paths)
        let flag = PlanInterruptFlag()
        let interrupt = flag.install()
        defer { interrupt.cancel() }
        let printer = PlanProgressPrinter()
        let result: PlanRunResult
        do {
            result = try await service.undo(
                planId: id, config: context.config, session: session, sessionStore: store,
                isCancelled: { flag.isRaised }, progress: { printer.update($0) })
        } catch let error as PlanError {
            printer.finish()
            throw CLIError(error.description)
        } catch let error as DownloadError {
            printer.finish()
            throw CLIError(error.description)
        }
        printer.finish()
        try report(result, service: service)
    }
}
