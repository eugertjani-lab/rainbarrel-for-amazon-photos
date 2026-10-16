import Foundation

/// A tool as announced to clients (name, description and JSON Schema for its arguments).
public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// True when the tool changes nothing on disk (neither the state database nor the drive).
    public var readOnly: Bool
}

/// The result of a tool call: JSON or a plain message, and whether it is an error.
public struct ToolCallOutcome: Sendable, Equatable {
    public var text: String
    public var isError: Bool
}

/// The six MCP tools, independent of any transport. A transport lists `definitions` and forwards
/// calls to `call`, which never throws: failures come back as an error outcome with a readable message.
public struct MirrorToolRegistry: Sendable {
    public static let maxListLimit = 500
    public static let maxScanLimit = 5000
    public static let defaultListLimit = 50
    public static let defaultScanLimit = 500

    public let tools: MirrorTools

    public init(tools: MirrorTools = MirrorTools()) {
        self.tools = tools
    }

    // MARK: Definitions

    private static func schema(_ properties: [String: JSONValue] = [:]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ])
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int? = nil, defaultValue: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("integer"), "description": .string(description), "minimum": .int(minimum),
        ]
        if let maximum { fields["maximum"] = .int(maximum) }
        if let defaultValue { fields["default"] = .int(defaultValue) }
        return .object(fields)
    }

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "sync_status",
            description: """
                Compare the Amazon Photos cloud catalog with the backup drive, by MD5, and return the full \
                report as JSON: photo and video totals, how many are in sync (a copy exists on the drive), \
                online only, Live Photo videos split the same way, drive-only files, unhashed and errored \
                drive files, a per-year table, catalog freshness and whether the drive is mounted.
                """,
            inputSchema: schema([
                "refresh": .object([
                    "type": .string("boolean"),
                    "description": .string("Re-read the Amazon Photos app index first. Default: only when the last refresh is more than 10 minutes old."),
                ]),
            ]),
            readOnly: false),
        ToolDefinition(
            name: "list_online_only",
            description: "List photos and videos that exist in the Amazon Photos cloud but have no copy on the backup drive, oldest first. Live Photo videos are not listed. Returns total, offset, limit and items.",
            inputSchema: schema([
                "year": integer("Only items captured in this year (UTC).", minimum: 1, maximum: 9999),
                "limit": integer("Maximum number of items.", minimum: 1, maximum: maxListLimit, defaultValue: defaultListLimit),
                "offset": integer("Number of items to skip.", minimum: 0, defaultValue: 0),
            ]),
            readOnly: true),
        ToolDefinition(
            name: "list_drive_only",
            description: "List hashed files on the backup drive whose MD5 is in neither the cloud photo/video catalog nor the Live Photo video catalog, ordered by path. Returns total, offset, limit and items.",
            inputSchema: schema([
                "limit": integer("Maximum number of items.", minimum: 1, maximum: maxListLimit, defaultValue: defaultListLimit),
                "offset": integer("Number of items to skip.", minimum: 0, defaultValue: 0),
            ]),
            readOnly: true),
        ToolDefinition(
            name: "breakdown_by_year",
            description: "Per-year rows for cloud photos and videos: year (UTC capture date), cloud count, in sync, online only and cloud bytes. Uses the stored catalog without refreshing it.",
            inputSchema: schema(),
            readOnly: true),
        ToolDefinition(
            name: "refresh_catalog",
            description: "Take a fresh snapshot of the Amazon Photos desktop app's local index and replace the stored cloud catalog. Returns photo, video and Live Photo video counts. The app's own files are never modified.",
            inputSchema: schema(),
            readOnly: false),
        ToolDefinition(
            name: "scan_drive",
            description: """
                Incrementally index the backup drive (read-only): record size and modification time of new or \
                changed files and, when hash is true, compute their MD5. Stops after `limit` files needed work so \
                the call returns in reasonable time, and reports whether the whole drive was covered and how many \
                files still have no hash. Call it again to continue. Full scans of a large drive are better run \
                from the command line or the menu-bar app.
                """,
            inputSchema: schema([
                "hash": .object([
                    "type": .string("boolean"), "default": .bool(true),
                    "description": .string("Compute MD5s. False only records sizes and modification times."),
                ]),
                "limit": integer("Stop after this many files needed work.", minimum: 1, maximum: maxScanLimit, defaultValue: defaultScanLimit),
            ]),
            readOnly: false),
    ]

    // MARK: Calls

    /// Run a tool. Never throws.
    public func call(name: String, arguments: [String: JSONValue]?) -> ToolCallOutcome {
        do {
            let args = arguments ?? [:]
            switch name {
            case "sync_status":
                let refresh = try Self.bool(args, "refresh")
                return try ok(tools.syncStatus(refresh: refresh))
            case "list_online_only":
                let year = try Self.int(args, "year", range: 1...9999)
                let limit = try Self.limit(args, defaultValue: Self.defaultListLimit, maximum: Self.maxListLimit)
                let offset = try Self.int(args, "offset", range: 0...Int.max) ?? 0
                return try ok(tools.listOnlineOnly(year: year, limit: limit, offset: offset))
            case "list_drive_only":
                let limit = try Self.limit(args, defaultValue: Self.defaultListLimit, maximum: Self.maxListLimit)
                let offset = try Self.int(args, "offset", range: 0...Int.max) ?? 0
                return try ok(tools.listDriveOnly(limit: limit, offset: offset))
            case "breakdown_by_year":
                return try ok(tools.breakdownByYear())
            case "refresh_catalog":
                return try ok(tools.refreshCatalog())
            case "scan_drive":
                let hash = try Self.bool(args, "hash") ?? true
                let limit = try Self.limit(args, defaultValue: Self.defaultScanLimit, maximum: Self.maxScanLimit)
                return try ok(tools.scanDrive(hash: hash, limit: limit))
            default:
                return ToolCallOutcome(text: "Unknown tool: \(name)", isError: true)
            }
        } catch let error as ToolError {
            return ToolCallOutcome(text: error.message, isError: true)
        } catch {
            return ToolCallOutcome(text: "\(name) failed: \(error)", isError: true)
        }
    }

    private func ok<T: Encodable>(_ value: T) throws -> ToolCallOutcome {
        ToolCallOutcome(text: try JSONOutput.string(value), isError: false)
    }

    // MARK: Argument parsing

    private static func bool(_ args: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = args[key], value != .null else { return nil }
        guard let flag = value.boolValue else { throw ToolError("Argument `\(key)` must be true or false.") }
        return flag
    }

    private static func int(_ args: [String: JSONValue], _ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let value = args[key], value != .null else { return nil }
        guard let number = value.intValue else { throw ToolError("Argument `\(key)` must be a whole number.") }
        guard range.contains(number) else {
            let upper = range.upperBound == Int.max ? "" : " to \(range.upperBound)"
            throw ToolError("Argument `\(key)` must be \(range.lowerBound)\(upper.isEmpty ? " or more" : upper).")
        }
        return number
    }

    /// `limit` defaults when missing and is clamped into 1...maximum.
    private static func limit(_ args: [String: JSONValue], defaultValue: Int, maximum: Int) throws -> Int {
        guard let value = args["limit"], value != .null else { return defaultValue }
        guard let number = value.intValue else { throw ToolError("Argument `limit` must be a whole number.") }
        return min(max(number, 1), maximum)
    }
}
