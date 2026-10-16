import Foundation

/// Retry schedule for flaky drive access (NTFS over FSKit drops out briefly).
///
/// An operation is attempted once, then retried once per entry in `delays`,
/// sleeping that many seconds before each retry.
public struct RetryPolicy: Sendable {
    public var delays: [TimeInterval]
    public var sleep: @Sendable (TimeInterval) -> Void

    public init(
        delays: [TimeInterval],
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.delays = delays
        self.sleep = sleep
    }

    /// 2, 4, 6, 8 and 10 seconds between attempts, up to 5 retries.
    public static let `default` = RetryPolicy(delays: [2, 4, 6, 8, 10])

    /// No retries and no waiting; for tests.
    public static let none = RetryPolicy(delays: [])

    /// Same number of retries as `delays` but no waiting; for tests.
    public static func immediate(retries: Int) -> RetryPolicy {
        RetryPolicy(delays: Array(repeating: 0, count: retries), sleep: { _ in })
    }

    /// Run `operation`, retrying after each failure according to the schedule.
    /// Throws the last error when every attempt fails.
    public func attempt<T>(_ operation: () throws -> T) throws -> T {
        var retriesUsed = 0
        while true {
            do {
                return try operation()
            } catch {
                guard retriesUsed < delays.count else { throw error }
                sleep(delays[retriesUsed])
                retriesUsed += 1
            }
        }
    }
}
