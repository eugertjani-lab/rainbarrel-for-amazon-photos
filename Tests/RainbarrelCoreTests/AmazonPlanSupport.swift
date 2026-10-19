import Foundation
@testable import RainbarrelCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let emptyContentMD5 = "d41d8cd98f00b204e9800998ecf8427e"

/// A counter that a stub handler can bump from any thread.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Adds one and returns the new count.
    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Values collected from a callback.
final class Collected<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element] = []

    func add(_ value: Element) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var items: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// A switch that a stub handler can read from any thread.
final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool

    init(_ on: Bool = false) { self.on = on }

    var isOn: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return on
        }
        set {
            lock.lock()
            on = newValue
            lock.unlock()
        }
    }
}

/// Everything for a plan test: a fake Amazon with a small library, the same library as a catalog in a
/// state database, a data directory for the run lock, and a clock that costs no real time.
///
///     ROOT
///     ├ E-3  empty-root.jpg   (empty)
///     ├ F-PICS Pictures
///     │   └ F-PHONE Phone     (E-1 broken1.jpg, E-2 broken2.png: empty; G-1 good.jpg, 100 bytes)
///     └ F-DOCS Docs           (E-4 empty-doc.pdf: empty)
final class PlanFixture: @unchecked Sendable {
    let amazon: WriteFixture
    let store: StateStore
    let plans: PlanStore
    let home: TempDirectory
    let paths: AppPaths
    let clock = FakeClock(start: noonOct16)
    var config: Config

    static func nodes() -> [WriteFixture.Node] {
        [
            .folder("ROOT", "", in: nil),
            .folder("F-PICS", "Pictures", in: "ROOT"),
            .folder("F-PHONE", "Phone", in: "F-PICS"),
            .folder("F-DOCS", "Docs", in: "ROOT"),
            .file("E-1", "broken1.jpg", in: "F-PHONE", md5: emptyContentMD5, size: 0),
            .file("E-2", "broken2.png", in: "F-PHONE", md5: emptyContentMD5, size: 0),
            .file("E-3", "empty-root.jpg", in: "ROOT", md5: emptyContentMD5, size: 0),
            .file("E-4", "empty-doc.pdf", in: "F-DOCS", md5: emptyContentMD5, size: 0),
            .file("G-1", "good.jpg", in: "F-PHONE", md5: String(repeating: "a", count: 32), size: 100),
        ]
    }

    /// The catalog rows that match `nodes()`.
    static func items() -> [CloudItem] {
        func item(_ id: String, _ name: String, _ parent: String, empty: Bool = true) -> CloudItem {
            CloudItem(
                nodeId: id, kind: .file, name: name, md5: empty ? emptyContentMD5 : String(repeating: "a", count: 32),
                size: empty ? 0 : 100, takenAt: t2019, ext: name.split(separator: ".").last.map(String.init), parentId: parent)
        }
        return [
            item("E-1", "broken1.jpg", "F-PHONE"), item("E-2", "broken2.png", "F-PHONE"),
            item("E-3", "empty-root.jpg", "ROOT"), item("E-4", "empty-doc.pdf", "F-DOCS"),
            item("G-1", "good.jpg", "F-PHONE", empty: false),
        ]
    }

    static let folders = [
        CloudFolder(nodeId: "ROOT", name: "", parentId: nil),
        CloudFolder(nodeId: "F-PICS", name: "Pictures", parentId: "ROOT"),
        CloudFolder(nodeId: "F-PHONE", name: "Phone", parentId: "F-PICS"),
        CloudFolder(nodeId: "F-DOCS", name: "Docs", parentId: "ROOT"),
    ]

    init(
        nodes: [WriteFixture.Node]? = nil, items: [CloudItem]? = nil, folders: [CloudFolder]? = nil,
        config: Config = Config()
    ) throws {
        amazon = WriteFixture(nodes: nodes ?? Self.nodes())
        store = try makeStore()
        plans = PlanStore(store: store)
        home = try TempDirectory()
        paths = AppPaths(dataDirectory: home.url.appendingPathComponent("data", isDirectory: true))
        try paths.ensureDataDirectory()
        self.config = config
        try CatalogRefresher(store: store).refresh(
            from: StaticCatalog(items: items ?? Self.items(), folders: folders ?? Self.folders),
            now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    var environment: DownloadEnvironment { DownloadEnvironment(clock: clock.clock, random: { 0.5 }) }

    /// A plan from the empty-file planner (steps in the planner's order: E-3, E-4, E-1, E-2).
    func makePlan() throws -> Plan {
        try unwrapped(plans.createPlan(using: EmptyFileCleanupPlanner()))
    }

    func makeApplier(refresh: @escaping () async throws -> Void = {}) throws -> PlanApplier {
        PlanApplier(
            store: store, client: try amazon.client(), paths: paths, config: config, environment: environment,
            refreshCatalog: refresh)
    }

    func makeUndoer() throws -> PlanUndoer {
        PlanUndoer(store: store, client: try amazon.client(), paths: paths, config: config, environment: environment)
    }

    func apply(
        _ id: Int64, refresh: @escaping () async throws -> Void = {}, isCancelled: () -> Bool = { false },
        progress: (PlanProgress) -> Void = { _ in }
    ) async throws -> PlanRunResult {
        try await makeApplier(refresh: refresh).apply(planId: id, isCancelled: isCancelled, progress: progress)
    }

    func undo(
        _ id: Int64, isCancelled: () -> Bool = { false }, progress: (PlanProgress) -> Void = { _ in }
    ) async throws -> PlanRunResult {
        try await makeUndoer().undo(planId: id, isCancelled: isCancelled, progress: progress)
    }

    func steps(_ plan: Plan) throws -> [PlanStep] { try plans.steps(planId: plan.id) }

    /// The step of `plan` that acts on `nodeId`.
    func step(_ plan: Plan, _ nodeId: String) throws -> PlanStep {
        try unwrapped(plans.steps(planId: plan.id).first { $0.nodeId == nodeId })
    }

    func reload(_ plan: Plan) throws -> Plan { try unwrapped(plans.plan(id: plan.id)) }

    /// Node ids of the catalog's items.
    func catalogItemIDs() throws -> Set<String> {
        Set(try store.database.rows("SELECT node_id FROM cloud_items", map: { $0.string(0) ?? "" }))
    }

    func catalogItem(_ id: String) throws -> CloudItem? { try LocalCatalog(database: store.database).item(id) }

    func catalogFolder(_ id: String) throws -> CloudFolder? {
        try store.database.rows(
            "SELECT node_id, name, parent_id FROM cloud_folders WHERE node_id = ?", [id],
            map: { CloudFolder(nodeId: $0.string(0) ?? "", name: $0.string(1) ?? "", parentId: $0.string(2)) }
        ).first
    }

    /// The write calls (everything but GET) that reached the fake Amazon, in order.
    var writeCalls: [String] { amazon.calls.filter { !$0.hasPrefix("GET ") } }
}

struct PlanTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Unwraps a value that a helper expects to find, and fails with a message that names the place.
func unwrapped<T>(_ value: T?, _ what: String = "value", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw PlanTestFailure(description: "missing \(what) at \(file):\(line)") }
    return value
}
