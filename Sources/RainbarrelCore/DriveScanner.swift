import Foundation

public struct ScanOptions: Sendable {
    /// Compute MD5s for new or changed files. When false only size and mtime are recorded.
    public var hash: Bool
    /// Stop after this many files needed work in this run: new, changed or seed-adopted files,
    /// plus files hashed because an earlier run left them without a hash. Files that are already
    /// up to date are free, so repeated limited runs keep making progress.
    public var limit: Int?
    public var retry: RetryPolicy
    /// Polled between files and between chunks; when it returns true the scan stops cleanly.
    public var isCancelled: @Sendable () -> Bool

    public init(
        hash: Bool = true, limit: Int? = nil, retry: RetryPolicy = .default,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.hash = hash
        self.limit = limit
        self.retry = retry
        self.isCancelled = isCancelled
    }
}

public struct ScanProgress: Sendable {
    public var filesSeen: Int
    public var filesHashed: Int
    public var bytesHashed: Int64
    public var errors: Int
    public var currentPath: String?
}

public struct ScanResult: Sendable {
    public var scanId: Int64
    public var startedAt: Date
    public var finishedAt: Date
    public var filesSeen: Int
    public var filesHashed: Int
    public var bytesHashed: Int64
    /// Rows whose seed-imported hash was kept and whose mtime was filled in from disk.
    public var filesAdopted: Int
    public var errors: Int
    /// Directory listings that failed after all retries ("path: message").
    public var directoryErrors: [String]
    public var stoppedByLimit: Bool
    public var cancelled: Bool
    /// True when the whole scope was walked, so nothing was left unvisited.
    public var walkedEverything: Bool { !stoppedByLimit && !cancelled }
    /// Rows for housekeeping files that were removed at the start.
    public var removedSkipped: Int
    /// Rows outside the scan scope that were removed at the start.
    public var removedOutOfScope: Int
    /// Rows for files that are gone from the drive. Only set by scans that walked everything, and
    /// only for rows whose folder was listed successfully.
    public var pruned: Int
}

public enum DriveScanError: Error, CustomStringConvertible {
    case rootUnavailable(path: String, reason: String)
    case invalidSubpath(String)

    public var description: String {
        switch self {
        case .rootUnavailable(let path, let reason): return "Cannot read \(path): \(reason)"
        case .invalidSubpath(let value): return "Invalid scan subpath: \(value)"
        }
    }
}

/// Walks the backup drive read-only and records size, mtime and MD5 of every file in `drive_files`.
/// Nothing is ever written to, created on or modified on the drive.
public final class DriveScanner {
    /// True when a directory or file name is operating-system housekeeping that never holds photos.
    public static func shouldSkip(name: String, isDirectory: Bool) -> Bool {
        SkipRules.shouldSkip(name: name, isDirectory: isDirectory)
    }

    private let store: StateStore
    private let driveRoot: String
    private let scope: DriveScope

    /// - Parameters:
    ///   - driveRoot: mount point of the backup drive; `rel_path` values are relative to it.
    ///   - scanSubpath: optional folder below `driveRoot` to walk instead of the whole drive.
    public init(store: StateStore, driveRoot: String, scanSubpath: String? = nil) throws {
        self.store = store
        self.driveRoot = driveRoot.count > 1 && driveRoot.hasSuffix("/") ? String(driveRoot.dropLast()) : driveRoot
        self.scope = try DriveScope(scanSubpath: scanSubpath)
    }

    private struct Entry {
        var name: String
        var isDirectory: Bool
        var isRegularFile: Bool
        var size: Int64
        var mtime: Int64
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]

    private func absolutePath(forRelative relative: String) -> String {
        relative.isEmpty ? driveRoot : (driveRoot == "/" ? "/" + relative : driveRoot + "/" + relative)
    }

    /// Test hook: called with the drive-relative folder path before every listing attempt; throwing
    /// simulates a listing that fails (for example a drive that dropped out).
    var listingHook: ((String) throws -> Void)?

    private func listDirectory(atRelative relative: String) throws -> [Entry] {
        try listingHook?(relative)
        let url = URL(fileURLWithPath: absolutePath(forRelative: relative), isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Self.resourceKeys, options: [])
        var entries: [Entry] = []
        entries.reserveCapacity(urls.count)
        for child in urls {
            let values = try child.resourceValues(forKeys: Set(Self.resourceKeys))
            if values.isSymbolicLink == true { continue }
            entries.append(Entry(
                name: child.lastPathComponent,
                isDirectory: values.isDirectory == true,
                isRegularFile: values.isRegularFile == true,
                size: Int64(values.fileSize ?? 0),
                mtime: Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970.rounded(.down))))
        }
        entries.sort { $0.name < $1.name }
        return entries
    }

    private enum FileAction {
        case upToDate
        case adoptMTime
        case needsHash(metadataChanged: Bool)
    }

    private func decide(existing: DriveFileRecord?, size: Int64, mtime: Int64) -> FileAction {
        guard let existing else { return .needsHash(metadataChanged: true) }
        if existing.size == size {
            if existing.mtime == mtime {
                return existing.md5 == nil ? .needsHash(metadataChanged: false) : .upToDate
            }
            if existing.mtime == 0 && existing.md5 != nil { return .adoptMTime }
        }
        return .needsHash(metadataChanged: true)
    }

    /// Walk the drive. Throws only when the scan root itself cannot be listed.
    public func scan(
        options: ScanOptions = ScanOptions(),
        progress: ((ScanProgress) -> Void)? = nil
    ) throws -> ScanResult {
        let startedAt = Date()
        let scanId = try store.beginScan(startedAt: startedAt)
        var state = ScanProgress(filesSeen: 0, filesHashed: 0, bytesHashed: 0, errors: 0, currentPath: nil)
        var adopted = 0
        var work = 0
        var stoppedByLimit = false
        var cancelled = false
        var directoryErrors: [String] = []
        var seen = Set<String>()
        // For every folder listed successfully: the names of the sub-folders it contained.
        var listed: [String: Set<String>] = [:]

        // Housekeeping rows (for example from an older import) and rows outside the scope go first.
        let removedSkipped = try store.removeSkippedDriveFiles()
        let removedOutOfScope = try store.removeDriveFiles(outside: scope)

        func report() { progress?(state) }

        // Depth-first walk with an explicit stack of relative directory paths.
        var stack: [String] = [scope.directoryPath]
        var isRoot = true
        walk: while let relativeDirectory = stack.popLast() {
            let entries: [Entry]
            do {
                entries = try options.retry.attempt { try listDirectory(atRelative: relativeDirectory) }
            } catch {
                if isRoot {
                    try? store.finishScan(
                        id: scanId, filesSeen: state.filesSeen, filesHashed: state.filesHashed, errors: 1)
                    throw DriveScanError.rootUnavailable(
                        path: absolutePath(forRelative: relativeDirectory), reason: "\(error)")
                }
                state.errors += 1
                if directoryErrors.count < 100 {
                    directoryErrors.append("\(relativeDirectory): \(error)")
                }
                report()
                continue
            }
            isRoot = false
            listed[relativeDirectory] = Set(entries.lazy.filter(\.isDirectory).map(\.name))

            var subdirectories: [String] = []
            for entry in entries {
                if entry.isDirectory {
                    if Self.shouldSkip(name: entry.name, isDirectory: true) { continue }
                    subdirectories.append(relativeDirectory.isEmpty ? entry.name : relativeDirectory + "/" + entry.name)
                    continue
                }
                guard entry.isRegularFile, !Self.shouldSkip(name: entry.name, isDirectory: false) else { continue }

                if options.isCancelled() {
                    cancelled = true
                    break walk
                }
                if let limit = options.limit, work >= limit {
                    stoppedByLimit = true
                    break walk
                }

                let relPath = relativeDirectory.isEmpty ? entry.name : relativeDirectory + "/" + entry.name
                seen.insert(relPath)
                state.filesSeen += 1
                state.currentPath = relPath

                do {
                    let existing = try store.driveFile(relPath: relPath)
                    switch decide(existing: existing, size: entry.size, mtime: entry.mtime) {
                    case .upToDate:
                        break
                    case .adoptMTime:
                        try store.updateDriveFileMTime(relPath: relPath, mtime: entry.mtime)
                        adopted += 1
                        work += 1
                    case .needsHash(let metadataChanged):
                        if metadataChanged {
                            try store.upsertDriveFile(DriveFileRecord(
                                relPath: relPath, size: entry.size, mtime: entry.mtime))
                            work += 1
                        }
                        guard options.hash else { break }
                        if !metadataChanged { work += 1 }
                        let absolute = absolutePath(forRelative: relPath)
                        var attemptBytes: Int64 = 0
                        do {
                            let digest = try options.retry.attempt {
                                state.bytesHashed -= attemptBytes
                                attemptBytes = 0
                                return try MD5Hasher.hexDigest(ofFileAtPath: absolute) { count in
                                    attemptBytes += Int64(count)
                                    state.bytesHashed += Int64(count)
                                    report()
                                }
                            }
                            try store.upsertDriveFile(DriveFileRecord(
                                relPath: relPath, size: entry.size, mtime: entry.mtime, md5: digest,
                                hashedAt: Int64(Date().timeIntervalSince1970), lastError: nil))
                            state.filesHashed += 1
                        } catch {
                            state.bytesHashed -= attemptBytes
                            state.errors += 1
                            try store.recordDriveFileError(
                                relPath: relPath, size: entry.size, mtime: entry.mtime,
                                message: Self.describe(error))
                        }
                    }
                } catch {
                    // A failure of the state database itself is not recoverable per file.
                    try? store.finishScan(
                        id: scanId, filesSeen: state.filesSeen, filesHashed: state.filesHashed,
                        errors: state.errors + 1)
                    throw error
                }
                report()
            }
            // Push in reverse so directories are visited in name order.
            stack.append(contentsOf: subdirectories.reversed())
        }

        var pruned = 0
        if !stoppedByLimit && !cancelled {
            pruned = try pruneUnseen(seen: seen, listed: listed)
        }

        let finishedAt = Date()
        try store.finishScan(
            id: scanId, finishedAt: finishedAt, filesSeen: state.filesSeen,
            filesHashed: state.filesHashed, errors: state.errors)
        return ScanResult(
            scanId: scanId, startedAt: startedAt, finishedAt: finishedAt,
            filesSeen: state.filesSeen, filesHashed: state.filesHashed, bytesHashed: state.bytesHashed,
            filesAdopted: adopted, errors: state.errors, directoryErrors: directoryErrors,
            stoppedByLimit: stoppedByLimit, cancelled: cancelled, removedSkipped: removedSkipped,
            removedOutOfScope: removedOutOfScope, pruned: pruned)
    }

    /// Delete rows for files that were not seen. A row is only removed when a successful listing
    /// proves it is gone: its own folder was listed and lacks the file, or an ancestor folder was
    /// listed and lacks the sub-folder that led to it. A folder whose listing failed (or was never
    /// reached) never causes pruning, so a drive that drops out cannot mark real backups as missing.
    private func pruneUnseen(seen: Set<String>, listed: [String: Set<String>]) throws -> Int {
        var doomed: [String] = []
        try store.forEachDriveFilePath(in: scope) { relPath in
            if seen.contains(relPath) { return }
            if Self.isProvablyGone(relPath, scopeRoot: scope.directoryPath, listed: listed) {
                doomed.append(relPath)
            }
        }
        return try store.deleteDriveFiles(doomed)
    }

    static func isProvablyGone(_ relPath: String, scopeRoot: String, listed: [String: Set<String>]) -> Bool {
        let below = scopeRoot.isEmpty
            ? relPath
            : String(decoding: relPath.utf8.dropFirst(scopeRoot.utf8.count + 1), as: UTF8.self)
        var folders = below.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !folders.isEmpty else { return false }
        folders.removeLast()  // the file name itself

        var directory = scopeRoot
        guard var contents = listed[directory] else { return false }
        for folder in folders {
            if !contents.contains(folder) { return true }  // the folder is gone from a good listing
            directory = directory.isEmpty ? folder : directory + "/" + folder
            guard let next = listed[directory] else { return false }  // listing failed or not reached
            contents = next
        }
        return true  // the file's own folder was listed and does not contain it
    }

    static func describe(_ error: Error) -> String {
        if let posix = error as? POSIXError {
            return "\(String(cString: strerror(posix.code.rawValue))) (errno \(posix.code.rawValue))"
        }
        return "\(error)"
    }
}
