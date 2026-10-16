import Foundation

/// A count of items together with their total size in bytes.
public struct CountBytes: Codable, Sendable, Equatable {
    public var count: Int
    public var bytes: Int64

    public init(count: Int = 0, bytes: Int64 = 0) {
        self.count = count
        self.bytes = bytes
    }
}

/// One row of the per-year table (photos and videos only; Live Photo videos are reported separately).
public struct YearRow: Codable, Sendable, Equatable {
    public var year: Int
    public var cloudCount: Int
    public var inSync: Int
    public var onlineOnly: Int
    public var cloudBytes: Int64
}

/// Result of comparing the cloud catalog with the backup drive, by MD5.
public struct SyncReport: Codable, Sendable, Equatable {
    public var generatedAt: Date

    // Cloud photos and videos
    public var photosVideos: CountBytes
    public var distinctMD5: Int
    /// Cloud items whose MD5 exists among the hashed drive files. One drive copy satisfies
    /// every cloud node with the same MD5.
    public var inSync: CountBytes
    public var onlineOnly: CountBytes

    // Live Photo videos (not part of the photo/video totals)
    public var liveVideos: CountBytes
    public var liveVideosInSync: CountBytes
    public var liveVideosOnlineOnly: CountBytes

    // Drive
    /// Hashed drive files whose MD5 appears in neither cloud table.
    public var driveOnly: CountBytes
    public var driveHashedFiles: Int
    public var driveUnhashedFiles: Int
    public var driveFilesWithErrors: Int

    public var years: [YearRow]

    // Context
    /// When the cloud catalog was last changed by the Amazon Photos app (mtime of the `-wal` file).
    public var catalogFreshness: Date?
    /// When PhotoMirror last copied the catalog into its state database.
    public var catalogRefreshedAt: Date?
    public var driveRoot: String?
    /// Folder below `driveRoot` that is tracked; nil when the whole drive is tracked.
    public var scanSubpath: String?
    public var driveMounted: Bool
    public var lastScanAt: Date?

    /// Share of cloud photos and videos that are backed up, 0...1 (nil when the cloud is empty).
    public var inSyncFraction: Double? {
        photosVideos.count == 0 ? nil : Double(inSync.count) / Double(photosVideos.count)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// A cloud item that has no copy on the drive.
public struct OnlineOnlyItem: Codable, Sendable, Equatable {
    public var nodeId: String
    public var name: String
    public var md5: String
    public var size: Int64
    public var takenAt: Int64
    public var ext: String?
    public var parentId: String?
}

/// A hashed drive file whose MD5 is not in the cloud catalog.
public struct DriveOnlyItem: Codable, Sendable, Equatable {
    public var relPath: String
    public var md5: String
    public var size: Int64
    /// Modification time (Unix seconds); 0 when the row came from a seed import and was not scanned yet.
    public var mtime: Int64
}

/// A page of a listing together with the total number of matches.
public struct Page<Item: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var total: Int
    public var offset: Int
    public var limit: Int
    public var items: [Item]
}

/// JSON text output shared by the command line tool and the MCP tools.
public enum JSONOutput {
    public static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try SyncReport.makeEncoder().encode(value), as: UTF8.self)
    }
}
