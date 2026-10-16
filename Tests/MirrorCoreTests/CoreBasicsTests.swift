import Foundation
import Testing
@testable import MirrorCore

@Suite("Ticks, CSV, retry, config, hashing")
struct CoreBasicsTests {
    @Test func ticksConvertToUnixSeconds() {
        #expect(DotNetTicks.unixSeconds(fromTicks: DotNetTicks.unixEpochTicks) == 0)
        #expect(DotNetTicks.unixSeconds(fromTicks: 636_964_273_770_000_000) == t2019)
        #expect(DotNetTicks.unixSeconds(fromTicks: DotNetTicks.unixEpochTicks + 10_000_000) == 1)
        // Before 1970 the result rounds down, so one tick before the epoch is second -1.
        #expect(DotNetTicks.unixSeconds(fromTicks: DotNetTicks.unixEpochTicks - 1) == -1)
        #expect(DotNetTicks.unixSeconds(fromTicks: DotNetTicks.unixEpochTicks - 10_000_000) == -1)
    }

    @Test func takenAtPrefersContentDateThenCreatedDate() {
        let content = ticks(unix: t2019)
        let created = ticks(unix: t2015)
        #expect(DotNetTicks.takenAt(contentDate: content, createdDate: created) == t2019)
        #expect(DotNetTicks.takenAt(contentDate: 0, createdDate: created) == t2015)
        #expect(DotNetTicks.takenAt(contentDate: nil, createdDate: created) == t2015)
        #expect(DotNetTicks.takenAt(contentDate: nil, createdDate: nil) == 0)
    }

    @Test func csvHandlesQuotesCommasNewlinesAndBOM() {
        let text = "\u{FEFF}a,b,c\r\n\"x, y\",\"he said \"\"hi\"\"\",plain\n\n\"multi\nline\",,last"
        let rows = CSVParser.parse(text)
        #expect(rows == [
            ["a", "b", "c"],
            ["x, y", "he said \"hi\"", "plain"],
            ["multi\nline", "", "last"],
        ])
    }

    @Test func csvKeepsEmptyTrailingFieldAndLastRowWithoutNewline() {
        #expect(CSVParser.parse("a,b\n1,") == [["a", "b"], ["1", ""]])
    }

    @Test func retryPolicyRetriesThenSucceeds() throws {
        final class Counter: @unchecked Sendable { var sleeps: [TimeInterval] = [] }
        let counter = Counter()
        let policy = RetryPolicy(delays: [2, 4, 6]) { counter.sleeps.append($0) }
        var calls = 0
        let value = try policy.attempt { () throws -> Int in
            calls += 1
            if calls < 3 { throw POSIXError(.EIO) }
            return 42
        }
        #expect(value == 42)
        #expect(calls == 3)
        #expect(counter.sleeps == [2, 4])
    }

    @Test func retryPolicyGivesUpAfterAllDelays() {
        final class Counter: @unchecked Sendable { var sleeps: [TimeInterval] = [] }
        let counter = Counter()
        let policy = RetryPolicy(delays: RetryPolicy.default.delays) { counter.sleeps.append($0) }
        var calls = 0
        #expect(throws: POSIXError.self) {
            try policy.attempt { () throws -> Int in
                calls += 1
                throw POSIXError(.ENXIO)
            }
        }
        #expect(calls == 6)  // first try plus five retries
        #expect(counter.sleeps == [2, 4, 6, 8, 10])
    }

    @Test func md5MatchesKnownDigestsAndStreamsLargeFiles() throws {
        #expect(MD5Hasher.hexDigest(of: Array("hello".utf8)) == "5d41402abc4b2a76b9719d911017c592")
        let dir = try TempDirectory()
        let small = try dir.write("small.txt", "hello")
        #expect(try MD5Hasher.hexDigest(ofFileAtPath: small) == "5d41402abc4b2a76b9719d911017c592")
        // Larger than one 8 MB chunk, to exercise the streaming loop.
        let big = Data(repeating: 0x61, count: MD5Hasher.chunkSize + 12_345)
        try big.write(to: dir.url.appendingPathComponent("big.bin"))
        var chunks = 0
        let digest = try MD5Hasher.hexDigest(ofFileAtPath: dir.path("big.bin")) { _ in chunks += 1 }
        #expect(digest == MD5Hasher.hexDigest(of: [UInt8](big)))
        #expect(chunks == 2)
    }

    @Test func missingFileThrows() {
        #expect(throws: POSIXError.self) {
            try MD5Hasher.hexDigest(ofFileAtPath: "/nonexistent/photomirror-test-file")
        }
    }

    @Test func configRoundTripAndScanRoot() throws {
        let dir = try TempDirectory()
        let store = ConfigStore(url: dir.url.appendingPathComponent("nested/config.json"))
        #expect(try store.load() == Config())
        var config = Config(driveRoot: "/Volumes/MyBackupDrive", scanSubpath: "Photos")
        try store.save(config)
        #expect(try store.load() == config)
        #expect(config.scanRootPath == "/Volumes/MyBackupDrive/Photos")
        config.scanSubpath = nil
        #expect(config.scanRootPath == "/Volumes/MyBackupDrive")
        #expect(Config().scanRootPath == nil)
    }

    @Test func appPathsHonourOverrideAndPlatformDefault() {
        let override = AppPaths.default(environment: ["PHOTOMIRROR_DATA_DIR": "/tmp/pm-test"])
        #expect(override.dataDirectory.path == "/tmp/pm-test")
        #expect(override.stateURL.lastPathComponent == "state.sqlite")
        #expect(override.configURL.lastPathComponent == "config.json")

        let home = URL(fileURLWithPath: "/home/someone")
        let standard = AppPaths.default(environment: [:], home: home)
        #if os(macOS)
        #expect(standard.dataDirectory.path == "/home/someone/Library/Application Support/PhotoMirror")
        #else
        #expect(standard.dataDirectory.path == "/home/someone/.local/share/photomirror")
        let xdg = AppPaths.default(environment: ["XDG_DATA_HOME": "/data"], home: home)
        #expect(xdg.dataDirectory.path == "/data/photomirror")
        #endif
    }

    @Test func pathHelpersExpandTildeAndJoinWithOneSlash() {
        #expect(PathUtilities.expandingTilde("~", home: "/home/someone") == "/home/someone")
        #expect(PathUtilities.expandingTilde("~/Photos", home: "/home/someone/") == "/home/someone/Photos")
        #expect(PathUtilities.expandingTilde("/abs/~/x", home: "/home/someone") == "/abs/~/x")
        #expect(PathUtilities.join("/a/", "/b") == "/a/b")
        #expect(PathUtilities.join("/a", "b/c") == "/a/b/c")
        #expect(PathUtilities.join("", "b") == "b")
    }

    @Test func firstParentIsReadFromJSONArray() {
        #expect(AmazonAppIndexSource.firstParentID(in: "[\"abc\",\"def\"]") == "abc")
        #expect(AmazonAppIndexSource.firstParentID(in: "[]") == nil)
        #expect(AmazonAppIndexSource.firstParentID(in: nil) == nil)
        #expect(AmazonAppIndexSource.firstParentID(in: "") == nil)
    }
}
