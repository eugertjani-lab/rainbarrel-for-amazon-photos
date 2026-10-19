import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RainbarrelCore

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private let writeCounter = WriteCounter()

/// A fake Amazon Drive API with an in-memory node tree that answers the calls of the write client:
/// node reads, child-folder listings with paging, folder creation, move, rename, description, trash
/// and restore. It follows what was seen on the live API (201 with an empty body for a created
/// folder, a delay before the folder is listed, 200 with the node for the others). Two answers are
/// assumptions that were not confirmed live: HTTP 409 when a name is already taken in the target
/// folder, and HTTP 404 for an unknown id.
final class WriteFixture: @unchecked Sendable {
    struct Node: Sendable {
        var id: String
        var name: String
        var kind = "FILE"
        var status = "AVAILABLE"
        var parents: [String]
        var description: String?
        var md5: String?
        var size: Int64?
        /// The next `hiddenListings` listings of the parent leave this node out (a folder that was
        /// created a moment ago and is not listed yet).
        var hiddenListings = 0

        static func folder(_ id: String, _ name: String, in parent: String?, status: String = "AVAILABLE") -> Node {
            Node(id: id, name: name, kind: "FOLDER", status: status, parents: parent.map { [$0] } ?? [])
        }

        static func file(
            _ id: String, _ name: String, in parent: String, md5: String = "0123456789ABCDEF0123456789ABCDEF",
            size: Int64 = 1234
        ) -> Node {
            Node(id: id, name: name, parents: [parent], md5: md5, size: size)
        }
    }

    /// What a write answers with.
    enum WriteAnswer: Sendable {
        /// 200 with the node, as the live API does.
        case node
        /// 200 with an empty body, so that the client has to read the node again.
        case empty
    }

    private struct State {
        var order: [String] = []
        var nodes: [String: Node] = [:]
        var nextId = 1
        var ignoreWrites = false
        var writeAnswer = WriteAnswer.node
        /// How many listings of the parent leave out a folder that was just created.
        var newFolderHiddenListings = 0
        var pageSize: Int?
        var listsTrashedFolders = false
        var override: (@Sendable (StubServer.Request) -> StubServer.Reply?)?
        var sessionCheckOverride: (@Sendable (Int) -> StubServer.Reply?)?
        var sessionChecks = 0
    }

    let host: String
    let server: StubServer
    let sessionID = "write-session-id-778899"
    let secretToken = "write-secret-token-AABBCCDD"
    var timeouts = AmazonClient.Timeouts(request: 5, stall: 5)
    private let lock = NSLock()
    private var state = State()

    /// The standard tree:
    ///
    ///     ROOT
    ///     ├ F-A  Albums     (F-1 photo.jpg, F-2 notes.txt)
    ///     └ F-B  Backup     (F-3 photo.jpg, F-4 other.jpg, F-SUB1 and F-SUB2 folders)
    init(nodes: [Node]? = nil) {
        let id = writeCounter.next()
        host = "wr\(id).amazon.com"
        server = StubServer(hosts: [host])
        let tree: [Node] =
            nodes ?? [
                .folder("ROOT", "", in: nil),
                .folder("F-A", "Albums", in: "ROOT"),
                .folder("F-B", "Backup", in: "ROOT"),
                .file("F-1", "photo.jpg", in: "F-A"),
                .file("F-2", "notes.txt", in: "F-A", md5: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", size: 10),
                .file("F-3", "photo.jpg", in: "F-B"),
                .file("F-4", "other.jpg", in: "F-B"),
                .folder("F-SUB1", "Sub one", in: "F-B"),
                .folder("F-SUB2", "Sub two", in: "F-B"),
            ]
        for node in tree {
            state.order.append(node.id)
            state.nodes[node.id] = node
        }
        server.handler = { [unowned self] request in handle(request) }
    }

    // MARK: Switches and views

    private func update(_ body: (inout State) -> Void) {
        lock.lock()
        body(&state)
        lock.unlock()
    }

    private func read<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    /// Writes answer as if they worked (200, or 201 for a created folder) but change nothing.
    func ignoreWrites(_ value: Bool = true) { update { $0.ignoreWrites = value } }

    func writeAnswer(_ value: WriteAnswer) { update { $0.writeAnswer = value } }

    func newFolderHiddenListings(_ value: Int) { update { $0.newFolderHiddenListings = value } }

    func pageSize(_ value: Int?) { update { $0.pageSize = value } }

    /// Child listings include folders in the trash (the live API's behavior is not known).
    func listsTrashedFolders(_ value: Bool = true) { update { $0.listsTrashedFolders = value } }

    /// Replace the answer to a request before the tree sees it (return nil to leave it alone).
    func override(_ body: (@Sendable (StubServer.Request) -> StubServer.Reply?)?) { update { $0.override = body } }

    /// Replace the answer to the session check (the file-count listing); called with how many checks
    /// came before.
    func overrideSessionCheck(_ body: (@Sendable (Int) -> StubServer.Reply?)?) { update { $0.sessionCheckOverride = body } }

    func node(_ id: String) -> Node? { read { $0.nodes[id] } }

    func add(_ node: Node) {
        update {
            $0.order.append(node.id)
            $0.nodes[node.id] = node
        }
    }

    /// Change a node behind a plan's back, as someone else would in the Amazon Photos app.
    func modify(_ id: String, _ body: (inout Node) -> Void) {
        update { state in
            guard var node = state.nodes[id] else { return }
            body(&node)
            state.nodes[id] = node
        }
    }

    /// Forget a node, as if Amazon had purged it: later reads answer 404.
    func remove(_ id: String) {
        update {
            $0.nodes[id] = nil
            $0.order.removeAll { $0 == id }
        }
    }

    var session: StoredSession {
        StoredSession(
            host: host,
            cookies: [
                SessionCookie(name: "session-id", value: sessionID, domain: ".amazon.com"),
                SessionCookie(name: "session-token", value: secretToken, domain: ".amazon.com"),
            ],
            savedAt: noonOct16)
    }

    func client(session other: StoredSession? = nil) throws -> AmazonClient {
        let configuration = AmazonClient.defaultConfiguration()
        configuration.protocolClasses = [StubURLProtocol.self]
        return try AmazonClient(
            session: other ?? session, host: host, configuration: configuration, timeouts: timeouts)
    }

    /// Requests below `/drive/v1`, in order, as `METHOD path`.
    var calls: [String] { server.requests(host: host).map { "\($0.method) \($0.url.path)" } }

    /// Requests of the session check (the file-count listing).
    var sessionChecks: Int { read { $0.sessionChecks } }

    // MARK: The API

    private func json(_ object: Any, status: Int = 200) -> StubServer.Reply {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .body(data, status: status, headers: ["Content-Type": "application/json"])
    }

    private func object(_ node: Node) -> [String: Any] {
        var result: [String: Any] = [
            "id": node.id, "name": node.name, "kind": node.kind, "status": node.status, "parents": node.parents,
            "labels": [String](), "version": 3,
        ]
        if let description = node.description { result["description"] = description }
        if node.kind != "FOLDER" {
            var content: [String: Any] = ["contentType": "image/jpeg", "contentDate": "2019-04-24T05:53:46.264Z"]
            if let md5 = node.md5 { content["md5"] = md5 }
            if let size = node.size { content["size"] = size }
            result["contentProperties"] = content
        }
        return result
    }

    private func handle(_ request: StubServer.Request) -> StubServer.Reply {
        guard request.header("x-amzn-sessionid") == sessionID else {
            return json(["message": "No Auth Method Provided"], status: 401)
        }
        if let reply = read({ $0.override })?(request) { return reply }
        let parts = request.url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "drive", parts[1] == "v1" else { return .body(Data(), status: 404) }
        let rest = Array(parts.dropFirst(2))
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func queryValue(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]

        lock.lock()
        defer { lock.unlock() }
        switch (request.method, rest) {
        case ("GET", ["nodes"]):
            let count = state.sessionChecks
            state.sessionChecks += 1
            if let reply = state.sessionCheckOverride?(count) { return reply }
            return json(["count": 3, "data": [Any]()])
        case ("POST", ["nodes"]):
            return create(body)
        case ("GET", _) where rest.count == 2 && rest[0] == "nodes":
            guard let node = state.nodes[rest[1]] else { return .body(Data(), status: 404) }
            return json(object(node))
        case ("PATCH", _) where rest.count == 2 && rest[0] == "nodes":
            return patch(rest[1], body)
        case ("GET", _) where rest.count == 3 && rest[0] == "nodes" && rest[2] == "children":
            return listChildren(of: rest[1], filter: queryValue("filters"), limit: queryValue("limit"), start: queryValue("startToken"))
        case ("POST", _) where rest.count == 3 && rest[0] == "nodes" && rest[2] == "children":
            return move(into: rest[1], body)
        case ("PUT", _) where rest.count == 2 && rest[0] == "trash":
            return setStatus(rest[1], "TRASH")
        case ("POST", _) where rest.count == 3 && rest[0] == "trash" && rest[2] == "restore":
            return setStatus(rest[1], "AVAILABLE")
        default:
            return .body(Data(), status: 404)
        }
    }

    // The functions below run with `lock` held.

    private func clash(_ name: String, in parents: [String], except id: String?) -> Bool {
        state.nodes.values.contains {
            $0.id != id && $0.name == name && $0.status == "AVAILABLE" && !Set($0.parents).isDisjoint(with: parents)
        }
    }

    private func answer(_ node: Node) -> StubServer.Reply {
        switch state.writeAnswer {
        case .node: return json(object(node))
        case .empty: return .body(Data())
        }
    }

    private func create(_ body: [String: Any]) -> StubServer.Reply {
        guard let name = body["name"] as? String, let parents = body["parents"] as? [String],
            let parent = parents.first
        else { return json(["message": "bad request"], status: 400) }
        guard state.nodes[parent] != nil else { return .body(Data(), status: 404) }
        if clash(name, in: parents, except: nil) { return json(["message": "conflict"], status: 409) }
        if state.ignoreWrites { return .body(Data(), status: 201) }
        let id = "N-NEW\(state.nextId)"
        state.nextId += 1
        var node = Node.folder(id, name, in: parent)
        node.hiddenListings = state.newFolderHiddenListings
        state.order.append(id)
        state.nodes[id] = node
        return .body(Data(), status: 201)
    }

    private func patch(_ id: String, _ body: [String: Any]) -> StubServer.Reply {
        guard var node = state.nodes[id] else { return .body(Data(), status: 404) }
        if state.ignoreWrites { return answer(node) }
        if let name = body["name"] as? String {
            if clash(name, in: node.parents, except: id) { return json(["message": "conflict"], status: 409) }
            node.name = name
        }
        if let description = body["description"] as? String {
            node.description = description.isEmpty ? nil : description
        }
        state.nodes[id] = node
        return answer(node)
    }

    private func move(into newParent: String, _ body: [String: Any]) -> StubServer.Reply {
        guard state.nodes[newParent] != nil, let childId = body["childId"] as? String,
            var node = state.nodes[childId]
        else { return .body(Data(), status: 404) }
        guard let from = body["fromParent"] as? String, node.parents.contains(from) else {
            return json(["message": "fromParent is not a parent"], status: 400)
        }
        if state.ignoreWrites { return answer(node) }
        if clash(node.name, in: [newParent], except: childId) { return json(["message": "conflict"], status: 409) }
        node.parents = node.parents.filter { $0 != from } + [newParent]
        state.nodes[childId] = node
        return answer(node)
    }

    private func setStatus(_ id: String, _ status: String) -> StubServer.Reply {
        guard var node = state.nodes[id] else { return .body(Data(), status: 404) }
        if state.ignoreWrites { return answer(node) }
        node.status = status
        state.nodes[id] = node
        return answer(node)
    }

    private func listChildren(of parent: String, filter: String?, limit: String?, start: String?) -> StubServer.Reply {
        guard state.nodes[parent] != nil else { return .body(Data(), status: 404) }
        var visible: [Node] = []
        for id in state.order {
            guard var node = state.nodes[id], node.parents.contains(parent) else { continue }
            if filter == "kind:FOLDER", node.kind != "FOLDER" { continue }
            if node.status != "AVAILABLE", !(state.listsTrashedFolders && node.kind == "FOLDER") { continue }
            if node.hiddenListings > 0 {
                if start == nil {
                    node.hiddenListings -= 1
                    state.nodes[id] = node
                }
                continue
            }
            visible.append(node)
        }
        let size = min(limit.flatMap(Int.init) ?? 200, state.pageSize ?? Int.max)
        let offset = start.flatMap { $0.hasPrefix("tok") ? Int($0.dropFirst(3)) : nil } ?? 0
        let page = Array(visible.dropFirst(offset).prefix(size))
        var answer: [String: Any] = ["count": visible.count, "data": page.map(object)]
        if offset + size < visible.count { answer["nextToken"] = "tok\(offset + size)" }
        return json(answer)
    }
}
