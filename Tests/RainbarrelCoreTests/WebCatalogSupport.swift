import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RainbarrelCore

private final class WebCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private let webCounter = WebCounter()

/// A node as Amazon's web API writes it, built from synthetic values only.
struct FakeNode {
    var id: String
    var name = ""
    var kind = "FILE"
    var status = "AVAILABLE"
    var isRoot = false
    var parents: [String] = ["T-D2"]
    var md5: String?
    var size: Int64?
    var contentDate: String? = "2019-04-24T05:53:46.264Z"
    var createdDate = "2019-05-01T10:00:00.000Z"
    var ext: String? = "jpg"
    var assetType: String?

    var json: String {
        var parts = [
            "\"id\":\"\(id)\"", "\"name\":\"\(name)\"", "\"kind\":\"\(kind)\"", "\"status\":\"\(status)\"",
            "\"isRoot\":\(isRoot)", "\"parents\":[\(parents.map { "\"\($0)\"" }.joined(separator: ","))]",
            "\"createdDate\":\"\(createdDate)\"", "\"modifiedDate\":\"\(createdDate)\"",
        ]
        if kind != "FOLDER" {
            var content: [String] = []
            if let md5 { content.append("\"md5\":\"\(md5)\"") }
            if let size { content.append("\"size\":\(size)") }
            if let contentDate { content.append("\"contentDate\":\"\(contentDate)\"") }
            if let ext { content.append("\"extension\":\"\(ext)\"") }
            content.append("\"contentType\":\"image/jpeg\"")
            parts.append("\"contentProperties\":{\(content.joined(separator: ","))}")
        }
        parts.append(assetType.map { "\"assetProperties\":{\"assetType\":\"\($0)\"}" } ?? "\"assetProperties\":null")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func folder(_ id: String, _ name: String, parent: String?, root: Bool = false, status: String = "AVAILABLE") -> FakeNode {
        FakeNode(id: id, name: name, kind: "FOLDER", status: status, isRoot: root, parents: parent.map { [$0] } ?? [])
    }

    static func file(
        _ id: String, _ name: String, md5 digit: Character?, size: Int64? = 100, parent: String = "T-D2",
        status: String = "AVAILABLE"
    ) -> FakeNode {
        FakeNode(
            id: id, name: name, status: status, parents: [parent], md5: digit.map { String(repeating: $0, count: 32) },
            size: size)
    }

    static func live(
        _ id: String, parent: String, md5 digit: Character?, size: Int64? = 50, status: String = "AVAILABLE"
    ) -> FakeNode {
        FakeNode(
            id: id, name: "\(id).mov", kind: "ASSET", status: status, parents: [parent],
            md5: digit.map { String(repeating: $0, count: 32) }, size: size, contentDate: nil, ext: "mov",
            assetType: "LIVE_VIDEO")
    }
}

/// A stubbed Amazon web API for one account: a change feed that starts with the library and goes on with
/// the batches added later, and the file count of a listing.
final class WebFixture: @unchecked Sendable {
    let home: TempDirectory
    let paths: AppPaths
    let host: String
    let server: StubServer
    let clock: FakeClock
    let sessionID = "web-session-id-4455667788"
    let secretToken = "web-secret-token-99AABBCC"
    var config: Config
    var timeouts = AmazonClient.Timeouts(request: 5, stall: 5)

    private let lock = NSLock()
    private var folderNodes: [FakeNode] = []
    private var fileNodes: [FakeNode] = []
    private var assetNodes: [FakeNode] = []
    private var batches: [[FakeNode]] = []
    private var nodeCalls = 0
    private var changeCalls = 0
    private var chunkSizeValue = 1000
    private var chunksPerResponseValue: Int?
    private var nodesOverrideValue: (@Sendable (Int) -> StubServer.Reply?)?
    private var changesOverrideValue: (@Sendable (Int) -> StubServer.Reply?)?
    private var resetFeedValue = false
    private var resetChunksValue: Set<Int> = []
    private var signInPageValue = false
    private var fileCountOffsetValue = 0

    init(throttle: ThrottleConfig = ThrottleConfig(), catalogSource: CatalogSourceChoice = .web) throws {
        let id = webCounter.next()
        host = "w\(id).amazon.com"
        home = try TempDirectory()
        paths = AppPaths(dataDirectory: home.url.appendingPathComponent("data", isDirectory: true))
        try paths.ensureDataDirectory()
        server = StubServer(hosts: [host])
        clock = FakeClock(start: noonOct16)
        config = Config(amazonHost: host, throttle: throttle, catalogSource: catalogSource)
        setStandardLibrary()
        server.handler = { [unowned self] request in handle(request) }
    }

    // MARK: The library on the server

    /// Six photos (two without usable data), four assets (one Live Photo video, one without MD5, one
    /// trashed, one that is no Live Photo video) and three folders: five catalog items, three skipped.
    func setStandardLibrary() {
        setLibrary(
            folders: [
                .folder("T-ROOT", "Root", parent: "ignored-parent", root: true),
                .folder("T-D1", "Pictures", parent: "T-ROOT"),
                .folder("T-D2", "Phone", parent: "T-D1"),
            ],
            files: [
                .file("T-F1", "one.jpg", md5: "1", size: 100),
                {
                    var node = FakeNode.file("T-F2", "two.heic", md5: nil, size: 200, parent: "T-D1")
                    node.md5 = "ABCDEF0123456789ABCDEF0123456789"
                    node.contentDate = nil
                    node.ext = "heic"
                    return node
                }(),
                {
                    var node = FakeNode.file("T-F3", "three.png", md5: "3", size: 300)
                    node.contentDate = "2020-02-29T12:00:00Z"
                    node.ext = nil
                    return node
                }(),
                .file("T-F4", "four.jpg", md5: nil, size: 400),
                .file("T-F5", "five.jpg", md5: "5", size: nil),
                {
                    var node = FakeNode.file("T-F6", "six.mov", md5: "6", size: 600)
                    node.contentDate = "garbage"
                    node.createdDate = "not a date"
                    return node
                }(),
            ],
            assets: [
                FakeNode(id: "T-A1", name: "other.dat", kind: "ASSET", parents: ["T-F1"], md5: String(repeating: "9", count: 32), size: 5),
                .live("T-L1", parent: "T-F1", md5: "7", size: 50),
                .live("T-L2", parent: "T-F3", md5: nil, size: 50),
                .live("T-L3", parent: "T-F3", md5: "8", size: 50, status: "TRASH"),
            ])
    }

    func setLibrary(folders: [FakeNode], files: [FakeNode], assets: [FakeNode]) {
        lock.lock()
        folderNodes = folders
        fileNodes = files
        assetNodes = assets
        lock.unlock()
    }

    /// Nodes per chunk of the library at the start of the feed; checkpoints are `cp-<chunks so far>`.
    var chunkSize: Int {
        get { lock.withLock { chunkSizeValue } }
        set { lock.withLock { chunkSizeValue = newValue } }
    }

    /// At most this many chunks in one answer, whatever `maxNodes` says; nil follows `maxNodes`.
    var chunksPerResponse: Int? {
        get { lock.withLock { chunksPerResponseValue } }
        set { lock.withLock { chunksPerResponseValue = newValue } }
    }

    /// Replace the answer of a listing (file count) request; called with the index among those requests.
    func overrideNodes(_ body: (@Sendable (Int) -> StubServer.Reply?)?) {
        lock.withLock { nodesOverrideValue = body }
    }

    /// Replace the answer of a change-feed request; called with the index among those requests.
    func overrideChanges(_ body: (@Sendable (Int) -> StubServer.Reply?)?) {
        lock.withLock { changesOverrideValue = body }
    }

    /// Answer the next change-feed request that carries a checkpoint with `reset: true` and no nodes.
    var feedAsksForReset: Bool {
        get { lock.withLock { resetFeedValue } }
        set { lock.withLock { resetFeedValue = newValue } }
    }

    /// Chunks (by position in the feed) that are sent with `reset: true`. The first chunk of a fresh feed always is.
    var resetChunks: Set<Int> {
        get { lock.withLock { resetChunksValue } }
        set { lock.withLock { resetChunksValue = newValue } }
    }

    /// Answer every request with a sign-in page and status 200.
    var answersWithSignInPage: Bool {
        get { lock.withLock { signInPageValue } }
        set { lock.withLock { signInPageValue = newValue } }
    }

    /// Files that Amazon counts but the feed does not show, for example uploads that landed after the drain.
    var fileCountOffset: Int {
        get { lock.withLock { fileCountOffsetValue } }
        set { lock.withLock { fileCountOffsetValue = newValue } }
    }

    /// Add one batch to the end of the change feed (checkpoint `cp-<number of chunks>`).
    func addChanges(_ nodes: [FakeNode]) {
        lock.withLock { batches.append(nodes) }
    }

    // MARK: The stub

    private func jsonReply(_ text: String, status: Int = 200) -> StubServer.Reply {
        .body(Data(text.utf8), status: status, headers: ["Content-Type": "application/json"])
    }

    private func handle(_ request: StubServer.Request) -> StubServer.Reply {
        guard request.header("x-amzn-sessionid") == sessionID else {
            return jsonReply(#"{"message":"No Auth Method Provided"}"#, status: 401)
        }
        if lock.withLock({ signInPageValue }) {
            return .body(Data("<html>Sign in</html>".utf8), headers: ["Content-Type": "text/html; charset=utf-8"])
        }
        switch (request.method, request.url.path) {
        case ("GET", "/drive/v1/nodes"): return handleNodes(request.url)
        case ("POST", "/drive/v1/changes"): return handleChanges(request)
        default: return .body(Data(), status: 404)
        }
    }

    /// The feed in order: the library in chunks, then every batch as a chunk of its own.
    private func history() -> [[FakeNode]] {
        let library = folderNodes + fileNodes + assetNodes
        var chunks: [[FakeNode]] = []
        var index = 0
        while index < library.count {
            chunks.append(Array(library[index..<min(index + chunkSizeValue, library.count)]))
            index += chunkSizeValue
        }
        return chunks + batches
    }

    /// The only listing the product asks for: one file, to read the `count` of available files.
    private func handleNodes(_ url: URL) -> StubServer.Reply {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let (index, override, count): (Int, (@Sendable (Int) -> StubServer.Reply?)?, Int) = lock.withLock {
            let index = nodeCalls
            nodeCalls += 1
            var latest: [String: FakeNode] = [:]
            for node in history().joined() { latest[node.id] = node }
            let available = latest.values.filter { $0.kind == "FILE" && $0.status == "AVAILABLE" }.count
            return (index, nodesOverrideValue, available + fileCountOffsetValue)
        }
        if let reply = override?(index) { return reply }
        guard value("filters") == "kind:FILE AND status:AVAILABLE", value("limit") == "1",
            value("resourceVersion") == "V2", value("ContentType") == "JSON"
        else { return jsonReply(#"{"message":"limit is not within allowed range"}"#, status: 400) }
        return jsonReply("{\"count\":\(count),\"data\":[]}")
    }

    private func handleChanges(_ request: StubServer.Request) -> StubServer.Reply {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let checkpoint = body?["checkpoint"] as? String
        let maxNodes = body?["maxNodes"] as? Int ?? 0
        let (index, override, chunks, perResponse, askedForReset, resetChunks): (
            Int, (@Sendable (Int) -> StubServer.Reply?)?, [[FakeNode]], Int?, Bool, Set<Int>
        ) = lock.withLock {
            let index = changeCalls
            changeCalls += 1
            let reset = resetFeedValue && checkpoint != nil
            if reset { resetFeedValue = false }
            return (index, changesOverrideValue, history(), chunksPerResponseValue, reset, resetChunksValue)
        }
        if let reply = override?(index) { return reply }
        func chunk(_ nodes: [FakeNode], _ checkpoint: String, reset: Bool) -> String {
            "{\"nodes\":[\(nodes.map(\.json).joined(separator: ","))],\"checkpoint\":\"\(checkpoint)\",\"reset\":\(reset),\"statusCode\":200}"
        }
        var start = 0
        if let checkpoint {
            guard checkpoint.hasPrefix("cp-"), let number = Int(checkpoint.dropFirst(3)), number <= chunks.count else {
                return jsonReply(#"{"message":"unknown checkpoint"}"#, status: 400)
            }
            start = number
        }
        var lines: [String] = []
        if askedForReset, let checkpoint {
            lines.append(chunk([], checkpoint, reset: true))
        } else {
            var nodeCount = 0
            for position in start..<chunks.count {
                if nodeCount >= maxNodes || (perResponse.map { lines.count >= $0 } ?? false) { break }
                let reset = (checkpoint == nil && position == 0) || resetChunks.contains(position)
                lines.append(chunk(chunks[position], "cp-\(position + 1)", reset: reset))
                nodeCount += chunks[position].count
            }
            // Nothing new: an empty chunk that repeats the position.
            if lines.isEmpty { lines.append(chunk([], "cp-\(start)", reset: false)) }
        }
        lines.append(#"{"end":true}"#)
        return jsonReply(lines.joined(separator: "\n"))
    }

    // MARK: Using it

    var session: StoredSession {
        StoredSession(
            host: host,
            cookies: [
                SessionCookie(name: "session-id", value: sessionID, domain: ".amazon.com"),
                SessionCookie(name: "session-token", value: secretToken, domain: ".amazon.com"),
                SessionCookie(name: "other-site", value: "other-site-secret-9999", domain: ".example.org"),
            ],
            savedAt: noonOct16)
    }

    var environment: DownloadEnvironment {
        DownloadEnvironment(
            clock: clock.clock, random: { 1.0 }, freeSpace: { _ in nil },
            sessionConfiguration: {
                let configuration = AmazonClient.defaultConfiguration()
                configuration.protocolClasses = [StubURLProtocol.self]
                return configuration
            },
            timeouts: timeouts, calendar: utcCalendar)
    }

    enum AppIndex: Sendable {
        case catalog([CloudItem])
        case missing
        case broken
    }

    /// Tools over this account; `app` decides what the desktop app index looks like.
    func tools(app: AppIndex = .missing, signedIn: Bool = true) throws -> RainbarrelTools {
        let tools = RainbarrelTools(
            paths: paths,
            catalogSource: { _ in
                switch app {
                case .catalog(let items): return StaticCatalog(items: items)
                case .missing: throw CatalogError.indexNotFound("no amzn1.account.*-cloud.db in /nowhere")
                case .broken: throw CatalogError.snapshotFailed("disk image is malformed")
                }
            },
            sessionStore: MemorySessionStore(signedIn ? session : nil), downloadEnvironment: environment)
        try tools.saveConfig(config)
        return tools
    }

    func store() throws -> StateStore { try StateStore(path: paths.stateURL.path) }

    func source() throws -> WebAPICatalogSource {
        try WebAPICatalogSource.make(session: session, config: config, environment: environment)
    }

    func refresher(_ store: StateStore) -> CatalogRefresher {
        CatalogRefresher(store: store, downloadLockPath: paths.downloadLockURL.path)
    }

    /// Requests for the file count (the only listing the product asks for), in order.
    var listingRequests: [StubServer.Request] {
        server.requests.filter { $0.method == "GET" && $0.url.path == "/drive/v1/nodes" }
    }

    /// Requests for the change feed, in order.
    var changeRequests: [StubServer.Request] {
        server.requests.filter { $0.method == "POST" && $0.url.path == "/drive/v1/changes" }
    }

    static func filter(of request: StubServer.Request) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filters" }?.value
    }

    static func checkpoint(of request: StubServer.Request) -> String? {
        ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["checkpoint"] as? String
    }
}

// MARK: Reading the state store

func storedItems(_ store: StateStore) throws -> [CloudItem] {
    try store.database.rows(
        "SELECT node_id, kind, name, md5, size, taken_at, ext, parent_id FROM cloud_items ORDER BY node_id"
    ) { row in
        CloudItem(
            nodeId: row.string(0) ?? "", kind: CloudItemKind(rawValue: row.string(1) ?? "") ?? .file,
            name: row.string(2) ?? "", md5: row.string(3) ?? "", size: row.int64(4), takenAt: row.int64(5),
            ext: row.string(6), parentId: row.string(7))
    }
}

func storedFolders(_ store: StateStore) throws -> [CloudFolder] {
    try store.database.rows("SELECT node_id, name, parent_id FROM cloud_folders ORDER BY node_id") { row in
        CloudFolder(nodeId: row.string(0) ?? "", name: row.string(1) ?? "", parentId: row.string(2))
    }
}

/// The error a body throws, or nil.
func thrownError(_ body: () async throws -> Void) async -> Error? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}
