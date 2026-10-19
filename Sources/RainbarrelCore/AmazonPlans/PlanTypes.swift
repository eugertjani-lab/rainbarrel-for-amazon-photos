import Foundation

/// What one step of a plan does to one node of the Amazon library. There is no purge: trashing is the
/// strongest change Rainbarrel makes.
public enum PlanOperation: String, Codable, Sendable, CaseIterable {
    case createFolder
    case move
    case rename
    case describe
    case trash
    case restore

    /// A verb for lists and headlines.
    public var verb: String {
        switch self {
        case .createFolder: return "create"
        case .move: return "move"
        case .rename: return "rename"
        case .describe: return "describe"
        case .trash: return "trash"
        case .restore: return "restore"
        }
    }

    /// The count with its noun: "1 folder", "192 items".
    func counted(_ count: Int) -> String {
        let number = DisplayFormat.number(count)
        switch self {
        case .createFolder: return "\(number) \(count == 1 ? "folder" : "folders")"
        case .describe: return "\(number) \(count == 1 ? "description" : "descriptions")"
        default: return "\(number) \(count == 1 ? "item" : "items")"
        }
    }
}

/// Where a plan stands as a whole.
public enum PlanStatus: String, Codable, Sendable {
    /// Made and reviewable; nothing has been sent to Amazon.
    case draft
    /// A run is writing to Amazon right now (or was cut off while it did).
    case applying
    /// Every ticked step has been dealt with: done, or skipped because the node changed meanwhile.
    case applied
    /// Some ticked steps are still waiting or failed, or an undo could not reverse every step.
    case partlyApplied
    /// Every step that had been done was reversed.
    case undone

    public var text: String {
        switch self {
        case .draft: return "draft"
        case .applying: return "applying"
        case .applied: return "applied"
        case .partlyApplied: return "partly applied"
        case .undone: return "undone"
        }
    }
}

/// Where one step stands.
public enum PlanStepState: String, Codable, Sendable, CaseIterable {
    case pending
    case done
    /// Not applied, because the node no longer looks like it did when the plan was made.
    case skippedChanged
    /// Amazon refused or the run could not go on; the text is in `result`. Apply tries it again.
    case failed
    case undone

    public var text: String {
        switch self {
        case .pending: return "pending"
        case .done: return "done"
        case .skippedChanged: return "skipped (changed meanwhile)"
        case .failed: return "failed"
        case .undone: return "undone"
        }
    }
}

/// What a node looked like at one moment: the values that the drift check compares. A nil field is
/// not compared.
public struct PlanSnapshot: Codable, Sendable, Equatable {
    public var parent: String?
    public var name: String?
    /// Amazon's spelling: AVAILABLE or TRASH.
    public var status: String?
    /// Lower-case MD5 of the content; files only.
    public var md5: String?

    public init(parent: String? = nil, name: String? = nil, status: String? = nil, md5: String? = nil) {
        self.parent = parent
        self.name = name
        self.status = status
        self.md5 = md5
    }
}

/// A step as a planner proposes it, before it belongs to a plan.
///
/// Which fields an operation uses:
///
///     createFolder  parentId = the folder to create it in, toValue = the new name
///     move          nodeId, parentId = the destination folder, fromValue / toValue = old and new folder
///                   path (for display), before.parent = the folder it is in now
///     rename        nodeId, fromValue / toValue = old and new name
///     describe      nodeId, toValue = the new description (fromValue = the old one, when known)
///     trash         nodeId, fromValue = where it is (for display)
///     restore       nodeId
public struct PlanStepDraft: Sendable, Equatable {
    public var operation: PlanOperation
    public var nodeId: String?
    public var parentId: String?
    public var fromValue: String?
    public var toValue: String?
    /// In plain words, shown on the review screen.
    public var reason: String
    /// What a review screen groups by, usually the folder path.
    public var groupLabel: String?
    /// Bytes this step concerns, for the totals.
    public var size: Int64
    public var before: PlanSnapshot
    /// The catalog row of the node when the plan was made, so that undo can put it back.
    public var catalogItem: CloudItem?

    public init(
        operation: PlanOperation, nodeId: String? = nil, parentId: String? = nil, fromValue: String? = nil,
        toValue: String? = nil, reason: String, groupLabel: String? = nil, size: Int64 = 0,
        before: PlanSnapshot = PlanSnapshot(), catalogItem: CloudItem? = nil
    ) {
        self.operation = operation
        self.nodeId = nodeId
        self.parentId = parentId
        self.fromValue = fromValue
        self.toValue = toValue
        self.reason = reason
        self.groupLabel = groupLabel
        self.size = size
        self.before = before
        self.catalogItem = catalogItem
    }
}

/// One step of a stored plan, with its state and, once it ran, its result.
public struct PlanStep: Codable, Sendable, Equatable {
    public var planId: Int64
    /// 1-based position in the plan; steps run in this order.
    public var position: Int
    public var operation: PlanOperation
    public var nodeId: String?
    public var parentId: String?
    public var fromValue: String?
    public var toValue: String?
    public var reason: String
    public var groupLabel: String?
    public var size: Int64
    /// Unticked steps are never applied.
    public var included: Bool
    public var before: PlanSnapshot
    public var state: PlanStepState
    /// A sentence about what happened, or why nothing did.
    public var result: String?
    /// What the node looked like right after the step ran; undo checks it before it reverses the step.
    public var after: PlanSnapshot?
    /// What undo puts back: the old name, the old description or the folder it was moved out of.
    public var inverseValue: String?
    /// The folder that a `createFolder` step made (or found).
    public var createdNodeId: String?
    /// True when a `createFolder` step found the folder already there and did not make it, so undo
    /// leaves it alone.
    public var reusedExisting: Bool
    public var catalogItem: CloudItem?
    public var updatedAt: Date?

    /// A line for lists: what the step does to what.
    public var summaryLine: String {
        switch operation {
        case .createFolder:
            return "create folder \"\(toValue ?? "")\""
        case .move:
            return "move \(fromValue ?? nodeId ?? "?") to \(toValue ?? "?")"
        case .rename:
            return "rename \"\(fromValue ?? "")\" to \"\(toValue ?? "")\""
        case .describe:
            return "set the description of \(fromValue ?? nodeId ?? "?")"
        case .trash:
            return "trash \(fromValue ?? nodeId ?? "?")"
        case .restore:
            return "restore \(fromValue ?? nodeId ?? "?")"
        }
    }
}

/// How many steps of one operation a plan has, split by whether they are ticked.
public struct PlanOperationCount: Codable, Sendable, Equatable {
    public var operation: PlanOperation
    public var included: Int
    public var excluded: Int
    public var includedBytes: Int64
    public var excludedBytes: Int64
}

/// How many steps are in each state.
public struct PlanStateCounts: Codable, Sendable, Equatable {
    public var pending = 0
    public var done = 0
    public var skippedChanged = 0
    public var failed = 0
    public var undone = 0

    public var total: Int { pending + done + skippedChanged + failed + undone }

    mutating func add(_ state: PlanStepState, _ count: Int) {
        switch state {
        case .pending: pending += count
        case .done: done += count
        case .skippedChanged: skippedChanged += count
        case .failed: failed += count
        case .undone: undone += count
        }
    }
}

/// The counts that a review screen shows above a plan.
public struct PlanSummary: Codable, Sendable, Equatable {
    /// One entry for every operation the plan uses, in the order of `PlanOperation.allCases`.
    public var operations: [PlanOperationCount]
    public var includedSteps: Int
    public var excludedSteps: Int
    public var includedBytes: Int64
    public var excludedBytes: Int64
    /// All steps, ticked or not.
    public var states: PlanStateCounts
    /// Ticked steps that an apply would still run: pending, or failed and to be tried again.
    public var remainingToApply: Int
    /// Steps that were done and that an undo would reverse.
    public var reversible: Int

    public var totalSteps: Int { includedSteps + excludedSteps }

    public func count(of operation: PlanOperation) -> PlanOperationCount? {
        operations.first { $0.operation == operation }
    }

    /// "Trash 192 items (0 B)", with every ticked operation in one line, and the unticked steps
    /// counted at the end.
    public var headline: String {
        var parts: [String] = []
        for entry in operations where entry.included > 0 {
            var text = "\(entry.operation.verb) \(entry.operation.counted(entry.included))"
            if entry.operation == .trash || entry.operation == .restore {
                text += " (\(DisplayFormat.bytes(entry.includedBytes)))"
            }
            parts.append(text)
        }
        guard !parts.isEmpty else { return excludedSteps > 0 ? "No steps are ticked" : "No steps" }
        var line = parts.joined(separator: ", ")
        line = line.prefix(1).uppercased() + line.dropFirst()
        if excludedSteps > 0 { line += "; \(DisplayFormat.number(excludedSteps)) unticked" }
        return line
    }
}

/// A stored plan: the header row and its summary.
public struct Plan: Codable, Sendable, Equatable {
    public var id: Int64
    /// Which planner made it, for example `cleanup-empty`.
    public var planner: String
    public var title: String
    public var createdAt: Date
    /// When the catalog the plan was made from was last refreshed.
    public var catalogRefreshedAt: Date?
    public var status: PlanStatus
    public var appliedAt: Date?
    public var undoneAt: Date?
    public var summary: PlanSummary
}

/// A set of steps that a review screen shows together: one folder, one operation.
public struct PlanGroup: Codable, Sendable, Equatable {
    public var label: String?
    public var operation: PlanOperation
    public var included: Int
    public var excluded: Int
    public var bytes: Int64
}

/// What can go wrong with a plan before or around its run, as a sentence for a person.
public enum PlanError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    case notFound(Int64)
    case cannotApply(status: PlanStatus, reason: String)
    case cannotUndo(status: PlanStatus, reason: String)
    case nothingToDo(String)

    public var description: String {
        switch self {
        case .notFound(let id):
            return "There is no plan with id \(id). `rainbarrel plan list` shows the plans."
        case .cannotApply(_, let reason), .cannotUndo(_, let reason), .nothingToDo(let reason):
            return reason
        }
    }

    public var errorDescription: String? { description }
}
