import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Everything that can stop `organize` before it starts, with messages that are complete and readable.
public enum OrganizeError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    case catalogEmpty
    case folderTreeMissing
    case nothingToUndo
    case fileSystem(String)

    public var description: String {
        switch self {
        case .catalogEmpty:
            return "The cloud catalog is empty, so no file can be matched. Run `rainbarrel catalog refresh` first."
        case .folderTreeMissing:
            return "The cloud folder tree has not been read yet, so the target folders are unknown. Run `rainbarrel catalog refresh` first."
        case .nothingToUndo:
            return "There is no organize run to undo."
        case .fileSystem(let detail):
            return "File system error: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

/// Why a file that has a cloud match is left where it is.
public enum OrganizeSkipReason: String, Codable, Sendable, CaseIterable {
    /// The target folder is on another volume, so a move would be a copy.
    case differentVolume
    /// The indexed file is no longer on the drive.
    case missing
    /// Size or modification time differ from the drive index, so the stored MD5 may be out of date.
    case changed
    /// The row came from a hash import and no scan has confirmed the file yet.
    case unverified
    /// The target path would lie outside the backup folder.
    case unsafePath
    /// Every numbered name for the target is taken.
    case noFreeName
    /// The file system refused the move.
    case failed

    public var explanation: String {
        switch self {
        case .differentVolume:
            return "the target folder is on a different volume; a move would need a copy, which organize never does"
        case .missing:
            return "no longer on the drive; run `rainbarrel scan` to refresh the index"
        case .changed:
            return "changed since the last scan, so its MD5 may be out of date; run `rainbarrel scan`"
        case .unverified:
            return "its hash came from an import and no scan has confirmed the file yet; run `rainbarrel scan`"
        case .unsafePath:
            return "the target path would leave the backup folder"
        case .noFreeName:
            return "every numbered name for the target is taken"
        case .failed:
            return "the file system refused the move"
        }
    }
}

/// How many files were skipped for one reason, with a few paths as examples.
public struct OrganizeSkipGroup: Codable, Sendable, Equatable {
    public var reason: OrganizeSkipReason
    public var explanation: String
    public var count: Int
    /// Drive-relative paths, at most `OrganizeSkipTally.maxExamples`.
    public var examples: [String]
}

/// Collects skipped files by reason, keeping only a few example paths per reason.
struct OrganizeSkipTally {
    static let maxExamples = 5
    private(set) var counts: [OrganizeSkipReason: Int] = [:]
    private var examples: [OrganizeSkipReason: [String]] = [:]

    var total: Int { counts.values.reduce(0, +) }

    mutating func add(_ reason: OrganizeSkipReason, path: String, detail: String? = nil) {
        counts[reason, default: 0] += 1
        guard examples[reason, default: []].count < Self.maxExamples else { return }
        examples[reason, default: []].append(detail.map { "\(path) (\($0))" } ?? path)
    }

    var groups: [OrganizeSkipGroup] {
        OrganizeSkipReason.allCases.compactMap { reason in
            guard let count = counts[reason] else { return nil }
            return OrganizeSkipGroup(
                reason: reason, explanation: reason.explanation, count: count, examples: examples[reason] ?? [])
        }
    }
}

/// One file that would move (dry run) or did move.
public struct OrganizeMoveEntry: Codable, Sendable, Equatable {
    /// Path below the drive root, with `/` separators.
    public var from: String
    public var to: String
    public var size: Int64
    public var kind: CloudItemKind
    /// A sentence about the target, for example that the cloud folder is unknown.
    public var note: String?
}

/// A drive file with the same content as another one that is kept; it stays where it is.
public struct OrganizeDuplicateEntry: Codable, Sendable, Equatable {
    public var path: String
    /// The copy of the same content that organize keeps or moves to the target.
    public var keptAt: String
    public var size: Int64
}

/// What an organize run would do, in counts. Paths are relative to the drive root.
public struct OrganizeSummary: Codable, Sendable, Equatable {
    /// Files that would move.
    public var toMove: Int
    public var toMoveBytes: Int64
    /// Of those, files that go to `_Unsorted/<year>/<month>` because their cloud folder is unknown.
    public var toUnsorted: Int
    /// Of those, files that get a numbered name because the target name holds different content.
    public var renamedForCollision: Int
    public var alreadyInPlace: Int
    /// Extra copies of content that is kept elsewhere; they stay where they are.
    public var duplicatesLeft: Int
    public var duplicatesLeftBytes: Int64
    /// Hashed drive files that match no cloud item. Never touched.
    public var driveOnlyUntouched: Int
    public var driveOnlyUntouchedBytes: Int64
    /// Drive files without an MD5 (not scanned yet, or unreadable). They cannot be matched and stay.
    public var unhashedUntouched: Int
    public var skipped: [OrganizeSkipGroup]
    public var skippedTotal: Int
    /// Cloud items without any copy on the drive: the downloads' job, not organize's.
    public var onlineOnly: Int
}

/// The dry run: the summary and a sample of what would happen.
public struct OrganizePreview: Codable, Sendable, Equatable {
    public var summary: OrganizeSummary
    /// The first moves, in the order a run makes them.
    public var sample: [OrganizeMoveEntry]
    public var duplicateSample: [OrganizeDuplicateEntry]
    public var driveRoot: String?
    /// The folder the files are organized in (drive root plus scan subpath).
    public var targetFolder: String?
    /// Judged without writing: nil when the drive is not mounted.
    public var driveWritable: Bool?
}

public enum OrganizeStopReason: String, Codable, Sendable {
    case limit
    case cancelled
    case tooManyErrors
}

/// The result of `organize --apply`.
public struct OrganizeRunResult: Codable, Sendable, Equatable {
    /// The journal id of the run; nil when nothing was moved. `organize --undo` reverses the highest id.
    public var runId: Int64?
    public var moved: Int
    public var movedBytes: Int64
    public var alreadyInPlace: Int
    public var duplicatesLeft: Int
    public var skipped: [OrganizeSkipGroup]
    public var skippedTotal: Int
    /// Folders removed by `--prune-empty-dirs`.
    public var prunedFolders: Int
    /// Planned moves not made because of the limit, Ctrl-C or too many errors.
    public var remaining: Int
    public var stopReason: OrganizeStopReason?
    public var durationSeconds: Double
}

/// The result of `organize --undo`.
public struct OrganizeUndoResult: Codable, Sendable, Equatable {
    public var runId: Int64
    public var restored: Int
    /// Entries left alone, each with the reason; they stay in the journal.
    public var refused: [OrganizeUndoRefusal]
    /// Folders that the run had created and that are empty now.
    public var removedFolders: Int
    public var cancelled: Bool
}

public struct OrganizeUndoRefusal: Codable, Sendable, Equatable {
    /// Where the file is now (the target of the original move).
    public var path: String
    public var reason: String
}

/// Progress of a run, reported through a callback.
public struct OrganizeProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case planning, moving, pruning, undoing }
    public var phase: Phase
    public var done: Int
    public var total: Int
    public var currentPath: String?
}

/// The file system questions that tests replace.
public struct OrganizeEnvironment: Sendable {
    /// Identifier of the volume that holds `absolutePath`; for a path that does not exist yet, the
    /// volume of its nearest existing parent. nil when unknown.
    public var volumeID: @Sendable (String) -> UInt64?
    public var now: @Sendable () -> Date

    public init(
        volumeID: @escaping @Sendable (String) -> UInt64? = { OrganizeFS.volumeID(of: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.volumeID = volumeID
        self.now = now
    }

    public static let live = OrganizeEnvironment()
}

/// What `lstat` says about a path.
struct OrganizeFileInfo: Equatable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var mtime: Int64
    var isRegularFile: Bool
    var isDirectory: Bool
}

/// Blocking POSIX helpers for organize.
public enum OrganizeFS {
    /// `lstat` of `path`; nil when nothing exists there.
    static func info(_ path: String) -> OrganizeFileInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        #if os(macOS)
        let mtime = Int64(st.st_mtimespec.tv_sec)
        #else
        let mtime = Int64(st.st_mtim.tv_sec)
        #endif
        return OrganizeFileInfo(
            device: UInt64(truncatingIfNeeded: st.st_dev), inode: UInt64(truncatingIfNeeded: st.st_ino),
            size: Int64(st.st_size), mtime: mtime, isRegularFile: (st.st_mode & S_IFMT) == S_IFREG,
            isDirectory: (st.st_mode & S_IFMT) == S_IFDIR)
    }

    /// Device of `path`, or of its nearest existing parent when it does not exist.
    public static func volumeID(of path: String) -> UInt64? {
        var current = path
        while true {
            var st = stat()
            if stat(current, &st) == 0 { return UInt64(truncatingIfNeeded: st.st_dev) }
            if current == "/" || current.isEmpty { return nil }
            let parent = PathGuard.parent(of: current)
            if parent == current { return nil }
            current = parent
        }
    }

    enum RenameResult: Equatable {
        case done
        case targetExists
        case crossDevice
        case failed(code: Int32, message: String)
    }

    /// Rename `source` to `destination` with rename(2) semantics, but never replace an existing
    /// `destination`. macOS asks the file system to refuse an existing target (`RENAME_EXCL`); where
    /// it cannot (exFAT, Linux), the check and the rename run back to back.
    static func renameWithoutReplacing(_ source: String, to destination: String) -> RenameResult {
        #if os(macOS)
        if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return .done }
        let code = errno
        if code == EEXIST { return .targetExists }
        if code == EXDEV { return .crossDevice }
        if code != ENOTSUP && code != EINVAL && code != ENOSYS {
            return .failed(code: code, message: FileOps.errnoMessage(code))
        }
        #endif
        if FileOps.exists(destination) { return .targetExists }
        if rename(source, destination) == 0 { return .done }
        let failure = errno
        return failure == EXDEV ? .crossDevice : .failed(code: failure, message: FileOps.errnoMessage(failure))
    }

    /// The folders that `makeDirectories(path)` would have to create, outermost first.
    static func missingDirectories(for path: String, below root: String) -> [String] {
        var missing: [String] = []
        var current = path
        while current.count > root.count, !FileOps.exists(current) {
            missing.append(current)
            current = PathGuard.parent(of: current)
        }
        return missing.reversed()
    }
}
