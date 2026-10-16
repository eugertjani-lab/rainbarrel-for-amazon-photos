import Foundation
#if canImport(Glibc)
import Glibc
#endif

public struct OrganizeOptions: Sendable, Equatable {
    /// Stop after this many files were moved.
    public var limit: Int?
    /// Remove the folders this run emptied.
    public var pruneEmptyDirs: Bool

    public init(limit: Int? = nil, pruneEmptyDirs: Bool = false) {
        self.limit = limit
        self.pruneEmptyDirs = pruneEmptyDirs
    }
}

/// Makes the moves of a plan and keeps the journal. Every move is a rename(2) inside one volume: no
/// file is copied, overwritten or deleted. Each move is checked again just before it is made, because
/// the drive may have changed since the plan was drawn up.
final class OrganizeExecutor {
    private let store: StateStore
    private let driveRoot: String
    private let scanFolder: String
    private let environment: OrganizeEnvironment
    /// Moves are committed to the database in batches of this size (and at the end of a run).
    static let batchSize = 25
    /// A run stops after this many failed moves in a row, which means the drive is in trouble.
    static let maxConsecutiveFailures = 25

    init(store: StateStore, driveRoot: String, scanFolder: String, environment: OrganizeEnvironment) {
        self.store = store
        self.driveRoot = driveRoot
        self.scanFolder = scanFolder
        self.environment = environment
    }

    // MARK: Batches

    private struct JournalEntry {
        var from: String
        var to: String
        var size: Int64
        var mtime: Int64
        var movedAt: Int64
    }

    private struct Batch {
        var entries: [JournalEntry] = []
        var directories: [String] = []
        var isEmpty: Bool { entries.isEmpty && directories.isEmpty }
    }

    private func nextRunId() throws -> Int64 {
        let highest = try store.database.scalarInt64("""
            SELECT MAX(m) FROM (SELECT MAX(run_id) AS m FROM organize_moves
                                UNION ALL SELECT MAX(run_id) FROM organize_dirs)
            """)
        return (highest ?? 0) + 1
    }

    /// Commit the moves of a batch: the drive index follows the files and the journal remembers them.
    private func flush(_ batch: inout Batch, runId: Int64) throws {
        guard !batch.isEmpty else { return }
        let entries = batch.entries
        let directories = batch.directories
        try store.database.transaction {
            let database = store.database
            let dropStale = try database.prepare("DELETE FROM drive_files WHERE rel_path = ?")
            let relocate = try database.prepare("UPDATE drive_files SET rel_path = ? WHERE rel_path = ?")
            let journal = try database.prepare("""
                INSERT INTO organize_moves(run_id, from_path, to_path, moved_at, size, mtime)
                VALUES(?, ?, ?, ?, ?, ?)
                """)
            let folder = try database.prepare("INSERT INTO organize_dirs(run_id, path) VALUES(?, ?)")
            for entry in entries {
                // A row at the target path can only be left over from a file that is gone.
                try dropStale.run([entry.to])
                try relocate.run([entry.to, entry.from])
                try journal.run([runId, entry.from, entry.to, entry.movedAt, entry.size, entry.mtime])
            }
            for path in directories { try folder.run([runId, path]) }
        }
        batch = Batch()
    }

    // MARK: One move

    private enum Outcome {
        case moved(to: String, createdDirectories: [String])
        case alreadyInPlace
        case duplicate
        case skipped(OrganizeSkipReason, detail: String?)
        case failed(code: Int32, message: String)
    }

    private func relative(_ absolute: String) -> String {
        absolute.hasPrefix(driveRoot + "/") ? String(absolute.dropFirst(driveRoot.count + 1)) : absolute
    }

    private func occupant(at candidate: String, source: OrganizeFileInfo) -> OrganizeCollision.Occupant? {
        guard let absolute = try? PathGuard.resolve(root: driveRoot, relative: candidate) else {
            return .init(md5: nil, isSource: false)
        }
        guard let found = OrganizeFS.info(absolute) else { return nil }
        var md5: String?
        if let record = try? store.driveFile(relPath: candidate), record.mtime != 0,
            record.size == found.size, record.mtime == found.mtime
        {
            md5 = record.md5
        }
        return .init(md5: md5, isSource: found.device == source.device && found.inode == source.inode)
    }

    private func perform(_ move: OrganizePlannedMove) -> Outcome {
        guard let sourceAbsolute = try? PathGuard.resolve(root: driveRoot, relative: move.from) else {
            return .skipped(.unsafePath, detail: nil)
        }
        guard let info = OrganizeFS.info(sourceAbsolute), info.isRegularFile else {
            return .skipped(.missing, detail: nil)
        }
        guard move.mtime != 0 else { return .skipped(.unverified, detail: nil) }
        guard info.size == move.size, info.mtime == move.mtime else { return .skipped(.changed, detail: nil) }

        for _ in 0..<8 {
            let resolution = OrganizeCollision.resolve(source: move.from, ideal: move.idealTo, md5: move.md5) {
                occupant(at: $0, source: info)
            }
            guard let resolution else { return .skipped(.noFreeName, detail: nil) }
            switch resolution {
            case .alreadyInPlace:
                return .alreadyInPlace
            case .duplicate:
                return .duplicate
            case .place(let destination):
                guard let targetAbsolute = try? PathGuard.resolve(root: driveRoot, relative: destination) else {
                    return .skipped(.unsafePath, detail: nil)
                }
                if let here = environment.volumeID(sourceAbsolute), let there = environment.volumeID(targetAbsolute),
                    here != there
                {
                    return .skipped(.differentVolume, detail: nil)
                }
                let parent = PathGuard.parent(of: targetAbsolute)
                let created = OrganizeFS.missingDirectories(for: parent, below: driveRoot)
                do {
                    try FileOps.makeDirectories(parent)
                } catch {
                    removeEmptyDirectories(created)
                    return .failed(code: FileOps.isMountedReadOnly(path: driveRoot) ? EROFS : 0, message: "\(error)")
                }
                switch OrganizeFS.renameWithoutReplacing(sourceAbsolute, to: targetAbsolute) {
                case .done:
                    return .moved(to: destination, createdDirectories: created.map(relative))
                case .targetExists:
                    removeEmptyDirectories(created)
                    continue  // somebody put a file there since we looked: choose again
                case .crossDevice:
                    removeEmptyDirectories(created)
                    return .skipped(.differentVolume, detail: nil)
                case .failed(let code, let message):
                    removeEmptyDirectories(created)
                    return .failed(code: code, message: message)
                }
            }
        }
        return .skipped(.failed, detail: "the target name kept changing")
    }

    /// Remove folders (deepest first, as `missingDirectories` lists them outermost first) that are empty.
    private func removeEmptyDirectories(_ directories: [String]) {
        for directory in directories.reversed() { _ = rmdir(directory) }
    }

    // MARK: Apply

    func apply(
        plan: OrganizePlan, options: OrganizeOptions, isCancelled: () -> Bool,
        progress: (OrganizeProgress) -> Void
    ) throws -> OrganizeRunResult {
        let started = environment.now()
        let runId = try nextRunId()
        var skips = plan.skips
        var batch = Batch()
        var moved = 0
        var movedBytes: Int64 = 0
        var inPlace = plan.alreadyInPlace
        var duplicates = plan.duplicates.count
        var movedFrom: [String] = []
        var stop: OrganizeStopReason?
        var consecutiveFailures = 0
        var handled = 0

        func finish(fatal: Error?) throws {
            try flush(&batch, runId: runId)
            if let fatal { throw fatal }
        }

        do {
            for move in plan.moves {
                if let limit = options.limit, moved >= limit {
                    stop = .limit
                    break
                }
                if isCancelled() {
                    stop = .cancelled
                    break
                }
                progress(OrganizeProgress(phase: .moving, done: handled, total: plan.moves.count, currentPath: move.from))
                handled += 1
                switch perform(move) {
                case .moved(let destination, let created):
                    consecutiveFailures = 0
                    moved += 1
                    movedBytes += move.size
                    movedFrom.append(move.from)
                    batch.entries.append(JournalEntry(
                        from: move.from, to: destination, size: move.size, mtime: move.mtime,
                        movedAt: Int64(environment.now().timeIntervalSince1970)))
                    batch.directories.append(contentsOf: created)
                    if batch.entries.count >= Self.batchSize { try flush(&batch, runId: runId) }
                case .alreadyInPlace:
                    inPlace += 1
                case .duplicate:
                    duplicates += 1
                case .skipped(let reason, let detail):
                    skips.add(reason, path: move.from, detail: detail)
                case .failed(let code, let message):
                    skips.add(.failed, path: move.from, detail: message)
                    if code == EROFS {
                        try finish(fatal: DownloadError.targetNotWritable(path: scanFolder, detail: nil))
                    }
                    if !FileOps.isDirectory(driveRoot) { try finish(fatal: DownloadError.driveUnavailable) }
                    consecutiveFailures += 1
                    if consecutiveFailures >= Self.maxConsecutiveFailures {
                        stop = .tooManyErrors
                    }
                }
                if stop != nil { break }
            }
        } catch {
            try? flush(&batch, runId: runId)
            throw error
        }
        try flush(&batch, runId: runId)

        var pruned = 0
        if options.pruneEmptyDirs, !movedFrom.isEmpty {
            progress(OrganizeProgress(phase: .pruning, done: moved, total: plan.moves.count, currentPath: nil))
            pruned = pruneEmptied(afterMovingFrom: movedFrom)
        }
        return OrganizeRunResult(
            runId: moved > 0 ? runId : nil, moved: moved, movedBytes: movedBytes, alreadyInPlace: inPlace,
            duplicatesLeft: duplicates, skipped: skips.groups, skippedTotal: skips.total, prunedFolders: pruned,
            remaining: max(plan.moves.count - handled, 0), stopReason: stop,
            durationSeconds: environment.now().timeIntervalSince(started))
    }

    /// Remove the folders that the moves left empty, and the parents that became empty because of
    /// that, never the scan folder itself or anything above it. Only `rmdir` is used, so a folder
    /// that still holds anything (a `.DS_Store` file included) stays.
    private func pruneEmptied(afterMovingFrom sources: [String]) -> Int {
        let scanRelative = relative(scanFolder)
        func isInside(_ directory: String) -> Bool {
            scanFolder == driveRoot ? !directory.isEmpty : directory.hasPrefix(scanRelative + "/")
        }
        func depth(_ directory: String) -> Int { directory.split(separator: "/").count }
        var levels: [Int: Set<String>] = [:]
        for source in sources {
            guard let slash = source.lastIndex(of: "/") else { continue }
            let directory = String(source[..<slash])
            if isInside(directory) { levels[depth(directory), default: []].insert(directory) }
        }
        var removed = 0
        guard var level = levels.keys.max() else { return 0 }
        while level >= 1 {
            for directory in (levels[level] ?? []).sorted() {
                guard let absolute = try? PathGuard.resolve(root: driveRoot, relative: directory),
                    let info = OrganizeFS.info(absolute), info.isDirectory,
                    (try? FileManager.default.contentsOfDirectory(atPath: absolute))?.isEmpty == true,
                    rmdir(absolute) == 0
                else { continue }
                removed += 1
                if let slash = directory.lastIndex(of: "/") {
                    let parent = String(directory[..<slash])
                    if isInside(parent) { levels[depth(parent), default: []].insert(parent) }
                }
            }
            level -= 1
        }
        return removed
    }

    // MARK: Undo

    private struct StoredMove {
        var rowid: Int64
        var from: String
        var to: String
        var size: Int64?
        var mtime: Int64?
    }

    /// Reverse the last run: every file goes back to where it was, unless it was changed or its old
    /// place is taken, in which case the entry is refused and stays in the journal.
    func undo(isCancelled: () -> Bool, progress: (OrganizeProgress) -> Void) throws -> OrganizeUndoResult {
        let database = store.database
        guard let runId = try database.scalarInt64("SELECT MAX(run_id) FROM organize_moves") else {
            throw OrganizeError.nothingToUndo
        }
        let entries = try database.rows("""
            SELECT rowid, from_path, to_path, size, mtime FROM organize_moves
            WHERE run_id = ? ORDER BY rowid DESC
            """, [runId]) { row in
            StoredMove(
                rowid: row.int64(0), from: row.string(1) ?? "", to: row.string(2) ?? "",
                size: row.isNull(3) ? nil : row.int64(3), mtime: row.isNull(4) ? nil : row.int64(4))
        }

        var restored = 0
        var refused: [OrganizeUndoRefusal] = []
        var cancelled = false
        var done: [StoredMove] = []

        func commit() throws {
            guard !done.isEmpty else { return }
            let finished = done
            try database.transaction {
                let dropStale = try database.prepare("DELETE FROM drive_files WHERE rel_path = ?")
                let relocate = try database.prepare("UPDATE drive_files SET rel_path = ? WHERE rel_path = ?")
                let forget = try database.prepare("DELETE FROM organize_moves WHERE rowid = ?")
                for entry in finished {
                    try dropStale.run([entry.from])
                    try relocate.run([entry.from, entry.to])
                    try forget.run([entry.rowid])
                }
            }
            done = []
        }

        do {
            for (index, entry) in entries.enumerated() {
                if isCancelled() {
                    cancelled = true
                    break
                }
                progress(OrganizeProgress(phase: .undoing, done: index, total: entries.count, currentPath: entry.to))
                if let reason = undoOne(entry) {
                    refused.append(OrganizeUndoRefusal(path: entry.to, reason: reason))
                    continue
                }
                restored += 1
                done.append(entry)
                if done.count >= Self.batchSize { try commit() }
            }
        } catch {
            try? commit()
            throw error
        }
        try commit()

        // The folders the run created go too, when they are empty again.
        var removedFolders = 0
        let recorded = try database.rows(
            "SELECT path FROM organize_dirs WHERE run_id = ?", [runId]) { $0.string(0) ?? "" }
        for directory in recorded.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            guard let absolute = try? PathGuard.resolve(root: driveRoot, relative: directory) else { continue }
            guard FileOps.exists(absolute) else { continue }
            if rmdir(absolute) == 0 { removedFolders += 1 }
        }
        let remaining = try database.scalarInt64(
            "SELECT COUNT(*) FROM organize_moves WHERE run_id = ?", [runId]) ?? 0
        if remaining == 0 { try database.run("DELETE FROM organize_dirs WHERE run_id = ?", [runId]) }
        return OrganizeUndoResult(
            runId: runId, restored: restored, refused: refused, removedFolders: removedFolders, cancelled: cancelled)
    }

    /// Move one file back. Returns nil when it was moved, otherwise why it was not.
    private func undoOne(_ entry: StoredMove) -> String? {
        guard let currentAbsolute = try? PathGuard.resolve(root: driveRoot, relative: entry.to),
            let originalAbsolute = try? PathGuard.resolve(root: driveRoot, relative: entry.from)
        else { return "the path is outside the backup folder" }
        guard let info = OrganizeFS.info(currentAbsolute), info.isRegularFile else {
            return "the file is no longer there"
        }
        if let size = entry.size, let mtime = entry.mtime, info.size != size || info.mtime != mtime {
            return "the file was changed after it was moved"
        }
        if FileOps.exists(originalAbsolute) { return "something else is at the original place now" }
        if let here = environment.volumeID(currentAbsolute), let there = environment.volumeID(originalAbsolute),
            here != there
        {
            return "the original place is on a different volume"
        }
        let parent = PathGuard.parent(of: originalAbsolute)
        let created = OrganizeFS.missingDirectories(for: parent, below: driveRoot)
        do { try FileOps.makeDirectories(parent) } catch {
            removeEmptyDirectories(created)
            return "the original folder cannot be created: \(error)"
        }
        switch OrganizeFS.renameWithoutReplacing(currentAbsolute, to: originalAbsolute) {
        case .done:
            return nil
        case .targetExists:
            removeEmptyDirectories(created)
            return "something else is at the original place now"
        case .crossDevice:
            removeEmptyDirectories(created)
            return "the original place is on a different volume"
        case .failed(_, let message):
            removeEmptyDirectories(created)
            return message
        }
    }
}
