import ArgumentParser
import Foundation
import MirrorCore

/// Prints one updating progress line on stderr (or a line every 30 seconds when stderr is not a terminal).
final class ProgressPrinter {
    private let interactive = isatty(STDERR_FILENO) != 0
    private var lastPrint = Date.distantPast
    private var printedInteractive = false
    private let startedAt = Date()

    func update(_ progress: ScanProgress) {
        let now = Date()
        let interval: TimeInterval = interactive ? 0.2 : 30
        guard now.timeIntervalSince(lastPrint) >= interval else { return }
        lastPrint = now
        let prefix = "seen \(Format.number(progress.filesSeen))  hashed \(Format.number(progress.filesHashed))"
            + "  \(Format.bytes(progress.bytesHashed))  errors \(progress.errors)  "
        if interactive {
            let width = max(40, Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 100)
            var path = (progress.currentPath ?? "").sanitizedForTerminal
            let room = width - prefix.count - 1
            if room > 3, path.count > room { path = "..." + path.suffix(room - 3) } else if room <= 3 { path = "" }
            FileHandle.standardError.write(Data(("\r" + prefix + path + "\u{1B}[K").utf8))
            printedInteractive = true
        } else {
            printError(prefix.trimmingCharacters(in: .whitespaces))
        }
    }

    func finish() {
        if printedInteractive { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    }
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Walk the backup drive and record size, modification time and MD5 of its files.",
        discussion: """
            Only new files, changed files and files that have no hash yet are hashed. The drive is \
            opened read-only and nothing is ever written to it. Reads that fail are retried up to \
            5 times with growing pauses (2 to 10 seconds) because some drives drop out briefly.
            """)

    @Flag(name: .customLong("no-hash"), help: "Only record size and modification time; do not compute MD5s.")
    var noHash = false

    @Option(help: "Stop after N files needed work (new, changed or unhashed). Up-to-date files are free.")
    var limit: Int?

    func run() throws {
        let context = try AppContext.open()
        guard let rootPath = context.config.scanRootPath, let driveRoot = context.config.driveRoot else {
            throw CLIError("No drive configured. Run `apmirror config set-drive <path>` first.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError("\(rootPath) is not available. Is the drive mounted?")
        }
        if let limit, limit < 1 { throw CLIError("--limit must be at least 1.") }

        let scanner = try DriveScanner(
            store: context.store, driveRoot: driveRoot, scanSubpath: context.config.scanSubpath)
        let printer = ProgressPrinter()
        let result = try scanner.scan(
            options: ScanOptions(hash: !noHash, limit: limit),
            progress: { printer.update($0) })
        printer.finish()

        let seconds = max(1, Int(result.finishedAt.timeIntervalSince(result.startedAt)))
        print("Scan \(result.stoppedByLimit ? "stopped at the limit" : "finished") in \(seconds) s")
        if result.removedSkipped > 0 || result.removedOutOfScope > 0 || result.pruned > 0 {
            print("  Removed records:  \(Format.number(result.pruned)) for files gone from the drive, "
                + "\(Format.number(result.removedSkipped)) housekeeping, "
                + "\(Format.number(result.removedOutOfScope)) outside the scan folder")
        }
        print("  Files seen:      \(Format.number(result.filesSeen))")
        print("  Files hashed:    \(Format.number(result.filesHashed))  (\(Format.bytes(result.bytesHashed)))")
        print("  Seed hashes kept (mtime filled in): \(Format.number(result.filesAdopted))")
        print("  Errors:          \(Format.number(result.errors))")
        for line in result.directoryErrors.prefix(10) { print("    directory: \(line.sanitizedForTerminal)") }
        if result.directoryErrors.count > 10 { print("    ... and \(result.directoryErrors.count - 10) more") }
    }
}
