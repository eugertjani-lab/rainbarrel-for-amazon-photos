import ArgumentParser
import Foundation
import MirrorCore

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change the configuration.",
        subcommands: [Show.self, SetDrive.self, SetIndex.self],
        defaultSubcommand: Show.self
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the current configuration.")

        func run() throws {
            let paths = AppPaths.default()
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
            let paths = AppPaths.default()
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
            let paths = AppPaths.default()
            let store = ConfigStore(url: paths.configURL)
            var config = try store.load()
            config.amazonIndexPath = resolved
            try store.save(config)
            print("amazonIndexPath: \(resolved.sanitizedForTerminal)")
        }
    }
}
