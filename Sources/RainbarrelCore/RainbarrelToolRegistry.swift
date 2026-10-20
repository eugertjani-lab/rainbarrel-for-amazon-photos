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

/// The eleven MCP tools, independent of any transport. A transport lists `definitions` and forwards
/// calls to `call`, which never throws: failures come back as an error outcome with a readable message.
public struct RainbarrelToolRegistry: Sendable {
    public static let maxListLimit = 500
    public static let maxScanLimit = 5000
    public static let defaultListLimit = 50
    public static let defaultScanLimit = 500
    public static let maxBatchLimit = 50
    public static let defaultBatchLimit = 10

    public let tools: RainbarrelTools

    public init(tools: RainbarrelTools = RainbarrelTools()) {
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
                online only (with onlineOnlyDistinctBytes, the space a full mirror still needs), Live Photo \
                videos split the same way, drive-only files, unhashed and errored drive files, a per-year \
                table, catalog freshness and source (catalogSource: app or web), whether the drive is \
                mounted and, when it is, its capacity (driveSpace). Files that are only online can be \
                fetched with download_batch.
                """,
            inputSchema: schema([
                "refresh": .object([
                    "type": .string("boolean"),
                    "description": .string("Refresh the cloud catalog first (from the Amazon Photos app index or the web API, as configured). Default: only when the last refresh is more than 10 minutes old. The first refresh from the web API lists the whole library and can take a long while."),
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
            description: """
                Refresh the stored cloud catalog and return photo, video and Live Photo video counts, the \
                source that was read (app or web) and whether the whole catalog was read (full) or only the \
                changes since the last refresh (incremental). The source is the Amazon Photos desktop app's \
                local index (never modified; a private snapshot is read) or Amazon's web API through the \
                signed-in session; by default the app index when it exists and the web API otherwise. \
                Fails with a clear message while a download is running. The first web read drains the whole \
                change feed and can take a long while; warnings (for example a file count that differs \
                from Amazon's) come back in the answer.
                """,
            inputSchema: schema([
                "source": .object([
                    "type": .string("string"),
                    "enum": .array([.string("auto"), .string("app"), .string("web")]),
                    "description": .string("Where to read the catalog from. Default: the configured source (auto unless changed)."),
                ]),
            ]),
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
        ToolDefinition(
            name: "download_status",
            description: """
                Report the state of the downloads: queue counts (pending, downloading, done, failed, skipped \
                and online-only items not queued yet), failed files grouped by reason (how many wait for a \
                retry and when the next try is, how many failed for good), recent failures with reasons, the \
                last run's summary, the Amazon session (signed in or not, host, when it was saved, no cookie \
                values), the throttle settings, the target folder and whether the drive is mounted and \
                writable. Makes no network call and writes nothing.
                """,
            inputSchema: schema(),
            readOnly: true),
        ToolDefinition(
            name: "download_batch",
            description: """
                Download the newest photos and videos that are missing from the backup drive, wait until the \
                batch is finished, and return how many files were downloaded, adopted, skipped and failed, with \
                one entry per file. Every file is checked by MD5 before it counts as backed up, existing files \
                are never overwritten or deleted, and the configured throttle limits apply. Fails with a clear \
                message when the Amazon session is missing or expired, when the drive is not mounted or is \
                read-only (for example NTFS on macOS), or when the active hours are closed. For large amounts \
                use `rainbarrel download` on the command line.
                """,
            inputSchema: schema([
                "year": integer("Only items captured in this year (UTC).", minimum: 1, maximum: 9999),
                "limit": integer("Maximum number of files to start.", minimum: 1, maximum: maxBatchLimit, defaultValue: defaultBatchLimit),
            ]),
            readOnly: false),
        ToolDefinition(
            name: "organize_preview",
            description: """
                Dry run of `rainbarrel organize`: which files that are already on the backup drive would be \
                moved into the folder layout the downloads use (<scan folder>/<cloud folder path>/<file name>, \
                matched to the catalog by the MD5s in the drive index). Returns counts (files to move, already \
                in place, extra copies that stay, drive-only files that are never touched, files skipped with \
                the reason) and a sample of moves with paths relative to the drive root. Makes no network \
                call and changes nothing; moving the files is only possible with `rainbarrel organize --apply`.
                """,
            inputSchema: schema([
                "sample": integer("How many example moves to return.", minimum: 0, maximum: OrganizeService.maxSampleSize, defaultValue: OrganizeService.defaultSampleSize),
            ]),
            readOnly: true),
        ToolDefinition(
            name: "plan_create_cleanup_empty",
            description: """
                Make a draft plan that moves every photo and video of the catalog that was uploaded empty \
                (0 bytes) to Amazon's trash, and return the plan with its summary (steps, bytes, how many \
                are ticked). Reads the stored catalog and writes only the draft to Rainbarrel's own \
                database: nothing is sent to Amazon, and there is no tool that applies a plan. The person \
                reviews the plan and applies it in the app or with `rainbarrel apply <id>`; every \
                step is checked against Amazon again right before it runs, and an applied plan can be \
                undone. Rainbarrel never empties Amazon's trash. Returns created=false when there is no \
                empty file.
                """,
            inputSchema: schema(),
            readOnly: false),
        ToolDefinition(
            name: "plan_show",
            description: """
                Show a plan made by Rainbarrel: its title, status (draft, applying, applied, partlyApplied, \
                undone), counts per operation with bytes, how many steps are ticked and in which state, and a \
                sample of the first steps with what each does, why, and how it went. Makes no network call \
                and changes nothing.
                """,
            inputSchema: schema([
                "id": integer("The plan id, as `plan_create_cleanup_empty` or `rainbarrel plan list` shows it.", minimum: 1),
                "sample": integer("How many of the first steps to return.", minimum: 0, maximum: PlanService.maxStepSample, defaultValue: PlanService.defaultStepSample),
            ]),
            readOnly: true),
    ]

    // MARK: Calls

    /// Run a tool and wait for the result; safe to call from any thread that is not part of Swift's
    /// cooperative pool. The tools that may use the network (`download_batch`, `refresh_catalog`, and
    /// `sync_status` unless it is told not to refresh) are waited for with a semaphore here;
    /// transports should use `callAsync`. Never throws.
    public func call(name: String, arguments: [String: JSONValue]?) -> ToolCallOutcome {
        if Self.needsAsync(name, arguments) {
            let box = OutcomeBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached { [self] in
                box.outcome = await callAsync(name: name, arguments: arguments)
                semaphore.signal()
            }
            semaphore.wait()
            return box.outcome ?? ToolCallOutcome(text: "\(name) failed", isError: true)
        }
        do {
            let args = arguments ?? [:]
            switch name {
            case "sync_status":
                // Only `refresh: false` gets here; every other call may use the network.
                return try ok(tools.currentReport())
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
            case "scan_drive":
                let hash = try Self.bool(args, "hash") ?? true
                let limit = try Self.limit(args, defaultValue: Self.defaultScanLimit, maximum: Self.maxScanLimit)
                return try ok(tools.scanDrive(hash: hash, limit: limit))
            case "download_status":
                return try ok(tools.downloadStatus())
            case "organize_preview":
                let sample = try Self.int(args, "sample", range: 0...OrganizeService.maxSampleSize)
                return try ok(tools.organizePreview(sample: sample ?? OrganizeService.defaultSampleSize))
            case "plan_create_cleanup_empty":
                return try ok(tools.planCreateCleanupEmpty())
            case "plan_show":
                guard let id = try Self.int(args, "id", range: 1...Int.max) else {
                    throw ToolError("Argument `id` is required.")
                }
                let sample = try Self.int(args, "sample", range: 0...PlanService.maxStepSample)
                return try ok(tools.planShow(id: Int64(id), sample: sample ?? PlanService.defaultStepSample))
            default:
                return ToolCallOutcome(text: "Unknown tool: \(name)", isError: true)
            }
        } catch let error as ToolError {
            return ToolCallOutcome(text: error.message, isError: true)
        } catch let error as OrganizeError {
            return ToolCallOutcome(text: error.description, isError: true)
        } catch {
            return ToolCallOutcome(text: "\(name) failed: \(error)", isError: true)
        }
    }

    /// Tools that may wait for the network; `call` runs them through `callAsync`.
    private static func needsAsync(_ name: String, _ arguments: [String: JSONValue]?) -> Bool {
        switch name {
        case "download_batch", "refresh_catalog": return true
        case "sync_status": return arguments?["refresh"]?.boolValue != false
        default: return false
        }
    }

    /// Run a tool without blocking a cooperative thread: blocking tools run on a dispatch thread and
    /// the tools that wait for the network (`sync_status`, `refresh_catalog`, `download_batch`) run as
    /// plain async calls. Never throws.
    public func callAsync(name: String, arguments: [String: JSONValue]?) async -> ToolCallOutcome {
        guard ["download_batch", "refresh_catalog", "sync_status"].contains(name) else {
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: call(name: name, arguments: arguments))
                }
            }
        }
        do {
            let args = arguments ?? [:]
            switch name {
            case "refresh_catalog":
                return try ok(await tools.refreshCatalog(source: try Self.catalogSource(args)))
            case "sync_status":
                return try ok(await tools.syncStatus(refresh: try Self.bool(args, "refresh")))
            default:
                let year = try Self.int(args, "year", range: 1...9999)
                let limit = try Self.limit(args, defaultValue: Self.defaultBatchLimit, maximum: Self.maxBatchLimit)
                return try ok(await tools.downloadBatch(limit: limit, year: year))
            }
        } catch let error as ToolError {
            return ToolCallOutcome(text: error.message, isError: true)
        } catch let error as DownloadError {
            return ToolCallOutcome(text: error.description, isError: true)
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

    private static func catalogSource(_ args: [String: JSONValue]) throws -> CatalogSourceChoice? {
        guard let value = args["source"], value != .null else { return nil }
        guard let text = value.stringValue, let choice = CatalogSourceChoice(rawValue: text.lowercased()) else {
            throw ToolError("Argument `source` must be \(CatalogSourceChoice.valueList).")
        }
        return choice
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

/// Carries the result of `download_batch` from the task that ran it to the waiting caller.
private final class OutcomeBox: @unchecked Sendable {
    var outcome: ToolCallOutcome?
}
