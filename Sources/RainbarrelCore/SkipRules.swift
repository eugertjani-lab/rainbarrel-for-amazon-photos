import Foundation

/// Operating-system housekeeping that never holds photos and is excluded from scans and hash imports.
public enum SkipRules {
    /// Folder names (lowercased) that are skipped at any depth.
    public static let directoryNames: Set<String> = [
        "$recycle.bin", "system volume information", ".spotlight-v100", ".fseventsd", ".trashes",
        ".temporaryitems",
    ]
    /// File names (lowercased) that are skipped. Files starting with `._` are skipped as well.
    public static let fileNames: Set<String> = [".ds_store", "desktop.ini", "thumbs.db"]

    /// True when a single folder or file name is housekeeping.
    public static func shouldSkip(name: String, isDirectory: Bool) -> Bool {
        let lowered = name.lowercased()
        if isDirectory { return directoryNames.contains(lowered) }
        return lowered.hasPrefix("._") || fileNames.contains(lowered)
    }

    /// True when a drive-relative file path lies inside a skipped folder or names a skipped file.
    public static func shouldSkip(relPath: String) -> Bool {
        let parts = relPath.split(separator: "/", omittingEmptySubsequences: true)
        guard let name = parts.last else { return false }
        for folder in parts.dropLast() where shouldSkip(name: String(folder), isDirectory: true) {
            return true
        }
        return shouldSkip(name: String(name), isDirectory: false)
    }
}

/// The part of the drive that Rainbarrel tracks: the whole drive, or the folder named by the
/// scan subpath. Drive rows outside the scope are ignored by reports and removed by the next scan.
public struct DriveScope: Sendable, Equatable {
    public let components: [String]

    /// - Throws: `DriveScanError.invalidSubpath` when the subpath contains `..`.
    public init(scanSubpath: String?) throws {
        var parts: [String] = []
        for part in (scanSubpath ?? "").split(separator: "/") where part != "." {
            if part == ".." { throw DriveScanError.invalidSubpath(scanSubpath ?? "") }
            parts.append(String(part))
        }
        components = parts
    }

    public static let wholeDrive = try! DriveScope(scanSubpath: nil)

    public var isWholeDrive: Bool { components.isEmpty }

    /// Drive-relative folder path without a trailing slash; empty for the whole drive.
    public var directoryPath: String { components.joined(separator: "/") }

    /// True when `relPath` is inside the scope (compared byte for byte, like the database does).
    public func contains(_ relPath: String) -> Bool {
        isWholeDrive || relPath.utf8.starts(with: (directoryPath + "/").utf8)
    }

    /// SQL condition selecting rows of `column` that lie inside the scope. Every path below
    /// "dir/" sorts between "dir/" and "dir0" because "0" is the character after "/".
    public func sqlCondition(column: String) -> String {
        guard !isWholeDrive else { return "1" }
        let lower = Self.quote(directoryPath + "/")
        let upper = Self.quote(directoryPath + "0")
        return "(\(column) >= \(lower) AND \(column) < \(upper))"
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
