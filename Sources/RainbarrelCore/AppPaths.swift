import Foundation

/// Where Rainbarrel keeps its own files.
///
/// macOS: `~/Library/Application Support/Rainbarrel/`
/// Linux: `$XDG_DATA_HOME/rainbarrel`, falling back to `~/.local/share/rainbarrel`
///
/// The `RAINBARREL_DATA_DIR` environment variable overrides both, which is useful for tests and
/// for running against a scratch directory. The old name `PHOTOMIRROR_DATA_DIR` is still honoured
/// as a deprecated fallback.
///
/// Before the project was renamed the data lived in `PhotoMirror` (macOS) or `photomirror`
/// (Linux). When the new directory does not exist yet and the old one does, `default` moves the
/// old directory to the new path, so the database, its -wal/-shm files, the configuration and the
/// seed CSV all travel together.
public struct AppPaths: Sendable, Equatable {
    public let dataDirectory: URL

    public var configURL: URL { dataDirectory.appendingPathComponent("config.json") }
    public var stateURL: URL { dataDirectory.appendingPathComponent("state.sqlite") }
    /// Where the Amazon session lives when it is kept in a file instead of the Keychain.
    public var sessionURL: URL { dataDirectory.appendingPathComponent("session.json") }
    /// Held (with `flock`) by the process that is downloading, so two runs never overlap.
    public var downloadLockURL: URL { dataDirectory.appendingPathComponent("download.lock") }

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    #if os(macOS)
    static let directoryName = "Rainbarrel"
    static let legacyDirectoryName = "PhotoMirror"
    #else
    static let directoryName = "rainbarrel"
    static let legacyDirectoryName = "photomirror"
    #endif

    /// Called with the old and the new directory after the legacy data directory was moved.
    public typealias MigrationNotice = @Sendable (_ from: URL, _ to: URL) -> Void

    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        onMigration: MigrationNotice? = nil
    ) -> AppPaths {
        for key in ["RAINBARREL_DATA_DIR", "PHOTOMIRROR_DATA_DIR"] {
            if let override = environment[key], !override.isEmpty {
                return AppPaths(dataDirectory: URL(fileURLWithPath: override, isDirectory: true))
            }
        }
        #if os(macOS)
        let base = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        #else
        let base: URL
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = home
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        #endif
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        return AppPaths(dataDirectory: migrateLegacyDirectory(from: legacy, to: directory, onMigration: onMigration))
    }

    /// Move the pre-rename data directory to its new path when only the old one exists, and return
    /// the directory to use. One atomic rename on the same volume; nothing is copied or deleted.
    /// When the move fails and the new directory is still missing, the old directory stays in use
    /// so that no data seems to vanish.
    static func migrateLegacyDirectory(
        from legacy: URL, to directory: URL, onMigration: MigrationNotice? = nil
    ) -> URL {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard !fileManager.fileExists(atPath: directory.path),
            fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return directory }
        do {
            try fileManager.createDirectory(
                at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: directory)
            onMigration?(legacy, directory)
            return directory
        } catch {
            // Another process may have moved the directory meanwhile; the new one then wins.
            if fileManager.fileExists(atPath: directory.path) { return directory }
            return legacy
        }
    }

    /// Create the data directory when missing. Never removes or replaces anything.
    public func ensureDataDirectory() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    }
}

/// Small path helpers that avoid NSString so they behave the same on macOS and Linux.
public enum PathUtilities {
    /// Replace a leading `~` or `~/` with the home directory.
    public static func expandingTilde(
        _ path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return join(home, String(path.dropFirst(2))) }
        return path
    }

    /// Join two path pieces with exactly one `/` between them.
    public static func join(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        if component.isEmpty { return base }
        let left = base.hasSuffix("/") ? String(base.dropLast()) : base
        let right = component.hasPrefix("/") ? String(component.dropFirst()) : component
        return left + "/" + right
    }
}
