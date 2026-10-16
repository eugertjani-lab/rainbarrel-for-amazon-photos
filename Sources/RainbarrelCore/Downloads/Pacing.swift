import Foundation

/// The time source of a download run. Tests replace it so that waiting costs no real time.
public struct DownloadClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = DownloadClock(
        now: { Date() },
        sleep: { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000))
        })
}

/// A token bucket for requests to Amazon: `requestsPerMinute` tokens per minute, with a burst of
/// at most five seconds' worth (at least one token). `acquire()` waits until a token is free.
public actor RateLimiter {
    private let clock: DownloadClock
    private let tokensPerSecond: Double
    private let capacity: Double
    private var tokens: Double
    private var lastRefill: Date

    public init(requestsPerMinute: Int, clock: DownloadClock) {
        self.clock = clock
        tokensPerSecond = Double(max(requestsPerMinute, 1)) / 60
        capacity = max(1, Double(max(requestsPerMinute, 1)) / 12)
        tokens = capacity
        lastRefill = clock.now()
    }

    private func refill() {
        let now = clock.now()
        let elapsed = max(now.timeIntervalSince(lastRefill), 0)
        lastRefill = now
        tokens = min(capacity, tokens + elapsed * tokensPerSecond)
    }

    public func acquire() async throws {
        while true {
            refill()
            if tokens >= 1 {
                tokens -= 1
                return
            }
            try await clock.sleep((1 - tokens) / tokensPerSecond)
        }
    }
}

/// Holds the total download speed at `bytesPerSecond` by telling the receiving code how long to
/// pause after each chunk. One pacer serves all downloads, so the limit covers them together.
public final class BandwidthPacer: @unchecked Sendable {
    private let lock = NSLock()
    private let bytesPerSecond: Double
    private let minimumPause: TimeInterval
    private var nextFree: Date?

    /// - Parameters:
    ///   - bytesPerSecond: the limit; 0 or less turns pacing off.
    ///   - minimumPause: pauses shorter than this are not taken, but remembered, so the average
    ///     speed still matches the limit while tiny sleeps are avoided.
    public init(bytesPerSecond: Double, minimumPause: TimeInterval = 0.05) {
        self.bytesPerSecond = bytesPerSecond
        self.minimumPause = minimumPause
    }

    public var isLimited: Bool { bytesPerSecond > 0 }

    /// How long to wait before reading more, after `bytes` arrived at `now`.
    public func pause(afterBytes bytes: Int, now: Date) -> TimeInterval {
        guard bytesPerSecond > 0, bytes > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let start = max(nextFree ?? now, now)
        let free = start.addingTimeInterval(Double(bytes) / bytesPerSecond)
        nextFree = free
        let pause = free.timeIntervalSince(now)
        return pause > minimumPause ? pause : 0
    }
}

/// Bytes per second over the last ten seconds.
public final class RollingRate: @unchecked Sendable {
    private let lock = NSLock()
    private let window: Int
    private var buckets: [Int: Int64] = [:]
    private let startedAt: Date

    public init(startedAt: Date, windowSeconds: Int = 10) {
        self.startedAt = startedAt
        window = windowSeconds
    }

    public func record(bytes: Int, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        let second = Int(date.timeIntervalSince1970)
        buckets[second, default: 0] += Int64(bytes)
        let oldest = second - window
        if buckets.count > window * 3 { buckets = buckets.filter { $0.key > oldest } }
    }

    public func bytesPerSecond(at date: Date) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let second = Int(date.timeIntervalSince1970)
        let total = buckets.filter { $0.key > second - window && $0.key <= second }.values.reduce(0, +)
        let observed = min(Double(window), max(date.timeIntervalSince(startedAt), 1))
        return Double(total) / observed
    }
}

/// Run-wide backoff when Amazon limits requests or the network fails.
///
/// Every throttle answer lengthens the wait (exponential with full jitter, 5 s up to 300 s, and at
/// least the server's `Retry-After`). After five answers in a row the whole run pauses for
/// 15 minutes. Any success resets the count. All workers wait for `blockedUntil`.
public actor ThrottleGate {
    public struct Decision: Sendable, Equatable {
        public var delay: TimeInterval
        public var until: Date
        /// True when this answer was the fifth in a row and started the long pause.
        public var longPause: Bool
    }

    public static let baseDelay: TimeInterval = 5
    public static let maxDelay: TimeInterval = 300
    public static let longPauseAfter = 5
    public static let longPauseDuration: TimeInterval = 900
    /// A `Retry-After` larger than this is cut down to it.
    public static let maxRetryAfter: TimeInterval = 3600

    private let clock: DownloadClock
    private let random: @Sendable () -> Double
    private var consecutive = 0
    private var blockedUntil: Date?
    public private(set) var longPauses = 0

    public init(clock: DownloadClock, random: @escaping @Sendable () -> Double) {
        self.clock = clock
        self.random = random
    }

    public var blockedUntilDate: Date? {
        guard let blockedUntil, blockedUntil > clock.now() else { return nil }
        return blockedUntil
    }

    public var consecutiveThrottles: Int { consecutive }

    /// Note a throttle answer and compute how long everybody waits.
    public func registerThrottle(retryAfter: TimeInterval?) -> Decision {
        consecutive += 1
        let now = clock.now()
        var delay: TimeInterval
        var longPause = false
        if consecutive >= Self.longPauseAfter {
            delay = Self.longPauseDuration
            longPause = true
            longPauses += 1
            consecutive = 0
        } else {
            let ceiling = min(Self.maxDelay, Self.baseDelay * pow(2, Double(consecutive - 1)))
            delay = min(max(random(), 0), 1) * ceiling
        }
        if let retryAfter { delay = max(delay, min(max(retryAfter, 0), Self.maxRetryAfter)) }
        let until = max(now.addingTimeInterval(delay), blockedUntil ?? now)
        blockedUntil = until
        return Decision(delay: delay, until: until, longPause: longPause)
    }

    public func registerSuccess() {
        consecutive = 0
    }

    /// Wait until no backoff is in force.
    public func waitUntilClear() async throws {
        while let until = blockedUntil {
            let remaining = until.timeIntervalSince(clock.now())
            if remaining <= 0 {
                if blockedUntil == until { blockedUntil = nil }
                return
            }
            try await clock.sleep(remaining)
        }
    }
}
