import Foundation

public enum CatalogError: Error, CustomStringConvertible {
    case indexNotFound(String)
    case snapshotFailed(String)

    public var description: String {
        switch self {
        case .indexNotFound(let detail): return "Amazon Photos app index not found: \(detail)"
        case .snapshotFailed(let detail): return "Could not read the Amazon Photos app index: \(detail)"
        }
    }
}

/// Reads the cloud catalog from the Amazon Photos desktop app's local SQLite index.
///
/// The app keeps the database open and writes to it, so the original is never
/// opened. Each read copies the database, its `-wal` and its `-shm` file into a
/// private temporary directory and opens the copy read-only.
public struct AmazonAppIndexSource: CloudCatalogSource {
    /// Path of the main database file (`amzn1.account.<id>-cloud.db`).
    public let indexPath: String
    public var sourceName: String { "Amazon Photos app index" }

    public init(indexPath: String) {
        self.indexPath = indexPath
    }

    // MARK: Locating the index

    /// Folder where the Amazon Photos Mac app keeps its databases.
    public static func defaultSupportDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/Amazon Cloud Drive", isDirectory: true)
    }

    /// Find `amzn1.account.*-cloud.db` in `directory`. With several matches the
    /// most recently modified one wins (newest of the database and its `-wal` file).
    public static func locateIndex(in directory: URL) throws -> String {
        let fileManager = FileManager.default
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw CatalogError.indexNotFound("cannot list \(directory.path): \(error.localizedDescription)")
        }
        let candidates = names.filter { $0.hasPrefix("amzn1.account.") && $0.hasSuffix("-cloud.db") }
        guard !candidates.isEmpty else {
            throw CatalogError.indexNotFound("no amzn1.account.*-cloud.db in \(directory.path)")
        }
        let ranked = candidates.map { name -> (String, Date) in
            let path = directory.appendingPathComponent(name).path
            return (path, modificationDate(ofIndexAt: path) ?? .distantPast)
        }
        return ranked.max { $0.1 < $1.1 }!.0
    }

    /// Resolve the index from an explicit path (config override) or by detection on macOS.
    public static func resolve(explicitPath: String?) throws -> AmazonAppIndexSource {
        if let explicitPath, !explicitPath.isEmpty {
            let expanded = PathUtilities.expandingTilde(explicitPath)
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw CatalogError.indexNotFound(expanded)
            }
            return AmazonAppIndexSource(indexPath: expanded)
        }
        #if os(macOS)
        return AmazonAppIndexSource(indexPath: try locateIndex(in: defaultSupportDirectory()))
        #else
        throw CatalogError.indexNotFound(
            "automatic detection is only available on macOS; set the path with `rainbarrel config set-index`")
        #endif
    }

    /// Catalog freshness: mtime of the `-wal` file, or of the database when there is no `-wal`.
    public static func modificationDate(ofIndexAt path: String) -> Date? {
        let fileManager = FileManager.default
        let wal = path + "-wal"
        let target = fileManager.fileExists(atPath: wal) ? wal : path
        let attributes = try? fileManager.attributesOfItem(atPath: target)
        return attributes?[.modificationDate] as? Date
    }

    public var modifiedAt: Date? { Self.modificationDate(ofIndexAt: indexPath) }

    // MARK: Reading

    /// Rows that count as cloud items: available photos/videos and Live Photo videos with an MD5.
    static let catalogQuery = """
        SELECT id, name, kind, parents, content_md5, content_size, content_date, createdDate, content_extension
        FROM nodes
        WHERE status = 'AVAILABLE'
          AND content_md5 IS NOT NULL AND content_md5 <> ''
          AND (kind = 'FILE' OR (kind = 'ASSET' AND assetType = 'LIVE_VIDEO'))
        """

    public func readCatalog(_ body: (CloudItem) throws -> Void) throws -> CatalogReadResult {
        guard FileManager.default.fileExists(atPath: indexPath) else {
            throw CatalogError.indexNotFound(indexPath)
        }
        // Freshness is taken from the original before copying.
        let modifiedAt = Self.modificationDate(ofIndexAt: indexPath) ?? Date()
        let snapshot = try Snapshot.make(of: indexPath)
        defer { snapshot.cleanUp() }

        let statement = try snapshot.database.prepare(Self.catalogQuery)
        var count = 0
        while try statement.step() {
            guard let item = Self.makeItem(from: statement) else { continue }
            try body(item)
            count += 1
        }
        return CatalogReadResult(
            sourceDescription: indexPath, sourceModifiedAt: modifiedAt, itemCount: count)
    }

    static func makeItem(from row: SQLiteStatement) -> CloudItem? {
        guard let id = row.string(0), let md5 = row.string(4) else { return nil }
        let kindText = row.string(2)
        let kind: CloudItemKind = kindText == "FILE" ? .file : .liveVideo
        let contentDate: Int64? = row.isNull(6) ? nil : row.int64(6)
        let createdDate: Int64? = row.isNull(7) ? nil : row.int64(7)
        return CloudItem(
            nodeId: id,
            kind: kind,
            name: row.string(1) ?? "",
            md5: md5.trimmingCharacters(in: .whitespaces).lowercased(),
            size: row.isNull(5) ? 0 : row.int64(5),
            takenAt: DotNetTicks.takenAt(contentDate: contentDate, createdDate: createdDate),
            ext: row.string(8),
            parentId: firstParentID(in: row.string(3))
        )
    }

    /// First element of the `parents` JSON array (for example `["abc123"]`).
    static func firstParentID(in json: String?) -> String? {
        guard let json else { return nil }
        var iterator = json.makeIterator()
        var inString = false
        var value = ""
        while let character = iterator.next() {
            if !inString {
                if character == "\"" { inString = true }
            } else if character == "\\" {
                if let escaped = iterator.next() { value.append(escaped) }
            } else if character == "\"" {
                return value.isEmpty ? nil : value
            } else {
                value.append(character)
            }
        }
        return nil
    }
}

/// A private copy of the app index in a temporary directory.
struct Snapshot {
    let directory: URL
    let database: SQLiteDatabase

    /// Copy the database, `-wal` and `-shm` side by side and open the copy read-only.
    /// The app may write between the copies, so the result is probed and the copy is
    /// retried (finally without the `-shm`, which SQLite rebuilds from the `-wal`).
    static func make(of indexPath: String, attempts: Int = 3) throws -> Snapshot {
        var lastError: Error = CatalogError.snapshotFailed("no attempt made")
        for attempt in 1...attempts {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rainbarrel-snapshot-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent("cloud.db")
                let suffixes = attempt < attempts ? ["", "-wal", "-shm"] : ["", "-wal"]
                for suffix in suffixes {
                    let source = indexPath + suffix
                    guard FileManager.default.fileExists(atPath: source) else {
                        if suffix.isEmpty { throw CatalogError.indexNotFound(indexPath) }
                        continue
                    }
                    try FileManager.default.copyItem(
                        at: URL(fileURLWithPath: source),
                        to: URL(fileURLWithPath: target.path + suffix))
                }
                let database = try SQLiteDatabase(path: target.path, mode: .readOnly)
                _ = try database.scalarInt64("SELECT COUNT(*) FROM nodes")
                return Snapshot(directory: directory, database: database)
            } catch let error as CatalogError {
                try? FileManager.default.removeItem(at: directory)
                throw error
            } catch {
                try? FileManager.default.removeItem(at: directory)
                lastError = error
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        throw CatalogError.snapshotFailed("\(lastError)")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
