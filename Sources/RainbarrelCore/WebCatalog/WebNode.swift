import Foundation

/// One node as Amazon's `/drive/v1` answers describe it. Only the fields the catalog needs are
/// read, and a field of an unexpected type counts as missing instead of failing the whole answer.
struct WebNode: Decodable, Sendable, Equatable {
    struct ContentProperties: Sendable, Equatable {
        var md5: String?
        var size: Int64?
        var contentDate: String?
        var fileExtension: String?
    }

    var id: String
    var name: String?
    var kind: String?
    var status: String?
    var isRoot: Bool?
    var parents: [String]?
    var createdDate: String?
    var contentProperties: ContentProperties?
    var assetType: String?

    init(
        id: String, name: String? = nil, kind: String? = nil, status: String? = nil, isRoot: Bool? = nil,
        parents: [String]? = nil, createdDate: String? = nil, contentProperties: ContentProperties? = nil,
        assetType: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.isRoot = isRoot
        self.parents = parents
        self.createdDate = createdDate
        self.contentProperties = contentProperties
        self.assetType = assetType
    }

    private enum Keys: String, CodingKey {
        case id, name, kind, status, isRoot, parents, createdDate, contentProperties, assetProperties
    }

    private enum ContentKeys: String, CodingKey {
        case md5, size, contentDate, `extension`
    }

    private enum AssetKeys: String, CodingKey {
        case assetType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        name = Self.lenient(String.self, container, .name)
        kind = Self.lenient(String.self, container, .kind)
        status = Self.lenient(String.self, container, .status)
        isRoot = Self.lenient(Bool.self, container, .isRoot)
        parents = Self.lenient([String].self, container, .parents)
        createdDate = Self.lenient(String.self, container, .createdDate)
        if let content = try? container.nestedContainer(keyedBy: ContentKeys.self, forKey: .contentProperties) {
            contentProperties = ContentProperties(
                md5: Self.lenient(String.self, content, .md5),
                size: Self.size(content),
                contentDate: Self.lenient(String.self, content, .contentDate),
                fileExtension: Self.lenient(String.self, content, .extension))
        }
        // `assetProperties` is null for most assets.
        if let asset = try? container.nestedContainer(keyedBy: AssetKeys.self, forKey: .assetProperties) {
            assetType = Self.lenient(String.self, asset, .assetType)
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

/// The array of nodes in an answer. A node that cannot be read is counted and passed over, so one odd
/// node never fails a page of 200.
struct LossyNodes: Decodable, Sendable, Equatable {
    var nodes: [WebNode] = []
    var undecodable = 0

    private struct Discard: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init() {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let node = try? container.decode(WebNode.self) {
                nodes.append(node)
            } else {
                // A failed decode does not move the container on; this does.
                _ = try? container.decode(Discard.self)
                undecodable += 1
            }
        }
    }
}

/// What a node means for the catalog.
enum WebNodeDisposition: Equatable {
    case folder(CloudFolder)
    case item(CloudItem)
    /// A photo, video or Live Photo video without a usable MD5 or size: not in the catalog.
    case skipped
    /// Not part of the catalog (other assets, unknown kinds).
    case ignored
    /// Trashed, purged or otherwise not available.
    case removed
}

/// Turns web nodes into the catalog values that the desktop index source produces for the same
/// library.
enum WebNodeMapping {
    static func disposition(of node: WebNode) -> WebNodeDisposition {
        if let status = node.status?.uppercased(), status != "AVAILABLE" { return .removed }
        switch node.kind?.uppercased() {
        case "FOLDER":
            return .folder(CloudFolder(
                nodeId: node.id, name: node.name ?? "",
                parentId: node.isRoot == true ? nil : firstParent(of: node)))
        case "FILE":
            return item(from: node, kind: .file).map { .item($0) } ?? .skipped
        case "ASSET":
            guard node.assetType?.uppercased() == "LIVE_VIDEO" else { return .ignored }
            return item(from: node, kind: .liveVideo).map { .item($0) } ?? .skipped
        default:
            return .ignored
        }
    }

    static func item(from node: WebNode, kind: CloudItemKind) -> CloudItem? {
        guard let content = node.contentProperties,
            let md5 = content.md5?.trimmingCharacters(in: .whitespaces).lowercased(),
            HashSeedImporter.isValidMD5(md5), let size = content.size, size >= 0
        else { return nil }
        let name = node.name ?? ""
        return CloudItem(
            nodeId: node.id, kind: kind, name: name, md5: md5, size: size,
            takenAt: WebDate.unixSeconds(content.contentDate) ?? WebDate.unixSeconds(node.createdDate) ?? 0,
            ext: fileExtension(of: content, name: name), parentId: firstParent(of: node))
    }

    private static func firstParent(of node: WebNode) -> String? {
        guard let first = node.parents?.first, !first.isEmpty else { return nil }
        return first
    }

    /// The catalog's extension, else the one in the file name (without its dot). Like the desktop
    /// index source, the case is kept as Amazon has it.
    private static func fileExtension(of content: WebNode.ContentProperties, name: String) -> String? {
        if let ext = content.fileExtension?.trimmingCharacters(in: .whitespaces), !ext.isEmpty { return ext }
        let fromName = FileNameSanitizer.split(name).ext
        return fromName.isEmpty ? nil : String(fromName.dropFirst())
    }
}

/// ISO-8601 timestamps as Amazon writes them: `2019-04-24T05:53:46.264Z`, with or without the
/// fraction, with `Z` or an offset. Parsed by hand, so it behaves the same on every platform and is
/// cheap enough for hundreds of thousands of nodes.
enum WebDate {
    /// Unix seconds (the fraction is dropped), or nil when the text is not a timestamp.
    static func unixSeconds(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let bytes = Array(text.utf8)
        var index = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let digit = Int(bytes[index + offset]) - 48
                guard digit >= 0, digit <= 9 else { return nil }
                value = value * 10 + digit
            }
            index += count
            return value
        }
        func expect(_ characters: [UInt8]) -> Bool {
            guard index < bytes.count, characters.contains(bytes[index]) else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), expect([45]), let month = digits(2), expect([45]), let day = digits(2),
            expect([84, 116, 32]), let hour = digits(2), expect([58]), let minute = digits(2), expect([58]),
            let second = digits(2)
        else { return nil }
        guard (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
            hour < 24, minute < 60, second <= 60
        else { return nil }
        if index < bytes.count, bytes[index] == 46 {  // fraction: digits only, ignored
            index += 1
            let start = index
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
            guard index > start else { return nil }
        }
        var offsetSeconds = 0
        if index < bytes.count {
            if bytes[index] == 90 || bytes[index] == 122 {  // Z
                index += 1
            } else if bytes[index] == 43 || bytes[index] == 45 {  // +hh:mm, +hhmm or +hh
                let sign = bytes[index] == 45 ? -1 : 1
                index += 1
                guard let offsetHour = digits(2) else { return nil }
                _ = expect([58])
                let offsetMinute = index < bytes.count ? (digits(2) ?? -1) : 0
                guard offsetHour < 24, (0..<60).contains(offsetMinute) else { return nil }
                offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
            } else {
                return nil
            }
        }
        guard index == bytes.count else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        return Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second - offsetSeconds)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = (month + 9) % 12
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
