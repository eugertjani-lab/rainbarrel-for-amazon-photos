import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Organize: planning")
struct OrganizePlanTests {
    private let t = "Amazon Drive"

    /// A drive that was filled by a plain copy: one file to move, one in place, two copies of one
    /// file, one file with an unknown cloud folder, a drive-only file, a file without hash and a
    /// cloud file that is not on the drive.
    private func copiedDrive() throws -> OrganizeFixture {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let b = cloudFile("B", "IMG_0002.jpg", seed: 2)
        let c = cloudFile("C", "report.pdf", seed: 3, folder: "F-DOCS")
        let d = cloudFile("D", "IMG_0009.jpg", seed: 9)
        let u = cloudFile("U", "lost.jpg", seed: 7, folder: "F-GONE", takenAt: t2015)
        let fx = try OrganizeFixture(files: [a, b, c, d, u])
        try fx.put("\(t)/Old Backup/2019/a.jpg", a.data)
        try fx.put("\(t)/Pictures/Phone/IMG_0002.jpg", b.data)
        try fx.put("\(t)/stuff/c.pdf", c.data)
        try fx.put("\(t)/stuff/deep/er/c-copy.pdf", c.data)
        try fx.put("\(t)/misc/u.jpg", u.data)
        try fx.put("\(t)/Unrelated/vacation.mov", bytes(900, seed: 50))
        try fx.scan()
        // A file the index knows without a hash.
        let path = try fx.put("\(t)/Unrelated/new.bin", bytes(900, seed: 60))
        let info = try FileManager.default.attributesOfItem(atPath: path)
        try fx.store().upsertDriveFile(DriveFileRecord(
            relPath: "\(t)/Unrelated/new.bin", size: Int64(info[.size] as? UInt64 ?? 0), mtime: 1_500_000_000))
        return fx
    }

    @Test func theDryRunCountsEverythingAndChangesNothing() throws {
        let fx = try copiedDrive()
        let filesBefore = try fx.files()
        let foldersBefore = fx.folders()
        let indexBefore = try fx.indexedPaths()

        let preview = try fx.service.preview(config: fx.config, sample: 50)
        let s = preview.summary
        #expect(s.toMove == 3 && s.toMoveBytes == 2700)
        #expect(s.toUnsorted == 1 && s.renamedForCollision == 0)
        #expect(s.alreadyInPlace == 1)
        #expect(s.duplicatesLeft == 1 && s.duplicatesLeftBytes == 900)
        #expect(s.driveOnlyUntouched == 1 && s.driveOnlyUntouchedBytes == 900)
        #expect(s.unhashedUntouched == 1)
        #expect(s.skippedTotal == 0 && s.skipped.isEmpty)
        #expect(s.onlineOnly == 1)
        #expect(preview.sample.map(\.from) == ["\(t)/Old Backup/2019/a.jpg", "\(t)/stuff/c.pdf", "\(t)/misc/u.jpg"])
        #expect(preview.sample.map(\.to) == [
            "\(t)/Pictures/Phone/IMG_0001.jpg", "\(t)/Docs/report.pdf", "\(t)/_Unsorted/2015/03/lost.jpg",
        ])
        #expect(preview.sample[2].note?.contains("unknown") == true)
        #expect(preview.duplicateSample == [
            OrganizeDuplicateEntry(path: "\(t)/stuff/deep/er/c-copy.pdf", keptAt: "\(t)/Docs/report.pdf", size: 900)
        ])
        #expect(preview.targetFolder == fx.drive.path + "/" + t)

        // Nothing changed: not on the drive, not in the index, no journal.
        #expect(try fx.files() == filesBefore)
        #expect(fx.folders() == foldersBefore)
        #expect(try fx.indexedPaths() == indexBefore)
        #expect(try fx.journal().isEmpty)
    }

    @Test func theSampleIsCappedAndMayBeEmpty() throws {
        let fx = try copiedDrive()
        #expect(try fx.service.preview(config: fx.config, sample: 2).sample.count == 2)
        let none = try fx.service.preview(config: fx.config, sample: 0)
        #expect(none.sample.isEmpty && none.summary.toMove == 3)
    }

    @Test func aFileAlreadyAtItsTargetIsKept() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [a])
        try fx.put("\(t)/Pictures/Phone/IMG_0001.jpg", a.data)
        try fx.scan()
        let preview = try fx.service.preview(config: fx.config)
        #expect(preview.summary.toMove == 0 && preview.summary.alreadyInPlace == 1)
        let result = try fx.service.apply(config: fx.config)
        #expect(result.moved == 0 && result.runId == nil && result.alreadyInPlace == 1)
        #expect(try fx.journal().isEmpty)
    }

    @Test func ofSeveralCopiesTheOneAtTheTargetWins() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [a])
        try fx.put("\(t)/a/IMG.jpg", a.data)  // shorter than the target path
        try fx.put("\(t)/Pictures/Phone/IMG_0001.jpg", a.data)
        try fx.scan()
        let preview = try fx.service.preview(config: fx.config)
        #expect(preview.summary.toMove == 0 && preview.summary.alreadyInPlace == 1)
        #expect(preview.duplicateSample.map(\.path) == ["\(t)/a/IMG.jpg"])
        #expect(preview.duplicateSample.first?.keptAt == "\(t)/Pictures/Phone/IMG_0001.jpg")
    }

    @Test func ofSeveralCopiesAwayFromTheTargetTheShortestPathThenTheFirstWins() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [a])
        try fx.put("\(t)/long/folder/name/IMG.jpg", a.data)
        try fx.put("\(t)/b/IMG.jpg", a.data)
        try fx.put("\(t)/a/IMG.jpg", a.data)  // same length as b/IMG.jpg, first in order
        try fx.scan()
        let preview = try fx.service.preview(config: fx.config)
        #expect(preview.sample.map(\.from) == ["\(t)/a/IMG.jpg"])
        #expect(preview.duplicateSample.map(\.path) == ["\(t)/b/IMG.jpg", "\(t)/long/folder/name/IMG.jpg"])
        #expect(preview.summary.duplicatesLeft == 2)
    }

    @Test func aTargetHoldingTheSameContentMakesTheSourceADuplicate() throws {
        // Two cloud items with the same bytes and the same target name: one file is at the target
        // and satisfies the first item; the other copy would land on a name that already has its content.
        let first = cloudFile("A", "IMG_0001.jpg", seed: 1)
        var second = cloudFile("B", "IMG_0001.jpg", seed: 1)
        second.takenAt = t2015
        let fx = try OrganizeFixture(files: [first, second])
        try fx.put("\(t)/Pictures/Phone/IMG_0001.jpg", first.data)
        try fx.put("\(t)/elsewhere/copy.jpg", first.data)
        try fx.scan()
        let preview = try fx.service.preview(config: fx.config)
        #expect(preview.summary.toMove == 0 && preview.summary.alreadyInPlace == 1)
        #expect(preview.summary.duplicatesLeft == 1)
        #expect(preview.duplicateSample.map(\.path) == ["\(t)/elsewhere/copy.jpg"])
    }

    @Test func aTargetHoldingDifferentContentGivesANumberedName() throws {
        let wanted = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [wanted])
        let squatter = bytes(900, seed: 77)
        try fx.put("\(t)/Pictures/Phone/IMG_0001.jpg", squatter)  // a different photo with the same name
        try fx.put("\(t)/inbox/new.jpg", wanted.data)
        try fx.scan()
        let preview = try fx.service.preview(config: fx.config)
        #expect(preview.summary.toMove == 1 && preview.summary.renamedForCollision == 1)
        #expect(preview.sample.first?.to == "\(t)/Pictures/Phone/IMG_0001 (2).jpg")
        #expect(preview.sample.first?.note?.contains("numbered") == true)

        let result = try fx.service.apply(config: fx.config)
        #expect(result.moved == 1)
        #expect(fx.contents("\(t)/Pictures/Phone/IMG_0001.jpg") == squatter)  // untouched
        #expect(fx.contents("\(t)/Pictures/Phone/IMG_0001 (2).jpg") == wanted.data)
        #expect(!fx.exists("\(t)/inbox/new.jpg"))
    }

    @Test func twoCloudFilesWithTheSameNameAreNumberedInTheDownloadOrder() throws {
        let newer = cloudFile("N", "IMG_0001.jpg", seed: 1, takenAt: t2019)
        let older = cloudFile("O", "IMG_0001.jpg", seed: 2, takenAt: t2015)
        let fx = try OrganizeFixture(files: [newer, older])
        try fx.put("\(t)/x/1.jpg", older.data)
        try fx.put("\(t)/x/2.jpg", newer.data)
        try fx.scan()
        _ = try fx.service.apply(config: fx.config)
        // The downloads fetch the newest first, so the newest gets the plain name.
        #expect(fx.contents("\(t)/Pictures/Phone/IMG_0001.jpg") == newer.data)
        #expect(fx.contents("\(t)/Pictures/Phone/IMG_0001 (2).jpg") == older.data)
    }

    @Test func aMoveMayTakeANameThatAnotherMoveFrees() throws {
        // The file at IMG_0010.jpg belongs in Docs; the file that wants IMG_0010.jpg is elsewhere.
        let leaving = cloudFile("L", "n.pdf", seed: 4, folder: "F-DOCS")
        let arriving = cloudFile("R", "IMG_0010.jpg", seed: 5)
        let fx = try OrganizeFixture(files: [leaving, arriving])
        try fx.put("\(t)/Pictures/Phone/IMG_0010.jpg", leaving.data)
        try fx.put("\(t)/inbox/x.jpg", arriving.data)
        try fx.scan()
        let preview = try fx.service.preview(config: fx.config)
        #expect(preview.summary.toMove == 2 && preview.summary.renamedForCollision == 0)
        _ = try fx.service.apply(config: fx.config)
        #expect(fx.contents("\(t)/Pictures/Phone/IMG_0010.jpg") == arriving.data)
        #expect(fx.contents("\(t)/Docs/n.pdf") == leaving.data)
        #expect(!fx.exists("\(t)/Pictures/Phone/IMG_0010 (2).jpg"))
    }

    @Test func theVideoOfALivePhotoIsNamedAfterItsPhoto() throws {
        let photo = cloudFile("P4", "IMG_0004.HEIC", seed: 14)
        let video = cloudFile("V4", "something-else.mov", seed: 15, kind: .liveVideo, parent: "P4")
        let fx = try OrganizeFixture(files: [photo, video])
        try fx.put("\(t)/clips/p.heic", photo.data)
        try fx.put("\(t)/clips/v.mov", video.data)
        try fx.scan()
        let preview = try fx.service.preview(config: fx.config)
        #expect(Set(preview.sample.map(\.to)) == ["\(t)/Pictures/Phone/IMG_0004.HEIC", "\(t)/Pictures/Phone/IMG_0004.MOV"])
        #expect(preview.sample.first { $0.kind == .liveVideo }?.to == "\(t)/Pictures/Phone/IMG_0004.MOV")
        _ = try fx.service.apply(config: fx.config)
        #expect(fx.contents("\(t)/Pictures/Phone/IMG_0004.MOV") == video.data)
    }

    @Test func aFileWithAnUnknownCloudFolderGoesToUnsortedByCaptureMonth() throws {
        let lost = cloudFile("U", "lost.jpg", seed: 7, folder: "F-GONE", takenAt: t2019)
        let undated = cloudFile("V", "undated.jpg", seed: 8, folder: nil, takenAt: 0)
        let fx = try OrganizeFixture(files: [lost, undated])
        try fx.put("\(t)/misc/u.jpg", lost.data)
        try fx.put("\(t)/misc/v.jpg", undated.data)
        try fx.scan()
        let preview = try fx.service.preview(config: fx.config)
        #expect(preview.summary.toUnsorted == 2)
        #expect(Set(preview.sample.map(\.to)) == ["\(t)/_Unsorted/2019/06/lost.jpg", "\(t)/_Unsorted/unknown-date/undated.jpg"])
    }

    @Test func driveOnlyAndUnhashedFilesAreNeverTouched() throws {
        let fx = try copiedDrive()
        let result = try fx.service.apply(config: fx.config)
        #expect(result.moved == 3)
        #expect(fx.contents("\(t)/Unrelated/vacation.mov") == bytes(900, seed: 50))
        #expect(fx.contents("\(t)/Unrelated/new.bin") == bytes(900, seed: 60))
        #expect(fx.contents("\(t)/stuff/deep/er/c-copy.pdf") != nil)  // the extra copy stays
    }

    @Test func aFileOnAnotherVolumeIsSkippedNotCopied() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let b = cloudFile("B", "IMG_0002.jpg", seed: 2)
        let fx = try OrganizeFixture(files: [a, b])
        try fx.put("\(t)/other-volume/a.jpg", a.data)
        try fx.put("\(t)/inbox/b.jpg", b.data)
        try fx.scan()
        fx.markAsOtherVolume("/other-volume/")
        let preview = try fx.service.preview(config: fx.config)
        #expect(preview.summary.toMove == 1 && preview.summary.skippedTotal == 1)
        let group = try #require(preview.summary.skipped.first)
        #expect(group.reason == .differentVolume && group.count == 1)
        #expect(group.examples == ["\(t)/other-volume/a.jpg"])
        let result = try fx.service.apply(config: fx.config)
        #expect(result.moved == 1 && result.skippedTotal == 1)
        #expect(fx.contents("\(t)/other-volume/a.jpg") == a.data)  // still there, nothing copied
        #expect(!fx.exists("\(t)/Pictures/Phone/IMG_0001.jpg"))
    }

    @Test func aFileChangedSinceTheScanOrGoneIsSkipped() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let b = cloudFile("B", "IMG_0002.jpg", seed: 2)
        let c = cloudFile("C", "IMG_0003.jpg", seed: 3)
        let fx = try OrganizeFixture(files: [a, b, c])
        try fx.put("\(t)/in/a.jpg", a.data)
        try fx.put("\(t)/in/b.jpg", b.data)
        try fx.put("\(t)/in/c.jpg", c.data)
        try fx.scan()
        try fx.put("\(t)/in/a.jpg", a.data, mtime: 1_600_000_000)  // same bytes, new modification time
        try FileManager.default.removeItem(atPath: fx.drive.path("\(t)/in/b.jpg"))
        let preview = try fx.service.preview(config: fx.config)
        #expect(preview.summary.toMove == 1)
        #expect(Set(preview.summary.skipped.map(\.reason)) == [.changed, .missing])
        #expect(preview.sample.map(\.from) == ["\(t)/in/c.jpg"])
    }

    @Test func anImportedHashThatNoScanConfirmedIsNotTrusted() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [a])
        try fx.put("\(t)/in/a.jpg", a.data)
        try fx.store().upsertDriveFile(DriveFileRecord(
            relPath: "\(t)/in/a.jpg", size: 900, mtime: 0, md5: a.md5, hashedAt: 1))
        let preview = try fx.service.preview(config: fx.config)
        #expect(preview.summary.toMove == 0)
        #expect(preview.summary.skipped.map(\.reason) == [.unverified])
    }

    @Test func theWholeDriveCanBeTheScanFolder() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [a], scanSubpath: nil)
        try fx.put("inbox/a.jpg", a.data)
        try fx.scan()
        _ = try fx.service.apply(config: fx.config)
        #expect(fx.contents("Pictures/Phone/IMG_0001.jpg") == a.data)
    }

    @Test func withoutAFolderTreeOrCatalogNothingIsPlanned() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [a])
        try fx.fill([a.item], folders: [])
        #expect(throws: OrganizeError.folderTreeMissing) { try fx.service.preview(config: fx.config) }
        try fx.fill([], folders: testFolders)
        #expect(throws: OrganizeError.catalogEmpty) { try fx.service.preview(config: fx.config) }
        var unconfigured = fx.config
        unconfigured.driveRoot = nil
        #expect(throws: DownloadError.noDriveConfigured) { try fx.service.preview(config: unconfigured) }
        var missing = fx.config
        missing.driveRoot = fx.drive.path("not-mounted")
        #expect(throws: DownloadError.self) { try fx.service.preview(config: missing) }
    }
}

@Suite("Organize: moving, journal and undo")
struct OrganizeRunTests {
    private let t = "Amazon Drive"

    /// Four files to move, newest first in the order the downloads use.
    private func fourFiles() throws -> OrganizeFixture {
        let files = (1...4).map { cloudFile("N\($0)", "IMG_000\($0).jpg", seed: UInt8($0), takenAt: t2019 - Int64($0)) }
        let fx = try OrganizeFixture(files: files)
        for (index, file) in files.enumerated() { try fx.put("\(t)/inbox/\(index + 1)/f.jpg", file.data) }
        try fx.scan()
        return fx
    }

    @Test func applyProducesTheDownloadLayoutAndKeepsTheIndexInSync() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let c = cloudFile("C", "report.pdf", seed: 3, folder: "F-DOCS")
        let online = cloudFile("D", "IMG_0009.jpg", seed: 9)
        let fx = try OrganizeFixture(files: [a, c, online])
        try fx.put("\(t)/Old Backup/a.jpg", a.data)
        try fx.put("\(t)/stuff/c.pdf", c.data)
        try fx.scan()
        let result = try fx.service.apply(config: fx.config)
        #expect(result.moved == 2 && result.movedBytes == 1800 && result.runId == 1 && result.stopReason == nil)
        #expect(try fx.files() == [
            "\(t)/Docs/report.pdf 900 1500000000", "\(t)/Pictures/Phone/IMG_0001.jpg 900 1500000000",
        ])
        // The index follows the files, so nothing needs hashing again.
        #expect(try fx.indexedPaths() == ["\(t)/Docs/report.pdf", "\(t)/Pictures/Phone/IMG_0001.jpg"])
        let again = try fx.scan()
        #expect(again.filesHashed == 0 && again.pruned == 0)
        let report = try Reconciler(store: fx.store(), scope: DriveScope(scanSubpath: fx.config.scanSubpath))
            .report(driveRoot: fx.drive.path)
        #expect(report.inSync.count == 2 && report.onlineOnly.count == 1)
        // Organized once, organized for good.
        let second = try fx.service.apply(config: fx.config)
        #expect(second.moved == 0 && second.alreadyInPlace == 2)
    }

    @Test func aLimitStopsTheRunAndARerunContinues() throws {
        let fx = try fourFiles()
        let first = try fx.service.apply(config: fx.config, options: OrganizeOptions(limit: 2))
        #expect(first.moved == 2 && first.stopReason == .limit && first.remaining == 2 && first.runId == 1)
        #expect(try fx.journal().map(\.to) == [
            "\(t)/Pictures/Phone/IMG_0001.jpg", "\(t)/Pictures/Phone/IMG_0002.jpg",
        ])  // newest first

        var checks = 0
        let second = try fx.service.apply(config: fx.config, isCancelled: {
            checks += 1
            return checks > 1  // allows one move, like a Ctrl-C after the first file
        })
        #expect(second.moved == 1 && second.stopReason == .cancelled && second.remaining == 1 && second.runId == 2)

        let third = try fx.service.apply(config: fx.config)
        #expect(third.moved == 1 && third.stopReason == nil && third.runId == 3)
        let fourth = try fx.service.apply(config: fx.config)
        #expect(fourth.moved == 0 && fourth.alreadyInPlace == 4 && fourth.runId == nil)
        #expect(try fx.files().count == 4)
        for number in 1...4 { #expect(fx.exists("\(t)/Pictures/Phone/IMG_000\(number).jpg")) }
        #expect(try fx.journal().map(\.runId) == [1, 1, 2, 3])
    }

    @Test func aRunThatStoppedBetweenTheMoveAndTheBookkeepingIsHealedByAScan() throws {
        // A file that was renamed but not recorded (the process died in between) is simply found
        // at its new place by the next scan; organize never loses it.
        let fx = try fourFiles()
        try FileManager.default.createDirectory(
            atPath: fx.drive.path("\(t)/Pictures/Phone"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            atPath: fx.drive.path("\(t)/inbox/1/f.jpg"), toPath: fx.drive.path("\(t)/Pictures/Phone/IMG_0001.jpg"))
        let result = try fx.service.apply(config: fx.config)
        #expect(result.moved == 3 && result.skippedTotal == 1)
        #expect(result.skipped.first?.reason == .missing)
        try fx.scan()
        let after = try fx.service.apply(config: fx.config)
        #expect(after.moved == 0 && after.alreadyInPlace == 4)
    }

    @Test func undoRestoresTheOriginalTreeExactly() throws {
        let fx = try fourFiles()
        let filesBefore = try fx.files()
        let foldersBefore = fx.folders()
        let indexBefore = try fx.indexedPaths()

        let applied = try fx.service.apply(config: fx.config)
        #expect(applied.moved == 4)
        #expect(try fx.files() != filesBefore)

        let undone = try fx.service.undo(config: fx.config)
        #expect(undone.restored == 4 && undone.refused.isEmpty && undone.runId == 1)
        #expect(undone.removedFolders == 2)  // Pictures and Pictures/Phone, which the run had created
        #expect(try fx.files() == filesBefore)
        #expect(fx.folders() == foldersBefore)
        #expect(try fx.indexedPaths() == indexBefore)
        #expect(try fx.journal().isEmpty)
        #expect(throws: OrganizeError.nothingToUndo) { try fx.service.undo(config: fx.config) }
        // The index agrees with the drive again, without hashing.
        let again = try fx.scan()
        #expect(again.filesHashed == 0 && again.pruned == 0)
    }

    @Test func undoOnlyReversesTheLastRun() throws {
        let fx = try fourFiles()
        _ = try fx.service.apply(config: fx.config, options: OrganizeOptions(limit: 2))
        _ = try fx.service.apply(config: fx.config)
        let undone = try fx.service.undo(config: fx.config)
        #expect(undone.restored == 2 && undone.runId == 2)
        #expect(fx.exists("\(t)/Pictures/Phone/IMG_0001.jpg") && fx.exists("\(t)/Pictures/Phone/IMG_0002.jpg"))
        #expect(fx.exists("\(t)/inbox/3/f.jpg") && fx.exists("\(t)/inbox/4/f.jpg"))
        // Folders from the first run stay, because the first run created them.
        #expect(fx.folders().contains("\(t)/Pictures/Phone"))
    }

    @Test func undoRefusesAFileThatChangedAfterTheMove() throws {
        let fx = try fourFiles()
        _ = try fx.service.apply(config: fx.config)
        try fx.put("\(t)/Pictures/Phone/IMG_0002.jpg", bytes(900, seed: 99), mtime: 1_700_000_000)  // edited since

        let undone = try fx.service.undo(config: fx.config)
        #expect(undone.restored == 3)
        let refusal = try #require(undone.refused.first)
        #expect(undone.refused.count == 1 && refusal.path == "\(t)/Pictures/Phone/IMG_0002.jpg")
        #expect(refusal.reason.contains("changed"))
        #expect(fx.contents("\(t)/Pictures/Phone/IMG_0002.jpg") == bytes(900, seed: 99))  // left alone
        #expect(!fx.exists("\(t)/inbox/2/f.jpg"))
        // The refused entry stays in the journal; the folder it lives in is not removed.
        #expect(try fx.journal().count == 1)
        #expect(undone.removedFolders == 0)
        // Fixing the file lets a second undo finish the job.
        try fx.put("\(t)/Pictures/Phone/IMG_0002.jpg", bytes(900, seed: 2), mtime: 1_500_000_000)
        let retry = try fx.service.undo(config: fx.config)
        #expect(retry.restored == 1 && retry.refused.isEmpty && retry.removedFolders > 0)
        #expect(fx.exists("\(t)/inbox/2/f.jpg"))
    }

    @Test func undoRefusesWhenTheOriginalPlaceIsTaken() throws {
        let fx = try fourFiles()
        _ = try fx.service.apply(config: fx.config)
        try fx.put("\(t)/inbox/3/f.jpg", bytes(900, seed: 55))  // something new sits at the old place
        let undone = try fx.service.undo(config: fx.config)
        #expect(undone.restored == 3 && undone.refused.count == 1)
        #expect(undone.refused.first?.reason.contains("original place") == true)
        #expect(fx.contents("\(t)/inbox/3/f.jpg") == bytes(900, seed: 55))  // never overwritten
        #expect(fx.exists("\(t)/Pictures/Phone/IMG_0003.jpg"))
    }

    @Test func undoRefusesAFileThatIsGone() throws {
        let fx = try fourFiles()
        _ = try fx.service.apply(config: fx.config)
        try FileManager.default.removeItem(atPath: fx.drive.path("\(t)/Pictures/Phone/IMG_0004.jpg"))
        let undone = try fx.service.undo(config: fx.config)
        #expect(undone.restored == 3 && undone.refused.map(\.reason) == ["the file is no longer there"])
    }

    @Test func pruningRemovesOnlyTheFoldersTheRunEmptied() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let b = cloudFile("B", "IMG_0002.jpg", seed: 2)
        let fx = try OrganizeFixture(files: [a, b])
        try fx.put("\(t)/Old/2019/a.jpg", a.data)
        try fx.put("\(t)/Old/2019/note.txt", Data("a note".utf8))  // keeps its folder alive
        try fx.put("\(t)/Only/Here/b.jpg", b.data)
        try FileManager.default.createDirectory(atPath: fx.drive.path("\(t)/EmptyBefore"), withIntermediateDirectories: true)
        try fx.scan()

        let result = try fx.service.apply(config: fx.config, options: OrganizeOptions(pruneEmptyDirs: true))
        #expect(result.moved == 2 && result.prunedFolders == 2)  // Only/Here, then Only
        let folders = fx.folders()
        #expect(folders.contains("\(t)/Old/2019"))
        #expect(folders.contains("\(t)/EmptyBefore"))  // empty before the run: not ours to remove
        #expect(!folders.contains("\(t)/Only/Here") && !folders.contains("\(t)/Only"))
        #expect(fx.exists(t))  // the scan folder itself is never removed

        // Undo brings the removed folders back with the files.
        _ = try fx.service.undo(config: fx.config)
        #expect(fx.exists("\(t)/Only/Here/b.jpg") && fx.exists("\(t)/Old/2019/a.jpg"))
    }

    @Test func withoutThePruneFlagEmptiedFoldersStay() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [a])
        try fx.put("\(t)/Only/Here/a.jpg", a.data)
        try fx.scan()
        let result = try fx.service.apply(config: fx.config)
        #expect(result.prunedFolders == 0)
        #expect(fx.folders().contains("\(t)/Only/Here"))
    }

    @Test func aFolderWithOnlyAHousekeepingFileIsNotPruned() throws {
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [a])
        try fx.put("\(t)/Only/a.jpg", a.data)
        try fx.put("\(t)/Only/.DS_Store", Data("x".utf8))
        try fx.scan()
        let result = try fx.service.apply(config: fx.config, options: OrganizeOptions(pruneEmptyDirs: true))
        #expect(result.moved == 1 && result.prunedFolders == 0)
        #expect(fx.exists("\(t)/Only/.DS_Store"))
    }

    @Test func downloadsAndOrganizeKeepEachOtherOut() throws {
        let fx = try fourFiles()
        let download = try #require(try RunLock(path: fx.paths.downloadLockURL.path))
        #expect(throws: DownloadError.alreadyRunning) { try fx.service.apply(config: fx.config) }
        #expect(throws: DownloadError.alreadyRunning) { try fx.service.undo(config: fx.config) }
        // A dry run only reads, so it is allowed.
        #expect(try fx.service.preview(config: fx.config).summary.toMove == 4)
        #expect(try fx.files().count == 4 && !fx.exists("\(t)/Pictures"))
        download.release()

        // While organize runs, a download cannot take the lock.
        var downloadCouldStart = true
        _ = try fx.service.apply(config: fx.config, options: OrganizeOptions(limit: 1), progress: { _ in
            if (try? RunLock(path: fx.paths.downloadLockURL.path)) == nil { downloadCouldStart = false }
        })
        #expect(!downloadCouldStart)
        // And the lock is free again afterwards.
        let after = try RunLock(path: fx.paths.downloadLockURL.path)
        #expect(after != nil)
        after?.release()
    }

    @Test func aReadOnlyDriveIsRefusedWithTheDownloadMessage() throws {
        let fx = try fourFiles()
        var missing = fx.config
        missing.driveRoot = fx.drive.path("no-such-drive")
        #expect(throws: DownloadError.driveNotMounted(fx.drive.path("no-such-drive"))) {
            try fx.service.apply(config: missing)
        }
        // A folder that cannot be written to fails the probe the downloads use.
        let folder = fx.drive.path(t)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        if access(folder, W_OK) != 0 {  // not when the tests run as root
            #expect(throws: DownloadError.targetNotWritable(path: folder, detail: nil)) {
                try fx.service.apply(config: fx.config)
            }
            #expect(DownloadError.targetNotWritable(path: folder, detail: nil).description == DownloadError.readOnlyMessage)
            #expect(try fx.journal().isEmpty)
        }
    }

    @Test func nothingIsOverwrittenWhenAFileAppearsAtTheTargetAfterThePlan() throws {
        // The plan is made inside `apply`, so simulate the race with the executor directly.
        let a = cloudFile("A", "IMG_0001.jpg", seed: 1)
        let fx = try OrganizeFixture(files: [a])
        try fx.put("\(t)/in/a.jpg", a.data)
        try fx.scan()
        let store = try fx.store()
        let planner = try OrganizePlanner(store: store, config: fx.config, environment: fx.environment)
        let plan = try planner.plan()
        #expect(plan.moves.count == 1)
        let stranger = bytes(900, seed: 88)
        try fx.put("\(t)/Pictures/Phone/IMG_0001.jpg", stranger)
        let executor = OrganizeExecutor(
            store: store, driveRoot: fx.drive.path, scanFolder: fx.drive.path(t), environment: fx.environment)
        let result = try executor.apply(plan: plan, options: OrganizeOptions(), isCancelled: { false }, progress: { _ in })
        #expect(result.moved == 1)
        #expect(fx.contents("\(t)/Pictures/Phone/IMG_0001.jpg") == stranger)
        #expect(fx.contents("\(t)/Pictures/Phone/IMG_0001 (2).jpg") == a.data)
    }
}

@Suite("Organize: tool")
struct OrganizeToolTests {
    private let t = "Amazon Drive"

    @Test func theToolIsReadOnlyAndDescribesItsSampleArgument() throws {
        let definition = try #require(RainbarrelToolRegistry.definitions.first { $0.name == "organize_preview" })
        #expect(definition.readOnly)
        guard case .object(let schema) = definition.inputSchema, case .object(let properties)? = schema["properties"],
            case .object(let sample)? = properties["sample"]
        else {
            Issue.record("organize_preview has no sample property")
            return
        }
        #expect(Set(properties.keys) == ["sample"])
        #expect(sample["default"] == .int(20) && sample["maximum"] == .int(200) && sample["minimum"] == .int(0))
        #expect(schema["additionalProperties"] == .bool(false))
        #expect(definition.description.contains("--apply"))
        #expect((try? JSONEncoder().encode(definition.inputSchema)) != nil)
        // Applying is not offered as a tool.
        #expect(!RainbarrelToolRegistry.definitions.contains { $0.name.contains("organize") && !$0.readOnly })
    }

    @Test func thePreviewComesBackAsJSONAndChangesNothing() throws {
        let files = (1...3).map { cloudFile("N\($0)", "IMG_000\($0).jpg", seed: UInt8($0)) }
        let fx = try OrganizeFixture(files: files)
        for (index, file) in files.enumerated() { try fx.put("\(t)/inbox/\(index).jpg", file.data) }
        try fx.scan()
        let tools = RainbarrelTools(
            paths: fx.paths, catalogSource: { _ in StaticCatalog(items: []) }, sessionStore: MemorySessionStore(nil),
            organizeEnvironment: fx.environment)
        try tools.saveConfig(fx.config)
        let registry = RainbarrelToolRegistry(tools: tools)
        let before = try fx.files()

        let outcome = registry.call(name: "organize_preview", arguments: ["sample": .int(2)])
        #expect(!outcome.isError, "\(outcome.text)")
        let preview = try JSONDecoder.iso8601.decode(OrganizePreview.self, from: Data(outcome.text.utf8))
        #expect(preview.summary.toMove == 3 && preview.sample.count == 2)
        #expect(try fx.files() == before)
        #expect(try fx.journal().isEmpty)

        let defaults = registry.call(name: "organize_preview", arguments: nil)
        #expect(!defaults.isError)
        let tooMany = registry.call(name: "organize_preview", arguments: ["sample": .int(9999)])
        #expect(tooMany.isError && tooMany.text.contains("sample"))
    }

    @Test func problemsComeBackAsReadableToolErrors() async throws {
        let fx = try OrganizeFixture(files: [cloudFile("A", "IMG_0001.jpg", seed: 1)])
        try fx.fill([], folders: testFolders)
        let tools = RainbarrelTools(
            paths: fx.paths, catalogSource: { _ in StaticCatalog(items: []) }, sessionStore: MemorySessionStore(nil),
            organizeEnvironment: fx.environment)
        try tools.saveConfig(fx.config)
        let registry = RainbarrelToolRegistry(tools: tools)
        let empty = await registry.callAsync(name: "organize_preview", arguments: nil)
        #expect(empty.isError && empty.text == OrganizeError.catalogEmpty.description)

        var unmounted = fx.config
        unmounted.driveRoot = fx.drive.path("gone")
        try tools.saveConfig(unmounted)
        try fx.fill([cloudFile("A", "IMG_0001.jpg", seed: 1).item])
        let outcome = registry.call(name: "organize_preview", arguments: nil)
        #expect(outcome.isError && outcome.text.contains("not mounted"))
    }
}
