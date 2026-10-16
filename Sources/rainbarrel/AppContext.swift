import Foundation
import RainbarrelCore

extension AppPaths {
    /// The default paths; says so on stderr when the data directory left over from the old name was moved.
    static func forCLI() -> AppPaths {
        .default(onMigration: { from, to in
            printError("Moved data from \(from.path) to \(to.path)")
        })
    }
}

/// Everything a command needs: where files live, the configuration and the open state database.
struct AppContext {
    let paths: AppPaths
    let configStore: ConfigStore
    var config: Config
    let store: StateStore

    static func open() throws -> AppContext {
        let paths = AppPaths.forCLI()
        try paths.ensureDataDirectory()
        let configStore = ConfigStore(url: paths.configURL)
        return AppContext(
            paths: paths, configStore: configStore, config: try configStore.load(),
            store: try StateStore(path: paths.stateURL.path))
    }

    /// Reconciler limited to the configured scan scope.
    func reconciler() throws -> Reconciler {
        Reconciler(store: store, scope: try DriveScope(scanSubpath: config.scanSubpath))
    }

    /// Refresh the cloud catalog from the configured source: the Amazon Photos app index or the web
    /// API. `source` overrides the configured choice; `full` forces a full read from the web API.
    @discardableResult
    func refreshCatalog(source: CatalogSourceChoice? = nil, full: Bool = false) async throws -> CatalogRefreshOutcome {
        let printer = CatalogProgressPrinter()
        defer { printer.finish() }
        let service = CatalogRefreshService(paths: paths)
        let outcome = try await service.refresh(
            config: config, store: store, source: source, full: full, progress: { printer.update($0) })
        printer.finish()
        for warning in outcome.result.warnings { printError("Warning: \(warning)") }
        return outcome
    }

    /// Refresh when the last refresh is older than ten minutes. A failed refresh is only a
    /// warning when an older catalog is available.
    func refreshCatalogIfStale(quiet: Bool = false) async throws {
        let refresher = CatalogRefresher(store: store)
        guard try refresher.isStale(maxAge: 600) else { return }
        if !quiet { printError("Refreshing the cloud catalog...") }
        do {
            try await refreshCatalog()
        } catch {
            if try store.cloudItemCount() == 0 { throw error }
            printError("Warning: could not refresh the cloud catalog (\(error)). Using the previous copy.")
        }
    }
}

/// Prints how far a long catalog read has got to stderr: one line that is overwritten on a terminal,
/// a line every ten seconds otherwise.
final class CatalogProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPrinted = Date.distantPast
    private var drewLine = false
    private let interactive = isatty(2) != 0

    func update(_ progress: CatalogProgress) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastPrinted) >= (interactive ? 0.5 : 10) else { return }
        lastPrinted = now
        let label: String
        switch progress.phase {
        case .library: label = "Reading the whole library"
        case .changes: label = "Reading changes"
        }
        let text = "  \(label): \(Format.number(progress.nodes)) so far"
        if interactive {
            FileHandle.standardError.write(Data(("\r" + text + "    ").utf8))
            drewLine = true
        } else {
            printError(text)
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if drewLine { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        drewLine = false
    }
}

/// Expand `~` and make the path absolute without resolving symlinks.
func absolutePath(_ path: String) -> String {
    let expanded = PathUtilities.expandingTilde(path)
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardized.path }
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardized.path
}

func printJSON<T: Encodable>(_ value: T) throws {
    let data = try SyncReport.makeEncoder().encode(value)
    print(String(decoding: data, as: UTF8.self))
}
