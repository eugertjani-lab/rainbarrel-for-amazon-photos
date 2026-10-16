import Foundation

public enum SeedImportError: Error, CustomStringConvertible {
    case unreadable(String)
    case badHeader(String)

    public var description: String {
        switch self {
        case .unreadable(let detail): return "Cannot read the hash CSV: \(detail)"
        case .badHeader(let detail): return "Unexpected CSV header: \(detail). Expected path,size,md5,result."
        }
    }
}

public struct SeedImportResult: Sendable, Equatable {
    /// Data rows read (header excluded).
    public var rows: Int
    /// Rows stored with an MD5.
    public var imported: Int
    /// Rows stored without an MD5 and with `last_error` set.
    public var errorRows: Int
    /// Rows too short or without a path; not stored.
    public var skipped: Int
    /// Rows for housekeeping files (see `SkipRules`); not stored.
    public var excluded: Int
    /// Existing rows for housekeeping files that were removed from the state database.
    public var removedExisting: Int
}

/// Imports MD5s computed earlier by another tool: a CSV with the header `path,size,md5,result`.
/// Rows for housekeeping files (desktop.ini, Thumbs.db, ._*, .DS_Store, files inside skipped folders)
/// are ignored, exactly as the scanner ignores them.
/// `path` is relative to `<driveRoot>/<prefix>`. Imported rows get `mtime = 0`, which tells the
/// scanner to keep the hash and only fill in the real mtime when the size still matches.
public enum HashSeedImporter {
    public static func importCSV(
        at url: URL,
        prefix: String,
        into store: StateStore,
        now: Date = Date()
    ) throws -> SeedImportResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SeedImportError.unreadable("\(url.path): \(error.localizedDescription)")
        }
        return try importCSV(bytes: [UInt8](data), prefix: prefix, into: store, now: now)
    }

    public static func importCSV(
        bytes: [UInt8],
        prefix: String,
        into store: StateStore,
        now: Date = Date()
    ) throws -> SeedImportResult {
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hashedAt = Int64(now.timeIntervalSince1970)
        var result = SeedImportResult(rows: 0, imported: 0, errorRows: 0, skipped: 0, excluded: 0, removedExisting: 0)
        var columns: (path: Int, size: Int, md5: Int, result: Int?)?

        try store.database.transaction {
            try CSVParser.parse(bytes) { fields in
                guard let columns else {
                    let names = fields.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    guard let path = names.firstIndex(of: "path"),
                          let size = names.firstIndex(of: "size"),
                          let md5 = names.firstIndex(of: "md5") else {
                        throw SeedImportError.badHeader(fields.joined(separator: ","))
                    }
                    columns = (path, size, md5, names.firstIndex(of: "result"))
                    return
                }
                result.rows += 1
                let needed = max(columns.path, columns.size, columns.md5)
                guard fields.count > needed, !fields[columns.path].isEmpty else {
                    result.skipped += 1
                    return
                }
                let path = fields[columns.path]
                let relPath = trimmedPrefix.isEmpty ? path : trimmedPrefix + "/" + path
                if SkipRules.shouldSkip(relPath: relPath) {
                    result.excluded += 1
                    return
                }
                let size = Int64(fields[columns.size].trimmingCharacters(in: .whitespaces)) ?? -1
                let md5 = fields[columns.md5].trimmingCharacters(in: .whitespaces).lowercased()
                let note = columns.result.flatMap { $0 < fields.count ? fields[$0] : nil } ?? ""

                if size < 0 || md5.isEmpty || !isValidMD5(md5) {
                    let message = note.isEmpty
                        ? (md5.isEmpty ? "seed row has no MD5" : "seed row has an invalid MD5")
                        : note
                    try store.recordDriveFileError(relPath: relPath, size: size, mtime: 0, message: message)
                    result.errorRows += 1
                } else {
                    try store.upsertDriveFile(DriveFileRecord(
                        relPath: relPath, size: size, mtime: 0, md5: md5, hashedAt: hashedAt, lastError: nil))
                    result.imported += 1
                }
            }
        }
        if columns == nil { throw SeedImportError.badHeader("file is empty") }
        result.removedExisting = try store.removeSkippedDriveFiles()
        return result
    }

    static func isValidMD5(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
