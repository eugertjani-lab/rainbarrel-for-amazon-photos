import ArgumentParser
import Foundation
import RainbarrelCore

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show how the cloud catalog and the backup drive compare.",
        discussion: "Refreshes the cloud catalog first when the last refresh is older than 10 minutes.")

    @Flag(help: "Print the report as JSON.")
    var json = false

    @Flag(name: .customLong("no-refresh"), help: "Do not refresh the cloud catalog first.")
    var noRefresh = false

    func run() throws {
        let context = try AppContext.open()
        if !noRefresh { try context.refreshCatalogIfStale() }
        let report = try context.reconciler().report(driveRoot: context.config.driveRoot)
        if json {
            try printJSON(report)
        } else {
            printSummary(report)
        }
    }

    private func printSummary(_ report: SyncReport) {
        func row(_ label: String, _ value: String) {
            print("  " + label.padding(toLength: 24, withPad: " ", startingAt: 0) + value)
        }
        func countBytes(_ value: CountBytes) -> String {
            "\(Format.number(value.count))  (\(Format.bytes(value.bytes)))"
        }

        print("Rainbarrel status")
        row("Catalog as of:", "\(Format.dateTime(report.catalogFreshness)) (\(Format.age(of: report.catalogFreshness)))")
        row("Catalog refreshed:", Format.dateTime(report.catalogRefreshedAt))
        row("Drive:", ((report.driveRoot ?? "(not configured)") + (report.scanSubpath.map { " / " + $0 } ?? "")).sanitizedForTerminal)
        row("Drive mounted:", report.driveMounted ? "yes" : "no")
        row("Last drive scan:", Format.dateTime(report.lastScanAt))
        print("")
        print("Cloud photos and videos")
        row("Total:", "\(countBytes(report.photosVideos)), \(Format.number(report.distinctMD5)) distinct MD5s")
        row("In sync (on drive):", "\(countBytes(report.inSync))  \(Format.percent(report.inSyncFraction))")
        row("Online only:", countBytes(report.onlineOnly))
        print("")
        print("Live Photo videos (counted separately)")
        row("Total:", countBytes(report.liveVideos))
        row("In sync (on drive):", countBytes(report.liveVideosInSync))
        row("Online only:", countBytes(report.liveVideosOnlineOnly))
        print("")
        print("Drive")
        row("Hashed files:", Format.number(report.driveHashedFiles))
        row("Drive only:", "\(countBytes(report.driveOnly))  (hashed, not in the cloud)")
        row("Not hashed yet:", Format.number(report.driveUnhashedFiles))
        row("With errors:", Format.number(report.driveFilesWithErrors))
        if report.driveHashedFiles == 0 {
            print("")
            print("  No drive hashes yet: run `rainbarrel import-hashes` or `rainbarrel scan` to fill the drive index.")
        }

        if !report.years.isEmpty {
            print("")
            print("By year (photos and videos)")
            print("  " + "Year".padding(toLength: 6, withPad: " ", startingAt: 0)
                + "Cloud".leftPadded(10) + "In sync".leftPadded(10) + "Online only".leftPadded(13) + "Size".leftPadded(13))
            for year in report.years {
                print("  " + String(year.year).padding(toLength: 6, withPad: " ", startingAt: 0)
                    + Format.number(year.cloudCount).leftPadded(10)
                    + Format.number(year.inSync).leftPadded(10)
                    + Format.number(year.onlineOnly).leftPadded(13)
                    + Format.bytes(year.cloudBytes).leftPadded(13))
            }
        }
    }
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

struct OnlineOnly: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "online-only",
        abstract: "List photos and videos that exist in the cloud but not on the drive.",
        discussion: "Live Photo videos are not listed here; `status` reports them separately.")

    @Option(help: "Only items captured in this year (UTC).")
    var year: Int?

    @Option(help: "Maximum number of items to list.")
    var limit: Int = 50

    @Option(help: "Number of items to skip.")
    var offset: Int = 0

    @Flag(help: "Print JSON.")
    var json = false

    func validate() throws {
        if limit < 1 { throw ValidationError("--limit must be at least 1.") }
        if offset < 0 { throw ValidationError("--offset must not be negative.") }
    }

    func run() throws {
        let context = try AppContext.open()
        let page = try context.reconciler().onlineOnlyPage(year: year, limit: limit, offset: offset)
        if json {
            try printJSON(page)
            return
        }
        let scope = year.map { " in \($0)" } ?? ""
        print("Online-only photos and videos\(scope): \(Format.number(page.total)) total")
        if page.items.isEmpty {
            print("  (none in this range)")
            return
        }
        for item in page.items {
            print("  \(Format.day(unix: item.takenAt))  \(Format.bytes(item.size).leftPadded(10))  \(item.name.sanitizedForTerminal)  [\(Format.shortMD5(item.md5))]")
        }
        let shown = offset + page.items.count
        if shown < page.total {
            print("  ... showing \(offset + 1)-\(shown) of \(Format.number(page.total)); use --offset \(shown) for more")
        }
    }
}

struct DriveOnly: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drive-only",
        abstract: "List hashed drive files whose MD5 is not in the cloud catalog.")

    @Option(help: "Maximum number of items to list.")
    var limit: Int = 50

    @Option(help: "Number of items to skip.")
    var offset: Int = 0

    @Flag(help: "Print JSON.")
    var json = false

    func validate() throws {
        if limit < 1 { throw ValidationError("--limit must be at least 1.") }
        if offset < 0 { throw ValidationError("--offset must not be negative.") }
    }

    func run() throws {
        let context = try AppContext.open()
        let page = try context.reconciler().driveOnlyPage(limit: limit, offset: offset)
        if json {
            try printJSON(page)
            return
        }
        print("Drive-only files: \(Format.number(page.total)) total")
        if page.items.isEmpty {
            print("  (none in this range)")
            return
        }
        for item in page.items {
            print("  \(Format.bytes(item.size).leftPadded(10))  \(item.relPath.sanitizedForTerminal)  [\(Format.shortMD5(item.md5))]")
        }
        let shown = offset + page.items.count
        if shown < page.total {
            print("  ... showing \(offset + 1)-\(shown) of \(Format.number(page.total)); use --offset \(shown) for more")
        }
    }
}

struct Sync: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download online-only items to the drive (not implemented yet).")

    func run() throws {
        print("Downloading is not implemented yet (read-only monitoring milestone).")
        throw ExitCode(2)
    }
}
