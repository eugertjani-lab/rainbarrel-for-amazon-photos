import Foundation

/// How gently downloads treat Amazon and the drive. Stored in `config.json` under `throttle`;
/// every field is optional there and falls back to the default.
public struct ThrottleConfig: Codable, Sendable, Equatable {
    /// The allowed values of `maxConcurrentDownloads`. Every download slot draws on the same request
    /// budget (`maxRequestsPerMinute`, one token bucket), and the budget is spent against Amazon's
    /// unpublished web API. More than 8 parallel files mostly adds request pressure and the risk of
    /// 429 throttling or of Amazon flagging the account, while the drive and the network are already
    /// saturated well before that. 8 keeps a run fast but still gentle.
    public static let concurrencyRange = 1...8

    /// Files downloaded at the same time (1 to 8).
    public var maxConcurrentDownloads: Int
    /// All requests to Amazon together, as a token bucket.
    public var maxRequestsPerMinute: Int
    /// Download speed over all files together, in megabytes per second. 0 means unlimited.
    public var maxBandwidthMBps: Double
    /// Pause after each finished file, per download slot.
    public var pauseBetweenFilesMs: Int
    /// Local-time window "HH:MM-HH:MM" (may cross midnight) in which new files are started; nil means always.
    public var activeHours: String?
    /// Stop starting files after this many gigabytes per local day. 0 means unlimited.
    public var dailyLimitGB: Double
    /// Never start a file that would leave less free space than this.
    public var minFreeSpaceGB: Double

    public init(
        maxConcurrentDownloads: Int = 2, maxRequestsPerMinute: Int = 60, maxBandwidthMBps: Double = 0,
        pauseBetweenFilesMs: Int = 0, activeHours: String? = nil, dailyLimitGB: Double = 0,
        minFreeSpaceGB: Double = 5
    ) {
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.maxRequestsPerMinute = maxRequestsPerMinute
        self.maxBandwidthMBps = maxBandwidthMBps
        self.pauseBetweenFilesMs = pauseBetweenFilesMs
        self.activeHours = activeHours
        self.dailyLimitGB = dailyLimitGB
        self.minFreeSpaceGB = minFreeSpaceGB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThrottleConfig()
        maxConcurrentDownloads = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads)
            ?? defaults.maxConcurrentDownloads
        maxRequestsPerMinute = try container.decodeIfPresent(Int.self, forKey: .maxRequestsPerMinute)
            ?? defaults.maxRequestsPerMinute
        maxBandwidthMBps = try container.decodeIfPresent(Double.self, forKey: .maxBandwidthMBps)
            ?? defaults.maxBandwidthMBps
        pauseBetweenFilesMs = try container.decodeIfPresent(Int.self, forKey: .pauseBetweenFilesMs)
            ?? defaults.pauseBetweenFilesMs
        activeHours = try container.decodeIfPresent(String.self, forKey: .activeHours)
        dailyLimitGB = try container.decodeIfPresent(Double.self, forKey: .dailyLimitGB) ?? defaults.dailyLimitGB
        minFreeSpaceGB = try container.decodeIfPresent(Double.self, forKey: .minFreeSpaceGB)
            ?? defaults.minFreeSpaceGB
    }

    /// Check every field. Used when settings are changed; a hand-edited file with bad values is
    /// handled by `normalized` instead, so a typo never stops the app from starting.
    public func validate() throws {
        guard Self.concurrencyRange.contains(maxConcurrentDownloads) else {
            throw ToolError("maxConcurrentDownloads must be between 1 and 8.")
        }
        guard (1...6000).contains(maxRequestsPerMinute) else {
            throw ToolError("maxRequestsPerMinute must be between 1 and 6000.")
        }
        guard maxBandwidthMBps.isFinite, maxBandwidthMBps >= 0 else {
            throw ToolError("maxBandwidthMBps must be 0 (unlimited) or a positive number.")
        }
        guard pauseBetweenFilesMs >= 0 else { throw ToolError("pauseBetweenFilesMs cannot be negative.") }
        guard dailyLimitGB.isFinite, dailyLimitGB >= 0 else {
            throw ToolError("dailyLimitGB must be 0 (unlimited) or a positive number.")
        }
        guard minFreeSpaceGB.isFinite, minFreeSpaceGB >= 0 else {
            throw ToolError("minFreeSpaceGB cannot be negative.")
        }
        if let activeHours { _ = try ActiveHours.parse(activeHours) }
    }

    /// The same settings with every value forced into its valid range; an unreadable
    /// `activeHours` counts as "always".
    public var normalized: ThrottleConfig {
        func clean(_ value: Double) -> Double { value.isFinite ? max(value, 0) : 0 }
        var copy = self
        copy.maxConcurrentDownloads = min(max(maxConcurrentDownloads, 1), 8)
        copy.maxRequestsPerMinute = min(max(maxRequestsPerMinute, 1), 6000)
        copy.maxBandwidthMBps = clean(maxBandwidthMBps)
        copy.pauseBetweenFilesMs = max(pauseBetweenFilesMs, 0)
        copy.dailyLimitGB = clean(dailyLimitGB)
        copy.minFreeSpaceGB = clean(minFreeSpaceGB)
        if let hours = activeHours, (try? ActiveHours.parse(hours)) == nil { copy.activeHours = nil }
        return copy
    }

    /// The settings as short lines for `config show` and status screens.
    public var summaryLines: [String] {
        func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        }
        let normal = normalized
        return [
            "maxConcurrentDownloads:  \(normal.maxConcurrentDownloads)",
            "maxRequestsPerMinute:    \(normal.maxRequestsPerMinute)",
            "maxBandwidthMBps:        " + (normal.maxBandwidthMBps > 0 ? number(normal.maxBandwidthMBps) : "0 (unlimited)"),
            "pauseBetweenFilesMs:     \(normal.pauseBetweenFilesMs)",
            "activeHours:             " + (normal.activeHours ?? "off (any time)"),
            "dailyLimitGB:            " + (normal.dailyLimitGB > 0 ? number(normal.dailyLimitGB) : "0 (unlimited)"),
            "minFreeSpaceGB:          \(number(normal.minFreeSpaceGB))",
        ]
    }

    public var parsedActiveHours: ActiveHours? { activeHours.flatMap { try? ActiveHours.parse($0) } }

    public var bytesPerSecondLimit: Double { maxBandwidthMBps * 1_000_000 }
    public var dailyLimitBytes: Int64 { Int64(min(dailyLimitGB * 1_000_000_000, 9e18)) }
    public var minFreeSpaceBytes: Int64 { Int64(min(minFreeSpaceGB * 1_000_000_000, 9e18)) }
}

/// A daily time window in local time, written "HH:MM-HH:MM". When the end is earlier than the
/// start the window crosses midnight ("22:00-06:00").
public struct ActiveHours: Sendable, Equatable, CustomStringConvertible {
    public let startMinute: Int
    public let endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public static func parse(_ text: String) throws -> ActiveHours {
        let invalid = ToolError("Active hours must look like 22:00-06:00 (24-hour local time), or `off`.")
        let halves = text.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard halves.count == 2 else { throw invalid }
        func minutes(_ half: Substring) throws -> Int {
            let parts = half.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count <= 2, parts[1].count == 2,
                let hour = Int(parts[0]), let minute = Int(parts[1]),
                (0..<24).contains(hour), (0..<60).contains(minute)
            else { throw invalid }
            return hour * 60 + minute
        }
        let start = try minutes(halves[0])
        let end = try minutes(halves[1])
        guard start != end else { throw ToolError("Active hours must start and end at different times.") }
        return ActiveHours(startMinute: start, endMinute: end)
    }

    public var description: String {
        func text(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
        return text(startMinute) + "-" + text(endMinute)
    }

    private func minuteOfDay(_ date: Date, _ calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// True when `date` (read in the calendar's time zone) lies inside the window.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let minute = minuteOfDay(date, calendar)
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    /// Seconds until the window opens next; 0 when it is open now.
    public func secondsUntilOpen(from date: Date, calendar: Calendar = .current) -> TimeInterval {
        if contains(date, calendar: calendar) { return 0 }
        let components = DateComponents(hour: startMinute / 60, minute: startMinute % 60, second: 0)
        guard let next = calendar.nextDate(
            after: date, matching: components, matchingPolicy: .nextTime)
        else { return 60 }
        return max(next.timeIntervalSince(date), 1)
    }
}
