import Foundation

/// Selection and wording for the per-year views of the menu-bar app, kept here so they can be tested.
public enum YearMap {
    /// The year grid starts here; earlier years are summarised on one line.
    public static let firstGridYear = 2000

    /// The years with the most photos and videos only in the cloud, largest first (ties: newest first).
    /// Years that are fully on the drive are left out.
    public static func biggestGaps(_ years: [YearRow], limit: Int = 5) -> [YearRow] {
        years.filter { $0.onlineOnly > 0 }
            .sorted { ($0.onlineOnly, $0.year) > ($1.onlineOnly, $1.year) }
            .prefix(limit)
            .map { $0 }
    }

    /// Length of a bar for `value` when `maximum` is the longest one, 0...1.
    public static func relativeLength(_ value: Int, maximum: Int) -> Double {
        maximum <= 0 ? 0 : min(max(Double(value) / Double(maximum), 0), 1)
    }

    /// Years shown as cells in the grid: from `firstGridYear` on, oldest first.
    public static func gridYears(_ years: [YearRow]) -> [YearRow] {
        years.filter { $0.year >= firstGridYear }.sorted { $0.year < $1.year }
    }

    /// One line about the years before the grid, for example "1969 to 1980: 29 of 30 on the drive".
    public static func earlierSummary(_ years: [YearRow]) -> String? {
        let earlier = years.filter { $0.year < firstGridYear }
        guard let first = earlier.map(\.year).min(), let last = earlier.map(\.year).max() else { return nil }
        let total = earlier.reduce(0) { $0 + $1.cloudCount }
        let onDrive = earlier.reduce(0) { $0 + $1.inSync }
        let span = first == last ? "\(first)" : "\(first) to \(last)"
        return "\(span): \(DisplayFormat.number(onDrive)) of \(DisplayFormat.number(total)) on the drive"
    }

    /// Share of the year's photos and videos that are on the drive, 0...1.
    public static func onDriveFraction(_ row: YearRow) -> Double {
        row.cloudCount <= 0 ? 0 : min(max(Double(row.inSync) / Double(row.cloudCount), 0), 1)
    }

    /// Whole percent for speech and labels. Never shows 100 while something is missing or 0 while
    /// something is on the drive.
    public static func onDrivePercent(_ row: YearRow) -> Int {
        let rounded = Int((onDriveFraction(row) * 100).rounded())
        if row.onlineOnly <= 0 { return 100 }
        if row.inSync > 0 { return min(max(rounded, 1), 99) }
        return 0
    }

    /// Chip text for a year cell: "all safe", "871 missing" or "13k missing".
    public static func missingChip(_ row: YearRow) -> String {
        row.onlineOnly <= 0 ? "all safe" : "\(DisplayFormat.compactCount(row.onlineOnly)) missing"
    }

    /// Spoken description of a year cell, for example "2019: 75 percent on drive, 13,369 missing".
    public static func accessibilityLabel(_ row: YearRow) -> String {
        let missing = row.onlineOnly <= 0 ? "none missing" : "\(DisplayFormat.number(row.onlineOnly)) missing"
        return "\(row.year): \(onDrivePercent(row)) percent on drive, \(missing)"
    }
}
