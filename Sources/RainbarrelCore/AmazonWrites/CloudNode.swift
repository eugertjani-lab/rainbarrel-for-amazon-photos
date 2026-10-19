import Foundation

/// One node (file, folder or asset) as `GET /drive/v1/nodes/{id}` describes it, in the typed form that
/// the write client works with.
///
/// Decoding is lenient in the same way as the catalog's own node reader: only `id` is required, and a
/// field that is missing or has an unexpected type counts as absent instead of failing the whole answer.
/// Values this code does not know (a new `kind` or `status`) are kept as `.other` with Amazon's text.
public struct CloudNode: Sendable, Equatable, Hashable, Decodable {
    public enum Kind: Sendable, Equatable, Hashable {
        case file
        case folder
        case asset
        case other(String)

        init(_ text: String) {
            switch text.uppercased() {
            case "FILE": self = .file
            case "FOLDER": self = .folder
            case "ASSET": self = .asset
            default: self = .other(text)
            }
        }

        /// Amazon's own spelling.
        public var text: String {
            switch self {
            case .file: return "FILE"
            case .folder: return "FOLDER"
            case .asset: return "ASSET"
            case .other(let text): return text
            }
        }
    }

    public enum Status: Sendable, Equatable, Hashable {
        case available
        case trash
        case purged
        case other(String)

        init(_ text: String) {
            switch text.uppercased() {
            case "AVAILABLE": self = .available
            case "TRASH": self = .trash
            case "PURGED": self = .purged
            default: self = .other(text)
            }
        }

        /// Amazon's own spelling.
        public var text: String {
            switch self {
            case .available: return "AVAILABLE"
            case .trash: return "TRASH"
            case .purged: return "PURGED"
            case .other(let text): return text
            }
        }
    }

    public var id: String
    public var name: String?
    public var kind: Kind?
    public var status: Status?
    /// The ids of the folders that hold this node. Empty when Amazon gives none (the root has none).
    public var parents: [String]
    /// The node's description; nil when it has none.
    public var description: String?
    /// Lower-case MD5 of the content (files and assets only).
    public var md5: String?
    public var size: Int64?

    public init(
        id: String, name: String? = nil, kind: Kind? = nil, status: Status? = nil, parents: [String] = [],
        description: String? = nil, md5: String? = nil, size: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.parents = parents
        self.description = description
        self.md5 = md5
        self.size = size
    }

    private enum Keys: String, CodingKey {
        case id, name, kind, status, parents, description, contentProperties
    }

    private enum ContentKeys: String, CodingKey {
        case md5, size
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        name = Self.lenient(String.self, container, .name)
        kind = Self.lenient(String.self, container, .kind).map(Kind.init)
        status = Self.lenient(String.self, container, .status).map(Status.init)
        parents = Self.lenient([String].self, container, .parents) ?? []
        description = Self.lenient(String.self, container, .description)
        if let content = try? container.nestedContainer(keyedBy: ContentKeys.self, forKey: .contentProperties) {
            md5 = Self.lenient(String.self, content, .md5)?.lowercased()
            size = Self.size(content)
        }
    }

    private static func lenient<T: Decodable, K: CodingKey>(
        _ type: T.Type, _ container: KeyedDecodingContainer<K>, _ key: K
    ) -> T? {
        (try? container.decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// `size` is a number; whole doubles are accepted too, and so are numbers in quotes.
    private static func size(_ container: KeyedDecodingContainer<ContentKeys>) -> Int64? {
        if let value = lenient(Int64.self, container, .size) { return value }
        if let value = lenient(Double.self, container, .size), value.isFinite, value == value.rounded(),
            abs(value) < 9e15
        {
            return Int64(value)
        }
        if let text = lenient(String.self, container, .size) { return Int64(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
