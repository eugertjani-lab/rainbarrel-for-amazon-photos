import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Download paths: sanitising names and keeping writes inside the target")
struct DownloadPathTests {
    // MARK: Sanitising

    @Test func replacesSlashAndColonAndStripsControlCharacters() {
        #expect(FileNameSanitizer.sanitize("a/b:c.jpg") == "a_b_c.jpg")
        #expect(FileNameSanitizer.sanitize("tab\there\u{0}\u{7F}\u{85}.jpg") == "tabhere.jpg")
        // Characters that NTFS and exFAT reject are replaced too, so a drive reformatted to exFAT still works.
        #expect(FileNameSanitizer.sanitize("a\\b*c?d\"e<f>g|h.png") == "a_b_c_d_e_f_g_h.png")
    }

    @Test func dotsAndEmptyNamesBecomeUnderscore() {
        #expect(FileNameSanitizer.sanitize(".") == "_")
        #expect(FileNameSanitizer.sanitize("..") == "_")
        #expect(FileNameSanitizer.sanitize("") == "_")
        #expect(FileNameSanitizer.sanitize("\u{1}\u{2}") == "_")
        #expect(FileNameSanitizer.sanitize("   ") == "_")
        #expect(FileNameSanitizer.sanitize("...") == "_")
        #expect(FileNameSanitizer.sanitize("name. ") == "name")
    }

    @Test func traversalAttemptsStayInsideOneComponent() {
        for attack in ["../../etc/passwd", "..\\..\\windows", "a/../../b", "/absolute/path", "../", "....//....//x"] {
            let clean = FileNameSanitizer.sanitize(attack)
            #expect(!clean.contains("/"), "\(attack) -> \(clean)")
            #expect(clean != ".." && clean != ".")
        }
        #expect(FileNameSanitizer.sanitize("../../etc/passwd") == ".._.._etc_passwd")
    }

    @Test func longNamesAreCutToTheByteLimitKeepingTheExtension() {
        let long = String(repeating: "a", count: 400) + ".jpeg"
        let clean = FileNameSanitizer.sanitize(long)
        #expect(clean.utf8.count == 255)
        #expect(clean.hasSuffix(".jpeg"))
        // Multi-byte characters are not split.
        let emoji = String(repeating: "\u{1F600}", count: 100) + ".mov"
        let cutEmoji = FileNameSanitizer.sanitize(emoji)
        #expect(cutEmoji.utf8.count <= 255)
        #expect(cutEmoji.hasSuffix(".mov"))
        #expect(String(cutEmoji.dropLast(4)).allSatisfy { $0 == "\u{1F600}" })
    }

    @Test func numberedNamesInsertTheNumberBeforeTheExtension() {
        #expect(FileNameSanitizer.numbered("IMG_1.jpg", 1) == "IMG_1.jpg")
        #expect(FileNameSanitizer.numbered("IMG_1.jpg", 2) == "IMG_1 (2).jpg")
        #expect(FileNameSanitizer.numbered("archive.tar.gz", 3) == "archive.tar (3).gz")
        #expect(FileNameSanitizer.numbered("noext", 2) == "noext (2)")
        #expect(FileNameSanitizer.numbered(".hidden", 2) == ".hidden (2)")
        let long = String(repeating: "b", count: 255 - 4) + ".jpg"
        #expect(FileNameSanitizer.numbered(long, 10).utf8.count <= 255)
        #expect(DownloadPlanner.numbered("A/B/IMG_1.jpg", 2) == "A/B/IMG_1 (2).jpg")
    }

    @Test func temporaryNamesStayWithinTheLimitAndAreRecognised() {
        #expect(FileNameSanitizer.partName(for: "IMG_1.jpg", tag: "abcdef") == ".IMG_1.jpg.rainbarrel-part")
        let long = String(repeating: "c", count: 250) + ".jpg"
        let part = FileNameSanitizer.partName(for: long, tag: "0123456789abcdef0123")
        #expect(part.utf8.count <= 255)
        #expect(FileNameSanitizer.isPartFile(part))
        #expect(!FileNameSanitizer.isPartFile("IMG_1.jpg"))
        #expect(!FileNameSanitizer.isPartFile(".rainbarrel-part"))
        #expect(!FileNameSanitizer.isPartFile(".hidden"))
        // A cloud file that looks like one of our temporary files is renamed so cleanup never touches it.
        #expect(!FileNameSanitizer.isPartFile(FileNameSanitizer.sanitize(".x.rainbarrel-part")))
    }

    // MARK: Path guard

    @Test func guardRejectsPathsOutsideTheRoot() throws {
        let root = try TempDirectory()
        for attack in ["../outside.txt", "a/../../outside.txt", "..", "a/b/../../../x"] {
            #expect(throws: DownloadError.self, "\(attack)") {
                _ = try PathGuard.resolve(root: root.path, relative: attack)
            }
        }
        let inside = try PathGuard.resolve(root: root.path, relative: "a/b/c.jpg")
        #expect(inside.hasSuffix("/a/b/c.jpg"))
        let tricky = try PathGuard.resolve(root: root.path, relative: "a/../b.jpg")
        #expect(tricky.hasSuffix("/b.jpg"))
        // A leading slash does not make the path absolute: it stays below the root.
        let slashed = try PathGuard.resolve(root: root.path, relative: "/etc/passwd")
        #expect(slashed.hasSuffix("/etc/passwd") && slashed.contains(URL(fileURLWithPath: root.path).lastPathComponent))
    }

    @Test func guardRejectsASymbolicLinkThatLeadsOutside() throws {
        let root = try TempDirectory()
        let outside = try TempDirectory()
        try FileManager.default.createSymbolicLink(
            atPath: root.path("escape"), withDestinationPath: outside.path)
        #expect(throws: DownloadError.self) {
            _ = try PathGuard.resolve(root: root.path, relative: "escape/stolen.jpg")
        }
        #expect(throws: DownloadError.self) {
            _ = try PathGuard.resolve(root: root.path, relative: "escape/deeper/stolen.jpg")
        }
    }

    // MARK: Whole targets

    private func builder(folders: [CloudFolder], items: [CloudItem] = [], subpath: String? = "Amazon Drive")
        throws -> (TargetBuilder, StateStore)
    {
        let store = try makeStore()
        try store.replaceCloudCatalog { itemSink, folderSink in
            for folder in folders { try folderSink(folder) }
            for item in items { try itemSink(item) }
            return CatalogReadResult(sourceDescription: "t", sourceModifiedAt: Date(), itemCount: items.count)
        }
        return (try TargetBuilder(store: store, scanSubpath: subpath), store)
    }

    @Test func targetMirrorsTheCloudFolderPathUnderTheScanFolder() throws {
        let item = CloudItem(nodeId: "N1", kind: .file, name: "IMG_0001.HEIC", md5: md5("1"), size: 5, takenAt: t2019, parentId: "F-PHONE")
        let (builder, _) = try builder(folders: testFolders)
        let target = builder.target(for: item)
        #expect(target.relPath == "Amazon Drive/Pictures/Phone/IMG_0001.HEIC")
        #expect(target.resolved)
        // A file directly in the root folder has no folder part.
        let rootItem = CloudItem(nodeId: "N2", kind: .file, name: "top.jpg", md5: md5("2"), size: 5, takenAt: t2019, parentId: "ROOT")
        #expect(builder.target(for: rootItem).relPath == "Amazon Drive/top.jpg")
    }

    @Test func hostileFolderAndFileNamesCannotLeaveTheTarget() throws {
        let folders = [
            CloudFolder(nodeId: "ROOT", name: "", parentId: nil),
            CloudFolder(nodeId: "A", name: "..", parentId: "ROOT"),
            CloudFolder(nodeId: "B", name: "../../..", parentId: "A"),
            CloudFolder(nodeId: "C", name: "x/y:z", parentId: "B"),
        ]
        let item = CloudItem(nodeId: "N", kind: .file, name: "../../escape.jpg", md5: md5("1"), size: 1, takenAt: t2019, parentId: "C")
        let (builder, _) = try builder(folders: folders)
        let target = builder.target(for: item)
        #expect(target.relPath == "Amazon Drive/_/.._.._/x_y_z/.._.._escape.jpg")
        #expect(!target.relPath.split(separator: "/").contains(".."))
        let root = try TempDirectory()
        _ = try PathGuard.resolve(root: root.path, relative: target.relPath)
    }

    @Test func unresolvedFoldersGoToUnsortedByCaptureMonth() throws {
        let (builder, _) = try builder(folders: testFolders)
        let orphan = CloudItem(nodeId: "N", kind: .file, name: "a.jpg", md5: md5("1"), size: 1, takenAt: t2019, parentId: "NOPE")
        let target = builder.target(for: orphan)
        #expect(target.relPath == "Amazon Drive/_Unsorted/2019/06/a.jpg")  // t2019 is 2019-06-18 UTC
        #expect(!target.resolved)
        let noParent = CloudItem(nodeId: "N", kind: .file, name: "a.jpg", md5: md5("1"), size: 1, takenAt: t2015, parentId: nil)
        #expect(builder.target(for: noParent).relPath == "Amazon Drive/_Unsorted/2015/03/a.jpg")
        let undated = CloudItem(nodeId: "N", kind: .file, name: "a.jpg", md5: md5("1"), size: 1, takenAt: 0, parentId: nil)
        #expect(builder.target(for: undated).relPath == "Amazon Drive/_Unsorted/unknown-date/a.jpg")
        // A folder chain that never reaches the root (a loop) is unresolved too.
        let loop = [CloudFolder(nodeId: "L1", name: "a", parentId: "L2"), CloudFolder(nodeId: "L2", name: "b", parentId: "L1")]
        let (loopBuilder, _) = try self.builder(folders: loop)
        let inLoop = CloudItem(nodeId: "N", kind: .file, name: "a.jpg", md5: md5("1"), size: 1, takenAt: t2019, parentId: "L1")
        #expect(!loopBuilder.target(for: inLoop).resolved)
    }

    @Test func namesWithoutExtensionGetTheCatalogExtension() {
        let item = CloudItem(nodeId: "N", kind: .file, name: "photo", md5: md5("1"), size: 1, takenAt: t2019, ext: "jpg", parentId: "F")
        #expect(TargetBuilder.fileName(for: item) == "photo.jpg")
        let named = CloudItem(nodeId: "N", kind: .file, name: "photo.png", md5: md5("1"), size: 1, takenAt: t2019, ext: "jpg", parentId: "F")
        #expect(TargetBuilder.fileName(for: named) == "photo.png")
        let empty = CloudItem(nodeId: "N-ID", kind: .file, name: "", md5: md5("1"), size: 1, takenAt: t2019, ext: "jpg", parentId: "F")
        #expect(TargetBuilder.fileName(for: empty) == "N-ID.jpg")
    }

    @Test func liveVideoLandsBesideItsPhotoNamedLikeThePhoto() throws {
        let photo = CloudItem(nodeId: "P1", kind: .file, name: "IMG_0004.HEIC", md5: md5("4"), size: 5, takenAt: t2019, ext: "heic", parentId: "F-PHONE")
        let video = CloudItem(nodeId: "L1", kind: .liveVideo, name: "2019-06-18_04-02-57_002_lpv", md5: md5("5"), size: 5, takenAt: t2019, ext: "qt", parentId: "P1")
        let (builder, _) = try builder(folders: testFolders, items: [photo, video])
        let target = builder.target(for: video)
        #expect(target.relPath == "Amazon Drive/Pictures/Phone/IMG_0004.MOV")
        #expect(target.resolved)
        // Without the photo, the video goes to the unsorted folder under its own name.
        let lonely = CloudItem(nodeId: "L2", kind: .liveVideo, name: "clip_lpv", md5: md5("6"), size: 5, takenAt: t2019, ext: "qt", parentId: "GONE")
        #expect(builder.target(for: lonely).relPath == "Amazon Drive/_Unsorted/2019/06/clip_lpv.MOV")
    }

    @Test func noScanSubpathPutsTheCloudTreeAtTheDriveRoot() throws {
        let (builder, _) = try builder(folders: testFolders, subpath: nil)
        let item = CloudItem(nodeId: "N1", kind: .file, name: "a.jpg", md5: md5("1"), size: 5, takenAt: t2019, parentId: "F-DOCS")
        #expect(builder.target(for: item).relPath == "Docs/a.jpg")
    }
}
