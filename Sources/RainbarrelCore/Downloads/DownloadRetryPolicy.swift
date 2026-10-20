import Foundation

/// When a file that Amazon answers with HTTP 404 is tried again.
///
/// New uploads, the video part of Live Photos in particular, answer 404 until Amazon has processed
/// them, and they download fine a day later. So a 404 is never final at once: the file gets a
/// cool-down (6 hours after the first 404, 24 hours after later ones) and every 404 uses up one of
/// the attempts, which means that with five attempts a file is retried for about four days before
/// it counts as failed for good. A file captured within the last 48 hours is probably still being
/// processed: its 404 uses up no attempt and only waits one hour.
enum DownloadRetryPolicy {
    static let firstCooldown: TimeInterval = 6 * 3600
    static let laterCooldown: TimeInterval = 24 * 3600
    /// A capture date this close to now (before or after) counts as recent.
    static let recentWindow: TimeInterval = 48 * 3600
    static let recentCooldown: TimeInterval = 3600

    struct Decision: Equatable {
        /// The attempt count to store.
        var attempts: Int
        var retryAfter: Date
    }

    /// - Parameters:
    ///   - attempts: how often the file failed before this answer.
    ///   - takenAt: the capture date of the item, in Unix seconds.
    static func afterNotAvailable(attempts: Int, takenAt: Int64, now: Date) -> Decision {
        // A capture date far in the future is a wrong camera clock, not a fresh upload: it gets no
        // free retries, otherwise such a file would be tried every hour for good.
        let age = now.timeIntervalSince1970 - TimeInterval(takenAt)
        if abs(age) < recentWindow {
            return Decision(attempts: attempts, retryAfter: now.addingTimeInterval(recentCooldown))
        }
        let cooldown = attempts == 0 ? firstCooldown : laterCooldown
        return Decision(attempts: attempts + 1, retryAfter: now.addingTimeInterval(cooldown))
    }
}
