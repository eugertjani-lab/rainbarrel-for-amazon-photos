import Foundation

/// Where PhotoMirror keeps its own files.
///
/// macOS: `~/Library/Application Support/PhotoMirror/`
/// Linux: `$XDG_DATA_HOME/photomirror`, falling back to `~/.local/share/photomirror`
///
/// The `PHOTOMIRROR_DATA_DIR` environment variable overrides both, which is
/// useful for tests and for running against a scratch directory.
public struct AppPaths: Sendable, Equatable {
    public let dataDirectory: URL

    public var configURL: URL { dataDirectory.appendingPathComponent("config.json") }
    public var stateURL: URL { dataDirectory.appendingPathComponent("state.sqlite") }

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppPaths {
        if let override = environment["PHOTOMIRROR_DATA_DIR"], !override.isEmpty {
            return AppPaths(dataDirectory: URL(fileURLWithPath: override, isDirectory: true))
        }
        #if os(macOS)
        let directory = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PhotoMirror", isDirectory: true)
        #else
        let base: URL
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = home
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        let directory = base.appendingPathComponent("photomirror", isDirectory: true)
        #endif
        return AppPaths(dataDirectory: directory)
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
