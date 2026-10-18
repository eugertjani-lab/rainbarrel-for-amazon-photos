import Foundation

/// Where a file whose content is wanted at `ideal` really goes, given what already sits there.
/// Shared by the dry run (which looks at a simulated drive) and the run (which looks at the real one).
enum OrganizeCollision {
    struct Occupant {
        /// MD5 of the file at the path when the drive index knows it (and the file still matches the index).
        var md5: String?
        /// True when the path is the file being placed (same file, for example a different spelling of the
        /// name on a case-insensitive volume).
        var isSource: Bool
    }

    enum Resolution: Equatable {
        case place(String)
        case alreadyInPlace
        /// The path already holds the same content, so the source is an extra copy.
        case duplicate(of: String)
    }

    static let maxNumber = 9999

    /// Try `ideal`, then `name (2).ext`, `name (3).ext` and so on, like the downloads. A name that
    /// holds different (or unknown) content is passed over, the file itself stays where it is, and a
    /// name that holds the same content makes the source a duplicate. nil when no name is free.
    static func resolve(
        source: String, ideal: String, md5: String, occupant: (String) -> Occupant?
    ) -> Resolution? {
        for number in 1...maxNumber {
            let candidate = number == 1 ? ideal : DownloadPlanner.numbered(ideal, number)
            if candidate == source { return .alreadyInPlace }
            guard let found = occupant(candidate) else { return .place(candidate) }
            if found.isSource { return .alreadyInPlace }
            if let other = found.md5, other == md5 { return .duplicate(of: candidate) }
        }
        return nil
    }
}

/// A drive file as read from the index.
struct OrganizeDriveFile: Equatable {
    var path: String
    var size: Int64
    var mtime: Int64
    var md5: String
}

/// One move of a plan.
struct OrganizePlannedMove: Equatable {
    var nodeId: String
    var kind: CloudItemKind
    var md5: String
    var size: Int64
    /// Modification time from the drive index; the file must still have it when it is moved.
    var mtime: Int64
    var from: String
    /// The path the download layout names, before numbering.
    var idealTo: String
    /// The path the file would get now.
    var to: String
    var resolvedFolders: Bool
}

/// The result of planning: moves in the order a run makes them, and everything that stays.
struct OrganizePlan {
    var moves: [OrganizePlannedMove] = []
    var alreadyInPlace = 0
    var duplicates: [OrganizeDuplicateEntry] = []
    var skips = OrganizeSkipTally()
    var driveOnly = (count: 0, bytes: Int64(0))
    var unhashed = 0
    var empty = 0
    var onlineOnly = 0

    var summary: OrganizeSummary {
        OrganizeSummary(
            toMove: moves.count, toMoveBytes: moves.reduce(0) { $0 + $1.size },
            toUnsorted: moves.filter { !$0.resolvedFolders }.count,
            renamedForCollision: moves.filter { $0.to != $0.idealTo }.count,
            alreadyInPlace: alreadyInPlace, duplicatesLeft: duplicates.count,
            duplicatesLeftBytes: duplicates.reduce(0) { $0 + $1.size },
            driveOnlyUntouched: driveOnly.count, driveOnlyUntouchedBytes: driveOnly.bytes,
            unhashedUntouched: unhashed, emptyUntouched: empty, skipped: skips.groups, skippedTotal: skips.total, onlineOnly: onlineOnly)
    }

    func entry(for move: OrganizePlannedMove) -> OrganizeMoveEntry {
        var notes: [String] = []
        if !move.resolvedFolders { notes.append("cloud folder unknown: goes to the _Unsorted folder") }
        if move.to != move.idealTo { notes.append("the target name holds different content: numbered name") }
        return OrganizeMoveEntry(
            from: move.from, to: move.to, size: move.size, kind: move.kind,
            note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }
}

/// Works out which drive files belong somewhere else in the download layout. Reads the state
/// database and looks at the drive without changing either. No file is hashed: the MD5s come from
/// the drive index, and a file whose size or modification time no longer matches it is left alone.
struct OrganizePlanner {
    let store: StateStore
    let config: Config
    let environment: OrganizeEnvironment
    let driveRoot: String

    init(store: StateStore, config: Config, environment: OrganizeEnvironment) throws {
        self.store = store
        self.config = config
        self.environment = environment
        driveRoot = try DownloadEngine.targetRoot(config: config, options: DownloadOptions())
    }

    private struct Claim {
        var item: CloudItem
        var file: OrganizeDriveFile
        var ideal: String
        var resolvedFolders: Bool
        var order: Int
    }

    func plan() throws -> OrganizePlan {
        guard FileOps.isDirectory(driveRoot) else { throw DownloadError.driveNotMounted(driveRoot) }
        guard try store.cloudItemCount() > 0 else { throw OrganizeError.catalogEmpty }
        guard try store.cloudFolderCount() > 0 else { throw OrganizeError.folderTreeMissing }
        let scope = try DriveScope(scanSubpath: config.scanSubpath)
        let database = store.database
        let driveScope = scope.sqlCondition(column: "d.rel_path")
        var plan = OrganizePlan()

        // The drive files that have a cloud match, by MD5.
        var filesByMD5: [String: [OrganizeDriveFile]] = [:]
        let fileRows = try database.prepare("""
            SELECT d.rel_path, d.size, d.mtime, d.md5 FROM drive_files d
            WHERE d.md5 IS NOT NULL AND d.size > 0 AND \(driveScope)
              AND EXISTS (SELECT 1 FROM cloud_items c WHERE c.md5 = d.md5 AND c.kind IN ('file', 'live_video'))
            """)
        while try fileRows.step() {
            let file = OrganizeDriveFile(
                path: fileRows.string(0) ?? "", size: fileRows.int64(1), mtime: fileRows.int64(2),
                md5: fileRows.string(3) ?? "")
            filesByMD5[file.md5, default: []].append(file)
        }

        // The cloud items that have a copy on the drive, in the order the downloads use (newest first).
        var itemsByMD5: [String: [(item: CloudItem, order: Int)]] = [:]
        var matchedItems = 0
        let itemRows = try database.prepare("""
            SELECT c.node_id, c.kind, c.name, c.md5, c.size, c.taken_at, c.ext, c.parent_id
            FROM cloud_items c
            WHERE c.kind IN ('file', 'live_video')
              AND EXISTS (SELECT 1 FROM drive_files d WHERE d.md5 = c.md5 AND d.size > 0 AND \(driveScope))
            ORDER BY c.taken_at DESC, c.node_id
            """)
        while try itemRows.step() {
            let item = CloudItem(
                nodeId: itemRows.string(0) ?? "",
                kind: itemRows.string(1) == "live_video" ? .liveVideo : .file,
                name: itemRows.string(2) ?? "", md5: itemRows.string(3) ?? "", size: itemRows.int64(4),
                takenAt: itemRows.int64(5), ext: itemRows.string(6), parentId: itemRows.string(7))
            itemsByMD5[item.md5, default: []].append((item, matchedItems))
            matchedItems += 1
        }

        let totalItems = Int(try database.scalarInt64(
            "SELECT COUNT(*) FROM cloud_items WHERE kind IN ('file', 'live_video')") ?? 0)
        plan.onlineOnly = max(totalItems - matchedItems, 0)
        let driveOnlyRow = try database.rows("""
            SELECT COUNT(*), COALESCE(SUM(d.size), 0) FROM drive_files d
            WHERE d.md5 IS NOT NULL AND d.size > 0 AND \(driveScope)
              AND NOT EXISTS (SELECT 1 FROM cloud_items c WHERE c.md5 = d.md5)
            """) { ($0.int(0), $0.int64(1)) }.first
        plan.driveOnly = (driveOnlyRow?.0 ?? 0, driveOnlyRow?.1 ?? 0)
        plan.unhashed = Int(try database.scalarInt64(
            "SELECT COUNT(*) FROM drive_files d WHERE d.md5 IS NULL AND d.size > 0 AND \(driveScope)") ?? 0)
        // Empty files all share one MD5, so they match nothing and stay where they are.
        plan.empty = Int(try database.scalarInt64(
            "SELECT COUNT(*) FROM drive_files d WHERE d.size = 0 AND \(driveScope)") ?? 0)

        // 1. Every cloud item claims at most one drive file with its MD5.
        let builder = try TargetBuilder(store: store, scanSubpath: config.scanSubpath)
        var claims: [Claim] = []
        var leftovers: [(file: OrganizeDriveFile, md5: String)] = []
        for (md5, entries) in itemsByMD5 {
            var free: [String: OrganizeDriveFile] = [:]
            for file in filesByMD5[md5] ?? [] { free[file.path] = file }
            var claimed = [Bool](repeating: false, count: entries.count)
            let targets = entries.map { builder.target(for: $0.item) }
            // A file that already sits at an item's target is that item's file.
            for (index, entry) in entries.enumerated() {
                guard let file = free[targets[index].relPath] else { continue }
                free[file.path] = nil
                claimed[index] = true
                claims.append(Claim(
                    item: entry.item, file: file, ideal: targets[index].relPath,
                    resolvedFolders: targets[index].resolved, order: entry.order))
            }
            // The others take the shortest path, then the first in lexical order.
            for (index, entry) in entries.enumerated() where !claimed[index] {
                guard let file = Self.preferred(Array(free.values)) else { break }
                free[file.path] = nil
                claims.append(Claim(
                    item: entry.item, file: file, ideal: targets[index].relPath,
                    resolvedFolders: targets[index].resolved, order: entry.order))
            }
            for file in free.values { leftovers.append((file, md5)) }
        }
        claims.sort { $0.order < $1.order }

        // 2. Files that are at their target stay; the others are candidates for a move.
        var candidates: [Claim] = []
        var keptAtByMD5: [String: String] = [:]
        for claim in claims {
            if claim.file.path == claim.ideal {
                plan.alreadyInPlace += 1
                if keptAtByMD5[claim.file.md5] == nil { keptAtByMD5[claim.file.md5] = claim.file.path }
            } else {
                candidates.append(claim)
            }
        }

        // A target that another planned move is about to vacate is looked at after that move.
        let leaving = Set(candidates.map(\.file.path))
        let ready = candidates.filter { !leaving.contains($0.ideal) }
        let deferred = candidates.filter { leaving.contains($0.ideal) }

        var vacated = Set<String>()
        var added: [String: String] = [:]  // lower-cased path -> MD5 of the file planned to land there
        for claim in ready + deferred {
            let file = claim.file
            guard let sourceAbsolute = try? PathGuard.resolve(root: driveRoot, relative: file.path) else {
                plan.skips.add(.unsafePath, path: file.path)
                continue
            }
            guard let info = OrganizeFS.info(sourceAbsolute), info.isRegularFile else {
                plan.skips.add(.missing, path: file.path)
                continue
            }
            if file.mtime == 0 {
                plan.skips.add(.unverified, path: file.path)
                continue
            }
            if info.size != file.size || info.mtime != file.mtime {
                plan.skips.add(.changed, path: file.path)
                continue
            }
            guard let targetAbsolute = try? PathGuard.resolve(root: driveRoot, relative: claim.ideal) else {
                plan.skips.add(.unsafePath, path: file.path)
                continue
            }
            if let here = environment.volumeID(sourceAbsolute), let there = environment.volumeID(targetAbsolute),
                here != there
            {
                plan.skips.add(.differentVolume, path: file.path)
                continue
            }
            let resolution = OrganizeCollision.resolve(source: file.path, ideal: claim.ideal, md5: file.md5) { candidate in
                if let md5 = added[candidate.lowercased()] { return .init(md5: md5, isSource: false) }
                if vacated.contains(candidate) { return nil }
                guard let absolute = try? PathGuard.resolve(root: driveRoot, relative: candidate) else {
                    return .init(md5: nil, isSource: false)
                }
                guard let found = OrganizeFS.info(absolute) else { return nil }
                return .init(
                    md5: knownMD5(at: candidate, matching: found),
                    isSource: found.device == info.device && found.inode == info.inode)
            }
            switch resolution {
            case nil:
                plan.skips.add(.noFreeName, path: file.path)
            case .alreadyInPlace?:
                plan.alreadyInPlace += 1
                if keptAtByMD5[file.md5] == nil { keptAtByMD5[file.md5] = file.path }
            case .duplicate(let keptAt)?:
                plan.duplicates.append(OrganizeDuplicateEntry(path: file.path, keptAt: keptAt, size: file.size))
            case .place(let destination)?:
                vacated.insert(file.path)
                added[destination.lowercased()] = file.md5
                if keptAtByMD5[file.md5] == nil { keptAtByMD5[file.md5] = destination }
                plan.moves.append(OrganizePlannedMove(
                    nodeId: claim.item.nodeId, kind: claim.item.kind, md5: file.md5, size: file.size,
                    mtime: file.mtime, from: file.path, idealTo: claim.ideal, to: destination,
                    resolvedFolders: claim.resolvedFolders))
            }
        }

        // 3. Extra copies stay where they are. A copy whose file could not be moved is the one that is kept.
        for claim in claims where keptAtByMD5[claim.file.md5] == nil { keptAtByMD5[claim.file.md5] = claim.file.path }
        for (file, md5) in leftovers.sorted(by: { Self.precedes($0.file.path, $1.file.path) }) {
            plan.duplicates.append(OrganizeDuplicateEntry(
                path: file.path, keptAt: keptAtByMD5[md5] ?? "", size: file.size))
        }
        return plan
    }

    /// The MD5 the index holds for `path`, when the file there still has the size and modification
    /// time the index recorded.
    func knownMD5(at path: String, matching info: OrganizeFileInfo) -> String? {
        guard let record = try? store.driveFile(relPath: path), record.mtime != 0,
            record.size == info.size, record.mtime == info.mtime
        else { return nil }
        return record.md5
    }

    /// The best file to keep: the shortest path, then the first in byte order.
    private static func preferred(_ files: [OrganizeDriveFile]) -> OrganizeDriveFile? {
        files.min { precedes($0.path, $1.path) }
    }

    static func precedes(_ a: String, _ b: String) -> Bool {
        if a.utf8.count != b.utf8.count { return a.utf8.count < b.utf8.count }
        return a.utf8.lexicographicallyPrecedes(b.utf8)
    }
}
