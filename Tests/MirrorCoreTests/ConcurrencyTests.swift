import Foundation
import Testing
@testable import MirrorCore

@Suite("State store shared between processes")
struct ConcurrencyTests {
    /// Moves a non-Sendable value across a thread boundary where the test guarantees exclusive use.
    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    @Test func opensInWALModeWithABusyTimeout() throws {
        let dir = try TempDirectory()
        let store = try StateStore(path: dir.path("state.sqlite"))
        #expect(try store.database.scalarString("PRAGMA journal_mode") == "wal")
        #expect(try store.database.scalarInt64("PRAGMA busy_timeout") == 5000)
    }

    @Test func readersAreNotBlockedByAnOpenWriteTransaction() throws {
        let dir = try TempDirectory()
        let writer = try StateStore(path: dir.path("state.sqlite"))
        let reader = try StateStore(path: dir.path("state.sqlite"))
        try writer.setMeta("k", "before")

        try writer.database.execute("BEGIN IMMEDIATE")
        try writer.setMeta("k", "during")
        #expect(try reader.getMeta("k") == "before")  // reads the last committed state, immediately
        try writer.database.execute("COMMIT")
        #expect(try reader.getMeta("k") == "during")
    }

    @Test func aSecondWriterWaitsForTheFirstInsteadOfFailing() throws {
        let dir = try TempDirectory()
        let first = Box(try StateStore(path: dir.path("state.sqlite")))
        let second = try StateStore(path: dir.path("state.sqlite"))

        let holding = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? first.value.database.execute("BEGIN IMMEDIATE")
            try? first.value.setMeta("a", "1")
            holding.signal()
            Thread.sleep(forTimeInterval: 0.4)
            try? first.value.database.execute("COMMIT")
            finished.signal()
        }
        holding.wait()
        let started = Date()
        try second.setMeta("b", "2")  // waits for the commit above (busy timeout is 5 s)
        #expect(Date().timeIntervalSince(started) >= 0.2)
        finished.wait()
        #expect(try second.getMeta("a") == "1")
        #expect(try second.getMeta("b") == "2")
    }

    @Test func refreshingTheCatalogHoldsNoWriteLockWhileTheSourceIsRead() throws {
        let dir = try TempDirectory()
        let store = try StateStore(path: dir.path("state.sqlite"))
        let other = try StateStore(path: dir.path("state.sqlite"))

        var otherWriteSeconds = 99.0
        try store.replaceCloudItems { sink in
            // A slow source: while it is being read, another process must still be able to write.
            let started = Date()
            try other.setMeta("from-other-process", "yes")
            otherWriteSeconds = Date().timeIntervalSince(started)
            try sink(CloudItem(nodeId: "A", kind: .file, name: "IMG_0001.jpg", md5: md5("1"), size: 1, takenAt: t2019))
            return CatalogReadResult(sourceDescription: "test", sourceModifiedAt: Date(), itemCount: 1)
        }
        #expect(otherWriteSeconds < 1.0)
        #expect(try other.getMeta("from-other-process") == "yes")
        #expect(try other.database.scalarInt64("SELECT COUNT(*) FROM cloud_items") == 1)
    }

    @Test func aFailedRefreshLeavesTheOldCatalogAndNoStagingTable() throws {
        let dir = try TempDirectory()
        let store = try StateStore(path: dir.path("state.sqlite"))
        try CatalogRefresher(store: store).refresh(from: StaticCatalog(items: [
            CloudItem(nodeId: "A", kind: .file, name: "IMG_0001.jpg", md5: md5("1"), size: 1, takenAt: t2019),
        ]))
        #expect(throws: CatalogError.self) {
            try store.replaceCloudItems { _ in throw CatalogError.snapshotFailed("boom") }
        }
        #expect(try store.cloudItemCount() == 1)
        let staging = try store.database.scalarInt64(
            "SELECT COUNT(*) FROM sqlite_temp_master WHERE name = 'cloud_items_staging'")
        #expect(staging == 0)
    }
}
