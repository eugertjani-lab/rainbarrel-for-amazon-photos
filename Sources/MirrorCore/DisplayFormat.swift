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

    /// Decimal units with at most one decimal and no trailing ".0": 1_400_000_000_000 -> "1.4 TB",
    /// 5_000_000_000_000 -> "5 TB", 612_000_000 -> "612 MB".
    public static func bytesShort(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        if abs(value) < 1000 { return "\(value) B" }
        var amount = Double(value)
        var unit = 0
        while abs(amount) >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        // 999.96 rounds to 1000.0, which belongs in the next unit.
        if abs((amount * 10).rounded() / 10) >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        let rounded = (amount * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return text + " " + units[unit]
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

    /// When something happened, short: "22:33" for today, "2026-10-14 22:33" for any other day.
    public static func timeOrDate(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "never" }
        if calendar.isDate(date, inSameDayAs: now) {
            let formatter = formatter("HH:mm", utc: false)
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            return formatter.string(from: date)
        }
        let formatter = formatter("yyyy-MM-dd HH:mm", utc: false)
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
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

extension String {
    /// The text with every control character replaced by a visible escape such as `\u{1B}`, so a
    /// file name taken from the drive or the catalog cannot move the cursor, change colours or
    /// otherwise drive the terminal it is printed to. Covers C0 controls (U+0000 to U+001F),
    /// DEL (U+007F) and C1 controls (U+0080 to U+009F); everything else, including non-ASCII
    /// letters and emoji, passes through unchanged. Use it for plain-text output only: JSON
    /// escapes control characters by itself.
    public var sanitizedForTerminal: String {
        func isControl(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
        guard unicodeScalars.contains(where: isControl) else { return self }
        var result = ""
        for scalar in unicodeScalars {
            if isControl(scalar) {
                let hex = String(scalar.value, radix: 16, uppercase: true)
                result += "\\u{" + (hex.count < 2 ? "0" + hex : hex) + "}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
