import Foundation
import Testing
@testable import RainbarrelCore

private func decode(_ json: String) throws -> CloudNode {
    try JSONDecoder().decode(CloudNode.self, from: Data(json.utf8))
}

/// The two texts of a `verificationFailed` error, or nil for any other outcome.
private func verification(_ error: Error?) -> (expected: String, actual: String)? {
    guard case AmazonWriteError.verificationFailed(let expected, let actual)? = error else { return nil }
    return (expected, actual)
}

private func jsonBody(_ request: StubServer.Request) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]) ?? [:]
}

private func fastWait(_ clock: FakeClock) -> FolderLookupWait {
    FolderLookupWait(delays: FolderLookupWait.standard.delays, sleep: clock.clock.sleep)
}

// MARK: The node type

@Suite("CloudNode decoding")
struct CloudNodeTests {
    @Test func decodesAFullNode() throws {
        let node = try decode(
            #"""
            {"id":"N1","name":"a.jpg","kind":"FILE","status":"AVAILABLE","parents":["P1","P2"],
             "description":"hello","labels":[],"contentProperties":{"md5":"ABCDEF0123456789ABCDEF0123456789",
             "size":1234,"contentDate":"2019-04-24T05:53:46.264Z"}}
            """#)
        #expect(
            node
                == CloudNode(
                    id: "N1", name: "a.jpg", kind: .file, status: .available, parents: ["P1", "P2"],
                    description: "hello", md5: "abcdef0123456789abcdef0123456789", size: 1234))
    }

    @Test func aFolderHasNoContentProperties() throws {
        let node = try decode(#"{"id":"D1","name":"Trip","kind":"FOLDER","status":"TRASH","parents":["ROOT"]}"#)
        #expect(node.kind == .folder && node.status == .trash)
        #expect(node.md5 == nil && node.size == nil && node.description == nil)
    }

    @Test func aFieldOfTheWrongTypeCountsAsMissing() throws {
        let node = try decode(
            #"{"id":"N2","name":5,"kind":["x"],"status":null,"parents":"P","description":7,"contentProperties":{"md5":12,"size":"2048"}}"#)
        #expect(node.name == nil && node.kind == nil && node.status == nil)
        #expect(node.parents.isEmpty && node.description == nil && node.md5 == nil)
        #expect(node.size == 2048)  // a number in quotes is accepted
        #expect(try decode(#"{"id":"N3","contentProperties":{"size":10.0}}"#).size == 10)
        #expect(try decode(#"{"id":"N4","contentProperties":{"size":10.5}}"#).size == nil)
    }

    @Test func anUnknownKindOrStatusKeepsAmazonsText() throws {
        let node = try decode(#"{"id":"N5","kind":"WEIRD","status":"available"}"#)
        #expect(node.kind == .other("WEIRD"))
        #expect(node.kind?.text == "WEIRD")
        #expect(node.status == .available)  // the case does not matter
        #expect(try decode(#"{"id":"N6","status":"PURGED"}"#).status == .purged)
        #expect(try decode(#"{"id":"N6","status":"ARCHIVED"}"#).status == .other("ARCHIVED"))
        #expect(CloudNode.Kind.asset.text == "ASSET" && CloudNode.Status.trash.text == "TRASH")
    }

    @Test func aNodeWithoutIdIsRejected() {
        #expect(throws: DecodingError.self) { _ = try decode(#"{"name":"x"}"#) }
    }
}

// MARK: Reading

@Suite("Reading nodes and folders")
struct AmazonReadTests {
    @Test func nodeReturnsTheNodeFromAmazon() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let node = try await client.node("F-1")
        #expect(node.name == "photo.jpg" && node.kind == .file && node.status == .available)
        #expect(node.parents == ["F-A"] && node.size == 1234)
        #expect(node.md5 == "0123456789abcdef0123456789abcdef")
        #expect(fx.calls == ["GET /drive/v1/nodes/F-1"])
    }

    @Test func everyCallCarriesTheStandardQueryAndTheSession() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        _ = try await client.node("F-1")
        _ = try await client.rename("F-1", to: "renamed.jpg")
        let requests = fx.server.requests(host: fx.host)
        #expect(requests.count == 2)
        for request in requests {
            #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.query == "resourceVersion=V2&ContentType=JSON")
            #expect(request.url.scheme == "https")
            #expect(request.header("x-amzn-sessionid") == fx.sessionID)
            #expect(request.header("Cookie")?.contains("session-id=") == true)
        }
        #expect(requests[1].header("Content-Type") == "application/json")
    }

    @Test func cookieValuesNeverAppearInUrlsOrBodies() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        _ = try await client.createFolder(named: "New", in: "ROOT", lookup: .immediate)
        _ = try await client.move("F-2", from: "F-A", to: "F-B")
        _ = try await client.trash("F-2")
        for request in fx.server.requests(host: fx.host) {
            let text = request.url.absoluteString + String(decoding: request.body, as: UTF8.self)
            #expect(!text.contains(fx.sessionID) && !text.contains(fx.secretToken))
        }
    }

    @Test func anUnknownNodeIsNotFound() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: AmazonWriteError.notFound) { _ = try await client.node("NOPE") }
    }

    @Test func idsThatCouldChangeThePathAreRefusedBeforeAnyRequest() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        for bad in ["", "a/b", "..", ".", "a b", "x?y", "%2e%2e", String(repeating: "a", count: 201)] {
            await #expect(throws: DownloadError.invalidNodeId(bad)) { _ = try await client.node(bad) }
            await #expect(throws: DownloadError.invalidNodeId(bad)) { _ = try await client.trash(bad) }
            await #expect(throws: DownloadError.invalidNodeId(bad)) { _ = try await client.rename(bad, to: "x") }
        }
        await #expect(throws: DownloadError.invalidNodeId("a/b")) {
            _ = try await client.move("F-1", from: "a/b", to: "F-B")
        }
        await #expect(throws: DownloadError.invalidNodeId("..")) { _ = try await client.childFolders(of: "..") }
        #expect(fx.server.requests.isEmpty)
    }

    @Test func childFoldersListsOnlyFoldersAndAsksForThemByFilter() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let folders = try await client.childFolders(of: "F-B")
        #expect(folders.map(\.id) == ["F-SUB1", "F-SUB2"])  // F-3 and F-4 are files
        #expect(folders.allSatisfy { $0.kind == .folder })
        let request = try #require(fx.server.requests(host: fx.host).first)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "filters" }?.value == "kind:FOLDER")
        #expect(items.first { $0.name == "limit" }?.value == "200")
        #expect(request.url.path == "/drive/v1/nodes/F-B/children")
    }

    @Test func childFoldersFollowsEveryPage() async throws {
        let fx = WriteFixture()
        for index in 1...5 { fx.add(.folder("F-P\(index)", "Page \(index)", in: "F-A")) }
        fx.pageSize(2)
        let client = try fx.client()
        defer { client.invalidate() }
        let folders = try await client.childFolders(of: "F-A")
        #expect(folders.map(\.id) == ["F-P1", "F-P2", "F-P3", "F-P4", "F-P5"])
        let requests = fx.server.requests(host: fx.host)
        #expect(requests.count == 3)
        let tokens = requests.map { request in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "startToken" }?.value
        }
        #expect(tokens == [nil, "tok2", "tok4"])
    }

    @Test func aFolderWithoutFoldersGivesAnEmptyList() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        #expect(try await client.childFolders(of: "F-SUB1").isEmpty)
    }

    @Test func aListingOfAnUnknownParentIsNotFound() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: AmazonWriteError.notFound) { _ = try await client.childFolders(of: "NOPE") }
    }

    @Test func aListingThatNeverAdvancesIsAnError() async throws {
        let fx = WriteFixture()
        fx.override { _ in
            .body(
                Data(#"{"count":1,"data":[{"id":"X","name":"x","kind":"FOLDER"}],"nextToken":"same"}"#.utf8),
                headers: ["Content-Type": "application/json"])
        }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.invalidResponse("the folder listing does not advance")) {
            _ = try await client.childFolders(of: "F-A")
        }
        #expect(fx.server.requests(host: fx.host).count == 2)
    }

    @Test func anAnswerThatIsNotAListingIsAnError() async throws {
        let fx = WriteFixture()
        fx.override { _ in .body(Data(#"{"hello":"world"}"#.utf8), headers: ["Content-Type": "application/json"]) }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.invalidResponse("the folder listing has no data")) {
            _ = try await client.childFolders(of: "F-A")
        }
        await #expect(throws: DownloadError.invalidResponse("the node description is not JSON")) {
            _ = try await client.node("F-A")
        }
    }

    @Test func aNodeAnswerForAnotherNodeIsAnError() async throws {
        let fx = WriteFixture()
        fx.override { _ in .body(Data(#"{"id":"OTHER","name":"x"}"#.utf8), headers: ["Content-Type": "application/json"]) }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.invalidResponse("the node description is for another node")) {
            _ = try await client.node("F-1")
        }
    }
}

// MARK: Creating a folder

@Suite("Creating a folder")
struct CreateFolderTests {
    @Test func createsTheFolderAndReturnsTheNodeFoundInTheListing() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let created = try await client.createFolder(named: "Holiday 2019", in: "F-A", lookup: .immediate)
        #expect(created.name == "Holiday 2019" && created.kind == .folder && created.status == .available)
        #expect(created.parents == ["F-A"])
        #expect(fx.node(created.id)?.name == "Holiday 2019")
        #expect(
            fx.calls == [
                "GET /drive/v1/nodes/F-A/children", "POST /drive/v1/nodes", "GET /drive/v1/nodes/F-A/children",
            ])
        let post = try #require(fx.server.requests(host: fx.host).first { $0.method == "POST" })
        #expect(post.header("Content-Type") == "application/json")
        let body = jsonBody(post)
        #expect(body["name"] as? String == "Holiday 2019" && body["kind"] as? String == "FOLDER")
        #expect(body["parents"] as? [String] == ["F-A"])
        #expect(body.count == 3)
    }

    @Test func aNewFolderThatIsListedLateIsFoundAfterShortIncreasingWaits() async throws {
        let fx = WriteFixture()
        fx.newFolderHiddenListings(3)
        let clock = FakeClock(start: noonOct16)
        let client = try fx.client()
        defer { client.invalidate() }
        let created = try await client.createFolder(named: "Late", in: "F-A", lookup: fastWait(clock))
        #expect(created.name == "Late")
        #expect(clock.sleeps == [0.5, 1, 2])
        // One listing before the create, then four lookups: three misses and the hit.
        #expect(fx.calls.filter { $0 == "GET /drive/v1/nodes/F-A/children" }.count == 5)
    }

    @Test func aFolderThatNeverShowsUpIsAVerificationFailureAfterAboutTwentySeconds() async throws {
        let fx = WriteFixture()
        fx.newFolderHiddenListings(1000)
        let clock = FakeClock(start: noonOct16)
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.createFolder(named: "Ghost", in: "F-A", lookup: fastWait(clock)) }
        let found = try #require(verification(error))
        #expect(found.expected == "a folder named \"Ghost\" in F-A")
        #expect(found.actual == "no such folder after waiting 21 seconds")
        #expect(clock.sleeps == [0.5, 1, 2, 3, 4, 5, 5])
        // One listing before, one create, eight lookups.
        #expect(fx.calls.count == 10 && fx.calls.filter { $0 == "POST /drive/v1/nodes" }.count == 1)
        let total = FolderLookupWait.standard.totalWait
        #expect(total >= 19 && total <= 22)
    }

    @Test func aCreateThatAmazonIgnoresIsAVerificationFailure() async throws {
        let fx = WriteFixture()
        fx.ignoreWrites()
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.createFolder(named: "Nothing", in: "F-A", lookup: .immediate) }
        #expect(verification(error) != nil)
        #expect(fx.node("N-NEW1") == nil)
    }

    @Test func anExistingFolderOfThatNameStopsTheCallBeforeAnyCreate() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.createFolder(named: "Sub one", in: "F-B", lookup: .immediate) }
        guard case AmazonWriteError.folderAlreadyExists(let existing)? = error else {
            Issue.record("expected folderAlreadyExists, got \(String(describing: error))")
            return
        }
        #expect(existing.id == "F-SUB1" && existing.name == "Sub one")
        #expect(fx.calls == ["GET /drive/v1/nodes/F-B/children"])  // nothing was posted
        #expect(String(describing: AmazonWriteError.folderAlreadyExists(existing: existing)).contains("F-SUB1"))
    }

    @Test func aFolderInTheTrashDoesNotCountAsExisting() async throws {
        let fx = WriteFixture()
        fx.add(.folder("F-OLD", "Holiday", in: "F-A", status: "TRASH"))
        fx.listsTrashedFolders()
        let client = try fx.client()
        defer { client.invalidate() }
        let created = try await client.createFolder(named: "Holiday", in: "F-A", lookup: .immediate)
        #expect(created.id != "F-OLD" && created.status == .available)
    }

    @Test func aFolderOfTheSameNameInAnotherParentDoesNotCount() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let created = try await client.createFolder(named: "Sub one", in: "F-A", lookup: .immediate)
        #expect(created.parents == ["F-A"] && created.id != "F-SUB1")
    }

    @Test func aNameTakenInTheMeantimeIsANameConflict() async throws {
        // The folder exists but is not listed yet, so the check before the create does not see it.
        let fx = WriteFixture()
        var race = WriteFixture.Node.folder("F-RACE", "Race", in: "ROOT")
        race.hiddenListings = 1
        fx.add(race)
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: AmazonWriteError.nameConflict) {
            _ = try await client.createFolder(named: "Race", in: "ROOT", lookup: .immediate)
        }
        #expect(fx.calls == ["GET /drive/v1/nodes/ROOT/children", "POST /drive/v1/nodes"])
    }

    @Test func anUnknownParentIsNotFoundAndNothingIsPosted() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: AmazonWriteError.notFound) {
            _ = try await client.createFolder(named: "x", in: "NOPE", lookup: .immediate)
        }
        #expect(fx.calls == ["GET /drive/v1/nodes/NOPE/children"])
    }

    @Test func aWaitThatIsCancelledEndsTheCall() async throws {
        let fx = WriteFixture()
        fx.newFolderHiddenListings(1000)
        let client = try fx.client()
        defer { client.invalidate() }
        let wait = FolderLookupWait(delays: [1, 1]) { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await client.createFolder(named: "Cancelled", in: "F-A", lookup: wait)
        }
    }
}

// MARK: Moving, renaming, describing

@Suite("Move")
struct MoveTests {
    @Test func movesAFileAndChecksTheNewParent() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let moved = try await client.move("F-2", from: "F-A", to: "F-B")
        #expect(moved.parents == ["F-B"])
        #expect(fx.node("F-2")?.parents == ["F-B"])
        #expect(fx.calls == ["POST /drive/v1/nodes/F-B/children"])  // the answer carried the node
        let body = jsonBody(try #require(fx.server.requests(host: fx.host).first))
        #expect(body["childId"] as? String == "F-2" && body["fromParent"] as? String == "F-A" && body.count == 2)
    }

    @Test func movesAFolderToo() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let moved = try await client.move("F-SUB1", from: "F-B", to: "F-A")
        #expect(moved.parents == ["F-A"] && moved.kind == .folder)
    }

    @Test func aNameAlreadyTakenInTheTargetIsANameConflict() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        // F-3 is also called photo.jpg and sits in F-B.
        await #expect(throws: AmazonWriteError.nameConflict) { _ = try await client.move("F-1", from: "F-A", to: "F-B") }
        #expect(fx.node("F-1")?.parents == ["F-A"])
    }

    @Test func unknownIdsAreNotFound() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: AmazonWriteError.notFound) { _ = try await client.move("NOPE", from: "F-A", to: "F-B") }
        await #expect(throws: AmazonWriteError.notFound) { _ = try await client.move("F-2", from: "F-A", to: "NOPE") }
    }

    @Test func aWrongOldParentIsRefused() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: AmazonWriteError.refused(status: 400)) {
            _ = try await client.move("F-2", from: "F-B", to: "F-SUB1")
        }
    }

    @Test func aMoveThatAmazonAcceptsButIgnoresIsAVerificationFailure() async throws {
        let fx = WriteFixture()
        fx.ignoreWrites()
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.move("F-2", from: "F-A", to: "F-B") }
        let found = try #require(verification(error))
        #expect(found.expected == "node F-2 has the parent F-B and no longer the parent F-A")
        #expect(found.actual == "the parents F-A")
        let text = String(describing: try #require(error))
        #expect(text.contains("did not carry it out") && text.contains(found.expected) && text.contains(found.actual))
    }

    @Test func aMoveThatLeavesTheOldParentBehindIsAVerificationFailure() async throws {
        // The node ends up with both parents: Amazon linked it instead of moving it.
        let fx = WriteFixture()
        fx.override { request in
            guard request.method == "POST", request.url.path == "/drive/v1/nodes/F-B/children" else { return nil }
            return .body(
                Data(#"{"id":"F-2","name":"notes.txt","kind":"FILE","status":"AVAILABLE","parents":["F-A","F-B"]}"#.utf8),
                headers: ["Content-Type": "application/json"])
        }
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.move("F-2", from: "F-A", to: "F-B") }
        #expect(verification(error)?.actual == "the parents F-A, F-B")
    }

    @Test func withoutANodeInTheAnswerTheNodeIsReadAgain() async throws {
        let fx = WriteFixture()
        fx.writeAnswer(.empty)
        let client = try fx.client()
        defer { client.invalidate() }
        let moved = try await client.move("F-2", from: "F-A", to: "F-B")
        #expect(moved.parents == ["F-B"])
        #expect(fx.calls == ["POST /drive/v1/nodes/F-B/children", "GET /drive/v1/nodes/F-2"])
    }

    @Test func theReadBackAlsoCatchesAnIgnoredMove() async throws {
        let fx = WriteFixture()
        fx.writeAnswer(.empty)
        fx.ignoreWrites()
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.move("F-2", from: "F-A", to: "F-B") }
        #expect(verification(error) != nil)
        #expect(fx.calls.last == "GET /drive/v1/nodes/F-2")
    }
}

@Suite("Rename and description")
struct RenameAndDescribeTests {
    @Test func renamesAndChecksTheName() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let renamed = try await client.rename("F-2", to: "2019-04-24_05-53-46.txt")
        #expect(renamed.name == "2019-04-24_05-53-46.txt")
        #expect(fx.node("F-2")?.name == "2019-04-24_05-53-46.txt")
        let request = try #require(fx.server.requests(host: fx.host).first)
        #expect(request.method == "PATCH" && request.url.path == "/drive/v1/nodes/F-2")
        let body = jsonBody(request)
        #expect(body.count == 1 && body["name"] as? String == "2019-04-24_05-53-46.txt")
    }

    @Test func namesWithQuotesAndUnicodeSurviveTheRoundTrip() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let name = "Urlaub \"Süd\" 2019 \\ 😀.jpg"
        let renamed = try await client.rename("F-2", to: name)
        #expect(renamed.name == name && fx.node("F-2")?.name == name)
    }

    @Test func aNameAlreadyTakenInTheFolderIsANameConflict() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: AmazonWriteError.nameConflict) { _ = try await client.rename("F-4", to: "photo.jpg") }
        #expect(fx.node("F-4")?.name == "other.jpg")
    }

    @Test func anUnknownNodeIsNotFound() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: AmazonWriteError.notFound) { _ = try await client.rename("NOPE", to: "x") }
        await #expect(throws: AmazonWriteError.notFound) { _ = try await client.setDescription("NOPE", to: "x") }
    }

    @Test func aRenameThatAmazonIgnoresIsAVerificationFailure() async throws {
        let fx = WriteFixture()
        fx.ignoreWrites()
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.rename("F-2", to: "new.txt") }
        let found = try #require(verification(error))
        #expect(found.expected == "node F-2 is named \"new.txt\"" && found.actual == "the name \"notes.txt\"")
    }

    @Test func aRenameWithoutANodeInTheAnswerIsReadBack() async throws {
        let fx = WriteFixture()
        fx.writeAnswer(.empty)
        let client = try fx.client()
        defer { client.invalidate() }
        _ = try await client.rename("F-2", to: "new.txt")
        #expect(fx.calls == ["PATCH /drive/v1/nodes/F-2", "GET /drive/v1/nodes/F-2"])
    }

    @Test func setsADescription() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let described = try await client.setDescription("F-1", to: "Sunset at the lake")
        #expect(described.description == "Sunset at the lake" && fx.node("F-1")?.description == "Sunset at the lake")
        let request = try #require(fx.server.requests(host: fx.host).first)
        #expect(request.method == "PATCH")
        let body = jsonBody(request)
        #expect(body.count == 1 && body["description"] as? String == "Sunset at the lake")
    }

    @Test func anEmptyDescriptionClearsItAndAbsentCountsAsEmpty() async throws {
        let fx = WriteFixture()
        var node = WriteFixture.Node.file("F-DESC", "described.jpg", in: "F-A")
        node.description = "old"
        fx.add(node)
        let client = try fx.client()
        defer { client.invalidate() }
        let cleared = try await client.setDescription("F-DESC", to: "")
        #expect(cleared.description == nil && fx.node("F-DESC")?.description == nil)
        // Clearing a description that is not there is fine as well.
        _ = try await client.setDescription("F-1", to: "")
    }

    @Test func aDescriptionThatAmazonIgnoresIsAVerificationFailure() async throws {
        let fx = WriteFixture()
        fx.ignoreWrites()
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.setDescription("F-1", to: "text") }
        let found = try #require(verification(error))
        #expect(found.expected == "node F-1 has the description \"text\"" && found.actual == "no description")
    }
}

// MARK: Trash and restore

@Suite("Trash and restore")
struct TrashTests {
    @Test func trashesAndRestoresWithTheRightCalls() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let trashed = try await client.trash("F-1")
        #expect(trashed.status == .trash && fx.node("F-1")?.status == "TRASH")
        let restored = try await client.restore("F-1")
        #expect(restored.status == .available && fx.node("F-1")?.status == "AVAILABLE")
        #expect(fx.calls == ["PUT /drive/v1/trash/F-1", "POST /drive/v1/trash/F-1/restore"])
        let requests = fx.server.requests(host: fx.host)
        #expect(requests.allSatisfy { $0.body.isEmpty })
    }

    @Test func trashingAFolderLeavesItsFilesAsTheyAre() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        let folder = try await client.trash("F-A")
        #expect(folder.status == .trash)
        #expect(fx.node("F-1")?.status == "AVAILABLE")
    }

    @Test func anUnknownNodeIsNotFound() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: AmazonWriteError.notFound) { _ = try await client.trash("NOPE") }
        await #expect(throws: AmazonWriteError.notFound) { _ = try await client.restore("NOPE") }
    }

    @Test func aTrashThatAmazonIgnoresIsAVerificationFailure() async throws {
        let fx = WriteFixture()
        fx.ignoreWrites()
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.trash("F-1") }
        let found = try #require(verification(error))
        #expect(found.expected == "node F-1 has the status TRASH" && found.actual == "the status AVAILABLE")
    }

    @Test func aRestoreThatAmazonIgnoresIsAVerificationFailure() async throws {
        let fx = WriteFixture()
        fx.add(.folder("F-GONE", "Gone", in: "ROOT", status: "TRASH"))
        fx.ignoreWrites()
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.restore("F-GONE") }
        let found = try #require(verification(error))
        #expect(found.expected == "node F-GONE has the status AVAILABLE" && found.actual == "the status TRASH")
    }

    @Test func aTrashWithoutANodeInTheAnswerIsReadBack() async throws {
        let fx = WriteFixture()
        fx.writeAnswer(.empty)
        let client = try fx.client()
        defer { client.invalidate() }
        #expect(try await client.trash("F-1").status == .trash)
        #expect(fx.calls == ["PUT /drive/v1/trash/F-1", "GET /drive/v1/nodes/F-1"])
    }

    @Test func nothingEverSendsADeleteOrAPurge() async throws {
        let fx = WriteFixture()
        let client = try fx.client()
        defer { client.invalidate() }
        _ = try await client.createFolder(named: "Tidy", in: "ROOT", lookup: .immediate)
        _ = try await client.move("F-2", from: "F-A", to: "F-B")
        _ = try await client.rename("F-2", to: "x.txt")
        _ = try await client.setDescription("F-2", to: "d")
        _ = try await client.trash("F-2")
        _ = try await client.restore("F-2")
        let methods = Set(fx.server.requests(host: fx.host).map(\.method))
        #expect(methods.isSubset(of: ["GET", "POST", "PATCH", "PUT"]))
        #expect(!fx.calls.contains { $0.contains("purge") })
    }
}

// MARK: How Amazon's answers are treated

@Suite("Answers to writes")
struct WriteAnswerTests {
    @Test func a403GoesThroughTheSessionCheckAndIsThrottlingWhileTheSessionWorks() async throws {
        let fx = WriteFixture()
        fx.override { $0.method == "PATCH" ? .body(Data(), status: 403) : nil }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.throttled(status: 403, retryAfter: nil)) {
            _ = try await client.rename("F-2", to: "x.txt")
        }
        #expect(fx.sessionChecks == 1)
    }

    @Test func a403WithARefusedSessionCheckIsAnExpiredSession() async throws {
        let fx = WriteFixture()
        fx.override { $0.method == "PUT" ? .body(Data(), status: 403) : nil }
        fx.overrideSessionCheck { _ in .body(Data(), status: 403) }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.sessionExpired) { _ = try await client.trash("F-1") }
        #expect(fx.sessionChecks == 1)  // the check does not check itself
    }

    @Test func aBurstOf403sSharesOneSessionCheck() async throws {
        let fx = WriteFixture()
        fx.override { $0.method == "POST" ? .body(Data(), status: 403) : nil }
        let client = try fx.client()
        defer { client.invalidate() }
        for index in 0..<3 {
            await #expect(throws: DownloadError.throttled(status: 403, retryAfter: nil)) {
                _ = try await client.move("F-2", from: "F-A", to: "F-SUB\(index % 2 + 1)")
            }
        }
        #expect(fx.sessionChecks == 1)
    }

    @Test func a403OnACreateIsTreatedTheSameWay() async throws {
        let fx = WriteFixture()
        fx.override { $0.method == "POST" ? .body(Data(), status: 403) : nil }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.throttled(status: 403, retryAfter: nil)) {
            _ = try await client.createFolder(named: "x", in: "F-A", lookup: .immediate)
        }
    }

    @Test func a401IsAnExpiredSession() async throws {
        let fx = WriteFixture()
        let stale = StoredSession(
            host: fx.host, cookies: [SessionCookie(name: "session-id", value: "stale-session-9999", domain: ".amazon.com")])
        let client = try fx.client(session: stale)
        defer { client.invalidate() }
        await #expect(throws: DownloadError.sessionExpired) { _ = try await client.node("F-1") }
        await #expect(throws: DownloadError.sessionExpired) { _ = try await client.trash("F-1") }
    }

    @Test func throttlingAnswersPassThroughUnchanged() async throws {
        let fx = WriteFixture()
        fx.override { request in
            switch request.url.path {
            case "/drive/v1/trash/F-1": return .body(Data(), status: 429, headers: ["Retry-After": "7"])
            case "/drive/v1/trash/F-2": return .body(Data(), status: 503)
            default: return nil
            }
        }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.throttled(status: 429, retryAfter: 7)) { _ = try await client.trash("F-1") }
        await #expect(throws: DownloadError.throttled(status: 503, retryAfter: nil)) { _ = try await client.trash("F-2") }
        #expect(fx.sessionChecks == 0)
    }

    @Test func aNetworkFailurePassesThrough() async throws {
        let fx = WriteFixture()
        fx.override { _ in .fail(.notConnectedToInternet) }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.network("no internet connection")) { _ = try await client.trash("F-1") }
    }

    @Test func anyOtherRefusalCarriesItsStatus() async throws {
        let fx = WriteFixture()
        fx.override { _ in .body(Data(), status: 422) }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: AmazonWriteError.refused(status: 422)) { _ = try await client.rename("F-2", to: "x") }
        await #expect(throws: AmazonWriteError.refused(status: 422)) { _ = try await client.node("F-2") }
    }

    @Test func aSignInPageWithASuccessStatusIsAnExpiredSession() async throws {
        let fx = WriteFixture()
        fx.override { _ in .body(Data("<html>Sign in</html>".utf8), headers: ["Content-Type": "text/html"]) }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.sessionExpired) { _ = try await client.trash("F-1") }
        await #expect(throws: DownloadError.sessionExpired) { _ = try await client.node("F-1") }
    }

    @Test func aCreatedAnswerWithAnEmptyBodyIsAccepted() async throws {
        let fx = WriteFixture()
        fx.override { request in
            request.method == "POST" && request.url.path == "/drive/v1/nodes"
                ? .body(Data(), status: 201, headers: ["Content-Type": "text/html"]) : nil
        }
        let client = try fx.client()
        defer { client.invalidate() }
        // The create itself was swallowed by the override, so the folder is not listed, but the 201
        // was taken for success: the failure is the missing folder, not the status.
        let error = await thrownError { _ = try await client.createFolder(named: "x", in: "F-A", lookup: .immediate) }
        #expect(verification(error) != nil)
    }

    @Test func aRedirectToAnotherHostIsRefusedAndNothingIsSentThere() async throws {
        let fx = WriteFixture()
        let evilHost = "evil-\(fx.host.replacingOccurrences(of: ".amazon.com", with: "")).example.org"
        let evil = StubServer(hosts: [evilHost])
        evil.handler = { _ in .body(Data(#"{}"#.utf8)) }
        fx.override { $0.method == "PUT" ? .redirect(to: "https://\(evilHost)/trash") : nil }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.redirectRefused(host: evilHost)) { _ = try await client.trash("F-1") }
        #expect(evil.requests.isEmpty)
        #expect(fx.node("F-1")?.status == "AVAILABLE")
    }

    @Test func writesAreNotSentOnToOtherAmazonHostsEither() async throws {
        let fx = WriteFixture()
        fx.override { $0.method == "PATCH" ? .redirect(to: "https://files.amazonaws.com/x") : nil }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.redirectRefused(host: "files.amazonaws.com")) {
            _ = try await client.rename("F-2", to: "x")
        }
    }

    @Test func aRedirectToANonHttpsAddressIsRefused() async throws {
        let fx = WriteFixture()
        fx.override { [host = fx.host] _ in .redirect(to: "http://\(host)/drive/v1/nodes/F-1") }
        let client = try fx.client()
        defer { client.invalidate() }
        await #expect(throws: DownloadError.redirectRefused(host: "a non-https address")) { _ = try await client.node("F-1") }
    }

    @Test func aRedirectOnTheSameHostIsAPlainReadAndTheWriteIsNotDone() async throws {
        let fx = WriteFixture()
        let host = fx.host
        fx.override { request in
            request.method == "PUT"
                ? .redirect(to: "https://\(host)/drive/v1/nodes/F-1?resourceVersion=V2&ContentType=JSON") : nil
        }
        let client = try fx.client()
        defer { client.invalidate() }
        let error = await thrownError { _ = try await client.trash("F-1") }
        #expect(verification(error)?.actual == "the status AVAILABLE")
        #expect(fx.node("F-1")?.status == "AVAILABLE")
        #expect(fx.server.requests(host: host).filter { $0.method == "GET" }.count == 1)
    }

    @Test func theErrorsHaveClearDescriptions() {
        #expect(AmazonWriteError.nameConflict.description.contains("already exists"))
        #expect(AmazonWriteError.notFound.description.contains("404"))
        #expect(AmazonWriteError.refused(status: 422).description == "Amazon refused the change (HTTP 422)")
        #expect(AmazonWriteError.refused(status: 422).errorDescription == AmazonWriteError.refused(status: 422).description)
        let verified = AmazonWriteError.verificationFailed(expected: "E", actual: "A")
        #expect(verified.description == "Amazon accepted the change but did not carry it out. Expected: E. Amazon shows: A")
        let existing = CloudNode(id: "N9", name: "Trip")
        #expect(AmazonWriteError.folderAlreadyExists(existing: existing).description.contains("\"Trip\""))
    }
}
