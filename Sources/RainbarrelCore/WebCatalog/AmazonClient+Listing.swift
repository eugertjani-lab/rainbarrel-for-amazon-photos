import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AmazonEndpoints {
    /// Characters that need no escaping inside a query value.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }

    /// `GET nodes?filters=...&limit=...`: a filtered listing, here only for the `count` in its answer.
    static func listURL(host: String, filter: String, limit: Int) throws -> URL {
        guard isValidHost(host) else { throw DownloadError.invalidHost(host) }
        let query = "filters=\(escaped(filter))&limit=\(limit)&resourceVersion=V2&ContentType=JSON"
        return try build(host: host, path: "/drive/v1/nodes", query: query)
    }

    /// `POST changes`: the change feed.
    static func changesURL(host: String) throws -> URL {
        guard isValidHost(host) else { throw DownloadError.invalidHost(host) }
        return try build(host: host, path: "/drive/v1/changes", query: "resourceVersion=V2&ContentType=JSON")
    }

    private static func build(host: String, path: String, query: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        components.percentEncodedQuery = query
        guard let url = components.url else { throw DownloadError.invalidHost(host) }
        return url
    }
}

/// One line of the change feed that carries nodes.
struct WebFeedChunk: Sendable, Equatable {
    var nodes: [WebNode]
    var undecodable: Int
    var checkpoint: String?
    var reset: Bool
}

/// The answer of one `changes` call.
struct WebChangeFeed: Sendable, Equatable {
    var chunks: [WebFeedChunk]

    var reset: Bool { chunks.contains { $0.reset } }
    var nodeCount: Int { chunks.reduce(0) { $0 + $1.nodes.count + $1.undecodable } }
    var lastCheckpoint: String? { chunks.reversed().lazy.compactMap(\.checkpoint).first }
}

extension AmazonClient {
    /// One cheap call that shows whether the session works: it asks for the number of files in the
    /// account (a listing of one node). Throws `DownloadError.sessionExpired` when Amazon refuses the
    /// session (401 or 403) or answers with a sign-in page. The menu-bar app uses it to check a fresh
    /// sign-in, and the client uses it to find out what a 403 means, so a 403 here is final.
    public func verifySession() async throws -> Int {
        try await availableFileCount(confirmForbidden: false)
    }

    /// The number of photo and video files Amazon has right now, from the `count` of a listing that
    /// asks for a single node. A 403 is checked like any other (see `check`) unless `confirmForbidden` is false.
    func availableFileCount(confirmForbidden: Bool = true) async throws -> Int {
        let url = try AmazonEndpoints.listURL(host: host, filter: "kind:FILE AND status:AVAILABLE", limit: 1)
        let response = try await streaming.perform(
            try request(for: url), timeouts: timeouts, collectLimit: 1_000_000, onData: nil,
            redirect: { [self] in redirectRequest(to: $0) })
        try await check(response, confirmForbidden: confirmForbidden)
        try rejectSignInPage(response)
        struct Payload: Decodable { var count: Int }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body), payload.count >= 0 else {
            throw DownloadError.invalidResponse("the file count is missing")
        }
        return payload.count
    }

    /// The changes after `checkpoint`, or from the beginning of the account's history without one. At
    /// most about `maxNodes` nodes come back; call again with the last checkpoint to continue.
    func fetchChanges(checkpoint: String?, maxNodes: Int) async throws -> WebChangeFeed {
        struct RequestBody: Encodable {
            var includePurged = "true"
            var maxNodes: Int
            var checkpoint: String?
        }
        let url = try AmazonEndpoints.changesURL(host: host)
        let body = try JSONEncoder().encode(RequestBody(maxNodes: maxNodes, checkpoint: checkpoint))
        // The answer to 10,000 nodes is about 14 MB that Amazon may assemble before it sends the first
        // byte, so a change-feed call waits three times as long for it as other calls do.
        let patient = AmazonClient.Timeouts(request: timeouts.request * 3, stall: timeouts.stall)
        let response = try await streaming.perform(
            try request(for: url, body: body, timeouts: patient), timeouts: patient, collectLimit: 256_000_000,
            onData: nil, redirect: { [self] in redirectRequest(to: $0) })
        try await check(response)
        try rejectSignInPage(response)
        return try Self.parseChangeFeed(response.body)
    }

    /// A sign-in page that comes back with status 200 would otherwise be taken for the answer.
    private func rejectSignInPage(_ response: StreamingSession.Response) throws {
        if response.contentType?.lowercased().hasPrefix("text/html") == true {
            throw DownloadError.sessionExpired
        }
    }

    /// The feed is one JSON object per line: chunks with nodes and a checkpoint, then `{"end":true}`.
    static func parseChangeFeed(_ body: Data) throws -> WebChangeFeed {
        struct Line: Decodable {
            var nodes: LossyNodes?
            var checkpoint: String?
            var reset: Bool?
            var statusCode: Int?
            var end: Bool?
        }
        var chunks: [WebFeedChunk] = []
        var ended = false
        for lineData in body.split(separator: UInt8(ascii: "\n")) {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(lineData)) else {
                if lineData.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
                throw DownloadError.invalidResponse("the change feed contains a line that is not valid JSON")
            }
            if let status = line.statusCode, !(200..<300).contains(status) {
                if status == 401 || status == 403 { throw DownloadError.sessionExpired }
                throw DownloadError.invalidResponse("the change feed reported HTTP \(status)")
            }
            if line.end == true {
                ended = true
                continue
            }
            guard line.nodes != nil || line.checkpoint != nil else { continue }
            chunks.append(WebFeedChunk(
                nodes: line.nodes?.nodes ?? [], undecodable: line.nodes?.undecodable ?? 0,
                checkpoint: line.checkpoint.flatMap { $0.isEmpty ? nil : $0 }, reset: line.reset ?? false))
        }
        guard ended else {
            throw DownloadError.invalidResponse("the change feed ended before its last line")
        }
        return WebChangeFeed(chunks: chunks)
    }
}
