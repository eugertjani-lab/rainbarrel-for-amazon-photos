import Foundation

/// Plain-text formatting shared by the command line tool and the menu-bar app.
public enum DisplayFormat {
    /// 1234567 -> "1,234,567"
    public static func number(_ value: Int) -> String {
        let digits = String(abs(value))
        var grouped = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return (value < 0 ? "-" : "") + String(grouped.reversed())
    }

    /// Short form for tight spaces: 950 -> "950", 147351 -> "147k", 1250000 -> "1.2M".
    public static func compactCount(_ value: Int) -> String {
        switch value {
        case ..<1000:
            return String(value)
        case ..<10_000:
            let tenths = (value / 100)
            return tenths % 10 == 0 ? "\(tenths / 10)k" : "\(tenths / 10).\(tenths % 10)k"
        case ..<1_000_000:
            return "\(value / 1000)k"
        default:
            let tenths = value / 100_000
            return tenths % 10 == 0 ? "\(tenths / 10)M" : "\(tenths / 10).\(tenths % 10)M"
        }
    }

    /// Decimal units, as drive makers and the Amazon Photos app report them.
    public static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = Double(value)
        var unit = 0
        while abs(amount) >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        if unit == 0 { return "\(value) B" }
        return String(format: "%.2f", amount) + " " + units[unit]
    }

    public static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "n/a" }
        return String(format: "%.1f%%", fraction * 100)
    }

    private static func formatter(_ pattern: String, utc: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        formatter.timeZone = utc ? TimeZone(identifier: "UTC") : .current
        return formatter
    }

    /// Local date and time, for example "2026-10-15 22:04".
    public static func dateTime(_ date: Date?) -> String {
        guard let date else { return "never" }
        return formatter("yyyy-MM-dd HH:mm", utc: false).string(from: date)
    }

    /// Capture date (UTC) from Unix seconds.
    public static func day(unix: Int64) -> String {
        formatter("yyyy-MM-dd", utc: true).string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// "5 min ago" style age.
    public static func age(of date: Date?, now: Date = Date()) -> String {
        guard let date else { return "unknown" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) d ago"
    }

    public static func shortMD5(_ md5: String) -> String { String(md5.prefix(8)) }
}
