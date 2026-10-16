import ArgumentParser
import Dispatch
import Foundation
import RainbarrelCore

/// One updating progress line on stderr (or a line every 30 seconds when stderr is not a terminal).
final class DownloadProgressPrinter: @unchecked Sendable {
    private let interactive = isatty(STDERR_FILENO) != 0
    private let lock = NSLock()
    private var lastPrint = Date.distantPast
    private var printedInteractive = false

    func update(_ progress: DownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastPrint) >= (interactive ? 0.25 : 30) else { return }
        lastPrint = now
        let line = Self.line(progress, width: max(40, Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 100))
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

    static func line(_ progress: DownloadProgress, width: Int) -> String {
        var parts = ["\(Format.number(progress.filesDone))/\(Format.number(progress.filesTotal)) files"]
        parts.append("\(Format.bytes(progress.bytesDone)) / \(Format.bytes(progress.bytesTotal))")
        if progress.bytesPerSecond > 0 { parts.append("\(Format.bytes(Int64(progress.bytesPerSecond)))/s") }
        if progress.filesFailed > 0 { parts.append("\(progress.filesFailed) failed") }
        var text = parts.joined(separator: "  ")
        switch progress.state {
        case .waitingForWindow(let until):
            text += "  waiting for the active hours (opens \(Format.timeOrDate(until)))"
        case .backingOff(let until):
            text += "  backing off until \(Format.timeOrDate(until))"
        default:
            break
        }
        if let message = progress.message { text += "  " + message }
        let names = progress.currentFiles.joined(separator: ", ")
        if !names.isEmpty {
            let room = width - text.count - 3
            if room > 8 { text += "  " + (names.count > room ? names.prefix(room - 3) + "..." : names) }
        }
        return text.sanitizedForTerminal
    }
}

struct Download: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download the photos and videos that are missing from the backup drive.",
        discussion: """
            Files are written to <drive>/<scan folder>/<cloud folder path>/<file name>, checked by MD5 \
            against the catalog, and only then recorded as backed up. Existing files are never overwritten \
            or deleted. Throttling is set with `rainbarrel config set-throttle`. Uses Amazon's private web \
            API with the session from `rainbarrel auth import`; Ctrl-C stops cleanly and the next run continues.
            """)

    @Option(help: "Start at most this many files.")
    var limit: Int?

    @Option(help: "Only items captured in this year (UTC).")
    var year: Int?

    @Option(help: "Write below this folder instead of the backup drive (for testing). Nothing is recorded as backed up.")
    var to: String?

    @Flag(name: .customLong("dry-run"), help: "Print where files would go; no network, nothing is written.")
    var dryRun = false

    @Flag(name: .customLong("no-live-videos"), help: "Leave out the video part of Live Photos.")
    var noLiveVideos = false

    @Option(help: "Files downloaded at the same time for this run (1 to 8).")
    var concurrency: Int?

    @Option(help: "Speed limit for this run in megabytes per second, all files together.")
    var mbps: Double?

    @Flag(name: .customLong("ignore-hours"), help: "Download even outside the configured active hours.")
    var ignoreHours = false

    @Flag(name: .customLong("respect-hours"),
          help: "Outside the active hours, stop with a message instead of waiting for them.")
    var respectHours = false

    func validate() throws {
        if let limit, limit < 1 { throw ValidationError("--limit must be at least 1.") }
        if let year, !(1...9999).contains(year) { throw ValidationError("--year must be a four-digit year.") }
        if let concurrency, !(1...8).contains(concurrency) { throw ValidationError("--concurrency must be 1 to 8.") }
        if let mbps, !(mbps.isFinite && mbps >= 0) { throw ValidationError("--mbps must be 0 or more.") }
        if ignoreHours && respectHours { throw ValidationError("--ignore-hours and --respect-hours exclude each other.") }
    }

    func run() async throws {
        let context = try AppContext.open()
        let config = context.config
        guard let driveRoot = config.driveRoot, !driveRoot.isEmpty else {
            throw CLIError(DownloadError.noDriveConfigured.description)
        }
        let options = DownloadOptions(
            year: year, limit: limit, includeLiveVideos: !noLiveVideos,
            targetRoot: to.map { absolutePath($0) }, concurrency: concurrency, maxMBps: mbps,
            hoursPolicy: ignoreHours ? .ignore : (respectHours ? .exit : .wait))
        let engine = DownloadEngine(paths: context.paths)

        if dryRun {
            try await ensureCatalog(context)
            let planned = try engine.plan(config: config, options: options)
            printPlan(planned, driveRoot: driveRoot, root: options.targetRoot)
            return
        }

        // The target comes first: a read-only drive needs no session and no network.
        do { try DownloadEngine.prepareTarget(config: config, options: options) } catch let error as DownloadError {
            throw CLIError(error.description)
        }
        let store = SessionStoreFactory.make(paths: context.paths)
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
        try await ensureCatalog(context)

        let printer = DownloadProgressPrinter()
        let task = Task { try await engine.run(config: config, session: session, options: options) { printer.update($0) } }
        let interrupt = Self.cancelOnInterrupt { task.cancel() }
        defer { interrupt.cancel() }
        let summary: DownloadSummary
        do {
            summary = try await task.value
        } catch let error as DownloadError {
            printer.finish()
            throw CLIError(error.description)
        }
        printer.finish()
        try report(summary)
    }

    private func ensureCatalog(_ context: AppContext) async throws {
        try await context.refreshCatalogIfStale()
        if try context.store.cloudFolderCount() == 0 {
            printError("Reading the cloud folder tree...")
            try await context.refreshCatalog()
        }
    }

    private func printPlan(_ planned: [PlannedDownload], driveRoot: String, root: String?) {
        if planned.isEmpty {
            print("Nothing to download: every cloud file is on the drive.")
            return
        }
        print("Target root: \((root ?? driveRoot).sanitizedForTerminal)")
        var bytes: Int64 = 0
        for item in planned {
            bytes += item.size
            let kind = item.kind == .liveVideo ? "  [live photo video]" : ""
            print("  \(item.finalRelPath.sanitizedForTerminal)  (\(Format.bytes(item.size)), \(Format.day(unix: item.takenAt)))\(kind)")
            if let note = item.note { print("      note: \(note)") }
            if !item.resolvedFolders { print("      note: cloud folder not found; placed under \(TargetFolders.unsorted)") }
        }
        print("\(Format.number(planned.count)) files, \(Format.bytes(bytes)) would be downloaded. Nothing was written (dry run).")
    }

    private func report(_ summary: DownloadSummary) throws {
        let handled = summary.filesDownloaded + summary.filesAdopted + summary.filesSkipped + summary.filesFailed
        if handled == 0 {
            guard let reason = summary.stopReason else {
                print("Nothing to download: no missing file matches. See `rainbarrel download-status` for the queue.")
                return
            }
            print(reason.description.sanitizedForTerminal)
            throw ExitCode(reason == .cancelled ? 130 : 1)
        }
        let seconds = max(1, Int(summary.durationSeconds))
        print("Downloaded \(Format.number(summary.filesDownloaded)) files (\(Format.bytes(summary.bytesDownloaded))) in \(seconds) s")
        if summary.filesAdopted > 0 {
            print("  Already on the drive, content verified: \(Format.number(summary.filesAdopted))")
        }
        if summary.filesSkipped > 0 { print("  Skipped, same content already handled: \(Format.number(summary.filesSkipped))") }
        if summary.filesFailed > 0 {
            print("  Failed: \(Format.number(summary.filesFailed))")
            let failed = summary.results.filter { $0.outcome == .failed }
            for result in failed.prefix(10) {
                print("    \(result.path.sanitizedForTerminal): \((result.detail ?? "unknown").sanitizedForTerminal)")
            }
            if failed.count > 10 { print("    ... and \(failed.count - 10) more; see `rainbarrel download-status`") }
        }
        if let reason = summary.stopReason {
            print(reason.description.sanitizedForTerminal)
            throw ExitCode(reason == .cancelled ? 130 : 1)
        }
        if summary.filesFailed > 0 { throw ExitCode(1) }
    }

    /// Run `handler` on the first Ctrl-C; a second one ends the process at once.
    private static func cancelOnInterrupt(_ handler: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
        let state = InterruptState()
        source.setEventHandler {
            if state.markFirst() {
                printError("\nStopping after the files in progress are cleaned up (press Ctrl-C again to quit at once)...")
                handler()
            } else {
                quitImmediately()
            }
        }
        source.resume()
        return source
    }
}

/// Ends the process at once (a second Ctrl-C).
private func quitImmediately() -> Never {
    exit(130)
}

private final class InterruptState: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false

    func markFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { seen = true }
        return !seen
    }
}

enum TargetFolders {
    static let unsorted = "_Unsorted/<year>/<month>"
}

struct DownloadStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download-status",
        abstract: "Show the download queue, failures, the Amazon session and the limits.",
        discussion: "Makes no network call and writes nothing.")

    @Flag(help: "Print the report as JSON.")
    var json = false

    func run() throws {
        let tools = RainbarrelTools(paths: .forCLI())
        let report = try tools.downloadStatus(failureLimit: json ? 200 : 20)
        if json {
            try printJSON(report)
            return
        }
        func row(_ label: String, _ value: String) {
            print("  " + label.padding(toLength: 18, withPad: " ", startingAt: 0) + value)
        }
        let queue = report.queue
        print("Queue")
        row("Waiting:", "\(Format.number(queue.pending))  (\(Format.bytes(queue.pendingBytes)))")
        row("Downloading:", Format.number(queue.downloading))
        row("Done:", Format.number(queue.done))
        row("Failed:", Format.number(queue.failed))
        row("Skipped:", Format.number(queue.skipped))
        row("Not queued yet:", "\(Format.number(queue.notQueued))  (the queue is filled when a download starts)")
        if !report.failures.isEmpty {
            print("\nFailures")
            for failure in report.failures.prefix(20) {
                print("  \(failure.targetRelPath.sanitizedForTerminal)  (\(failure.attempts) attempts)")
                print("      \(failure.reason.sanitizedForTerminal)")
            }
            if queue.failed > report.failures.count { print("  ... and \(queue.failed - report.failures.count) more (use --json)") }
        }
        print("\nLast run")
        if let last = report.lastRun {
            let s = last.summary
            row("Finished:", "\(Format.dateTime(last.finishedAt)) (\(Format.age(of: last.finishedAt)))")
            row("Result:", "\(s.filesDownloaded) downloaded (\(Format.bytes(s.bytesDownloaded))), \(s.filesAdopted) already present, \(s.filesSkipped) skipped, \(s.filesFailed) failed")
            row("Ended:", (s.stopReason?.description ?? "completed").sanitizedForTerminal)
        } else {
            row("", "no download has run yet")
        }
        print("\nAmazon session")
        let session = report.session
        if session.signedIn {
            row("Signed in to:", (session.host ?? "?").sanitizedForTerminal)
            row("Saved:", session.savedAt.map { Format.dateTime($0) } ?? "unknown")
            row("Cookies:", "\(session.cookieCount)" + (session.usable ? "" : "  (session-id missing or expired: sign in again)"))
            row("Stored in:", session.storage.sanitizedForTerminal)
        } else {
            row("", "Not signed in" + (session.problem.map { " (\($0.sanitizedForTerminal))" } ?? ""))
        }
        print("\nTarget")
        row("Folder:", (report.targetFolder ?? "(no drive configured)").sanitizedForTerminal)
        let drive: String
        switch (report.driveMounted, report.driveWritable) {
        case (false, _): drive = "not mounted"
        case (true, false?): drive = "mounted, READ-ONLY (downloads cannot write here)"
        case (true, true?): drive = "mounted, writable"
        default: drive = "mounted"
        }
        row("Drive:", drive)
        row("Amazon host:", report.amazonHost.sanitizedForTerminal)
        print("\nLimits")
        for line in report.throttle.summaryLines { print("  " + line) }
    }
}
