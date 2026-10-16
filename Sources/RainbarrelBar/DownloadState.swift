import Foundation
import RainbarrelCore

/// Whether the stored Amazon session can be used.
enum AccountState: Equatable, Sendable {
    /// Not looked at yet.
    case unknown
    case signedOut
    case signedIn
    /// A session is stored but Amazon no longer accepts it (or its cookies ran out).
    case expired
}

/// What a download would do right now, from the planner: online-only items including Live Photo videos.
struct QueuePreview: Equatable, Sendable {
    var count: Int
    var bytes: Int64
}

/// Why the engine task is being cancelled. All three cancel the same way; they differ in what the
/// panel shows afterwards.
enum StopRequest: Equatable, Sendable {
    /// The Pause button: the card stays, with Resume.
    case pause
    /// The Stop button (and signing out): back to the ready state.
    case stop
    /// The app is quitting.
    case quit
}

/// Everything the progress card shows, already summed over the segments of a paused and resumed run.
struct DownloadDisplay: Equatable, Sendable {
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var bytesPerSecond: Double = 0
    /// The name of one file in flight, ready to show (control characters removed).
    var currentFile: String?
    /// The throttle's active hours keep new files from starting.
    var waitingForHours = false
    /// Amazon asked for a pause; the run goes on at this time.
    var backoffUntil: Date?
    /// A sentence from the engine to show next to the state.
    var message: String?

    init() {}

    /// - Parameters:
    ///   - carryFiles: files finished in earlier segments of the same paused and resumed run.
    ///   - carryBytes: bytes written in those segments.
    init(_ progress: DownloadProgress, carryFiles: Int = 0, carryBytes: Int64 = 0, now: Date = Date()) {
        filesDone = carryFiles + progress.filesDone
        filesTotal = carryFiles + progress.filesTotal
        bytesDone = carryBytes + progress.bytesDone
        bytesTotal = carryBytes + progress.bytesTotal
        bytesPerSecond = progress.bytesPerSecond
        currentFile = progress.currentFiles.first.map { DisplayFormat.displayFileName($0, maxLength: 40) }
        switch progress.state {
        case .waitingForWindow(let until):
            waitingForHours = until > now
        case .backingOff(let until):
            backoffUntil = until > now ? until : nil
        default:
            break
        }
        message = progress.message.map { DisplayFormat.displayFileName($0, maxLength: 200) }
    }

    /// Share of the bytes done, or of the files when no sizes are known; 0...1.
    var fraction: Double {
        let value = bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal)
            : (filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0)
        return min(max(value.isFinite ? value : 0, 0), 1)
    }

    var percent: Int { Int((fraction * 100).rounded(.down)) }

    var bytesLeft: Int64 { max(bytesTotal - bytesDone, 0) }

    /// "about 35 min left", or nil while the speed is not known.
    var timeLeft: String? {
        DisplayFormat.timeRemaining(bytesLeft: bytesLeft, bytesPerSecond: bytesPerSecond)
    }
}

/// What the download part of the panel is doing.
enum DownloadState: Equatable {
    case idle
    case running(DownloadDisplay)
    case paused(DownloadDisplay)
    /// One line about the run that just ended.
    case finished(String)
}

/// The one thing the primary action area of the panel shows.
enum PrimaryAction: Equatable {
    /// Nothing to offer yet (no report, or still reading the session).
    case none
    case signIn
    case signInAgain
    case driveMissing
    case driveReadOnly
    case ready(count: Int, bytes: Int64, note: String?)
    case nothingToDownload(note: String?)
    case downloading(DownloadDisplay, stopping: StopRequest?)
    case paused(DownloadDisplay)
}

/// How a download task ended, with nothing that could carry a secret.
enum DownloadRunResult: Sendable {
    case summary(DownloadSummary)
    case cancelled
    case sessionExpired
    case signedOut
    case failed(String)
}

/// The states `--render-snapshot --state` can draw, each with fixture data and no network.
enum PanelScenario: String, CaseIterable {
    case signedOut = "signed-out"
    case ready
    case downloading
    case waiting
    case paused
    case readOnly = "read-only"
    case driveMissing = "drive-missing"
    case expired
    case finished
}
