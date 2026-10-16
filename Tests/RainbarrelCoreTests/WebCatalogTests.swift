import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Web API catalog source")
struct WebCatalogTests {
    private let oldItem = CloudItem(nodeId: "OLD-1", kind: .file, name: "old.jpg", md5: md5("a"), size: 11, takenAt: t2015, ext: "jpg", parentId: "OLD-F")
    private let oldFolder = CloudFolder(nodeId: "OLD-F", name: "Old", parentId: nil)

    /// A catalog from the desktop app index, as if refreshed earlier.
    private func seedOldCatalog(_ store: StateStore) throws {
        try CatalogRefresher(store: store).refresh(from: StaticCatalog(items: [oldItem], folders: [oldFolder]))
    }

    private func expectOldCatalog(_ store: StateStore) throws {
        #expect(try storedItems(store) == [oldItem])
        #expect(try storedFolders(store) == [oldFolder])
        #expect(try store.catalogOrigin() == .app)
        #expect(try store.catalogCheckpoint() == nil)
    }

    // MARK: Full read

    @Test func aFullReadDrainsTheChangeFeedFromScratchAcrossSeveralAnswers() async throws {
        let fx = try WebFixture()
        fx.chunkSize = 2  // thirteen nodes in seven chunks
        fx.chunksPerResponse = 3  // so the feed needs more than one answer
        let store = try fx.store()
        let outcome = try await fx.refresher(store).refresh(web: try fx.source())

        #expect(outcome.origin == .web && outcome.mode == .full)
        #expect(outcome.result.itemCount == 5 && outcome.result.folderCount == 3)
        #expect(outcome.result.skippedCount == 3)  // two files and one Live Photo video without MD5 or size
        #expect(outcome.result.warnings.isEmpty)

        // From the beginning, then from the last checkpoint of each answer, until an answer has no nodes.
        #expect(fx.changeRequests.map(WebFixture.checkpoint(of:)) == [nil, "cp-3", "cp-6", "cp-7"])
        let first = try #require(fx.server.requests.first)
        #expect(first.method == "POST" && first.url.path == "/drive/v1/changes")
        let body = String(decoding: first.body, as: UTF8.self)
        #expect(body.contains("\"includePurged\":\"true\"") && body.contains("\"maxNodes\":10000"))
        #expect(!body.contains("checkpoint"))
        // The position the drain ended with is the baseline for incremental refreshes.
        #expect(try store.catalogCheckpoint() == CatalogCheckpoint(source: .web, host: fx.host, token: "cp-7"))

        // No listing of nodes; the one request for the file count comes last.
        let last = try #require(fx.server.requests.last)
        #expect(last.method == "GET" && fx.listingRequests.count == 1 && fx.listingRequests.first?.url == last.url)
        #expect(WebFixture.filter(of: last) == "kind:FILE AND status:AVAILABLE")
        let query = try #require(last.url.query)
        #expect(query.contains("filters=kind%3AFILE%20AND%20status%3AAVAILABLE"))
        #expect(query.contains("limit=1&") && query.contains("resourceVersion=V2") && query.contains("ContentType=JSON"))

        for request in fx.server.requests {
            #expect(request.url.scheme == "https" && request.url.host == fx.host)
            #expect(request.header("x-amzn-sessionid") == fx.sessionID)
            let cookie = try #require(request.header("Cookie"))
            #expect(cookie.contains("session-id=\(fx.sessionID)") && cookie.contains("session-token="))
            #expect(!cookie.contains("other-site"))
        }
    }

    @Test func theLastWordAboutANodeWinsWhenTheFeedRepeatsIt() async throws {
        let fx = try WebFixture()
        // The library as first sent, then the changes that came after: F1 trashed, F2 renamed, a folder
        // purged, a skipped Live Photo video completed, and a file that was trashed and then restored.
        fx.addChanges([
            .file("T-F1", "one.jpg", md5: "1", size: 100, status: "TRASH"),
            .file("T-F2", "two-renamed.heic", md5: "2", size: 200, parent: "T-D1"),
            .folder("T-D1", "Pictures", parent: "T-ROOT", status: "PURGED"),
            .live("T-L2", parent: "T-F3", md5: "8", size: 50),
            .file("T-F3", "three.png", md5: "3", size: 300, status: "TRASH"),
        ])
        fx.addChanges([.file("T-F3", "three-back.png", md5: "3", size: 300)])
        let store = try fx.store()
        let outcome = try await fx.refresher(store).refresh(web: try fx.source())

        let items = try storedItems(store)
        #expect(items.map(\.nodeId) == ["T-F2", "T-F3", "T-F6", "T-L1", "T-L2"])  // F1 is gone
        #expect(items.first { $0.nodeId == "T-F2" }?.name == "two-renamed.heic")
        #expect(items.first { $0.nodeId == "T-F2" }?.md5 == md5("2"))
        #expect(items.first { $0.nodeId == "T-F3" }?.name == "three-back.png")
        #expect(try storedFolders(store).map(\.nodeId) == ["T-D2", "T-ROOT"])
        #expect(outcome.result.itemCount == 5 && outcome.result.folderCount == 2)
        // F4 and F5 are the only nodes left without MD5 or size; L2 got its data in the end.
        #expect(outcome.result.skippedCount == 2)
        #expect(outcome.result.warnings.isEmpty)
        #expect(try store.catalogCheckpoint()?.token == "cp-3")
    }

    @Test func aTrashedNodeThatWasNeverAvailableLeavesNothingBehind() async throws {
        let fx = try WebFixture()
        fx.setLibrary(
            folders: [.folder("T-ROOT", "Root", parent: nil, root: true)],
            files: [.file("T-F1", "one.jpg", md5: "1", size: 1, status: "TRASH"), .file("T-F2", "two.jpg", md5: "2", size: 2)],
            assets: [.live("T-L1", parent: "T-F2", md5: "7", size: 5, status: "PURGED")])
        let store = try fx.store()
        let outcome = try await fx.refresher(store).refresh(web: try fx.source())
        #expect(try storedItems(store).map(\.nodeId) == ["T-F2"])
        #expect(outcome.result.itemCount == 1 && outcome.result.folderCount == 1 && outcome.result.skippedCount == 0)
    }

    @Test func aResetDuringTheDrainDiscardsWhatWasStagedBefore() async throws {
        let fx = try WebFixture()
        fx.setLibrary(
            folders: [.folder("T-ROOT", "Root", parent: nil, root: true)],
            files: [.file("T-X1", "x1.jpg", md5: "1", size: 1), .file("T-X2", "x2.jpg", md5: "2", size: 2), .file("T-X3", "x3.jpg", md5: "3", size: 3)],
            assets: [])
        fx.chunkSize = 1
        fx.chunksPerResponse = 2
        fx.resetChunks = [2]  // the second answer starts the library anew: the folder and X1 are not part of it any more
        fx.fileCountOffset = -1  // Amazon no longer has X1 either
        let store = try fx.store()
        let outcome = try await fx.refresher(store).refresh(web: try fx.source())

        #expect(try storedItems(store).map(\.nodeId) == ["T-X2", "T-X3"])
        #expect(try storedFolders(store).isEmpty)
        #expect(outcome.result.itemCount == 2 && outcome.result.folderCount == 0)
        #expect(outcome.result.warnings.isEmpty)
        #expect(try store.catalogCheckpoint()?.token == "cp-4")
    }

    @Test func aFileCountThatDiffersFromTheCatalogGivesAWarningAndKeepsTheCatalog() async throws {
        let fx = try WebFixture()
        fx.fileCountOffset = 3  // three uploads landed after the drain
        let store = try fx.store()
        let outcome = try await fx.refresher(store).refresh(web: try fx.source())

        #expect(outcome.result.itemCount == 5)
        #expect(try storedItems(store).count == 5 && store.catalogOrigin() == .web)
        #expect(try store.catalogCheckpoint()?.token == "cp-1")
        let warning = try #require(outcome.result.warnings.first)
        #expect(outcome.result.warnings.count == 1)
        #expect(warning.contains("counts 9 photos and videos") && warning.contains("delivered 4"))
        #expect(warning.contains("2 more were left out"))  // F4 and F5 have no MD5 or size

        // The warning travels to the tool summary as well.
        let tools = try fx.tools()
        let summary = try await tools.refreshCatalog(source: .web, full: true)
        #expect(summary.warnings.count == 1 && summary.warnings[0].contains("delivered 4"))
    }

    @Test func aFileCountThatCannotBeReadIsAWarningNotAFailure() async throws {
        let fx = try WebFixture()
        fx.overrideNodes { _ in .body(Data(#"{"message":"expired"}"#.utf8), status: 401, headers: ["Content-Type": "application/json"]) }
        let store = try fx.store()
        let outcome = try await fx.refresher(store).refresh(web: try fx.source())
        #expect(outcome.result.itemCount == 5 && outcome.result.warnings.count == 1)
        #expect(outcome.result.warnings[0].contains("Could not check the catalog"))
        #expect(try storedItems(store).count == 5)

        // A count without a number is no better.
        fx.overrideNodes { _ in .body(Data(#"{"data":[]}"#.utf8), headers: ["Content-Type": "application/json"]) }
        let second = try await fx.refresher(store).refresh(web: try fx.source(), full: true)
        #expect(second.result.warnings.count == 1 && second.mode == .full)
    }

    @Test func theStoredCatalogHasTheValuesTheDesktopIndexProduces() async throws {
        let fx = try WebFixture()
        let store = try fx.store()
        try await fx.refresher(store).refresh(web: try fx.source())

        #expect(try storedFolders(store) == [
            CloudFolder(nodeId: "T-D1", name: "Pictures", parentId: "T-ROOT"),
            CloudFolder(nodeId: "T-D2", name: "Phone", parentId: "T-D1"),
            CloudFolder(nodeId: "T-ROOT", name: "Root", parentId: nil),  // the root has no parent
        ])
        #expect(try storedItems(store) == [
            CloudItem(nodeId: "T-F1", kind: .file, name: "one.jpg", md5: md5("1"), size: 100, takenAt: 1_556_085_226, ext: "jpg", parentId: "T-D2"),
            // Upper-case MD5 is lowered; no contentDate falls back to createdDate.
            CloudItem(nodeId: "T-F2", kind: .file, name: "two.heic", md5: "abcdef0123456789abcdef0123456789", size: 200, takenAt: 1_556_704_800, ext: "heic", parentId: "T-D1"),
            // No fraction in the date; the extension comes from the name.
            CloudItem(nodeId: "T-F3", kind: .file, name: "three.png", md5: md5("3"), size: 300, takenAt: 1_582_977_600, ext: "png", parentId: "T-D2"),
            // Neither date parses.
            CloudItem(nodeId: "T-F6", kind: .file, name: "six.mov", md5: md5("6"), size: 600, takenAt: 0, ext: "jpg", parentId: "T-D2"),
            // The Live Photo video points at its photo; the other assets are not in the catalog.
            CloudItem(nodeId: "T-L1", kind: .liveVideo, name: "T-L1.mov", md5: md5("7"), size: 50, takenAt: 1_556_704_800, ext: "mov", parentId: "T-F1"),
        ])
        #expect(try store.catalogOrigin() == .web)
        #expect(try store.getMeta(MetaKey.catalogItemCount) == "5" && store.getMeta(MetaKey.catalogFolderCount) == "3")
    }

    @Test func nodeMappingCoversTheEdgeCases() throws {
        func node(_ json: String) throws -> WebNode { try JSONDecoder().decode(WebNode.self, from: Data(json.utf8)) }

        // A size sent as a whole double, a null assetProperties and unknown fields are fine.
        let live = try node(#"{"id":"X1","name":"a_lpv","kind":"ASSET","status":"AVAILABLE","parents":["P1"],"contentProperties":{"md5":"\#(md5("c"))","size":10.0,"contentDate":"2019-04-24T05:53:46Z"},"assetProperties":{"assetType":"LIVE_VIDEO"},"extra":{"a":1}}"#)
        #expect(WebNodeMapping.disposition(of: live) == .item(CloudItem(
            nodeId: "X1", kind: .liveVideo, name: "a_lpv", md5: md5("c"), size: 10, takenAt: 1_556_085_226, ext: nil, parentId: "P1")))

        let plainAsset = try node(#"{"id":"X2","kind":"ASSET","status":"AVAILABLE","contentProperties":{"md5":"\#(md5("c"))","size":10},"assetProperties":null}"#)
        #expect(WebNodeMapping.disposition(of: plainAsset) == .ignored)
        let otherAsset = try node(#"{"id":"X3","kind":"ASSET","status":"AVAILABLE","assetProperties":{"assetType":"THUMBNAIL"}}"#)
        #expect(WebNodeMapping.disposition(of: otherAsset) == .ignored)

        let noMD5 = try node(#"{"id":"X4","kind":"FILE","status":"AVAILABLE","contentProperties":{"size":10}}"#)
        #expect(WebNodeMapping.disposition(of: noMD5) == .skipped)
        let badMD5 = try node(#"{"id":"X5","kind":"FILE","status":"AVAILABLE","contentProperties":{"md5":"xyz","size":10}}"#)
        #expect(WebNodeMapping.disposition(of: badMD5) == .skipped)
        let noSize = try node(#"{"id":"X6","kind":"FILE","status":"AVAILABLE","contentProperties":{"md5":"\#(md5("c"))"}}"#)
        #expect(WebNodeMapping.disposition(of: noSize) == .skipped)
        let noContent = try node(#"{"id":"X7","kind":"FILE","status":"AVAILABLE"}"#)
        #expect(WebNodeMapping.disposition(of: noContent) == .skipped)

        let trashed = try node(#"{"id":"X8","kind":"FILE","status":"TRASH","contentProperties":{"md5":"\#(md5("c"))","size":10}}"#)
        #expect(WebNodeMapping.disposition(of: trashed) == .removed)
        let purged = try node(#"{"id":"X9","kind":"FOLDER","status":"PURGED"}"#)
        #expect(WebNodeMapping.disposition(of: purged) == .removed)

        // A folder under the root keeps its parent; the root folder has none even if `parents` is set.
        let folder = try node(#"{"id":"D1","name":"Trips","kind":"FOLDER","status":"AVAILABLE","isRoot":false,"parents":["R"]}"#)
        #expect(WebNodeMapping.disposition(of: folder) == .folder(CloudFolder(nodeId: "D1", name: "Trips", parentId: "R")))
        let root = try node(#"{"id":"R","kind":"FOLDER","status":"AVAILABLE","isRoot":true,"parents":["junk"]}"#)
        #expect(WebNodeMapping.disposition(of: root) == .folder(CloudFolder(nodeId: "R", name: "", parentId: nil)))

        // A field of the wrong type counts as missing; a node without id cannot be read at all.
        let odd = try node(#"{"id":"Y1","name":7,"kind":"FILE","status":"AVAILABLE","contentProperties":{"md5":"\#(md5("d"))","size":"12","extension":4}}"#)
        #expect(WebNodeMapping.disposition(of: odd) == .item(CloudItem(
            nodeId: "Y1", kind: .file, name: "", md5: md5("d"), size: 12, takenAt: 0, ext: nil, parentId: nil)))
        let lossy = try JSONDecoder().decode(LossyNodes.self, from: Data(#"[{"id":"Z1"},{"name":"no id"},"text",{"id":"Z2"}]"#.utf8))
        #expect(lossy.nodes.map(\.id) == ["Z1", "Z2"] && lossy.undecodable == 2)
    }

    @Test func timestampsParseWithAndWithoutFractionsAndOffsets() {
        #expect(WebDate.unixSeconds("2019-04-24T05:53:46.264Z") == 1_556_085_226)
        #expect(WebDate.unixSeconds("2019-04-24T05:53:46Z") == 1_556_085_226)
        #expect(WebDate.unixSeconds("2019-04-24T07:53:46+02:00") == 1_556_085_226)
        #expect(WebDate.unixSeconds("2019-04-23T22:53:46.5-07:00") == 1_556_085_226)
        #expect(WebDate.unixSeconds("2019-04-24T05:53:46") == 1_556_085_226)  // no zone: UTC
        #expect(WebDate.unixSeconds("2020-02-29T12:00:00Z") == 1_582_977_600)
        #expect(WebDate.unixSeconds("1970-01-01T00:00:00.000Z") == 0)
        #expect(WebDate.unixSeconds("1969-12-31T23:59:59.999Z") == -1)
        #expect(WebDate.unixSeconds("2019-02-29T12:00:00Z") == nil)  // not a leap year
        #expect(WebDate.unixSeconds("2019-13-01T00:00:00Z") == nil)
        #expect(WebDate.unixSeconds("2019-04-24") == nil)
        #expect(WebDate.unixSeconds("2019-04-24T05:53:46.Z") == nil)
        #expect(WebDate.unixSeconds("yesterday") == nil)
        #expect(WebDate.unixSeconds("") == nil)
        #expect(WebDate.unixSeconds(nil) == nil)
    }

    // MARK: Failures keep the old catalog

    @Test func aRejectedSessionMidDrainLeavesTheOldCatalogUntouched() async throws {
        let fx = try WebFixture()
        fx.chunkSize = 2
        fx.chunksPerResponse = 3  // the drain needs several answers; the second one is refused
        let store = try fx.store()
        try seedOldCatalog(store)
        fx.overrideChanges { index in
            index == 1
                ? .body(Data(#"{"message":"expired"}"#.utf8), status: 401, headers: ["Content-Type": "application/json"])
                : nil
        }
        let error = await thrownError { try await fx.refresher(store).refresh(web: try fx.source()) }
        #expect(error as? DownloadError == .sessionExpired)
        #expect(fx.changeRequests.count == 2)  // it stopped at the failing answer, after staging the first
        #expect(fx.listingRequests.isEmpty)
        try expectOldCatalog(store)

        // Nothing is left half done: the next read with a good session works.
        fx.overrideChanges(nil)
        let outcome = try await fx.refresher(store).refresh(web: try fx.source())
        #expect(outcome.mode == .full && outcome.result.itemCount == 5)
        #expect(try store.catalogOrigin() == .web)
        #expect(try storedItems(store).count == 5)
    }

    @Test func aSessionErrorSurfacesAsTheSignInAgainMessage() async throws {
        let fx = try WebFixture()
        let tools = try fx.tools()
        _ = try await tools.refreshCatalog()  // first, a working catalog
        fx.overrideChanges { _ in .body(Data(), status: 403) }
        let error = await thrownError { _ = try await tools.refreshCatalog(full: true) }
        let message = (error as? ToolError)?.message ?? "\(String(describing: error))"
        #expect(message.contains("sign in again"))
        #expect(!message.contains(fx.sessionID) && !message.contains(fx.secretToken))
        #expect(try fx.store().cloudItemCount() == 5)
    }

    @Test func aSignInPageWithStatus200IsASessionError() async throws {
        let fx = try WebFixture()
        fx.answersWithSignInPage = true
        let store = try fx.store()
        try seedOldCatalog(store)
        let error = await thrownError { try await fx.refresher(store).refresh(web: try fx.source()) }
        #expect(error as? DownloadError == .sessionExpired)
        try expectOldCatalog(store)
    }

    @Test func malformedAnswersRollBackAndNameNoContent() async throws {
        let fx = try WebFixture()
        fx.chunkSize = 2
        fx.chunksPerResponse = 3
        let store = try fx.store()
        try seedOldCatalog(store)
        fx.overrideChanges { index in
            index == 1 ? .body(Data("{not json, secret-looking-value".utf8), headers: ["Content-Type": "application/json"]) : nil
        }
        let error = await thrownError { try await fx.refresher(store).refresh(web: try fx.source()) }
        guard case DownloadError.invalidResponse(let detail)? = error else {
            Issue.record("expected invalidResponse, got \(String(describing: error))")
            return
        }
        #expect(!detail.contains("secret-looking-value"))
        try expectOldCatalog(store)

        // A feed that stops before its closing line is just as wrong.
        fx.overrideChanges { _ in
            .body(Data(#"{"nodes":[],"checkpoint":"cp-1","reset":false}"#.utf8), headers: ["Content-Type": "application/json"])
        }
        let second = await thrownError { try await fx.refresher(store).refresh(web: try fx.source()) }
        #expect(second is DownloadError)
        try expectOldCatalog(store)
    }

    @Test func aCheckpointThatDoesNotMoveOnEndsTheRead() async throws {
        let fx = try WebFixture()
        let store = try fx.store()
        try seedOldCatalog(store)
        // The answer to the second call has nodes but repeats the checkpoint it was asked from.
        let repeated = "{\"nodes\":[\(FakeNode.file("T-Z", "z.jpg", md5: "9").json)],\"checkpoint\":\"cp-1\",\"reset\":false}\n{\"end\":true}"
        fx.overrideChanges { index in
            index == 0 ? nil : .body(Data(repeated.utf8), headers: ["Content-Type": "application/json"])
        }
        let error = await thrownError { try await fx.refresher(store).refresh(web: try fx.source()) }
        #expect(error is DownloadError)
        #expect(fx.changeRequests.count == 2)
        try expectOldCatalog(store)
    }

    @Test func cancellingARefreshKeepsTheOldCatalog() async throws {
        let fx = try WebFixture()
        fx.chunkSize = 2
        fx.chunksPerResponse = 3
        let tools = try fx.tools()
        try seedOldCatalog(try fx.store())
        fx.overrideChanges { index in index == 1 ? .hang : nil }
        let task = Task { try await tools.refreshCatalog(source: .web) }
        while fx.changeRequests.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()
        let result = await task.result
        if case .success = result { Issue.record("the cancelled refresh finished") }
        try expectOldCatalog(try fx.store())
    }

    // MARK: Pacing

    @Test func aThrottleAnswerWaitsForRetryAfterAndRepeatsTheRequest() async throws {
        let fx = try WebFixture()
        fx.overrideChanges { index in
            index == 1 ? .body(Data(), status: 429, headers: ["Retry-After": "30"]) : nil
        }
        let outcome = try await fx.refresher(try fx.store()).refresh(web: try fx.source())
        #expect(outcome.result.itemCount == 5)
        #expect(fx.clock.sleeps.contains { $0 >= 30 })
        #expect(fx.changeRequests.count == 3)  // the library, the refused call and its repeat
        #expect(fx.changeRequests[1].url == fx.changeRequests[2].url)
        #expect(WebFixture.checkpoint(of: fx.changeRequests[1]) == "cp-1" && WebFixture.checkpoint(of: fx.changeRequests[2]) == "cp-1")
    }

    @Test func serverErrorsBackOffWithoutRetryAfterAndNetworkTroubleDoesToo() async throws {
        let fx = try WebFixture()
        fx.overrideChanges { index in
            switch index {
            case 0: return .body(Data(), status: 503)
            case 2: return .fail(.networkConnectionLost)
            default: return nil
            }
        }
        let outcome = try await fx.refresher(try fx.store()).refresh(web: try fx.source())
        #expect(outcome.result.itemCount == 5)
        // Delays follow the download engine's schedule: 5 s after a first answer, with jitter 1.0 here.
        #expect(fx.clock.sleeps.contains { abs($0 - 5) < 0.001 })
        #expect(fx.changeRequests.count == 4)
    }

    @Test func fiveThrottleAnswersInARowEndTheReadAndKeepTheCatalog() async throws {
        let fx = try WebFixture()
        let store = try fx.store()
        try seedOldCatalog(store)
        fx.overrideChanges { index in index >= 1 ? .body(Data(), status: 429, headers: ["Retry-After": "1"]) : nil }
        let error = await thrownError { try await fx.refresher(store).refresh(web: try fx.source()) }
        guard case DownloadError.throttled(let status, _)? = error else {
            Issue.record("expected a throttle error, got \(String(describing: error))")
            return
        }
        #expect(status == 429)
        #expect(fx.clock.sleeps.allSatisfy { $0 < 900 })  // no 15-minute pause for a refresh
        try expectOldCatalog(store)
    }

    @Test func theRequestLimitPacesTheFeedReads() async throws {
        var throttle = ThrottleConfig()
        throttle.maxRequestsPerMinute = 6  // one request every ten seconds, no burst
        let fx = try WebFixture(throttle: throttle)
        try await fx.refresher(try fx.store()).refresh(web: try fx.source())
        let requests = fx.server.requests.count
        #expect(requests == 3)  // the library, the empty answer that ends the drain, and the file count
        #expect(abs(fx.clock.sleeps.reduce(0, +) - Double(requests - 1) * 10) < 0.5)
    }

    // MARK: Incremental refresh

    @Test func theChangeFeedAddsChangesAndRemovesTheTrashed() async throws {
        let fx = try WebFixture()
        let store = try fx.store()
        try await fx.refresher(store).refresh(web: try fx.source())
        #expect(try store.catalogCheckpoint() == CatalogCheckpoint(source: .web, host: fx.host, token: "cp-1"))
        let listingBefore = fx.listingRequests.count

        var renamed = FakeNode.file("T-F1", "one-renamed.jpg", md5: "1", size: 100)
        renamed.contentDate = "2019-04-24T05:53:46.264Z"
        fx.addChanges([
            .file("T-N1", "new.jpg", md5: "a", size: 21, parent: "T-D1"),
            renamed,
            .file("T-F2", "two.heic", md5: "2", size: 200, parent: "T-D1", status: "TRASH"),
            .folder("T-D3", "Trips", parent: "T-ROOT"),
            .folder("T-D1", "Pictures", parent: "T-ROOT", status: "PURGED"),
            .live("T-L1", parent: "T-F1", md5: "7", size: 50, status: "PURGED"),
            FakeNode(id: "T-A9", name: "thumb", kind: "ASSET", parents: ["T-F1"], md5: md5("5"), size: 5),  // not a Live Photo video
            .file("T-F6", "six.mov", md5: nil, size: 600),  // lost its data: out of the catalog
        ])
        fx.addChanges([.file("T-N1", "new-final.jpg", md5: "a", size: 21, parent: "T-D1")])  // the last word wins

        let outcome = try await fx.refresher(store).refresh(web: try fx.source())
        #expect(outcome.mode == .incremental && outcome.origin == .web)
        #expect(fx.listingRequests.count == listingBefore)  // no file count check either
        #expect(outcome.result.itemCount == 3 && outcome.result.folderCount == 3)

        let items = try storedItems(store)
        #expect(items.map(\.nodeId) == ["T-F1", "T-F3", "T-N1"])
        #expect(items.first { $0.nodeId == "T-F1" }?.name == "one-renamed.jpg")
        #expect(items.first { $0.nodeId == "T-N1" }?.name == "new-final.jpg")
        #expect(try storedFolders(store).map(\.nodeId) == ["T-D2", "T-D3", "T-ROOT"])
        #expect(try store.catalogCheckpoint()?.token == "cp-3")
        #expect(try store.getMeta(MetaKey.catalogItemCount) == "3" && store.getMeta(MetaKey.catalogFolderCount) == "3")

        // The full read took two calls; the incremental one asked with the stored position, then drained with the last one.
        let asks = fx.changeRequests.map(WebFixture.checkpoint(of:))
        #expect(asks == [nil, "cp-1", "cp-1", "cp-3"])
        let body = String(decoding: fx.changeRequests[2].body, as: UTF8.self)
        #expect(body.contains("\"includePurged\":\"true\"") && body.contains("\"maxNodes\":1000"))

        // Nothing new: a cheap read that changes nothing.
        let quiet = try await fx.refresher(store).refresh(web: try fx.source())
        #expect(quiet.mode == .incremental && quiet.changed == 0 && quiet.removed == 0)
        #expect(try storedItems(store) == items)
    }

    @Test func aResetAnswerToTheStoredCheckpointFallsBackToAFullRead() async throws {
        let fx = try WebFixture()
        let store = try fx.store()
        try await fx.refresher(store).refresh(web: try fx.source())
        let changesBefore = fx.changeRequests.count

        // The library starts over on Amazon's side; the stored position no longer fits.
        fx.setLibrary(
            folders: [.folder("T-ROOT", "Root", parent: nil, root: true)],
            files: [.file("T-ONLY", "only.jpg", md5: "4", size: 40, parent: "T-ROOT")], assets: [])
        fx.addChanges([.file("T-X", "x.jpg", md5: "5", size: 5)])
        fx.feedAsksForReset = true
        let outcome = try await fx.refresher(store).refresh(web: try fx.source())
        #expect(outcome.mode == .full)
        // The reset answer, then the whole feed from scratch.
        #expect(fx.changeRequests.dropFirst(changesBefore).map(WebFixture.checkpoint(of:)) == ["cp-1", nil, "cp-2"])
        #expect(try storedItems(store).map(\.nodeId) == ["T-ONLY", "T-X"])
        #expect(try storedFolders(store).map(\.nodeId) == ["T-ROOT"])
        #expect(try store.catalogCheckpoint()?.token == "cp-2")
    }

    @Test func theFullFlagForcesAFullRead() async throws {
        let fx = try WebFixture()
        let store = try fx.store()
        try await fx.refresher(store).refresh(web: try fx.source())
        let changesBefore = fx.changeRequests.count
        let outcome = try await fx.refresher(store).refresh(web: try fx.source(), full: true)
        #expect(outcome.mode == .full)
        #expect(fx.changeRequests.count == 2 * changesBefore)
        #expect(fx.changeRequests.map(WebFixture.checkpoint(of:)) == [nil, "cp-1", nil, "cp-1"])
        #expect(fx.listingRequests.count == 2)  // each full read ends with the file count
    }

    @Test func aFailedFeedReadChangesNothing() async throws {
        let fx = try WebFixture()
        let store = try fx.store()
        try await fx.refresher(store).refresh(web: try fx.source())
        let before = try storedItems(store)
        fx.addChanges([.file("T-N1", "new.jpg", md5: "a", size: 21)])

        // A feed without its closing line, and one that reports an error inside a chunk.
        for body in [
            #"{"nodes":[],"checkpoint":"cp-1","reset":false,"statusCode":200}"#,
            "{\"nodes\":[],\"checkpoint\":\"cp-1\",\"statusCode\":500}\n{\"end\":true}",
        ] {
            let feed = Data(body.utf8)
            #expect(throws: DownloadError.self) { try AmazonClient.parseChangeFeed(feed) }
        }
        #expect(throws: DownloadError.sessionExpired) {
            try AmazonClient.parseChangeFeed(Data("{\"statusCode\":401}\n{\"end\":true}".utf8))
        }
        #expect(throws: DownloadError.self) { try AmazonClient.parseChangeFeed(Data("garbage\n{\"end\":true}".utf8)) }

        // The stub answers 400 for an unknown checkpoint: the read fails and the catalog stays.
        try store.setCatalogCheckpoint(CatalogCheckpoint(source: .web, host: fx.host, token: "cp-99"))
        let error = await thrownError { try await fx.refresher(store).refresh(web: try fx.source()) }
        #expect(error as? DownloadError == .httpStatus(400))
        #expect(try storedItems(store) == before)
        #expect(try store.catalogCheckpoint()?.token == "cp-99")
    }

    // MARK: Checkpoint

    @Test func theCheckpointIsStoredWithTheSourceAndTheHost() async throws {
        let fx = try WebFixture()
        let store = try fx.store()
        #expect(try store.catalogCheckpoint() == nil)
        try await fx.refresher(store).refresh(web: try fx.source())
        let checkpoint = try #require(try store.catalogCheckpoint())
        #expect(checkpoint == CatalogCheckpoint(source: .web, host: fx.host, token: "cp-1"))
        // It is in the meta table, and a second connection sees it.
        #expect(try fx.store().catalogCheckpoint() == checkpoint)
        #expect(try store.getMeta(MetaKey.catalogCheckpoint)?.contains("\"source\":\"web\"") == true)
    }

    @Test func aCheckpointOfAnotherHostIsNotUsed() async throws {
        let fx = try WebFixture()
        let store = try fx.store()
        try await fx.refresher(store).refresh(web: try fx.source())
        try store.setCatalogCheckpoint(CatalogCheckpoint(source: .web, host: "www.amazon.co.uk", token: "cp-0"))
        let outcome = try await fx.refresher(store).refresh(web: try fx.source())
        #expect(outcome.mode == .full)
    }

    @Test func switchingTheSourceClearsTheCheckpoint() async throws {
        let fx = try WebFixture()
        let items = [CloudItem(nodeId: "APP-1", kind: .file, name: "a.jpg", md5: md5("f"), size: 1, takenAt: t2019)]
        let tools = try fx.tools(app: .catalog(items))
        let store = try fx.store()

        let first = try await tools.refreshCatalog(source: .web)
        #expect(first.source == .web && first.mode == .full)
        #expect(try store.catalogCheckpoint() != nil)
        let second = try await tools.refreshCatalog(source: .web)
        #expect(second.mode == .incremental)

        // A refresh from the app index replaces the catalog and forgets the checkpoint.
        let app = try await tools.refreshCatalog(source: .app)
        #expect(app.source == .app && app.photosVideos.count == 1)
        #expect(try store.catalogCheckpoint() == nil && store.catalogOrigin() == .app)

        // So the next web read drains the feed from scratch again (and ends with the file count).
        let listingBefore = fx.listingRequests.count
        let third = try await tools.refreshCatalog(source: .web)
        #expect(third.mode == .full && fx.listingRequests.count > listingBefore)
        #expect(try storedItems(store).map(\.nodeId).contains("APP-1") == false)
    }

    @Test func choosingAnotherCatalogSourceClearsTheCheckpointAndRoundTrips() async throws {
        let fx = try WebFixture(catalogSource: .web)
        let tools = try fx.tools()
        _ = try await tools.refreshCatalog()
        #expect(try fx.store().catalogCheckpoint() != nil)

        // Choosing the same source again changes nothing.
        try tools.setCatalogSource(.web)
        #expect(try fx.store().catalogCheckpoint() != nil)

        let config = try tools.setCatalogSource(.app)
        #expect(config.catalogSource == .app)
        #expect(try tools.loadConfig().catalogSource == .app)
        #expect(try fx.store().catalogCheckpoint() == nil)
        let json = String(decoding: try Data(contentsOf: fx.paths.configURL), as: UTF8.self)
        #expect(json.contains("\"catalogSource\" : \"app\""))

        try tools.setCatalogSource(.auto)
        #expect(try tools.loadConfig().catalogSource == .auto)
    }

    @Test func theConfigurationReadsAndWritesTheCatalogSource() throws {
        #expect(Config().catalogSource == .auto)
        for choice in CatalogSourceChoice.allCases {
            let data = try JSONEncoder().encode(Config(catalogSource: choice))
            #expect(try JSONDecoder().decode(Config.self, from: data).catalogSource == choice)
        }
        // Old files have no such key, and a typo never stops the app from starting.
        #expect(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).catalogSource == .auto)
        #expect(try JSONDecoder().decode(Config.self, from: Data(#"{"catalogSource":"cloud"}"#.utf8)).catalogSource == .auto)
        #expect(try JSONDecoder().decode(Config.self, from: Data(#"{"catalogSource":"web"}"#.utf8)).catalogSource == .web)
    }

    // MARK: Choosing the source

    @Test func autoUsesTheAppIndexWhenItIsFoundAndTheWebApiOtherwise() async throws {
        let items = [CloudItem(nodeId: "APP-1", kind: .file, name: "a.jpg", md5: md5("f"), size: 1, takenAt: t2019)]

        let withApp = try WebFixture(catalogSource: .auto)
        let found = try await withApp.tools(app: .catalog(items)).refreshCatalog()
        #expect(found.source == .app && found.photosVideos.count == 1)
        #expect(withApp.server.requests.isEmpty)

        let without = try WebFixture(catalogSource: .auto)
        let web = try await without.tools(app: .missing).refreshCatalog()
        #expect(web.source == .web && web.photosVideos.count == 4)  // four photos and videos, one Live Photo video
        #expect(web.liveVideos.count == 1)
        #expect(!without.server.requests.isEmpty)
        #expect(try without.store().catalogOrigin() == .web)

        // Without a session, the error names both ways forward.
        let signedOut = try WebFixture(catalogSource: .auto)
        let error = await thrownError { _ = try await signedOut.tools(app: .missing, signedIn: false).refreshCatalog() }
        let message = try #require((error as? ToolError)?.message)
        #expect(message.contains("Amazon Photos app index not found") && message.contains("config set-index"))
        #expect(message.contains("auth import"))
        #expect(signedOut.server.requests.isEmpty)

        // A damaged index is reported, not worked around.
        let broken = try WebFixture(catalogSource: .auto)
        let brokenError = await thrownError { _ = try await broken.tools(app: .broken).refreshCatalog() }
        #expect((brokenError as? ToolError)?.message.contains("malformed") == true)
        #expect(broken.server.requests.isEmpty)
    }

    @Test func anExplicitSourceOverridesTheConfiguredOne() async throws {
        let items = [CloudItem(nodeId: "APP-1", kind: .file, name: "a.jpg", md5: md5("f"), size: 1, takenAt: t2019)]
        let fx = try WebFixture(catalogSource: .app)
        let tools = try fx.tools(app: .catalog(items))
        let web = try await tools.refreshCatalog(source: .web)
        #expect(web.source == .web)
        let configured = try await tools.refreshCatalog()
        #expect(configured.source == .app)

        // `web` without a session is an error, not a fallback to the app index.
        let signedOut = try fx.tools(app: .catalog(items), signedIn: false)
        let error = await thrownError { _ = try await signedOut.refreshCatalog(source: .web) }
        #expect((error as? ToolError)?.message.contains("Not signed in") == true)
    }

    @Test func syncStatusNamesTheSourceThatProducedTheCatalog() async throws {
        let fx = try WebFixture()
        let tools = try fx.tools()
        #expect(try tools.currentReport().catalogSource == nil)
        let report = try await tools.syncStatus(refresh: true)
        #expect(report.catalogSource == .web)
        #expect(report.catalogFreshness != nil && report.catalogRefreshedAt != nil)
        #expect(try tools.currentReport().catalogSource == .web)

        let json = try JSONOutput.string(report)
        #expect(json.contains("\"catalogSource\" : \"web\""))
        let old = try JSONDecoder.iso8601.decode(SyncReport.self, from: Data(json.replacingOccurrences(of: "\"catalogSource\" : \"web\",", with: "").utf8))
        #expect(old.catalogSource == nil)
    }

    // MARK: Downloads and the catalog

    @Test func aRunningDownloadBlocksAWebRefresh() async throws {
        let fx = try WebFixture()
        let tools = try fx.tools()
        let store = try fx.store()
        try seedOldCatalog(store)

        let lock = try #require(try RunLock(path: fx.paths.downloadLockURL.path))
        let error = await thrownError { _ = try await tools.refreshCatalog(source: .web) }
        #expect((error as? ToolError)?.message.contains("download is running") == true)
        let direct = await thrownError { try await fx.refresher(store).refresh(web: try fx.source()) }
        #expect(direct is CatalogError)
        #expect(fx.server.requests.isEmpty)
        try expectOldCatalog(store)
        lock.release()

        let outcome = try await tools.refreshCatalog(source: .web)
        #expect(outcome.mode == .full)
        // The lock is free again afterwards.
        let again = try #require(try RunLock(path: fx.paths.downloadLockURL.path))
        again.release()
    }

    // MARK: MCP

    @Test func theRefreshToolTakesASourceAndReportsIt() async throws {
        let definition = try #require(RainbarrelToolRegistry.definitions.first { $0.name == "refresh_catalog" })
        guard case .object(let schema) = definition.inputSchema, case .object(let properties)? = schema["properties"],
            case .object(let source)? = properties["source"]
        else {
            Issue.record("refresh_catalog has no source property")
            return
        }
        #expect(source["enum"] == .array([.string("auto"), .string("app"), .string("web")]))
        #expect(!definition.readOnly)

        let fx = try WebFixture(catalogSource: .app)
        let registry = RainbarrelToolRegistry(tools: try fx.tools(app: .missing))
        let outcome = await registry.callAsync(name: "refresh_catalog", arguments: ["source": .string("web")])
        #expect(!outcome.isError, "\(outcome.text)")
        let summary = try JSONDecoder.iso8601.decode(CatalogRefreshSummary.self, from: Data(outcome.text.utf8))
        #expect(summary.source == .web && summary.mode == .full && summary.skippedNodes == 3 && summary.warnings.isEmpty)
        #expect(summary.photosVideos.count == 4)

        let again = await registry.callAsync(name: "refresh_catalog", arguments: ["source": .string("web")])
        let incremental = try JSONDecoder.iso8601.decode(CatalogRefreshSummary.self, from: Data(again.text.utf8))
        #expect(incremental.mode == .incremental)

        let status = await registry.callAsync(name: "sync_status", arguments: ["refresh": .bool(false)])
        #expect(status.text.contains("\"catalogSource\" : \"web\""))
        // The synchronous entry point works for the tools that wait for the network too.
        let sync = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: registry.call(name: "refresh_catalog", arguments: ["source": .string("web")]))
            }
        }
        #expect(!sync.isError, "\(sync.text)")

        let bad = await registry.callAsync(name: "refresh_catalog", arguments: ["source": .string("cloud")])
        #expect(bad.isError && bad.text.contains("auto, app or web"))
        let notText = await registry.callAsync(name: "refresh_catalog", arguments: ["source": .int(3)])
        #expect(notText.isError)
        let appFailure = await registry.callAsync(name: "refresh_catalog", arguments: ["source": .string("app")])
        #expect(appFailure.isError && appFailure.text.contains("Amazon Photos app index not found"))
    }

    // MARK: Credentials

    @Test func credentialsStayWithTheConfiguredHost() async throws {
        let fx = try WebFixture()
        // A second host that must never be contacted: the session belongs to the first.
        let other = StubServer(hosts: ["elsewhere.example.org"])
        other.handler = { _ in .body(Data(), status: 404) }
        let store = try fx.store()
        try await fx.refresher(store).refresh(web: try fx.source())
        #expect(other.requests.isEmpty)
        #expect(fx.server.requests.allSatisfy { $0.url.host == fx.host })

        // A host name that is not a plain host name is refused before any request.
        var bad = fx.config
        bad.amazonHost = "www.amazon.com/evil"
        #expect(throws: DownloadError.self) {
            try WebAPICatalogSource.make(session: fx.session, config: bad, environment: fx.environment)
        }
        #expect(throws: DownloadError.self) { try AmazonEndpoints.changesURL(host: "bad host") }
        #expect(throws: DownloadError.self) {
            try AmazonEndpoints.listURL(host: "evil.example.com/x", filter: "kind:FILE", limit: 1)
        }
    }
}
