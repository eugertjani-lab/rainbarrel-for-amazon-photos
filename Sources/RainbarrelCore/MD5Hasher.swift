#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Streaming MD5 of a file, read in 8 MB chunks with POSIX calls so failures carry an errno.
public enum MD5Hasher {
    public static let chunkSize = 8 * 1024 * 1024

    /// Hash the file at `path`, opened read-only.
    /// - Parameter onBytes: called after each chunk with the number of bytes just read.
    /// - Returns: lowercase hex digest.
    public static func hexDigest(
        ofFileAtPath path: String,
        onBytes: ((Int) -> Void)? = nil
    ) throws -> String {
        let descriptor = open(path, O_RDONLY)
        if descriptor < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }

        var hasher = Insecure.MD5()
        while true {
            let count = read(descriptor, buffer, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            onBytes?(count)
        }
        return hexString(hasher.finalize())
    }

    /// MD5 of in-memory bytes, as lowercase hex.
    public static func hexDigest(of bytes: [UInt8]) -> String {
        var hasher = Insecure.MD5()
        hasher.update(data: bytes)
        return hexString(hasher.finalize())
    }

    private static func hexString(_ digest: Insecure.MD5.Digest) -> String {
        let hex = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(32)
        for byte in digest {
            output.append(hex[Int(byte >> 4)])
            output.append(hex[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
