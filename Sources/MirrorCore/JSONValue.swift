import Foundation

/// A JSON value. Used for tool arguments and JSON Schemas so the tool layer needs no transport types.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Integers, and doubles that hold a whole number (some clients send 50.0).
    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value == value.rounded() && abs(value) < 1e15: return Int(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
