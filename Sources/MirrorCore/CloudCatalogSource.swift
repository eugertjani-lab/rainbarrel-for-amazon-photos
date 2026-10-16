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

/// Metadata about one read of a catalog source.
public struct CatalogReadResult: Sendable, Equatable {
    /// Human-readable description of where the catalog came from.
    public var sourceDescription: String
    /// When the source was last changed (mtime of the `-wal` file, or of the database when there is none).
    public var sourceModifiedAt: Date
    public var itemCount: Int

    public init(sourceDescription: String, sourceModifiedAt: Date, itemCount: Int) {
        self.sourceDescription = sourceDescription
        self.sourceModifiedAt = sourceModifiedAt
        self.itemCount = itemCount
    }
}

/// A provider of the cloud catalog. The Amazon Photos app's local index is the
/// first implementation; a web API source can plug in later.
public protocol CloudCatalogSource {
    /// Short name for messages, for example "Amazon Photos app index".
    var sourceName: String { get }

    /// Stream every photo, video and Live Photo video of the account to `body`.
    func readCatalog(_ body: (CloudItem) throws -> Void) throws -> CatalogReadResult
}
