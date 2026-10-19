import Foundation

/// User configuration stored in `config.json`.
public struct Config: Codable, Sendable, Equatable {
    /// Mount point (or folder) of the backup drive. Nil until `config set-drive` runs.
    public var driveRoot: String?
    /// Optional folder below `driveRoot` that holds the backup. Scans only walk this folder.
    public var scanSubpath: String?
    /// Optional explicit path to the Amazon Photos app index (`amzn1.account.*-cloud.db`).
    public var amazonIndexPath: String?
    /// Host of the Amazon website the downloads talk to; nil means `www.amazon.com`. Other regions
    /// use their own host, for example `www.amazon.co.uk`.
    public var amazonHost: String?
    /// Limits for the downloads engine (see `ThrottleConfig`); the catalog feed reads share the request limit.
    public var throttle: ThrottleConfig
    /// Where the cloud catalog is read from: the desktop app's index, Amazon's web API, or (the
    /// default) the index when it is found and the web API otherwise.
    public var catalogSource: CatalogSourceChoice
    /// Limits for changes to the Amazon library (see `AmazonWritesConfig`).
    public var amazonWrites: AmazonWritesConfig

    public static let defaultAmazonHost = "www.amazon.com"

    public init(
        driveRoot: String? = nil, scanSubpath: String? = nil, amazonIndexPath: String? = nil,
        amazonHost: String? = nil, throttle: ThrottleConfig = ThrottleConfig(),
        catalogSource: CatalogSourceChoice = .auto, amazonWrites: AmazonWritesConfig = AmazonWritesConfig()
    ) {
        self.driveRoot = driveRoot
        self.scanSubpath = scanSubpath
        self.amazonIndexPath = amazonIndexPath
        self.amazonHost = amazonHost
        self.throttle = throttle
        self.catalogSource = catalogSource
        self.amazonWrites = amazonWrites
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        driveRoot = try container.decodeIfPresent(String.self, forKey: .driveRoot)
        scanSubpath = try container.decodeIfPresent(String.self, forKey: .scanSubpath)
        amazonIndexPath = try container.decodeIfPresent(String.self, forKey: .amazonIndexPath)
        amazonHost = try container.decodeIfPresent(String.self, forKey: .amazonHost)
        throttle = try container.decodeIfPresent(ThrottleConfig.self, forKey: .throttle) ?? ThrottleConfig()
        // An unknown value falls back to the default, so a typo in the file never stops the app from starting.
        catalogSource = (try container.decodeIfPresent(String.self, forKey: .catalogSource))
            .flatMap { CatalogSourceChoice(rawValue: $0) } ?? .auto
        // Writes are the riskiest thing the tool does, so a damaged section falls back to the defaults
        // (the 50-step cap) instead of stopping the app from starting.
        amazonWrites = (try? container.decodeIfPresent(AmazonWritesConfig.self, forKey: .amazonWrites)) ?? nil
            ?? AmazonWritesConfig()
    }

    /// The Amazon host to talk to, lowercased.
    public var effectiveAmazonHost: String {
        let host = (amazonHost ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return host.isEmpty ? Self.defaultAmazonHost : host
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
