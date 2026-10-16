import Foundation

/// Capacity of the volume that holds the backup drive folder.
public struct DriveSpace: Codable, Sendable, Equatable {
    /// The volume's own name (for example "Backup Drive"), not the folder that is tracked.
    public var volumeName: String
    public var totalBytes: Int64
    public var availableBytes: Int64

    public init(volumeName: String, totalBytes: Int64, availableBytes: Int64) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    /// Space in use, never negative.
    public var usedBytes: Int64 { max(totalBytes - availableBytes, 0) }

    /// Read the capacity of the volume that contains `path`. Returns nil when the path does not
    /// exist (the drive is not mounted), when the volume reports no capacity, and on platforms
    /// other than macOS, where the volume name and capacity keys are not available.
    public static func read(at path: String) -> DriveSpace? {
        #if os(macOS)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
            let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        // Read-only volumes (NTFS, for example) report 0 or nothing for the "important usage"
        // figure but a correct plain figure, so a non-positive important figure falls through.
        var available: Int64 = 0
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = important
        } else if let plain = values.volumeAvailableCapacity, plain > 0 {
            available = Int64(plain)
        }
        return DriveSpace(
            volumeName: values.volumeName ?? volumeName(forPath: path),
            totalBytes: Int64(total),
            availableBytes: min(available, Int64(total)))
        #else
        return nil
        #endif
    }

    /// A display name derived from the path alone, for when the volume is not mounted:
    /// "/Volumes/Backup Drive/Photos" gives "Backup Drive", any other path gives its last component.
    public static func volumeName(forPath path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" { return parts[1] }
        return parts.last ?? path
    }

    /// How a full mirror (everything that is only in the cloud) compares with the free space.
    public func fit(needBytes: Int64) -> MirrorFit {
        MirrorFit(space: self, needBytes: max(needBytes, 0))
    }
}

/// Whether the space a full mirror still needs fits on the drive, and how to draw and word it.
public struct MirrorFit: Sendable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let freeBytes: Int64
    public let needBytes: Int64

    public init(space: DriveSpace, needBytes: Int64) {
        totalBytes = space.totalBytes
        usedBytes = space.usedBytes
        freeBytes = min(space.availableBytes, space.totalBytes)
        self.needBytes = needBytes
    }

    public var fits: Bool { needBytes <= freeBytes }

    /// Shares of the whole volume for the capacity bar: space in use, space the mirror still needs
    /// (cut off at the free space when it does not fit) and the free space that is left. They add up to 1.
    public var segments: (used: Double, need: Double, free: Double) {
        guard totalBytes > 0 else { return (0, 0, 1) }
        let total = Double(totalBytes)
        let used = min(Double(usedBytes) / total, 1)
        let need = min(Double(min(needBytes, freeBytes)) / total, 1 - used)
        return (used, need, max(1 - used - need, 0))
    }

    public var caption: String {
        if needBytes == 0 { return "The drive already holds a full mirror." }
        let need = DisplayFormat.bytesShort(needBytes)
        if fits { return "A full mirror needs \(need) more. It fits." }
        return "A full mirror needs \(need) more, but only \(DisplayFormat.bytesShort(freeBytes)) is free."
    }
}
