import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// POSIX helpers for the download engine. All of them are blocking; call them off the cooperative pool.
enum FileOps {
    /// Space that unprivileged programs can still use on the volume holding `path`.
    static func availableBytes(atPath path: String) -> Int64? {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return nil }
        let blocks = Int64(clamping: UInt64(info.f_bavail))
        let blockSize = Int64(clamping: UInt64(info.f_frsize))
        let (product, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
        return overflow ? Int64.max : product
    }

    /// True when the volume holding `path` is mounted read-only. Does not write anything.
    static func isMountedReadOnly(path: String) -> Bool {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return false }
        return info.f_flag & 1 != 0  // ST_RDONLY
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Size and modification time (Unix seconds, rounded down) of a regular file; nil when the
    /// path does not exist or is not a regular file.
    static func regularFileInfo(_ path: String) -> (size: Int64, mtime: Int64)? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        #if os(macOS)
        let mtime = Int64(info.st_mtimespec.tv_sec)
        #else
        let mtime = Int64(info.st_mtim.tv_sec)
        #endif
        return (Int64(info.st_size), mtime)
    }

    /// True when anything (file, folder, link) exists at `path`.
    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func errnoMessage(_ code: Int32 = errno) -> String { String(cString: strerror(code)) }

    /// Create `path` and its missing parents.
    static func makeDirectories(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.fileSystem(error.localizedDescription)
        }
    }

    /// Write and remove a probe file in `directory`. Throws `targetNotWritable` when that fails.
    static func probeWritable(directory: String) throws {
        let probe = directory + "/.rainbarrel-write-test"
        let descriptor = open(probe, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            let code = errno
            if code == EROFS || code == EACCES || code == EPERM {
                throw DownloadError.targetNotWritable(path: directory, detail: nil)
            }
            throw DownloadError.targetNotWritable(path: directory, detail: errnoMessage(code))
        }
        var writeFailure: Int32?
        if write(descriptor, "x", 1) != 1 { writeFailure = errno }
        close(descriptor)
        unlink(probe)
        if let writeFailure {
            throw DownloadError.targetNotWritable(
                path: directory, detail: writeFailure == EROFS ? nil : errnoMessage(writeFailure))
        }
    }

    /// Rename `source` to `destination` unless something exists at `destination`. Returns false in
    /// that case. macOS asks the file system to refuse an existing target; where it cannot
    /// (exFAT, Linux), the check and the rename run back to back.
    static func renameWithoutReplacing(_ source: String, to destination: String) throws -> Bool {
        #if os(macOS)
        if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return true }
        let code = errno
        if code == EEXIST { return false }
        if code != ENOTSUP && code != EINVAL && code != ENOSYS {
            throw DownloadError.fileSystem(errnoMessage(code))
        }
        #endif
        if exists(destination) { return false }
        guard rename(source, destination) == 0 else { throw DownloadError.fileSystem(errnoMessage()) }
        return true
    }

    /// Flush a directory entry to disk. Failures are ignored; not every file system supports it.
    static func syncDirectory(_ path: String) {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    /// Delete leftover `.rainbarrel-part` files directly inside `directory`. Returns how many were removed.
    @discardableResult
    static func removeStalePartFiles(inDirectory directory: String) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return 0 }
        var removed = 0
        for name in names where FileNameSanitizer.isPartFile(name) {
            let path = directory + "/" + name
            if regularFileInfo(path) != nil, unlink(path) == 0 { removed += 1 }
        }
        return removed
    }
}

/// An exclusive lock on a file, held until the object goes away (or the process ends). Used to
/// keep two download runs from overlapping.
final class RunLock: @unchecked Sendable {
    private var descriptor: Int32

    /// - Returns: nil when another process holds the lock.
    init?(path: String) throws {
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw DownloadError.fileSystem(FileOps.errnoMessage()) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
