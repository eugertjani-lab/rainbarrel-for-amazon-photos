import Foundation

/// User configuration stored in `config.json`.
public struct Config: Codable, Sendable, Equatable {
    /// Mount point (or folder) of the backup drive. Nil until `config set-drive` runs.
    public var driveRoot: String?
    /// Optional folder below `driveRoot` that holds the backup. Scans only walk this folder.
    public var scanSubpath: String?
    /// Optional explicit path to the Amazon Photos app index (`amzn1.account.*-cloud.db`).
    public var amazonIndexPath: String?

    public init(driveRoot: String? = nil, scanSubpath: String? = nil, amazonIndexPath: String? = nil) {
        self.driveRoot = driveRoot
        self.scanSubpath = scanSubpath
        self.amazonIndexPath = amazonIndexPath
    }

    /// The folder a scan walks: `driveRoot` plus `scanSubpath` when set.
    public var scanRootPath: String? {
        guard let driveRoot, !driveRoot.isEmpty else { return nil }
        guard let scanSubpath, !scanSubpath.isEmpty else { return driveRoot }
        return PathUtilities.join(driveRoot, scanSubpath)
    }
}

public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Load the config; a missing file yields an empty configuration.
    public func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Write the config atomically, creating the parent directory when missing.
    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
