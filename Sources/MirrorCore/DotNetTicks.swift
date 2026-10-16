import Foundation

/// Conversion for .NET ticks (100 ns units since 0001-01-01), as stored by the Amazon Photos app.
public enum DotNetTicks {
    /// Ticks at the Unix epoch (1970-01-01T00:00:00Z).
    public static let unixEpochTicks: Int64 = 621_355_968_000_000_000
    public static let ticksPerSecond: Int64 = 10_000_000

    /// Unix seconds for a tick count. Rounds toward negative infinity so dates before 1970 stay exact.
    public static func unixSeconds(fromTicks ticks: Int64) -> Int64 {
        let delta = ticks - unixEpochTicks
        let quotient = delta / ticksPerSecond
        return delta % ticksPerSecond < 0 ? quotient - 1 : quotient
    }

    /// Capture time for a catalog row: `content_date` when positive, otherwise `createdDate`.
    /// Returns 0 (1970-01-01) when neither is usable.
    public static func takenAt(contentDate: Int64?, createdDate: Int64?) -> Int64 {
        if let contentDate, contentDate > 0 { return unixSeconds(fromTicks: contentDate) }
        if let createdDate, createdDate > 0 { return unixSeconds(fromTicks: createdDate) }
        return 0
    }
}
