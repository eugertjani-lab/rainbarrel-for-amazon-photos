import Foundation
import Testing

@testable import RainbarrelCore

private final class NoticeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(URL, URL)] = []
    func add(_ from: URL, _ to: URL) { lock.lock(); entries.append((from, to)); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

/// The data directory that used to be called PhotoMirror (photomirror on Linux) moves to Rainbarrel.
struct DataDirectoryMigrationTests {
    /// A temporary "home" whose platform base directory (Application Support or the XDG default) exists.
    private func makeHome() throws -> (temp: TempDirectory, home: URL, base: URL) {
        let temp = try TempDirectory()
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        #if os(macOS)
        let base = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        let base = home.appendingPathComponent(".local/share", isDirectory: true)
        #endif
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (temp, home, base)
    }

    @Test func movesTheWholeOldDirectoryIncludingWalAndShm() throws {
        let (_, home, base) = try makeHome()
        let legacy = base.appendingPathComponent(AppPaths.legacyDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for (name, text) in [
            ("state.sqlite", "db"), ("state.sqlite-wal", "wal"), ("state.sqlite-shm", "shm"),
            ("config.json", "{}"), ("seed.csv", "a,b"),
        ] {
            try Data(text.utf8).write(to: legacy.appendingPathComponent(name))
        }
        let log = NoticeLog()
        let paths = AppPaths.default(environment: [:], home: home) { from, to in log.add(from, to) }

        let new = base.appendingPathComponent(AppPaths.directoryName, isDirectory: true)
        #expect(paths.dataDirectory.path == new.path)
        #expect(log.count == 1)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        for (name, text) in [
            ("state.sqlite", "db"), ("state.sqlite-wal", "wal"), ("state.sqlite-shm", "shm"),
            ("config.json", "{}"), ("seed.csv", "a,b"),
        ] {
            let data = try Data(contentsOf: new.appendingPathComponent(name))
            #expect(String(decoding: data, as: UTF8.self) == text)
        }
    }

    @Test func secondCallDoesNothing() throws {
        let (_, home, base) = try makeHome()
        let legacy = base.appendingPathComponent(AppPaths.legacyDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: legacy.appendingPathComponent("state.sqlite"))
        let log = NoticeLog()
        _ = AppPaths.default(environment: [:], home: home) { from, to in log.add(from, to) }
        _ = AppPaths.default(environment: [:], home: home) { from, to in log.add(from, to) }
        #expect(log.count == 1)
    }

    @Test func leavesTheOldDirectoryAloneWhenTheNewOneAlreadyExists() throws {
        let (_, home, base) = try makeHome()
        let legacy = base.appendingPathComponent(AppPaths.legacyDirectoryName, isDirectory: true)
        let new = base.appendingPathComponent(AppPaths.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("state.sqlite"))
        try Data("new".utf8).write(to: new.appendingPathComponent("state.sqlite"))
        let log = NoticeLog()
        let paths = AppPaths.default(environment: [:], home: home) { from, to in log.add(from, to) }

        #expect(paths.dataDirectory.path == new.path)
        #expect(log.count == 0)
        #expect(String(decoding: try Data(contentsOf: legacy.appendingPathComponent("state.sqlite")), as: UTF8.self) == "old")
        #expect(String(decoding: try Data(contentsOf: new.appendingPathComponent("state.sqlite")), as: UTF8.self) == "new")
    }

    @Test func doesNothingWhenNeitherDirectoryExists() throws {
        let (_, home, base) = try makeHome()
        let paths = AppPaths.default(environment: [:], home: home)
        #expect(paths.dataDirectory.path == base.appendingPathComponent(AppPaths.directoryName).path)
        #expect(!FileManager.default.fileExists(atPath: paths.dataDirectory.path))
    }

    @Test func environmentOverrideSkipsTheMigration() throws {
        let (temp, home, base) = try makeHome()
        let legacy = base.appendingPathComponent(AppPaths.legacyDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let scratch = temp.path("scratch")
        for key in ["RAINBARREL_DATA_DIR", "PHOTOMIRROR_DATA_DIR"] {
            let paths = AppPaths.default(environment: [key: scratch], home: home)
            #expect(paths.dataDirectory.path == scratch)
            #expect(FileManager.default.fileExists(atPath: legacy.path))
        }
    }

    @Test func failedMoveKeepsTheOldDirectoryInUse() throws {
        let temp = try TempDirectory()
        let legacy = temp.url.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: legacy.appendingPathComponent("state.sqlite"))
        // The new path sits below a regular file, so neither creating its parent nor the move can work.
        let blocker = temp.url.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let new = blocker.appendingPathComponent("sub/new", isDirectory: true)

        let result = AppPaths.migrateLegacyDirectory(from: legacy, to: new)
        #expect(result.path == legacy.path)
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("state.sqlite").path))
    }
}
