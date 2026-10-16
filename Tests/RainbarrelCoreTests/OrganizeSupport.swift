import Foundation
@testable import RainbarrelCore

/// Everything for an organize test: a data folder, a drive folder holding a copy, and a cloud catalog.
/// Every name and every byte is made up.
final class OrganizeFixture: @unchecked Sendable {
    let home: TempDirectory
    let drive: TempDirectory
    let paths: AppPaths
    var config: Config
    /// Folders (below the drive root) that the injected volume function reports as another volume.
    private let otherVolumeLock = NSLock()
    private var otherVolumeMarkers: [String] = []

    var environment: OrganizeEnvironment {
        OrganizeEnvironment(
            volumeID: { [unowned self] path in
                otherVolumeLock.lock()
                defer { otherVolumeLock.unlock() }
                return otherVolumeMarkers.contains(where: { path.contains($0) }) ? 2 : 1
            },
            now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    var service: OrganizeService { OrganizeService(paths: paths, environment: environment) }

    /// `scanSubpath` "Amazon Drive" unless told otherwise; `nil` tracks the whole drive.
    init(files: [TestFile], folders: [CloudFolder] = testFolders, scanSubpath: String? = "Amazon Drive") throws {
        home = try TempDirectory()
        drive = try TempDirectory()
        paths = AppPaths(dataDirectory: home.url.appendingPathComponent("data", isDirectory: true))
        try paths.ensureDataDirectory()
        config = Config(driveRoot: drive.path, scanSubpath: scanSubpath)
        if let scanSubpath { try drive.url.appendingPathComponent(scanSubpath).withDirectory() }
        try fill(files.map(\.item), folders: folders)
    }

    /// Put items and folders into the catalog (replacing what was there).
    func fill(_ items: [CloudItem], folders: [CloudFolder] = testFolders) throws {
        try store().replaceCloudCatalog { itemSink, folderSink in
            for folder in folders { try folderSink(folder) }
            for item in items { try itemSink(item) }
            return CatalogReadResult(
                sourceDescription: "test", sourceModifiedAt: noonOct16, itemCount: items.count,
                folderCount: folders.count)
        }
    }

    func store() throws -> StateStore { try StateStore(path: paths.stateURL.path) }

    /// Treat every path that contains `marker` as being on another volume.
    func markAsOtherVolume(_ marker: String) {
        otherVolumeLock.lock()
        otherVolumeMarkers.append(marker)
        otherVolumeLock.unlock()
    }

    /// Write a file below the drive root with a fixed modification time.
    @discardableResult
    func put(_ relative: String, _ data: Data, mtime: Int64 = 1_500_000_000) throws -> String {
        let target = drive.url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime))], ofItemAtPath: target.path)
        return target.path
    }

    /// Index the drive, hashing every file.
    @discardableResult
    func scan(hash: Bool = true) throws -> ScanResult {
        try DriveScanner(store: try store(), driveRoot: drive.path, scanSubpath: config.scanSubpath)
            .scan(options: ScanOptions(hash: hash, retry: .immediate(retries: 1)))
    }

    /// Sorted "path size mtime" lines for every file below the drive root.
    func files() throws -> [String] {
        var lines: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: drive.path)
        while let relative = enumerator?.nextObject() as? String {
            let attributes = try FileManager.default.attributesOfItem(atPath: drive.path(relative))
            guard (attributes[.type] as? FileAttributeType) == .typeRegular else { continue }
            let size = (attributes[.size] as? UInt64) ?? 0
            let mtime = Int64((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            lines.append("\(relative) \(size) \(mtime)")
        }
        return lines.sorted()
    }

    /// Sorted relative paths of every folder below the drive root.
    func folders() -> [String] {
        var result: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: drive.path)
        while let relative = enumerator?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: drive.path(relative), isDirectory: &isDirectory), isDirectory.boolValue {
                result.append(relative)
            }
        }
        return result.sorted()
    }

    func contents(_ relative: String) -> Data? { FileManager.default.contents(atPath: drive.path(relative)) }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: drive.path(relative)) }

    /// Paths of every row of the drive index, sorted.
    func indexedPaths() throws -> [String] {
        try store().database.rows("SELECT rel_path FROM drive_files ORDER BY rel_path") { $0.string(0) ?? "" }
    }

    func journal() throws -> [(runId: Int64, from: String, to: String)] {
        try store().database.rows("SELECT run_id, from_path, to_path FROM organize_moves ORDER BY rowid") {
            ($0.int64(0), $0.string(1) ?? "", $0.string(2) ?? "")
        }
    }
}

/// A test file in the fake cloud, with the data it has on the drive.
func cloudFile(
    _ nodeId: String, _ name: String, seed: UInt8, folder: String? = "F-PHONE", takenAt: Int64 = t2019,
    kind: CloudItemKind = .file, parent: String? = nil
) -> TestFile {
    TestFile(nodeId: nodeId, name: name, data: bytes(900, seed: seed), folder: folder, takenAt: takenAt, kind: kind, parent: parent)
}
