import Foundation

/// Which steps of a plan a call is about. Every field that is set must match.
public struct PlanStepFilter: Sendable, Equatable {
    public var operation: PlanOperation?
    public var state: PlanStepState?
    public var included: Bool?
    /// The group label exactly as the planner wrote it (usually a folder path).
    public var group: String?
    /// Part of a path or name, ignoring case.
    public var search: String?

    public init(
        operation: PlanOperation? = nil, state: PlanStepState? = nil, included: Bool? = nil, group: String? = nil,
        search: String? = nil
    ) {
        self.operation = operation
        self.state = state
        self.included = included
        self.group = group
        self.search = search
    }

    /// The WHERE clause (without the plan id) and its arguments.
    fileprivate var clause: (sql: String, args: [any SQLiteBindable]) {
        var parts: [String] = []
        var args: [any SQLiteBindable] = []
        if let operation {
            parts.append("operation = ?")
            args.append(operation.rawValue)
        }
        if let state {
            parts.append("state = ?")
            args.append(state.rawValue)
        }
        if let included {
            parts.append("included = ?")
            args.append(included ? 1 : 0)
        }
        if let group {
            parts.append("group_label = ?")
            args.append(group)
        }
        if let search, !search.isEmpty {
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            parts.append("""
                (from_value LIKE ? ESCAPE '\\' OR to_value LIKE ? ESCAPE '\\' OR group_label LIKE ? ESCAPE '\\' \
                OR reason LIKE ? ESCAPE '\\')
                """)
            for _ in 0..<4 { args.append("%" + escaped + "%") }
        }
        return (parts.isEmpty ? "" : " AND " + parts.joined(separator: " AND "), args)
    }
}

/// Plans in the state database (`amazon_plans` and `amazon_plan_steps`).
public struct PlanStore {
    public let store: StateStore

    public init(store: StateStore) {
        self.store = store
    }

    private var database: SQLiteDatabase { store.database }

    private static let stepColumns = """
        plan_id, position, operation, node_id, parent_id, from_value, to_value, reason, group_label, size, included, \
        before_parent, before_name, before_status, before_md5, state, result, after_parent, after_name, \
        after_status, inverse_value, created_node_id, reused, catalog_item, updated_at
        """

    private static let planColumns =
        "id, planner, title, created_at, catalog_refreshed_at, status, applied_at, undone_at"

    // MARK: Creating

    /// Run `planner` against the catalog and store what it proposes as a draft. Returns nil, and
    /// stores nothing, when the planner finds nothing to do.
    public func createPlan(using planner: any Planner, now: Date = Date()) throws -> Plan? {
        let steps = try planner.steps(in: store)
        guard !steps.isEmpty else { return nil }
        return try create(
            planner: planner.identifier, title: planner.title,
            catalogRefreshedAt: try store.getMetaDate(MetaKey.catalogRefreshedAt), steps: steps, now: now)
    }

    /// Store a draft plan with `steps` in the order given. All steps start ticked and pending.
    public func create(
        planner: String, title: String, catalogRefreshedAt: Date? = nil, steps: [PlanStepDraft], now: Date = Date()
    ) throws -> Plan {
        guard !steps.isEmpty else { throw PlanError.nothingToDo("A plan needs at least one step.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let id: Int64 = try database.transaction {
            try database.run(
                """
                INSERT INTO amazon_plans(planner, title, created_at, catalog_refreshed_at, status)
                VALUES(?, ?, ?, ?, ?)
                """,
                [planner, title, Int64(now.timeIntervalSince1970),
                 catalogRefreshedAt.map { Int64($0.timeIntervalSince1970) }, PlanStatus.draft.rawValue])
            let planId = database.lastInsertRowID
            let insert = try database.prepare("""
                INSERT INTO amazon_plan_steps(
                    plan_id, position, operation, node_id, parent_id, from_value, to_value, reason, group_label,
                    size, included, before_parent, before_name, before_status, before_md5, state, catalog_item,
                    updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?)
                """)
            for (index, step) in steps.enumerated() {
                let item = try step.catalogItem.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
                try insert.run([
                    planId, index + 1, step.operation.rawValue, step.nodeId, step.parentId, step.fromValue,
                    step.toValue, step.reason, step.groupLabel, step.size, step.before.parent, step.before.name,
                    step.before.status, step.before.md5, PlanStepState.pending.rawValue, item,
                    Int64(now.timeIntervalSince1970),
                ])
            }
            return planId
        }
        guard let plan = try plan(id: id) else { throw PlanError.notFound(id) }
        return plan
    }

    // MARK: Reading

    /// The plan `id` with its summary, or nil when there is none.
    public func plan(id: Int64) throws -> Plan? {
        let rows = try database.rows(
            "SELECT \(Self.planColumns) FROM amazon_plans WHERE id = ?", [id], map: { self.header(from: $0) })
        guard let header = rows.first else { return nil }
        return try complete(header)
    }

    /// The newest plans first.
    public func plans(limit: Int = 50) throws -> [Plan] {
        let headers = try database.rows(
            "SELECT \(Self.planColumns) FROM amazon_plans ORDER BY id DESC LIMIT ?", [max(limit, 1)],
            map: { self.header(from: $0) })
        return try headers.map { try complete($0) }
    }

    private struct Header {
        var id: Int64
        var planner: String
        var title: String
        var createdAt: Date
        var catalogRefreshedAt: Date?
        var status: PlanStatus
        var appliedAt: Date?
        var undoneAt: Date?
    }

    private func header(from row: SQLiteStatement) -> Header {
        func date(_ column: Int32) -> Date? {
            row.isNull(column) ? nil : Date(timeIntervalSince1970: TimeInterval(row.int64(column)))
        }
        return Header(
            id: row.int64(0), planner: row.string(1) ?? "", title: row.string(2) ?? "",
            createdAt: date(3) ?? Date(timeIntervalSince1970: 0), catalogRefreshedAt: date(4),
            status: PlanStatus(rawValue: row.string(5) ?? "") ?? .draft, appliedAt: date(6), undoneAt: date(7))
    }

    private func complete(_ header: Header) throws -> Plan {
        Plan(
            id: header.id, planner: header.planner, title: header.title, createdAt: header.createdAt,
            catalogRefreshedAt: header.catalogRefreshedAt, status: header.status, appliedAt: header.appliedAt,
            undoneAt: header.undoneAt, summary: try summary(planId: header.id))
    }

    /// The counts of one plan, from a single query.
    public func summary(planId: Int64) throws -> PlanSummary {
        struct Row {
            var operation: PlanOperation
            var included: Bool
            var state: PlanStepState
            var count: Int
            var bytes: Int64
        }
        let rows = try database.rows(
            """
            SELECT operation, included, state, COUNT(*), COALESCE(SUM(size), 0)
            FROM amazon_plan_steps WHERE plan_id = ? GROUP BY operation, included, state
            """, [planId],
            map: { row -> Row? in
                guard let operation = row.string(0).flatMap(PlanOperation.init(rawValue:)),
                    let state = row.string(2).flatMap(PlanStepState.init(rawValue:))
                else { return nil }
                return Row(
                    operation: operation, included: row.int(1) != 0, state: state, count: row.int(3),
                    bytes: row.int64(4))
            }
        ).compactMap { $0 }
        var perOperation: [PlanOperation: PlanOperationCount] = [:]
        var states = PlanStateCounts()
        var remaining = 0
        for row in rows {
            var entry = perOperation[row.operation]
                ?? PlanOperationCount(operation: row.operation, included: 0, excluded: 0, includedBytes: 0, excludedBytes: 0)
            if row.included {
                entry.included += row.count
                entry.includedBytes += row.bytes
                if row.state == .pending || row.state == .failed { remaining += row.count }
            } else {
                entry.excluded += row.count
                entry.excludedBytes += row.bytes
            }
            perOperation[row.operation] = entry
            states.add(row.state, row.count)
        }
        let operations = PlanOperation.allCases.compactMap { perOperation[$0] }
        return PlanSummary(
            operations: operations, includedSteps: operations.reduce(0) { $0 + $1.included },
            excludedSteps: operations.reduce(0) { $0 + $1.excluded },
            includedBytes: operations.reduce(0) { $0 + $1.includedBytes },
            excludedBytes: operations.reduce(0) { $0 + $1.excludedBytes }, states: states,
            remainingToApply: remaining, reversible: states.done)
    }

    /// Steps in plan order. `limit` nil returns all that match.
    public func steps(
        planId: Int64, filter: PlanStepFilter = PlanStepFilter(), limit: Int? = nil, offset: Int = 0
    ) throws -> [PlanStep] {
        let clause = filter.clause
        var args: [any SQLiteBindable] = [planId] + clause.args
        var sql = "SELECT \(Self.stepColumns) FROM amazon_plan_steps WHERE plan_id = ?\(clause.sql) ORDER BY position"
        if let limit {
            sql += " LIMIT ? OFFSET ?"
            args.append(max(limit, 0))
            args.append(max(offset, 0))
        } else if offset > 0 {
            sql += " LIMIT -1 OFFSET ?"
            args.append(offset)
        }
        return try database.rows(sql, args, map: { Self.step(from: $0) }).compactMap { $0 }
    }

    public func step(planId: Int64, position: Int) throws -> PlanStep? {
        try database.rows(
            "SELECT \(Self.stepColumns) FROM amazon_plan_steps WHERE plan_id = ? AND position = ?",
            [planId, position], map: { Self.step(from: $0) }
        ).compactMap { $0 }.first
    }

    /// How many steps match `filter`.
    public func count(planId: Int64, filter: PlanStepFilter = PlanStepFilter()) throws -> Int {
        let clause = filter.clause
        return Int(
            try database.scalarInt64(
                "SELECT COUNT(*) FROM amazon_plan_steps WHERE plan_id = ?\(clause.sql)", [planId] + clause.args) ?? 0)
    }

    /// The steps grouped by operation and group label, largest folders first within an operation.
    public func groups(planId: Int64) throws -> [PlanGroup] {
        try database.rows(
            """
            SELECT group_label, operation,
                   SUM(CASE WHEN included = 1 THEN 1 ELSE 0 END), SUM(CASE WHEN included = 0 THEN 1 ELSE 0 END),
                   COALESCE(SUM(size), 0)
            FROM amazon_plan_steps WHERE plan_id = ?
            GROUP BY group_label, operation ORDER BY operation, COUNT(*) DESC, group_label
            """, [planId],
            map: { row -> PlanGroup? in
                guard let operation = row.string(1).flatMap(PlanOperation.init(rawValue:)) else { return nil }
                return PlanGroup(
                    label: row.string(0), operation: operation, included: row.int(2), excluded: row.int(3),
                    bytes: row.int64(4))
            }
        ).compactMap { $0 }
    }

    private static func step(from row: SQLiteStatement) -> PlanStep? {
        guard let operation = row.string(2).flatMap(PlanOperation.init(rawValue:)),
            let state = row.string(15).flatMap(PlanStepState.init(rawValue:))
        else { return nil }
        let after: PlanSnapshot? =
            (row.isNull(17) && row.isNull(18) && row.isNull(19))
            ? nil : PlanSnapshot(parent: row.string(17), name: row.string(18), status: row.string(19))
        let item = row.string(23).flatMap { try? JSONDecoder().decode(CloudItem.self, from: Data($0.utf8)) }
        return PlanStep(
            planId: row.int64(0), position: row.int(1), operation: operation, nodeId: row.string(3),
            parentId: row.string(4), fromValue: row.string(5), toValue: row.string(6), reason: row.string(7) ?? "",
            groupLabel: row.string(8), size: row.int64(9), included: row.int(10) != 0,
            before: PlanSnapshot(
                parent: row.string(11), name: row.string(12), status: row.string(13), md5: row.string(14)),
            state: state, result: row.string(16), after: after, inverseValue: row.string(20),
            createdNodeId: row.string(21), reusedExisting: row.int(22) != 0, catalogItem: item,
            updatedAt: row.isNull(24) ? nil : Date(timeIntervalSince1970: TimeInterval(row.int64(24))))
    }

    // MARK: Ticking steps

    /// Tick or untick one step. Only a plan that has not been applied in full, and a step that has not
    /// run yet (or failed), can be changed. Returns whether the step changed.
    @discardableResult
    public func setIncluded(_ included: Bool, planId: Int64, position: Int) throws -> Bool {
        try setIncluded(included, planId: planId, matching: nil, position: position) > 0
    }

    /// Tick or untick every step that matches `filter`, for example one folder of one operation.
    /// Returns how many steps changed.
    @discardableResult
    public func setIncluded(_ included: Bool, planId: Int64, matching filter: PlanStepFilter) throws -> Int {
        try setIncluded(included, planId: planId, matching: filter, position: nil)
    }

    private func setIncluded(_ included: Bool, planId: Int64, matching filter: PlanStepFilter?, position: Int?) throws -> Int {
        guard let plan = try plan(id: planId) else { throw PlanError.notFound(planId) }
        guard plan.status == .draft || plan.status == .partlyApplied else {
            throw PlanError.cannotApply(
                status: plan.status, reason: "A plan that is \(plan.status.text) can no longer be edited.")
        }
        var sql = """
            UPDATE amazon_plan_steps SET included = ? WHERE plan_id = ? AND state IN ('pending', 'failed') \
            AND included <> ?
            """
        var args: [any SQLiteBindable] = [included ? 1 : 0, planId, included ? 1 : 0]
        if let position {
            sql += " AND position = ?"
            args.append(position)
        }
        if let filter {
            let clause = filter.clause
            sql += clause.sql
            args += clause.args
        }
        try database.run(sql, args)
        return database.changes
    }

    // MARK: Recording a run (used by the applier and the undoer)

    func setStatus(
        planId: Int64, _ status: PlanStatus, appliedAt: Date? = nil, undoneAt: Date? = nil
    ) throws {
        try database.run(
            """
            UPDATE amazon_plans SET status = ?, applied_at = COALESCE(?, applied_at),
                undone_at = COALESCE(?, undone_at) WHERE id = ?
            """,
            [status.rawValue, appliedAt.map { Int64($0.timeIntervalSince1970) },
             undoneAt.map { Int64($0.timeIntervalSince1970) }, planId])
    }

    /// Record how a step went. `result` replaces the old text; the other optional values keep what
    /// is stored when nil.
    func record(
        planId: Int64, position: Int, state: PlanStepState, result: String?, after: PlanSnapshot? = nil,
        inverseValue: String? = nil, createdNodeId: String? = nil, reusedExisting: Bool? = nil,
        catalogItem: CloudItem? = nil, now: Date
    ) throws {
        let item = try catalogItem.map { item -> String in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(item), as: UTF8.self)
        }
        try database.run(
            """
            UPDATE amazon_plan_steps SET state = ?, result = ?,
                after_parent = COALESCE(?, after_parent), after_name = COALESCE(?, after_name),
                after_status = COALESCE(?, after_status), inverse_value = COALESCE(?, inverse_value),
                created_node_id = COALESCE(?, created_node_id), reused = COALESCE(?, reused),
                catalog_item = COALESCE(?, catalog_item), updated_at = ?
            WHERE plan_id = ? AND position = ?
            """,
            [state.rawValue, result, after?.parent, after?.name, after?.status, inverseValue, createdNodeId,
             reusedExisting.map { $0 ? 1 : 0 }, item, Int64(now.timeIntervalSince1970), planId, position])
    }
}
