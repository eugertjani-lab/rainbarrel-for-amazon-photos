import ArgumentParser
import Foundation
import RainbarrelCore

/// `rainbarrel auth`: the Amazon session that downloads use. Cookie values are never printed.
struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage the Amazon session that downloads use.",
        discussion: """
            Downloads use Amazon's private web API with your own signed-in session. Sign in to Amazon \
            Photos in a browser, export the cookies of that site (Netscape cookies.txt, for example with \
            a cookie export extension) and import them here. The session is kept in the macOS Keychain, \
            or in a file with permissions 0600 in the data folder on Linux or when \
            RAINBARREL_SESSION_STORE=file is set.
            """,
        subcommands: [Status.self, Import.self, Logout.self],
        defaultSubcommand: Status.self)

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show whether you are signed in and whether the session still works.",
            discussion: "The live check asks Amazon for one known file of your catalog.")

        func run() async throws {
            let paths = AppPaths.forCLI()
            let config = try ConfigStore(url: paths.configURL).load()
            let store = SessionStoreFactory.make(paths: paths)
            let session: StoredSession
            do {
                guard let stored = try store.load() else {
                    print("Not signed in")
                    print("Import your Amazon cookies with `rainbarrel auth import <cookies.txt>`.")
                    return
                }
                session = stored
            } catch {
                throw CLIError("The stored session cannot be used: \(error)")
            }
            print("Signed in to:   \(session.host.sanitizedForTerminal)")
            print("Saved:          \(Format.dateTime(session.savedAt)) (\(Format.age(of: session.savedAt)))")
            print("Cookies:        \(session.cookies.count)")
            print("Stored in:      \(store.location.sanitizedForTerminal)")
            guard session.isUsable() else {
                throw CLIError("The session-id cookie is missing or expired. Sign in again and import fresh cookies.")
            }
            if session.host != config.effectiveAmazonHost {
                throw CLIError(
                    "The session is for \(session.host) but the configured Amazon host is \(config.effectiveAmazonHost).")
            }
            guard let nodeId = try firstNodeId(paths: paths) else {
                print("Live check:     skipped (no catalog yet; run `rainbarrel refresh-catalog`)")
                return
            }
            do {
                let client = try AmazonClient(session: session, host: config.effectiveAmazonHost)
                defer { client.invalidate() }
                _ = try await client.fetchMetadata(nodeId: nodeId)
                print("Live check:     passed")
            } catch DownloadError.sessionExpired {
                print("Live check:     failed")
                throw CLIError(DownloadError.sessionExpired.description)
            } catch {
                print("Live check:     could not be completed")
                throw CLIError("\(error)")
            }
        }

        private func firstNodeId(paths: AppPaths) throws -> String? {
            guard FileManager.default.fileExists(atPath: paths.stateURL.path) else { return nil }
            let store = try StateStore(path: paths.stateURL.path)
            return try store.database.scalarString("SELECT node_id FROM cloud_items WHERE kind = 'file' LIMIT 1")
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Store the cookies of a signed-in browser session.",
            discussion: """
                Accepts a Netscape cookies.txt or the JSON that Rainbarrel stores. Only cookies for the \
                configured Amazon host's domain are kept; all others are ignored. Delete the exported file \
                afterwards, because it contains your session.
                """)

        @Argument(help: "Cookie export file.")
        var file: String

        func run() throws {
            let paths = AppPaths.forCLI()
            let config = try ConfigStore(url: paths.configURL).load()
            let host = config.effectiveAmazonHost
            let url = URL(fileURLWithPath: absolutePath(file))
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes?[.size] as? NSNumber else { throw CLIError("File not found: \(url.path)") }
            guard size.intValue <= 10_000_000 else { throw CLIError("That file is too large for a cookie export.") }
            let data = try Data(contentsOf: url)
            let cookies: [SessionCookie]
            do {
                cookies = try CookieImporter.parse(data, host: host)
            } catch {
                throw CLIError("\(error)")
            }
            guard !cookies.isEmpty else {
                throw CLIError("The file has no unexpired cookies for \(host). Export the cookies while signed in at https://\(host).")
            }
            let session = StoredSession(host: host, cookies: cookies, savedAt: Date())
            guard session.isUsable() else {
                throw CLIError("The file has no valid session-id cookie for \(host). Sign in at https://\(host) and export the cookies again.")
            }
            let store = SessionStoreFactory.make(paths: paths)
            do { try store.save(session) } catch { throw CLIError("The session could not be stored: \(error)") }
            print("Imported \(cookies.count) cookies for \(host.sanitizedForTerminal), stored in \(store.location.sanitizedForTerminal).")
            print("The exported cookie file still holds your session; delete it now.")
            print("Check it with `rainbarrel auth status`.")
        }
    }

    struct Logout: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the stored Amazon session.")

        func run() throws {
            let store = SessionStoreFactory.make(paths: AppPaths.forCLI())
            do {
                let existed = try store.load() != nil
                try store.delete()
                print(existed ? "Signed out. The session was removed from \(store.location)." : "Not signed in.")
            } catch {
                throw CLIError("The session could not be removed: \(error)")
            }
        }
    }
}
