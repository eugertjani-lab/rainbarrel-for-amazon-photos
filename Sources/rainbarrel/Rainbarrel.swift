import ArgumentParser
import Foundation
import RainbarrelCore

@main
struct Rainbarrel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rainbarrel",
        abstract: "Compare your Amazon Photos cloud catalog with a backup drive, by MD5.",
        discussion: """
            rainbarrel reads your Amazon Photos catalog, from the desktop app's local index or, when \
            the app is not installed, from Amazon's web API with your signed-in session. It reports which \
            photos and videos are backed up on your drive, which exist only online, and which exist only \
            on the drive. Scanning and reporting never write to the drive. `rainbarrel download` is the one \
            command that does: it adds the missing files, never overwrites or deletes anything, and \
            verifies every file by MD5. `rainbarrel organize` moves files that are already on the drive \
            into the same folder layout, without copying or deleting anything.
            """,
        version: RainbarrelInfo.version,
        subcommands: [
            ConfigCommand.self, CatalogCommand.self, RefreshCatalog.self, ImportHashes.self, Scan.self, Status.self,
            OnlineOnly.self, DriveOnly.self, Download.self, DownloadStatus.self, Organize.self, AuthCommand.self, Mcp.self,
            Sync.self,
        ]
    )

    /// Same flow as ArgumentParser's own `main()`, except that a runtime error thrown while a command runs
    /// is printed with control characters escaped, because messages can contain drive file names.
    /// Everything else goes to `exit(withError:)` untouched.
    static func main() async {
        do {
            var command = try await asyncParseAsRoot(nil)
            do {
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            } catch {
                throw terminalSafe(error)
            }
        } catch {
            Self.exit(withError: error)
        }
    }

    /// Runtime errors become a one-line message with escaped control characters. ArgumentParser's own
    /// errors keep its handling: `--help` is answered by an internal command whose `run()` throws a
    /// `CommandError`, and ExitCode, CleanExit and ValidationError are its public types. The internal
    /// types cannot be named here, so the module name tells them apart.
    private static func terminalSafe(_ error: Error) -> Error {
        if String(reflecting: type(of: error)).hasPrefix("ArgumentParser.") { return error }
        return CLIError(String(describing: error))
    }
}
