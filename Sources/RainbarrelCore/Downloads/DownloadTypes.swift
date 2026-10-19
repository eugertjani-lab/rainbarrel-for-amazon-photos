import Foundation

/// Everything that can stop or fail a download, with messages that are complete and readable.
/// Messages never contain cookie values or full download links.
public enum DownloadError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    case notSignedIn
    case sessionExpired
    case sessionInvalid(String)
    /// HTTP 429, 503 or another 5xx answer.
    case throttled(status: Int, retryAfter: TimeInterval?)
    case network(String)
    case httpStatus(Int)
    /// Amazon will not hand out this one file although the sign-in works.
    case refusedFile(String)
    case redirectRefused(host: String)
    case insecureURL
    case invalidHost(String)
    case invalidNodeId(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case md5Mismatch(expected: String, actual: String)
    case targetNotWritable(path: String, detail: String?)
    case driveNotMounted(String)
    case driveUnavailable
    case pathEscapesRoot(String)
    case noDriveConfigured
    case alreadyRunning
    case invalidResponse(String)
    case fileSystem(String)

    public static let readOnlyMessage =
        "The backup drive is read-only (for example NTFS on macOS). Reformat it as APFS or exFAT, or choose another folder."

    public var description: String {
        switch self {
        case .notSignedIn:
            return "Not signed in to Amazon. Import your session with `rainbarrel auth import <cookies file>`."
        case .sessionExpired:
            return "Amazon session expired: sign in again"
        case .sessionInvalid(let detail):
            return "The stored Amazon session cannot be used: \(detail)"
        case .throttled(let status, _):
            return "Amazon is limiting requests (HTTP \(status))"
        case .network(let detail):
            return "Network problem: \(detail)"
        case .httpStatus(let status):
            return "Amazon answered HTTP \(status)"
        case .refusedFile(let reason):
            return reason
        case .redirectRefused(let host):
            return "Refused a redirect to \(host), which is not an Amazon host"
        case .insecureURL:
            return "Refused a request that is not https"
        case .invalidHost(let host):
            return "The Amazon host \"\(host)\" is not a valid host name"
        case .invalidNodeId(let id):
            return "Refused an unexpected node id (\(id.count) characters)"
        case .sizeMismatch(let expected, let actual):
            return "Size mismatch: expected \(expected) bytes, received \(actual)"
        case .md5Mismatch(let expected, let actual):
            return "MD5 mismatch: expected \(expected), computed \(actual)"
        case .targetNotWritable(let path, let detail):
            if detail == nil { return Self.readOnlyMessage }
            return "Cannot write to \(path): \(detail ?? "unknown error")"
        case .driveNotMounted(let path):
            return "The backup drive is not mounted: \(path) does not exist. Connect the drive and try again."
        case .driveUnavailable:
            return "The backup drive went away during the download. Reconnect it and run the download again."
        case .pathEscapesRoot(let path):
            return "Refused a target path outside the backup folder (\(path.count) characters)"
        case .noDriveConfigured:
            return "No backup drive is configured. Set it with `rainbarrel config set-drive <path>`."
        case .alreadyRunning:
            return "Another download or organize run is already running. Wait for it to finish or stop it first."
        case .invalidResponse(let detail):
            return "Unexpected answer from Amazon: \(detail)"
        case .fileSystem(let detail):
            return "File system error: \(detail)"
        }
    }

    public var errorDescription: String? { description }

    /// True for answers that say "try again later".
    var isTransient: Bool {
        switch self {
        case .throttled, .network: return true
        default: return false
        }
    }
}

public enum DownloadJobStatus: String, Codable, Sendable, CaseIterable {
    case pending, downloading, done, failed, skipped
}

/// One row of the `download_jobs` table.
public struct DownloadJob: Codable, Sendable, Equatable {
    public var nodeId: String
    public var kind: CloudItemKind
    public var md5: String
    public var size: Int64
    public var takenAt: Int64
    /// Path below the drive root (or below the `--to` folder), with `/` separators.
    public var targetRelPath: String
    public var status: DownloadJobStatus
    public var attempts: Int
    public var lastError: String?
    public var updatedAt: Int64

    public init(
        nodeId: String, kind: CloudItemKind, md5: String, size: Int64, takenAt: Int64,
        targetRelPath: String, status: DownloadJobStatus = .pending, attempts: Int = 0,
        lastError: String? = nil, updatedAt: Int64 = 0
    ) {
        self.nodeId = nodeId
        self.kind = kind
        self.md5 = md5
        self.size = size
        self.takenAt = takenAt
        self.targetRelPath = targetRelPath
        self.status = status
        self.attempts = attempts
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    /// Last path component, for display.
    public var fileName: String {
        targetRelPath.split(separator: "/").last.map(String.init) ?? targetRelPath
    }
}

/// Counts of the download queue, by status.
public struct DownloadQueueCounts: Codable, Sendable, Equatable {
    public var pending = 0
    public var downloading = 0
    public var done = 0
    public var failed = 0
    public var skipped = 0
    /// Online-only items that have no queue row yet (the queue is filled when a download starts).
    public var notQueued = 0
    public var pendingBytes: Int64 = 0

    public init() {}
}

/// Whether files are being downloaded right now, judged from the shared state database alone, so a
/// download run by another process (the command line) shows up too.
public struct DownloadActivity: Codable, Sendable, Equatable {
    /// Seconds of recently finished files that `recentBytes` covers.
    public static let window: TimeInterval = 60

    /// Jobs with status `downloading`.
    public var downloading = 0
    /// Bytes of jobs that finished (status `done`) within the last `window` seconds.
    public var recentBytes: Int64 = 0

    public init(downloading: Int = 0, recentBytes: Int64 = 0) {
        self.downloading = downloading
        self.recentBytes = recentBytes
    }

    public var isActive: Bool { downloading > 0 || recentBytes > 0 }

    /// Average speed over the window.
    public var bytesPerSecond: Double { Double(recentBytes) / Self.window }
}

/// A failed job with the reason, for `download-status`.
public struct DownloadFailure: Codable, Sendable, Equatable {
    public var nodeId: String
    public var targetRelPath: String
    public var attempts: Int
    public var reason: String
    public var updatedAt: Date
}

/// What a download run may do and where it writes.
public struct DownloadOptions: Sendable, Equatable {
    public var year: Int?
    /// Stop after this many files were started.
    public var limit: Int?
    public var includeLiveVideos: Bool
    /// Write below this folder instead of the configured drive root (a scratch run: no drive index
    /// rows and no queue changes are stored).
    public var targetRoot: String?
    public var concurrency: Int?
    public var maxMBps: Double?
    public var hoursPolicy: ActiveHoursPolicy
    /// A job that failed this many times is not tried again.
    public var maxAttempts: Int
    /// How often the run may pause for 15 minutes because Amazon keeps throttling; nil means
    /// without limit, 0 stops the run instead of pausing.
    public var maxLongPauses: Int?

    public init(
        year: Int? = nil, limit: Int? = nil, includeLiveVideos: Bool = true, targetRoot: String? = nil,
        concurrency: Int? = nil, maxMBps: Double? = nil, hoursPolicy: ActiveHoursPolicy = .wait,
        maxAttempts: Int = 5, maxLongPauses: Int? = nil
    ) {
        self.year = year
        self.limit = limit
        self.includeLiveVideos = includeLiveVideos
        self.targetRoot = targetRoot
        self.concurrency = concurrency
        self.maxMBps = maxMBps
        self.hoursPolicy = hoursPolicy
        self.maxAttempts = maxAttempts
        self.maxLongPauses = maxLongPauses
    }
}

/// What a run does outside the configured active hours.
public enum ActiveHoursPolicy: String, Codable, Sendable {
    /// Wait until the window opens.
    case wait
    /// Stop right away.
    case exit
    /// Run regardless.
    case ignore
}

public enum DownloadStopReason: Codable, Sendable, Equatable, CustomStringConvertible {
    case cancelled
    case sessionExpired
    case driveUnavailable
    case dailyLimitReached
    case lowDiskSpace
    case outsideActiveHours
    case throttled
    case failure(String)

    public var description: String {
        switch self {
        case .cancelled: return "Stopped. Progress is saved; run the download again to continue."
        case .sessionExpired: return DownloadError.sessionExpired.description
        case .driveUnavailable: return DownloadError.driveUnavailable.description
        case .dailyLimitReached: return "The daily download limit is reached. It resets at midnight."
        case .lowDiskSpace: return "Not enough free space on the drive to start the next file."
        case .outsideActiveHours: return "Outside the active hours; no new files are started."
        case .throttled: return "Amazon keeps limiting requests; try again later."
        case .failure(let message): return message
        }
    }
}

public enum DownloadRunState: Codable, Sendable, Equatable {
    case running
    case waitingForWindow(until: Date)
    case backingOff(until: Date)
    case paused
    case finished
    case stopped(DownloadStopReason)
}

/// A snapshot of a running download, for a progress line or the menu-bar app.
public struct DownloadProgress: Codable, Sendable, Equatable {
    public var filesDone: Int
    public var filesFailed: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// Average over the last 10 seconds.
    public var bytesPerSecond: Double
    /// Names of the files being downloaded right now.
    public var currentFiles: [String]
    public var state: DownloadRunState
    /// A sentence to show next to the state, for example why the run is waiting.
    public var message: String?

    public init(
        filesDone: Int = 0, filesFailed: Int = 0, filesTotal: Int = 0, bytesDone: Int64 = 0,
        bytesTotal: Int64 = 0, bytesPerSecond: Double = 0, currentFiles: [String] = [],
        state: DownloadRunState = .running, message: String? = nil
    ) {
        self.filesDone = filesDone
        self.filesFailed = filesFailed
        self.filesTotal = filesTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
        self.currentFiles = currentFiles
        self.state = state
        self.message = message
    }
}

/// How one file of a run ended.
public struct DownloadFileResult: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case downloaded, adopted, skipped, failed
    }

    public var nodeId: String
    public var path: String
    public var outcome: Outcome
    public var bytes: Int64
    public var detail: String?
}

/// The result of one run.
public struct DownloadSummary: Codable, Sendable, Equatable {
    public var filesDownloaded: Int
    /// Files that were already on the drive with the right content and were only recorded.
    public var filesAdopted: Int
    /// Files not downloaded because the same content is already on the drive or in this run.
    public var filesSkipped: Int
    public var filesFailed: Int
    public var bytesDownloaded: Int64
    public var durationSeconds: Double
    public var stopReason: DownloadStopReason?
    /// Per-file results, at most `DownloadSummary.maxResults` of them.
    public var results: [DownloadFileResult]

    public static let maxResults = 500

    public var finishedNormally: Bool { stopReason == nil }
}

/// The last run, stored in the `meta` table for `download-status`.
public struct DownloadRunRecord: Codable, Sendable, Equatable {
    public var finishedAt: Date
    public var summary: DownloadSummary
}
