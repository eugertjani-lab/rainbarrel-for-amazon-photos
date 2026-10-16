import ArgumentParser
import Foundation
import RainbarrelCore

@main
struct Rainbarrel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rainbarrel",
        abstract: "Compare your Amazon Photos cloud catalog with a backup drive, by MD5.",
        discussion: """
            Read-only monitoring: rainbarrel reads the Amazon Photos desktop app's local index and \
            reports which photos and videos are backed up on your drive, which exist only online, \
            and which exist only on the drive. It never writes to the drive.
            """,
        version: RainbarrelInfo.version,
        subcommands: [
            ConfigCommand.self, RefreshCatalog.self, ImportHashes.self, Scan.self, Status.self,
            OnlineOnly.self, DriveOnly.self, Mcp.self, Sync.self,
        ]
    )

    /// Same flow as ArgumentParser's own `main()`, except that an error thrown while a command runs
    /// is printed with control characters escaped, because messages can contain drive file names.
    static func main() async {
        var command: ParsableCommand
        do {
            command = try await asyncParseAsRoot(nil)
        } catch {
            exit(withError: error)
        }
        do {
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: terminalSafe(error))
        }
    }

    private static func terminalSafe(_ error: Error) -> Error {
        switch error {
        case is ExitCode, is CleanExit, is ValidationError: return error
        default: return CLIError(String(describing: error))
        }
    }
}
