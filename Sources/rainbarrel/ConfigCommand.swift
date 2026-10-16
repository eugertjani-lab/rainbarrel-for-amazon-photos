import ArgumentParser
import Foundation
import RainbarrelCore

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change the configuration.",
        subcommands: [Show.self, SetDrive.self, SetIndex.self, SetCatalogSource.self, SetThrottle.self],
        defaultSubcommand: Show.self
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the current configuration.")

        func run() throws {
            let paths = AppPaths.forCLI()
            let config = try ConfigStore(url: paths.configURL).load()
            print("Data directory:   \(paths.dataDirectory.path.sanitizedForTerminal)")
            print("Config file:      \(paths.configURL.path.sanitizedForTerminal)")
            print("State database:   \(paths.stateURL.path.sanitizedForTerminal)")
            print("driveRoot:        \((config.driveRoot ?? "(not set)").sanitizedForTerminal)")
            print("scanSubpath:      \((config.scanSubpath ?? "(not set)").sanitizedForTerminal)")
            if let explicit = config.amazonIndexPath {
                print("amazonIndexPath:  \(explicit.sanitizedForTerminal)")
            } else {
                let detected = (try? AmazonAppIndexSource.resolve(explicitPath: nil))?.indexPath
                print("amazonIndexPath:  (auto-detect)\((detected.map { " -> " + $0 } ?? " -> not found").sanitizedForTerminal)")
            }
            print("catalogSource:    \(config.catalogSource.rawValue)"
                + (config.catalogSource == .auto ? "  (the desktop app index when found, the web API otherwise)" : ""))
            print("amazonHost:       \(config.effectiveAmazonHost.sanitizedForTerminal)"
                + (config.amazonHost == nil ? "  (default)" : ""))
            print("throttle (downloads):")
            for line in config.throttle.summaryLines { print("  " + line) }
        }
    }

    struct SetDrive: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-drive", abstract: "Set the backup drive (mount point or folder).")

        @Argument(help: "Mount point or folder of the backup drive.")
        var path: String

        @Option(name: .customLong("scan-subpath"),
                help: "Folder below the drive root that holds the backup; scans only walk this folder.")
        var scanSubpath: String?

        func run() throws {
            let paths = AppPaths.forCLI()
            let store = ConfigStore(url: paths.configURL)
            var config = try store.load()
            config.driveRoot = absolutePath(path)
            if let scanSubpath { config.scanSubpath = scanSubpath.isEmpty ? nil : scanSubpath }
            try store.save(config)
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: config.driveRoot!, isDirectory: &isDirectory) {
                printError("Note: \(config.driveRoot!) does not exist right now; the setting is saved anyway.")
            }
            print("driveRoot:   \(config.driveRoot!.sanitizedForTerminal)")
            print("scanSubpath: \((config.scanSubpath ?? "(not set)").sanitizedForTerminal)")
        }
    }

    struct SetIndex: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-index",
            abstract: "Use a specific Amazon Photos index file instead of auto-detecting it.")

        @Argument(help: "Path of the amzn1.account.*-cloud.db file.")
        var path: String

        func run() throws {
            let resolved = absolutePath(path)
            guard FileManager.default.fileExists(atPath: resolved) else {
                throw CLIError("File not found: \(resolved)")
            }
            let paths = AppPaths.forCLI()
            let store = ConfigStore(url: paths.configURL)
            var config = try store.load()
            config.amazonIndexPath = resolved
            try store.save(config)
            print("amazonIndexPath: \(resolved.sanitizedForTerminal)")
        }
    }

    struct SetCatalogSource: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-catalog-source",
            abstract: "Choose where the cloud catalog is read from: auto, app or web.",
            discussion: """
                auto uses the Amazon Photos desktop app's index when it is found and Amazon's web API \
                otherwise. app always uses the index, web always uses the web API (it needs a session from \
                `rainbarrel auth import`). Changing the source makes the next web read start from scratch.
                """)

        @Argument(help: "auto, app or web.")
        var source: CatalogSourceChoice

        func run() throws {
            let tools = RainbarrelTools(paths: .forCLI())
            let config = try tools.setCatalogSource(source)
            print("catalogSource: \(config.catalogSource.rawValue)")
        }
    }

    struct SetThrottle: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-throttle",
            abstract: "Set how gently downloads treat Amazon and the drive.",
            discussion: """
                Only the options you give are changed. Defaults: concurrency 2, 60 requests per minute, \
                no bandwidth limit, no pause between files, any time of day, no daily limit, keep 5 GB free.
                """)

        @Option(help: "Files downloaded at the same time (1 to 8).")
        var concurrency: Int?

        @Option(help: "Requests to Amazon per minute, all calls together.")
        var rpm: Int?

        @Option(help: "Download speed limit in megabytes per second, all files together. 0 means unlimited.")
        var mbps: Double?

        @Option(name: .customLong("pause-ms"), help: "Pause after each finished file, in milliseconds.")
        var pauseMs: Int?

        @Option(help: "Local-time window for starting files, for example 22:00-06:00, or `off`.")
        var hours: String?

        @Option(name: .customLong("daily-gb"), help: "Stop after this many gigabytes per day. 0 means unlimited.")
        var dailyGB: Double?

        @Option(name: .customLong("min-free-gb"), help: "Never start a file that would leave less free space than this.")
        var minFreeGB: Double?

        func run() throws {
            let paths = AppPaths.forCLI()
            let store = ConfigStore(url: paths.configURL)
            var config = try store.load()
            var throttle = config.throttle
            if let concurrency { throttle.maxConcurrentDownloads = concurrency }
            if let rpm { throttle.maxRequestsPerMinute = rpm }
            if let mbps { throttle.maxBandwidthMBps = mbps }
            if let pauseMs { throttle.pauseBetweenFilesMs = pauseMs }
            if let hours {
                let trimmed = hours.trimmingCharacters(in: .whitespaces)
                throttle.activeHours = ["off", "none", "any", ""].contains(trimmed.lowercased()) ? nil : trimmed
            }
            if let dailyGB { throttle.dailyLimitGB = dailyGB }
            if let minFreeGB { throttle.minFreeSpaceGB = minFreeGB }
            try throttle.validate()
            if throttle != config.throttle {
                config.throttle = throttle
                try store.save(config)
            }
            for line in throttle.summaryLines { print(line) }
        }
    }
}
