import Foundation
import Testing
@testable import MirrorCore

@Suite("Scanner cleanup and pruning")
struct PruningTests {
    private func makeScanner(_ drive: TempDirectory, _ store: StateStore, subpath: String? = nil) throws -> DriveScanner {
        try DriveScanner(store: store, driveRoot: drive.path, scanSubpath: subpath)
    }

    private func run(
        _ scanner: DriveScanner, hash: Bool = true, limit: Int? = nil,
        cancelAfter: Int? = nil
    ) throws -> ScanResult {
        final class Counter: @unchecked Sendable { var polls = 0 }
        let counter = Counter()
        let cancel: @Sendable () -> Bool = {
            guard let cancelAfter else { return false }
            counter.polls += 1
            return counter.polls > cancelAfter
        }
        return try scanner.scan(options: ScanOptions(
            hash: hash, limit: limit, retry: .immediate(retries: 2), isCancelled: cancel))
    }

    private func paths(_ store: StateStore) throws -> [String] {
        try store.database.rows("SELECT rel_path FROM drive_files ORDER BY rel_path") { $0.string(0) ?? "" }
    }

    private func populate(_ drive: TempDirectory) throws {
        try drive.write("A/x.jpg", "one")
        try drive.write("A/y.jpg", "two")
        try drive.write("B/z.jpg", "three")
        try drive.write("B/deep/w.jpg", "four")
        try drive.write("C/gone/v.jpg", "five")
    }

    @Test func fullScanPrunesFilesThatAreGoneFromTheDrive() throws {
        let drive = try TempDirectory()
        try populate(drive)
        let store = try makeStore()
        let scanner = try makeScanner(drive, store)
        _ = try run(scanner)
        #expect(try paths(store).count == 5)

        try FileManager.default.removeItem(atPath: drive.path("A/x.jpg"))
        try FileManager.default.removeItem(atPath: drive.path("C/gone"))  // a whole folder disappears
        let result = try run(scanner)
        #expect(result.pruned == 2)
        #expect(result.walkedEverything)
        #expect(try paths(store) == ["A/y.jpg", "B/deep/w.jpg", "B/z.jpg"])
    }

    @Test func limitedAndCancelledScansNeverPrune() throws {
        let drive = try TempDirectory()
        try populate(drive)
        let store = try makeStore()
        let scanner = try makeScanner(drive, store)
        _ = try run(scanner)
        try FileManager.default.removeItem(atPath: drive.path("A/x.jpg"))

        // Work limit of 1: only a new file counts as work, and the walk stops early.
        try drive.write("A/new1.jpg", "n1")
        try drive.write("A/new2.jpg", "n2")
        let limited = try run(scanner, limit: 1)
        #expect(limited.stoppedByLimit)
        #expect(limited.pruned == 0)
        #expect(try paths(store).contains("A/x.jpg"))

        let cancelled = try run(scanner, cancelAfter: 1)
        #expect(cancelled.cancelled)
        #expect(!cancelled.walkedEverything)
        #expect(cancelled.pruned == 0)
        #expect(try paths(store).contains("A/x.jpg"))

        // A complete scan finally removes it.
        let complete = try run(scanner)
        #expect(complete.pruned == 1)
        #expect(try !paths(store).contains("A/x.jpg"))
    }

    @Test func aFolderWhoseListingFailsNeverCausesPruning() throws {
        let drive = try TempDirectory()
        try populate(drive)
        let store = try makeStore()
        let scanner = try makeScanner(drive, store)
        _ = try run(scanner)
        let before = try paths(store)

        // Simulate the drive dropping out while B and C/gone are listed; A is listed fine and
        // really lost a file, so only that record may be pruned.
        try FileManager.default.removeItem(atPath: drive.path("A/x.jpg"))
        try FileManager.default.removeItem(atPath: drive.path("B/z.jpg"))
        scanner.listingHook = { relative in
            if relative == "B" || relative == "C/gone" { throw POSIXError(.EIO) }
        }
        let result = try run(scanner)
        #expect(result.errors == 2)
        #expect(result.directoryErrors.count == 2)
        #expect(result.pruned == 1)
        let after = try paths(store)
        #expect(after == before.filter { $0 != "A/x.jpg" })
        #expect(after.contains("B/z.jpg"))  // its folder could not be listed, so it stays
        #expect(after.contains("B/deep/w.jpg"))
        #expect(after.contains("C/gone/v.jpg"))
    }

    @Test func aFailedAncestorListingProtectsEverythingBelowIt() throws {
        let drive = try TempDirectory()
        try populate(drive)
        let store = try makeStore()
        let scanner = try makeScanner(drive, store)
        _ = try run(scanner)
        // B lists fine but B/deep does not; B/deep/w.jpg also disappears from the drive.
        try FileManager.default.removeItem(atPath: drive.path("B/deep/w.jpg"))
        scanner.listingHook = { relative in
            if relative == "B/deep" { throw POSIXError(.ENXIO) }
        }
        let result = try run(scanner)
        #expect(result.pruned == 0)
        #expect(try paths(store).contains("B/deep/w.jpg"))
    }

    @Test func aListingThatFailsOnlyTemporarilyIsRetriedAndStillPrunesCorrectly() throws {
        let drive = try TempDirectory()
        try populate(drive)
        let store = try makeStore()
        let scanner = try makeScanner(drive, store)
        _ = try run(scanner)
        try FileManager.default.removeItem(atPath: drive.path("A/x.jpg"))

        final class Failures: @unchecked Sendable { var remaining = 2 }
        let failures = Failures()
        scanner.listingHook = { relative in
            if relative == "A", failures.remaining > 0 {
                failures.remaining -= 1
                throw POSIXError(.ENOENT)  // the spurious "No such file or directory"
            }
        }
        let result = try run(scanner)  // two retries are allowed
        #expect(result.errors == 0)
        #expect(result.directoryErrors.isEmpty)
        #expect(result.pruned == 1)
        #expect(try !paths(store).contains("A/x.jpg"))
    }

    @Test func provablyGoneRequiresASuccessfulListingOfTheFolderOrAnAncestor() {
        let listed: [String: Set<String>] = [
            "": ["A", "B"],
            "A": [],
            "B": ["deep"],
            // "B/deep" was never listed successfully
        ]
        // File missing from a folder that was listed.
        #expect(DriveScanner.isProvablyGone("A/x.jpg", scopeRoot: "", listed: listed))
        // Folder C is absent from a successful listing of the root, so everything below it is gone.
        #expect(DriveScanner.isProvablyGone("C/q/x.jpg", scopeRoot: "", listed: listed))
        // The folder exists but its listing failed or was never reached.
        #expect(!DriveScanner.isProvablyGone("B/deep/x.jpg", scopeRoot: "", listed: listed))
        #expect(!DriveScanner.isProvablyGone("B/deep/more/x.jpg", scopeRoot: "", listed: listed))
        // The scan root itself has no listing.
        #expect(!DriveScanner.isProvablyGone("A/x.jpg", scopeRoot: "", listed: [:]))
        // A scope below the drive root.
        let scoped: [String: Set<String>] = ["Backup": ["A"], "Backup/A": []]
        #expect(DriveScanner.isProvablyGone("Backup/A/x.jpg", scopeRoot: "Backup", listed: scoped))
        #expect(DriveScanner.isProvablyGone("Backup/Z/x.jpg", scopeRoot: "Backup", listed: scoped))
        #expect(!DriveScanner.isProvablyGone("Backup/x.jpg", scopeRoot: "Backup", listed: [:]))
    }

    @Test func scanStartRemovesHousekeepingRowsAndRowsOutsideTheScope() throws {
        let drive = try TempDirectory()
        try drive.write("Backup/IMG_0001.jpg", "hello")
        let store = try makeStore()
        try store.upsertDriveFile(DriveFileRecord(relPath: "Backup/desktop.ini", size: 1, mtime: 0, md5: md5("a")))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Autorun.inf", size: 1, mtime: 1))
        try store.upsertDriveFile(DriveFileRecord(relPath: "Other/IMG_0009.jpg", size: 1, mtime: 1, md5: md5("b")))

        let scanner = try makeScanner(drive, store, subpath: "Backup")
        let result = try run(scanner, hash: false, limit: 1)  // even a limited scan does the cleanup
        #expect(result.removedSkipped == 1)
        #expect(result.removedOutOfScope == 2)
        #expect(try paths(store) == ["Backup/IMG_0001.jpg"])
    }

    @Test func rowsOutsideTheScopeAreNotPrunedAsMissingButRemovedAsOutOfScope() throws {
        let drive = try TempDirectory()
        try drive.write("Backup/IMG_0001.jpg", "hello")
        try drive.write("Other/IMG_0002.jpg", "world")
        let store = try makeStore()
        _ = try run(try makeScanner(drive, store))  // whole drive
        #expect(try paths(store).count == 2)

        let result = try run(try makeScanner(drive, store, subpath: "Backup"))
        #expect(result.removedOutOfScope == 1)
        #expect(result.pruned == 0)
        #expect(try paths(store) == ["Backup/IMG_0001.jpg"])
    }

    @Test func pruningWorksWithoutHashing() throws {
        let drive = try TempDirectory()
        try drive.write("a.jpg", "x")
        try drive.write("b.jpg", "y")
        let store = try makeStore()
        let scanner = try makeScanner(drive, store)
        _ = try run(scanner, hash: false)
        try FileManager.default.removeItem(atPath: drive.path("b.jpg"))
        #expect(try run(scanner, hash: false).pruned == 1)
        #expect(try paths(store) == ["a.jpg"])
    }
}
