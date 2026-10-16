import Foundation

/// Where the stored catalog came from.
public enum CatalogOrigin: String, Codable, Sendable, CaseIterable {
    /// The Amazon Photos desktop app's local index.
    case app
    /// Amazon's web API, read with the stored session.
    case web
}

/// The configured choice of catalog source.
public enum CatalogSourceChoice: String, Codable, Sendable, CaseIterable {
    /// The desktop app's index when it is found, the web API otherwise.
    case auto
    case app
    case web

    public static let valueList = "auto, app or web"
}

/// The position in Amazon's change feed that the stored catalog is up to date with, together with
/// the source and the Amazon host it belongs to. A checkpoint is useless for another host.
public struct CatalogCheckpoint: Codable, Sendable, Equatable {
    public var source: CatalogOrigin
    public var host: String
    public var token: String

    public init(source: CatalogOrigin, host: String, token: String) {
        self.source = source
        self.host = host
        self.token = token
    }
}

/// What a read of the change feed found, merged so that the last word about each node wins.
public struct CatalogChangeSet: Sendable, Equatable {
    public private(set) var items: [String: CloudItem] = [:]
    public private(set) var folders: [String: CloudFolder] = [:]
    public private(set) var removed: Set<String> = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty && folders.isEmpty && removed.isEmpty }
    public var upsertCount: Int { items.count + folders.count }

    public mutating func upsert(_ item: CloudItem) {
        removed.remove(item.nodeId)
        folders[item.nodeId] = nil
        items[item.nodeId] = item
    }

    public mutating func upsert(_ folder: CloudFolder) {
        removed.remove(folder.nodeId)
        items[folder.nodeId] = nil
        folders[folder.nodeId] = folder
    }

    public mutating func remove(_ nodeId: String) {
        items[nodeId] = nil
        folders[nodeId] = nil
        removed.insert(nodeId)
    }
}

/// How far a long catalog read has got; for progress lines.
public struct CatalogProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case library, changes }

    public var phase: Phase
    /// Nodes received so far in this phase.
    public var nodes: Int

    public init(phase: Phase, nodes: Int) {
        self.phase = phase
        self.nodes = nodes
    }
}
