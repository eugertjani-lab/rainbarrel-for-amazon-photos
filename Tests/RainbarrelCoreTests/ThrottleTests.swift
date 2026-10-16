import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Throttling: settings, active hours, pacing, rate limit and backoff")
struct ThrottleTests {
    // MARK: Settings

    @Test func defaultsMatchTheDocumentedValues() {
        let throttle = ThrottleConfig()
        #expect(throttle.maxConcurrentDownloads == 2)
        #expect(throttle.maxRequestsPerMinute == 60)
        #expect(throttle.maxBandwidthMBps == 0)
        #expect(throttle.pauseBetweenFilesMs == 0)
        #expect(throttle.activeHours == nil)
        #expect(throttle.dailyLimitGB == 0)
        #expect(throttle.minFreeSpaceGB == 5)
        #expect(throttle.minFreeSpaceBytes == 5_000_000_000)
    }

    @Test func configWithoutThrottleOrWithPartOfItStillLoads() throws {
        let old = Data(#"{"driveRoot": "/Volumes/X", "scanSubpath": "Amazon Drive"}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: old)
        #expect(config.throttle == ThrottleConfig())
        #expect(config.amazonHost == nil)
        #expect(config.effectiveAmazonHost == "www.amazon.com")

        let partial = Data(#"{"amazonHost": "WWW.Amazon.co.uk", "throttle": {"maxConcurrentDownloads": 4, "activeHours": "22:00-06:00"}}"#.utf8)
        let custom = try JSONDecoder().decode(Config.self, from: partial)
        #expect(custom.throttle.maxConcurrentDownloads == 4)
        #expect(custom.throttle.activeHours == "22:00-06:00")
        #expect(custom.throttle.maxRequestsPerMinute == 60)
        #expect(custom.effectiveAmazonHost == "www.amazon.co.uk")
    }

    @Test func throttleSurvivesSavingAndLoading() throws {
        let directory = try TempDirectory()
        let store = ConfigStore(url: directory.url.appendingPathComponent("config.json"))
        var config = Config(driveRoot: "/Volumes/X")
        config.throttle = ThrottleConfig(maxConcurrentDownloads: 3, maxBandwidthMBps: 1.5, activeHours: "01:00-05:30", dailyLimitGB: 20)
        try store.save(config)
        #expect(try store.load() == config)
        let text = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
        #expect(text.contains("\"throttle\""))
        #expect(text.contains("\"activeHours\" : \"01:00-05:30\""))
    }

    @Test func validationNamesTheWrongSetting() {
        func message(_ change: (inout ThrottleConfig) -> Void) -> String? {
            var throttle = ThrottleConfig()
            change(&throttle)
            do { try throttle.validate(); return nil } catch { return "\(error)" }
        }
        #expect(message { _ in } == nil)
        #expect(message { $0.maxConcurrentDownloads = 0 }?.contains("maxConcurrentDownloads") == true)
        #expect(message { $0.maxConcurrentDownloads = 9 }?.contains("between 1 and 8") == true)
        #expect(message { $0.maxRequestsPerMinute = 0 }?.contains("maxRequestsPerMinute") == true)
        #expect(message { $0.maxBandwidthMBps = -1 }?.contains("maxBandwidthMBps") == true)
        #expect(message { $0.maxBandwidthMBps = .nan }?.contains("maxBandwidthMBps") == true)
        #expect(message { $0.pauseBetweenFilesMs = -5 }?.contains("pauseBetweenFilesMs") == true)
        #expect(message { $0.dailyLimitGB = -1 }?.contains("dailyLimitGB") == true)
        #expect(message { $0.minFreeSpaceGB = -1 }?.contains("minFreeSpaceGB") == true)
        #expect(message { $0.activeHours = "late" }?.contains("22:00-06:00") == true)
    }

    @Test func normalizedForcesValuesIntoRange() {
        var throttle = ThrottleConfig(maxConcurrentDownloads: 50, maxRequestsPerMinute: -3, maxBandwidthMBps: -2, pauseBetweenFilesMs: -1, activeHours: "nonsense", dailyLimitGB: .infinity, minFreeSpaceGB: -4)
        throttle = throttle.normalized
        #expect(throttle.maxConcurrentDownloads == 8)
        #expect(throttle.maxRequestsPerMinute == 1)
        #expect(throttle.maxBandwidthMBps == 0)
        #expect(throttle.pauseBetweenFilesMs == 0)
        #expect(throttle.activeHours == nil)
        #expect(throttle.dailyLimitGB == 0)
        #expect(throttle.minFreeSpaceGB == 0)
        #expect(ThrottleConfig(maxBandwidthMBps: 2.5).bytesPerSecondLimit == 2_500_000)
    }

    // MARK: Active hours

    private func date(_ hour: Int, _ minute: Int, second: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: hour, minute: minute, second: second))!
    }

    @Test func parsesWindowsAndRejectsNonsense() throws {
        let window = try ActiveHours.parse("22:00-06:00")
        #expect(window.startMinute == 1320 && window.endMinute == 360)
        #expect(window.description == "22:00-06:00")
        #expect(try ActiveHours.parse(" 9:05 - 17:30 ").description == "09:05-17:30")
        for bad in ["", "22:00", "22-06", "25:00-06:00", "22:60-06:00", "22:00-06:00-07:00", "ab:cd-ef:gh", "07:00-07:00"] {
            #expect(throws: ToolError.self, "\(bad)") { _ = try ActiveHours.parse(bad) }
        }
    }

    @Test func plainWindowContainsItsStartButNotItsEnd() throws {
        let window = try ActiveHours.parse("09:00-17:00")
        #expect(window.contains(date(9, 0), calendar: utcCalendar))
        #expect(window.contains(date(12, 30), calendar: utcCalendar))
        #expect(window.contains(date(16, 59, second: 59), calendar: utcCalendar))
        #expect(!window.contains(date(17, 0), calendar: utcCalendar))
        #expect(!window.contains(date(8, 59), calendar: utcCalendar))
        #expect(!window.contains(date(23, 0), calendar: utcCalendar))
    }

    @Test func windowCrossingMidnightCoversBothSides() throws {
        let window = try ActiveHours.parse("22:00-06:00")
        #expect(window.contains(date(22, 0), calendar: utcCalendar))
        #expect(window.contains(date(23, 59), calendar: utcCalendar))
        #expect(window.contains(date(0, 0), calendar: utcCalendar))
        #expect(window.contains(date(5, 59), calendar: utcCalendar))
        #expect(!window.contains(date(6, 0), calendar: utcCalendar))
        #expect(!window.contains(date(12, 0), calendar: utcCalendar))
        #expect(!window.contains(date(21, 59), calendar: utcCalendar))
    }

    @Test func secondsUntilTheWindowOpens() throws {
        let window = try ActiveHours.parse("22:00-06:00")
        #expect(window.secondsUntilOpen(from: date(12, 0), calendar: utcCalendar) == 10 * 3600)
        #expect(window.secondsUntilOpen(from: date(21, 59, second: 30), calendar: utcCalendar) == 30)
        #expect(window.secondsUntilOpen(from: date(23, 0), calendar: utcCalendar) == 0)
        let morning = try ActiveHours.parse("09:00-17:00")
        // After the window closed, the next opening is tomorrow morning.
        #expect(morning.secondsUntilOpen(from: date(18, 0), calendar: utcCalendar) == 15 * 3600)
    }

    // MARK: Bandwidth pacing

    @Test func pacingHoldsTheAverageSpeedAtTheLimit() {
        // 1 MB/s, chunks of 100 KB arriving instantly one after another: each must wait for its turn.
        let pacer = BandwidthPacer(bytesPerSecond: 1_000_000)
        let start = Date(timeIntervalSince1970: 1_000_000)
        var now = start
        for _ in 0..<50 { now = now.addingTimeInterval(pacer.pause(afterBytes: 100_000, now: now)) }
        #expect(abs(now.timeIntervalSince(start) - 5.0) < 0.01)  // 5 MB at 1 MB/s
    }

    @Test func tinyChunksAreBatchedButTheLimitStillHolds() {
        let pacer = BandwidthPacer(bytesPerSecond: 1_000_000)
        let start = Date(timeIntervalSince1970: 2_000_000)
        var now = start
        var pauses = 0
        for _ in 0..<2000 {
            let pause = pacer.pause(afterBytes: 1_000, now: now)  // 2 MB in 1 KB pieces
            if pause > 0 { pauses += 1 }
            now = now.addingTimeInterval(pause)
        }
        #expect(abs(now.timeIntervalSince(start) - 2.0) < 0.06)
        #expect(pauses < 100)  // not one sleep per chunk
    }

    @Test func idleTimeDoesNotBuildUpCredit() {
        let pacer = BandwidthPacer(bytesPerSecond: 1_000_000)
        let start = Date(timeIntervalSince1970: 3_000_000)
        #expect(pacer.pause(afterBytes: 1_000_000, now: start) == 1.0)
        // Ten idle seconds later the line is free again, but a new 1 MB burst still takes a second.
        #expect(pacer.pause(afterBytes: 1_000_000, now: start.addingTimeInterval(10)) == 1.0)
    }

    @Test func zeroMeansUnlimited() {
        let pacer = BandwidthPacer(bytesPerSecond: 0)
        #expect(!pacer.isLimited)
        #expect(pacer.pause(afterBytes: 50_000_000, now: Date()) == 0)
    }

    @Test func rollingRateAveragesTheLastTenSeconds() {
        let start = Date(timeIntervalSince1970: 4_000_000)
        let rate = RollingRate(startedAt: start)
        for second in 0..<10 { rate.record(bytes: 1_000_000, at: start.addingTimeInterval(Double(second))) }
        #expect(abs(rate.bytesPerSecond(at: start.addingTimeInterval(9.5)) - 1_000_000) < 150_000)
        // Long after the last byte, the rate falls to zero.
        #expect(rate.bytesPerSecond(at: start.addingTimeInterval(60)) == 0)
    }

    // MARK: Request rate

    @Test func rateLimiterPassesABurstThenWaitsOneSecondPerRequestAt60PerMinute() async throws {
        let clock = FakeClock(start: noonOct16)
        let limiter = RateLimiter(requestsPerMinute: 60, clock: clock.clock)
        for _ in 0..<5 { try await limiter.acquire() }  // the burst of five seconds' worth
        #expect(clock.sleeps.isEmpty)
        try await limiter.acquire()
        #expect(clock.sleeps.count == 1)
        #expect(abs(clock.sleeps[0] - 1.0) < 0.001)
        for _ in 0..<5 { try await limiter.acquire() }
        #expect(abs(clock.now.timeIntervalSince(noonOct16) - 6.0) < 0.01)  // 11 requests: 5 free, 6 at one second each
    }

    @Test func slowRatesWaitLonger() async throws {
        let clock = FakeClock(start: noonOct16)
        let limiter = RateLimiter(requestsPerMinute: 6, clock: clock.clock)  // one request every ten seconds, burst of one
        try await limiter.acquire()
        try await limiter.acquire()
        #expect(abs(clock.sleeps.reduce(0, +) - 10) < 0.01)
    }

    // MARK: Backoff

    @Test func backoffDoublesWithFullJitterAndHonoursRetryAfter() async {
        let gate = ThrottleGate(clock: FakeClock(start: noonOct16).clock, random: { 1.0 })
        #expect(await gate.registerThrottle(retryAfter: nil).delay == 5)
        #expect(await gate.registerThrottle(retryAfter: nil).delay == 10)
        #expect(await gate.registerThrottle(retryAfter: nil).delay == 20)
        #expect(await gate.registerThrottle(retryAfter: nil).delay == 40)
        // Full jitter: with a random draw of 0.5 the wait is half of the ceiling.
        let half = ThrottleGate(clock: FakeClock(start: noonOct16).clock, random: { 0.5 })
        #expect(await half.registerThrottle(retryAfter: nil).delay == 2.5)
        // Retry-After wins when it is longer.
        let retry = ThrottleGate(clock: FakeClock(start: noonOct16).clock, random: { 1.0 })
        #expect(await retry.registerThrottle(retryAfter: 120).delay == 120)
        // And is cut down to an hour at most.
        #expect(await retry.registerThrottle(retryAfter: 99_999).delay == 3600)
    }

    @Test func theCeilingStopsAtFiveMinutes() async {
        // Only reachable between long pauses when many answers arrive: the formula itself is capped.
        let ceiling = min(ThrottleGate.maxDelay, ThrottleGate.baseDelay * pow(2, 9))
        #expect(ceiling == 300)
    }

    @Test func fiveThrottlesInARowStartAFifteenMinutePause() async throws {
        let fake = FakeClock(start: noonOct16)
        let gate = ThrottleGate(clock: fake.clock, random: { 1.0 })
        var decisions: [ThrottleGate.Decision] = []
        for _ in 0..<5 { decisions.append(await gate.registerThrottle(retryAfter: nil)) }
        #expect(decisions.map(\.longPause) == [false, false, false, false, true])
        #expect(decisions[4].delay == 900)
        #expect(await gate.longPauses == 1)
        try await gate.waitUntilClear()
        #expect(fake.sleeps.last == 900)
        // The count starts again after the long pause, and a success resets it too.
        #expect(await gate.registerThrottle(retryAfter: nil).delay == 5)
        await gate.registerSuccess()
        #expect(await gate.consecutiveThrottles == 0)
        #expect(await gate.registerThrottle(retryAfter: nil).delay == 5)
    }

    @Test func waitingForABackoffMovesTheClockForward() async throws {
        let fake = FakeClock(start: noonOct16)
        let gate = ThrottleGate(clock: fake.clock, random: { 1.0 })
        _ = await gate.registerThrottle(retryAfter: 30)
        #expect(await gate.blockedUntilDate != nil)
        try await gate.waitUntilClear()
        #expect(abs(fake.now.timeIntervalSince(noonOct16) - 30) < 0.01)
        #expect(await gate.blockedUntilDate == nil)
    }

    @Test func retryAfterAcceptsSecondsAndHTTPDates() {
        let now = noonOct16
        #expect(AmazonClient.parseRetryAfter("120", now: now) == 120)
        #expect(AmazonClient.parseRetryAfter(" 7 ", now: now) == 7)
        #expect(AmazonClient.parseRetryAfter("Fri, 16 Oct 2026 12:01:30 GMT", now: now) == 90)
        #expect(AmazonClient.parseRetryAfter("Fri, 16 Oct 2026 11:00:00 GMT", now: now) == 0)
        #expect(AmazonClient.parseRetryAfter("soon", now: now) == nil)
        #expect(AmazonClient.parseRetryAfter(nil, now: now) == nil)
        #expect(AmazonClient.parseRetryAfter("-5", now: now) == nil)
    }
}
