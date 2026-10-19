import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The write client for Amazon's `/drive/v1` API: create a folder, move, rename, describe, trash and
// restore, each followed by a check that Amazon really did it.
//
// There is deliberately no purge and no "empty the trash" call here, and `AmazonClient.DriveMethod` has
// no DELETE. Rainbarrel never removes anything from Amazon for good. Trashing is the strongest change
// it makes, and every trash can be undone with `restore(_:)` for as long as Amazon keeps its trash.

/// What can go wrong with a write besides the errors every Amazon call can have.
///
/// The calls in `AmazonClient+Writes.swift` throw these, and they pass the shared `DownloadError`
/// cases through unchanged: `sessionExpired` when the sign-in is gone, `throttled` for HTTP 429 and
/// 5xx (and for a 403 while the session still works), `network`, `invalidNodeId` and the rest. After a
/// `throttled` or `network` error a write may or may not have reached Amazon, so a caller that retries
/// must read the node again first (`node(_:)`) and compare it with what it expects.
public enum AmazonWriteError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    /// Amazon answered HTTP 409: an item with that name is already in the target folder. This is the
    /// expected answer to a rename or move that collides with an existing name; it has not been
    /// confirmed against the live API yet.
    case nameConflict
    /// Amazon answered HTTP 404: a node or folder of the call does not exist.
    case notFound
    /// `createFolder(named:in:)` found a folder of that name in the parent before it created one, and
    /// created nothing. `existing` is that folder, so that a caller who resumes can use it.
    case folderAlreadyExists(existing: CloudNode)
    /// Amazon accepted the call, but the node does not show the change afterwards. `expected` says
    /// what should be true and `actual` what Amazon shows.
    case verificationFailed(expected: String, actual: String)
    /// Amazon answered with another status that is not a success and not covered by the cases above.
    case refused(status: Int)

    public var description: String {
        switch self {
        case .nameConflict:
            return "Amazon refused the change because an item with that name already exists in the target folder (HTTP 409)"
        case .notFound:
            return "Amazon does not know a node or folder of this change (HTTP 404)"
        case .folderAlreadyExists(let existing):
            return "A folder named \"\(existing.name ?? "")\" already exists here (id \(existing.id)), so none was created"
        case .verificationFailed(let expected, let actual):
            return "Amazon accepted the change but did not carry it out. Expected: \(expected). Amazon shows: \(actual)"
        case .refused(let status):
            return "Amazon refused the change (HTTP \(status))"
        }
    }

    public var errorDescription: String? { description }
}

/// How `createFolder(named:in:)` waits for a new folder to show up in its parent's listing. Amazon
/// answers the create call with an empty body and lists the folder only after a few seconds, so the
/// call looks right away and then again after each of `delays`. Tests pass short delays and a
/// `sleep` that costs no real time.
public struct FolderLookupWait: Sendable {
    /// The waits before the second, third, and later lookups, in seconds.
    public var delays: [TimeInterval]
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(delays: [TimeInterval], sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.delays = delays
        self.sleep = sleep
    }

    /// Eight lookups over about 20 seconds, with real waiting.
    public static let standard = FolderLookupWait(
        delays: [0.5, 1, 2, 3, 4, 5, 5], sleep: DownloadClock.system.sleep)

    /// One lookup and no waiting.
    public static let immediate = FolderLookupWait(delays: [], sleep: { _ in })

    /// The longest total wait, in seconds.
    public var totalWait: TimeInterval { delays.reduce(0, +) }
}

extension AmazonEndpoints {
    /// The query that every `/drive/v1` call of the web client carries.
    static let apiQuery = "resourceVersion=V2&ContentType=JSON"

    /// Characters that need no escaping inside a query value.
    private static let queryValueSafe = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func queryEscaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueSafe) ?? ""
    }
}

extension AmazonClient {
    /// The biggest answer a write or a node read collects. A page of 200 folders is far below it.
    private static let driveCollectLimit = 8_000_000
    private static let childPageSize = 200

    // MARK: Reading

    /// The node `id`, as Amazon describes it now.
    public func node(_ id: String) async throws -> CloudNode {
        let response = try await send(try driveRequest(.get, ["nodes", id]))
        return try Self.decodeNode(response.body, expecting: id)
    }

    /// Every folder directly below `parentId`, over all pages of the listing, in Amazon's order.
    /// A folder that was created a moment ago can be missing for a few seconds.
    public func childFolders(of parentId: String) async throws -> [CloudNode] {
        struct Page: Decodable {
            var count: Int?
            var data: [CloudNode]?
            var nextToken: String?
        }
        var folders: [CloudNode] = []
        var token: String?
        var seenTokens: Set<String> = []
        repeat {
            var query = "filters=\(AmazonEndpoints.queryEscaped("kind:FOLDER"))&limit=\(Self.childPageSize)"
            if let token { query += "&startToken=\(AmazonEndpoints.queryEscaped(token))" }
            query += "&" + AmazonEndpoints.apiQuery
            let response = try await send(try driveRequest(.get, ["nodes", parentId, "children"], query: query))
            guard let page = try? JSONDecoder().decode(Page.self, from: response.body) else {
                throw DownloadError.invalidResponse("the folder listing is not JSON")
            }
            guard let data = page.data ?? (page.count == 0 ? [] : nil) else {
                throw DownloadError.invalidResponse("the folder listing has no data")
            }
            folders.append(contentsOf: data)
            token = page.nextToken.flatMap { $0.isEmpty ? nil : $0 }
            if let token, !seenTokens.insert(token).inserted {
                throw DownloadError.invalidResponse("the folder listing does not advance")
            }
        } while token != nil
        return folders
    }

    // MARK: Writing

    /// Create the folder `name` below `parentId` and return it.
    ///
    /// Amazon answers the create call with an empty body, so the new folder is found by name in the
    /// parent's listing, looked up as `lookup` says (the default waits up to about 20 seconds).
    /// Before anything is created the parent's folders are listed: when one with that name is there,
    /// `AmazonWriteError.folderAlreadyExists` is thrown and nothing is created, so a repeated call
    /// never makes a duplicate. Folders that are in the trash do not count. When the folder is still not
    /// listed after the last wait, `verificationFailed` is thrown; the folder may show up later, so
    /// look for it before creating it again. This call makes at least two and at most nine requests.
    public func createFolder(
        named name: String, in parentId: String, lookup: FolderLookupWait = .standard
    ) async throws -> CloudNode {
        if let existing = Self.folder(named: name, in: try await childFolders(of: parentId)) {
            throw AmazonWriteError.folderAlreadyExists(existing: existing)
        }
        struct Body: Encodable {
            var name: String
            var kind = "FOLDER"
            var parents: [String]
        }
        let body = try Self.json(Body(name: name, parents: [parentId]))
        _ = try await send(try driveRequest(.post, ["nodes"], body: body))
        var waits = [0] + lookup.delays
        while !waits.isEmpty {
            let delay = waits.removeFirst()
            if delay > 0 { try await lookup.sleep(delay) }
            if let created = Self.folder(named: name, in: try await childFolders(of: parentId)) { return created }
        }
        throw AmazonWriteError.verificationFailed(
            expected: "a folder named \"\(name)\" in \(parentId)",
            actual: "no such folder after waiting \(Int(lookup.totalWait.rounded())) seconds")
    }

    /// Move `id` from the folder `oldParent` into `newParent`. The answer must show `newParent` among
    /// the node's parents and `oldParent` no longer there. A name that is already taken in `newParent`
    /// throws `nameConflict`.
    public func move(_ id: String, from oldParent: String, to newParent: String) async throws -> CloudNode {
        struct Body: Encodable {
            var fromParent: String
            var childId: String
        }
        try Self.requireDriveSegment(oldParent)  // it travels in the body, not in the path
        let body = try Self.json(Body(fromParent: oldParent, childId: id))
        let response = try await send(try driveRequest(.post, ["nodes", newParent, "children"], body: body))
        return try await settle(response, id: id, expecting: .parents(present: newParent, absent: oldParent))
    }

    /// Give `id` the name `name`. A name that is already taken in the node's folder throws
    /// `nameConflict`.
    public func rename(_ id: String, to name: String) async throws -> CloudNode {
        struct Body: Encodable { var name: String }
        let response = try await send(try driveRequest(.patch, ["nodes", id], body: try Self.json(Body(name: name))))
        return try await settle(response, id: id, expecting: .name(name))
    }

    /// Set the description of `id`. An empty `description` is how a description is cleared; the check
    /// treats a node without a description and one with an empty description as the same.
    public func setDescription(_ id: String, to description: String) async throws -> CloudNode {
        struct Body: Encodable { var description: String }
        let response = try await send(
            try driveRequest(.patch, ["nodes", id], body: try Self.json(Body(description: description))))
        return try await settle(response, id: id, expecting: .description(description))
    }

    /// Put `id` into Amazon's trash. Trashing a folder leaves the files inside it as they are, so a
    /// cleanup trashes the files one by one before it trashes the emptied folder.
    public func trash(_ id: String) async throws -> CloudNode {
        let response = try await send(try driveRequest(.put, ["trash", id]))
        return try await settle(response, id: id, expecting: .status(.trash))
    }

    /// Take `id` out of Amazon's trash again.
    public func restore(_ id: String) async throws -> CloudNode {
        let response = try await send(try driveRequest(.post, ["trash", id, "restore"]))
        return try await settle(response, id: id, expecting: .status(.available))
    }

    // MARK: Sending and checking

    /// Send one call. Redirects are followed only within Amazon's own API host (see `driveRedirect`),
    /// 401 and 403 go through the shared session check of `check(_:)`, and HTTP 404, 409 and other
    /// refusals become `AmazonWriteError` cases. Any 2xx counts as accepted, because the create call
    /// answers 201; whether the change really happened is decided by the caller's check afterwards.
    private func send(_ request: URLRequest) async throws -> StreamingSession.Response {
        let response = try await streaming.perform(
            request, timeouts: timeouts, collectLimit: Self.driveCollectLimit, onData: nil,
            redirect: { [self] in driveRedirect(to: $0) })
        do {
            try await check(response)
        } catch DownloadError.httpStatus(let status) {
            switch status {
            case 200...299: break
            case 404: throw AmazonWriteError.notFound
            case 409: throw AmazonWriteError.nameConflict
            default: throw AmazonWriteError.refused(status: status)
            }
        }
        // A sign-in page that comes back with a success status is not an answer to the call.
        if !response.body.isEmpty, response.contentType?.lowercased().hasPrefix("text/html") == true {
            throw DownloadError.sessionExpired
        }
        return response
    }

    /// A redirect of a write is followed only when it stays on this client's own host and is https,
    /// through `redirectRequest`, which builds it from scratch with the session's credentials for that
    /// host. Unlike downloads, writes are not sent on to other Amazon, AWS or CloudFront hosts. A
    /// followed redirect is a plain GET, so it cannot carry out a write; the check after the call then
    /// finds the node unchanged.
    private func driveRedirect(to url: URL) -> URLRequest? {
        guard url.host?.lowercased() == host else { return nil }
        return redirectRequest(to: url)
    }

    /// What a write promises about the node afterwards.
    private enum Expectation {
        case parents(present: String, absent: String)
        case name(String)
        case description(String)
        case status(CloudNode.Status)

        func expected(for id: String) -> String {
            switch self {
            case .parents(let present, let absent):
                return present == absent
                    ? "node \(id) has the parent \(present)"
                    : "node \(id) has the parent \(present) and no longer the parent \(absent)"
            case .name(let name):
                return "node \(id) is named \"\(name)\""
            case .description(let text):
                return text.isEmpty ? "node \(id) has no description" : "node \(id) has the description \"\(text)\""
            case .status(let status):
                return "node \(id) has the status \(status.text)"
            }
        }

        /// Nil when `node` shows the change; otherwise a description of what it shows instead.
        func mismatch(in node: CloudNode) -> String? {
            switch self {
            case .parents(let present, let absent):
                if node.parents.contains(present), present == absent || !node.parents.contains(absent) { return nil }
                return node.parents.isEmpty ? "no parents" : "the parents \(node.parents.joined(separator: ", "))"
            case .name(let name):
                if node.name == name { return nil }
                return node.name.map { "the name \"\($0)\"" } ?? "no name"
            case .description(let text):
                if (node.description ?? "") == text { return nil }
                return node.description.map { "the description \"\($0)\"" } ?? "no description"
            case .status(let status):
                if node.status == status { return nil }
                return node.status.map { "the status \($0.text)" } ?? "no status"
            }
        }
    }

    /// The node after a write: the one in Amazon's answer when it has one for `id`, and otherwise the
    /// node read again. Throws `verificationFailed` when it does not show the change.
    private func settle(
        _ response: StreamingSession.Response, id: String, expecting expectation: Expectation
    ) async throws -> CloudNode {
        let returned = try? JSONDecoder().decode(CloudNode.self, from: response.body)
        let current: CloudNode
        if let returned, returned.id == id {
            current = returned
        } else {
            current = try await node(id)
        }
        if let actual = expectation.mismatch(in: current) {
            throw AmazonWriteError.verificationFailed(expected: expectation.expected(for: id), actual: actual)
        }
        return current
    }

    private static func decodeNode(_ body: Data, expecting id: String) throws -> CloudNode {
        guard let node = try? JSONDecoder().decode(CloudNode.self, from: body) else {
            throw DownloadError.invalidResponse("the node description is not JSON")
        }
        guard node.id == id else {
            throw DownloadError.invalidResponse("the node description is for another node")
        }
        return node
    }

    /// The folder called `name` among `folders`, ignoring ones in the trash.
    private static func folder(named name: String, in folders: [CloudNode]) -> CloudNode? {
        folders.first { $0.name == name && $0.status != .trash && $0.status != .purged }
    }

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
