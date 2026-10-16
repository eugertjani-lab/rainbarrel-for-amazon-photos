import Foundation

/// Kind of cloud item tracked in the state store.
public enum CloudItemKind: String, Codable, Sendable {
    /// A photo or video file.
    case file
    /// The video half of a Live Photo.
    case liveVideo = "live_video"
}

/// One item of the cloud catalog.
public struct CloudItem: Codable, Sendable, Equatable {
    public var nodeId: String
    public var kind: CloudItemKind
    public var name: String
    public var md5: String
    public var size: Int64
    /// Capture time (Unix seconds, UTC). 0 when the catalog has no usable date.
    public var takenAt: Int64
    public var ext: String?
    /// First parent node: the containing folder for files, the still image for Live Photo videos.
    public var parentId: String?

    public init(
        nodeId: String, kind: CloudItemKind, name: String, md5: String, size: Int64,
        takenAt: Int64, ext: String? = nil, parentId: String? = nil
    ) {
        self.nodeId = nodeId
        self.kind = kind
        self.name = name
        self.md5 = md5
        self.size = size
        self.takenAt = takenAt
        self.ext = ext
        self.parentId = parentId
    }
}

/// One folder of the cloud tree. The root folder has no parent.
public struct CloudFolder: Codable, Sendable, Equatable {
    public var nodeId: String
    public var name: String
    public var parentId: String?

    public init(nodeId: String, name: String, parentId: String? = nil) {
        self.nodeId = nodeId
        self.name = name
        self.parentId = parentId
    }
}

/// Metadata about one read of a catalog source.
public struct CatalogReadResult: Sendable, Equatable {
    /// Human-readable description of where the catalog came from.
    public var sourceDescription: String
    /// When the source was last changed (mtime of the `-wal` file, or of the database when there is none).
    public var sourceModifiedAt: Date
    public var itemCount: Int
    /// Number of folder nodes that were read (0 for sources that do not provide the folder tree).
    public var folderCount: Int
    /// Photo and video nodes that were left out because they lack an MD5 or a size.
    public var skippedCount: Int
    /// Position in Amazon's change feed at the end of the read; only the web API source sets it.
    public var checkpoint: CatalogCheckpoint?
    /// Things the user should know about a catalog that was stored anyway.
    public var warnings: [String]

    public init(
        sourceDescription: String, sourceModifiedAt: Date, itemCount: Int, folderCount: Int = 0,
        skippedCount: Int = 0, checkpoint: CatalogCheckpoint? = nil, warnings: [String] = []
    ) {
        self.sourceDescription = sourceDescription
        self.sourceModifiedAt = sourceModifiedAt
        self.itemCount = itemCount
        self.folderCount = folderCount
        self.skippedCount = skippedCount
        self.checkpoint = checkpoint
        self.warnings = warnings
    }
}

/// A provider of the cloud catalog that has to wait for a network, so reading it suspends. The web
/// API source is the one implementation; sources that read a local file use `CloudCatalogSource`.
public protocol AsyncCloudCatalogSource {
    /// Short name for messages, for example "Amazon Photos web API".
    var sourceName: String { get }

    /// Stage the folder tree and every photo, video and Live Photo video of the account in `staging`.
    /// Whatever is thrown leaves the staging area's owner to roll back; it must not be used afterwards.
    func readCatalog(into staging: CloudCatalogStaging) async throws -> CatalogReadResult
}

/// A provider of the cloud catalog. The Amazon Photos app's local index is the
/// first implementation; the web API source (`AsyncCloudCatalogSource`) is the second.
public protocol CloudCatalogSource {
    /// Short name for messages, for example "Amazon Photos app index".
    var sourceName: String { get }

    /// Stream every photo, video and Live Photo video of the account to `body`.
    func readCatalog(_ body: (CloudItem) throws -> Void) throws -> CatalogReadResult

    /// Like `readCatalog(_:)`, but also streams the folder tree to `folders` first. The downloads
    /// engine needs the folder names to rebuild the cloud paths on the drive.
    func readCatalog(
        folders: (CloudFolder) throws -> Void, items: (CloudItem) throws -> Void
    ) throws -> CatalogReadResult
}

extension CloudCatalogSource {
    /// Sources without a folder tree read only the items.
    public func readCatalog(
        folders: (CloudFolder) throws -> Void, items: (CloudItem) throws -> Void
    ) throws -> CatalogReadResult {
        try readCatalog(items)
    }
}
