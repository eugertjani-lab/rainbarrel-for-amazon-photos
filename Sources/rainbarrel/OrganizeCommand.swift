import ArgumentParser
import Dispatch
import Foundation
import RainbarrelCore

/// One updating progress line on stderr (or a line every 30 seconds when stderr is not a terminal).
final class OrganizeProgressPrinter: @unchecked Sendable {
    private let interactive = isatty(STDERR_FILENO) != 0
    private let lock = NSLock()
    private var lastPrint = Date.distantPast
    private var printedInteractive = false

    func update(_ progress: OrganizeProgress) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastPrint) >= (interactive ? 0.25 : 30) else { return }
        lastPrint = now
        let label: String
        switch progress.phase {
        case .planning: label = "Planning"
        case .moving: label = "Moving"
        case .pruning: label = "Removing empty folders"
        case .undoing: label = "Restoring"
        }
        var line = label
        if progress.total > 0 { line += " \(Format.number(progress.done))/\(Format.number(progress.total))" }
        if let path = progress.currentPath {
            let width = max(40, Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 100)
            let room = width - line.count - 3
            if room > 8 { line += "  " + (path.count > room ? "..." + path.suffix(room - 3) : path) }
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

/// Set by the first Ctrl-C; the run looks at it between two files.
private final class InterruptFlag: @unchecked Sendable {
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
}

struct Organize: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move files that are already on the backup drive into the folder layout the downloads use.",
        discussion: """
            Files are matched to the cloud catalog by the MD5s of the last scan, and each one is moved to \
            <drive>/<scan folder>/<cloud folder path>/<file name>, exactly where `rainbarrel download` would \
            have put it. Nothing is hashed, copied, overwritten or deleted: a move is a rename inside one \
            volume. Files that match nothing in the cloud are never touched. Without --apply this only \
            prints what would happen. `--undo` reverses the last run.
            """)

    @Flag(help: "Make the moves. Without it, nothing is changed and the plan is printed.")
    var apply = false

    @Flag(help: "Reverse the last run: move every file back to where it was.")
    var undo = false

    @Option(help: "Move at most this many files in a run.")
    var limit: Int?

    @Flag(name: .customLong("prune-empty-dirs"), help: "With --apply, remove the folders this run emptied.")
    var pruneEmptyDirs = false

    @Flag(help: "Print the plan as JSON (dry run only).")
    var json = false

    func validate() throws {
        if let limit, limit < 1 { throw ValidationError("--limit must be at least 1.") }
        if undo && (apply || limit != nil || pruneEmptyDirs) {
            throw ValidationError("--undo cannot be combined with --apply, --limit or --prune-empty-dirs.")
        }
        if pruneEmptyDirs && !apply { throw ValidationError("--prune-empty-dirs needs --apply.") }
        if json && (apply || undo) { throw ValidationError("--json is for the dry run.") }
    }

    func run() throws {
        let context = try AppContext.open()
        let service = OrganizeService(paths: context.paths)
        do {
            if undo {
                try runUndo(service, context.config)
            } else if apply {
                try runApply(service, context.config)
            } else {
                try runPreview(service, context.config)
            }
        } catch let error as DownloadError {
            throw CLIError(error.description)
        } catch let error as OrganizeError {
            throw CLIError(error.description)
        }
    }

    // MARK: Dry run

    private func runPreview(_ service: OrganizeService, _ config: Config) throws {
        let preview = try service.preview(config: config, sample: json ? OrganizeService.maxSampleSize : 20)
        if json {
            try printJSON(preview)
            return
        }
        let s = preview.summary
        print("Organize (dry run): nothing is changed.")
        print("  Folder:           \((preview.targetFolder ?? "").sanitizedForTerminal)")
        print("  To move:          \(Format.number(s.toMove))  (\(Format.bytes(s.toMoveBytes)))")
        if s.toUnsorted > 0 {
            print("      \(Format.number(s.toUnsorted)) go to \(TargetFolders.unsorted) because their cloud folder is unknown")
        }
        if s.renamedForCollision > 0 {
            print("      \(Format.number(s.renamedForCollision)) get a numbered name because the target name holds different content")
        }
        print("  Already in place: \(Format.number(s.alreadyInPlace))")
        print("  Extra copies:     \(Format.number(s.duplicatesLeft))  (\(Format.bytes(s.duplicatesLeftBytes)), same content as a kept file; they stay)")
        print("  Drive only:       \(Format.number(s.driveOnlyUntouched))  (\(Format.bytes(s.driveOnlyUntouchedBytes)), in no cloud item; never touched)")
        if s.unhashedUntouched > 0 {
            print("  Not hashed:       \(Format.number(s.unhashedUntouched))  (run `rainbarrel scan`; they cannot be matched and stay)")
        }
        print("  Skipped:          \(Format.number(s.skippedTotal))")
        for group in s.skipped {
            print("      \(Format.number(group.count)) \(group.explanation)")
            for example in group.examples { print("          \(example.sanitizedForTerminal)") }
        }
        print("  Online only:      \(Format.number(s.onlineOnly))  (not on the drive; `rainbarrel download` fetches them)")
        if preview.driveWritable == false {
            print("\n\(DownloadError.readOnlyMessage)\nThe moves cannot be made until the drive can be written to.")
        }
        if !preview.sample.isEmpty {
            print("\nFirst \(preview.sample.count) of \(Format.number(s.toMove)) moves:")
            for move in preview.sample {
                print("  \(move.from.sanitizedForTerminal)")
                print("      -> \(move.to.sanitizedForTerminal)  (\(Format.bytes(move.size)))")
                if let note = move.note { print("      note: \(note)") }
            }
        }
        if !preview.duplicateSample.isEmpty {
            print("\nExtra copies that stay (first \(preview.duplicateSample.count) of \(Format.number(s.duplicatesLeft))):")
            for duplicate in preview.duplicateSample.prefix(10) {
                print("  \(duplicate.path.sanitizedForTerminal)")
                if !duplicate.keptAt.isEmpty { print("      same content as \(duplicate.keptAt.sanitizedForTerminal)") }
            }
        }
        if s.toMove == 0 {
            print("\nNothing to move.")
        } else {
            let capped = limit.map { " (with --limit \($0), the first \(min($0, s.toMove)))" } ?? ""
            print("\nRun `rainbarrel organize --apply` to make these moves\(capped). Nothing was changed (dry run).")
        }
    }

    // MARK: Apply

    private func runApply(_ service: OrganizeService, _ config: Config) throws {
        let flag = InterruptFlag()
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
        source.setEventHandler {
            if flag.raise() {
                printError("\nStopping after the file in progress is moved (press Ctrl-C again to quit at once)...")
            } else {
                Foundation.exit(130)
            }
        }
        source.resume()
        defer { source.cancel() }

        let printer = OrganizeProgressPrinter()
        let result: OrganizeRunResult
        do {
            result = try service.apply(
                config: config, options: OrganizeOptions(limit: limit, pruneEmptyDirs: pruneEmptyDirs),
                isCancelled: { flag.isRaised }, progress: { printer.update($0) })
        } catch {
            printer.finish()
            throw error
        }
        printer.finish()

        if result.moved == 0 && result.stopReason == nil {
            print("Nothing to move.")
        } else {
            print("Moved \(Format.number(result.moved)) files (\(Format.bytes(result.movedBytes))) in \(max(1, Int(result.durationSeconds))) s.")
        }
        print("  Already in place: \(Format.number(result.alreadyInPlace))")
        if result.duplicatesLeft > 0 {
            print("  Extra copies left where they are: \(Format.number(result.duplicatesLeft))")
        }
        if result.skippedTotal > 0 {
            print("  Skipped: \(Format.number(result.skippedTotal))")
            for group in result.skipped {
                print("      \(Format.number(group.count)) \(group.explanation)")
                for example in group.examples { print("          \(example.sanitizedForTerminal)") }
            }
        }
        if pruneEmptyDirs { print("  Removed empty folders: \(Format.number(result.prunedFolders))") }
        switch result.stopReason {
        case .limit?:
            print("Stopped at the limit; \(Format.number(result.remaining)) planned moves are left. Run it again to continue.")
        case .cancelled?:
            print("Stopped by Ctrl-C; \(Format.number(result.remaining)) planned moves are left. Run it again to continue.")
            throw ExitCode(130)
        case .tooManyErrors?:
            print("Stopped after too many failed moves in a row. Check the drive, then run it again.")
            throw ExitCode(1)
        case nil:
            break
        }
        if result.moved > 0 { print("`rainbarrel organize --undo` reverses this run.") }
    }

    // MARK: Undo

    private func runUndo(_ service: OrganizeService, _ config: Config) throws {
        let printer = OrganizeProgressPrinter()
        let result: OrganizeUndoResult
        do {
            result = try service.undo(config: config, progress: { printer.update($0) })
        } catch {
            printer.finish()
            throw error
        }
        printer.finish()
        print("Moved \(Format.number(result.restored)) files back to where they were.")
        if result.removedFolders > 0 {
            print("  Removed \(Format.number(result.removedFolders)) folders that the run had created.")
        }
        if !result.refused.isEmpty {
            print("  Left alone: \(Format.number(result.refused.count)); they stay in the journal.")
            for refusal in result.refused.prefix(10) {
                print("      \(refusal.path.sanitizedForTerminal): \(refusal.reason.sanitizedForTerminal)")
            }
            if result.refused.count > 10 { print("      ... and \(result.refused.count - 10) more") }
            throw ExitCode(1)
        }
        if result.cancelled { throw ExitCode(130) }
    }
}
