import Foundation

/// Looks at the stored catalog and proposes changes to the Amazon library as the steps of a plan.
/// A planner reads the database only: it never talks to Amazon and changes nothing.
public protocol Planner: Sendable {
    /// Short stable name stored with the plan, for example `cleanup-empty`.
    var identifier: String { get }
    /// What a person sees in a list of plans.
    var title: String { get }
    /// The steps, in the order they should run. Empty when there is nothing to do.
    func steps(in store: StateStore) throws -> [PlanStepDraft]
}

/// Trashes the files that were uploaded empty: every photo and video of the catalog whose size is 0
/// bytes (and Live Photo videos of that size, if any). An empty file has no content to lose, and the
/// trash keeps even that reversible.
public struct EmptyFileCleanupPlanner: Planner {
    public static let identifier = "cleanup-empty"
    public static let reason = "empty file (0 bytes)"
    /// The group label of a file in a folder that the catalog cannot trace back to the root.
    public static let unknownFolderLabel = "(unknown folder)"
    /// The group label of a file at the top of the library.
    public static let topLevelLabel = "(top level)"

    public var identifier: String { Self.identifier }
    public var title: String { "Trash empty files" }

    public init() {}

    public func steps(in store: StateStore) throws -> [PlanStepDraft] {
        let builder = try TargetBuilder(store: store, scanSubpath: nil)
        let items = try store.database.rows(
            """
            SELECT node_id, kind, name, md5, size, taken_at, ext, parent_id
            FROM cloud_items WHERE size = 0 AND kind IN ('file', 'live_video')
            """,
            map: { row in
                CloudItem(
                    nodeId: row.string(0) ?? "", kind: row.string(1) == "live_video" ? .liveVideo : .file,
                    name: row.string(2) ?? "", md5: row.string(3) ?? "", size: row.int64(4),
                    takenAt: row.int64(5), ext: row.string(6), parentId: row.string(7))
            })

        var drafts: [(label: String, draft: PlanStepDraft)] = []
        for item in items {
            let target = builder.target(for: item)
            let folders = target.relPath.split(separator: "/", omittingEmptySubsequences: false).dropLast()
            let label: String
            let path: String
            if !target.resolved {
                label = Self.unknownFolderLabel
                path = label + "/" + item.name
            } else if folders.isEmpty {
                label = Self.topLevelLabel
                path = item.name
            } else {
                label = folders.joined(separator: "/")
                path = label + "/" + item.name
            }
            drafts.append((
                label,
                PlanStepDraft(
                    operation: .trash, nodeId: item.nodeId, fromValue: path, reason: Self.reason,
                    groupLabel: label, size: item.size,
                    before: PlanSnapshot(
                        parent: item.parentId, name: item.name, status: CloudNode.Status.available.text,
                        md5: item.md5.lowercased()),
                    catalogItem: item)))
        }
        // Folder by folder, then by name, so that a plan reads like the library does.
        drafts.sort { left, right in
            if left.label != right.label { return left.label < right.label }
            let leftName = left.draft.before.name ?? ""
            let rightName = right.draft.before.name ?? ""
            if leftName != rightName { return leftName < rightName }
            return (left.draft.nodeId ?? "") < (right.draft.nodeId ?? "")
        }
        return drafts.map(\.draft)
    }
}
