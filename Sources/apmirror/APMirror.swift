import ArgumentParser
import Foundation
import MirrorCore

@main
struct APMirror: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apmirror",
        abstract: "Compare your Amazon Photos cloud catalog with a backup drive, by MD5.",
        discussion: """
            Read-only monitoring: apmirror reads the Amazon Photos desktop app's local index and \
            reports which photos and videos are backed up on your drive, which exist only online, \
            and which exist only on the drive. It never writes to the drive.
            """,
        version: MirrorInfo.version,
        subcommands: [
            ConfigCommand.self, RefreshCatalog.self, ImportHashes.self, Scan.self, Status.self,
            OnlineOnly.self, DriveOnly.self, Mcp.self, Sync.self,
        ]
    )
}
