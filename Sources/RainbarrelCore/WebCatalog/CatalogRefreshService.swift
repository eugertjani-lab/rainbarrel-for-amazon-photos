import Foundation

/// Chooses the catalog source from the configuration and runs the refresh. Shared by the command
/// line tool, the MCP tools and the menu-bar app.
public struct CatalogRefreshService: Sendable {
    public typealias AppSourceProvider = @Sendable (Config) throws -> any CloudCatalogSource

    public let paths: AppPaths
    private let appSource: AppSourceProvider
    private let sessionStore: any SessionStore
    private let environment: DownloadEnvironment

    public init(
        paths: AppPaths,
        appSource: @escaping AppSourceProvider = { config in
            try AmazonAppIndexSource.resolve(explicitPath: config.amazonIndexPath)
        },
        sessionStore: (any SessionStore)? = nil,
        environment: DownloadEnvironment = .live
    ) {
        self.paths = paths
        self.appSource = appSource
        self.sessionStore = sessionStore ?? SessionStoreFactory.make(paths: paths)
        self.environment = environment
    }

    private enum Resolved {
        case app(any CloudCatalogSource)
        case web(WebAPICatalogSource)
    }

    /// Refresh the catalog in `store`.
    /// - Parameters:
    ///   - source: overrides `config.catalogSource` for this refresh.
    ///   - full: read the whole catalog even when the web source could apply the change feed.
    ///   - progress: called while the web source reads; ignored for the app index.
    /// - Throws: `ToolError` with a readable message for every problem the user can act on.
    public func refresh(
        config: Config, store: StateStore, source: CatalogSourceChoice? = nil, full: Bool = false,
        progress: (@Sendable (CatalogProgress) -> Void)? = nil, now: Date = Date()
    ) async throws -> CatalogRefreshOutcome {
        let resolved: Resolved
        do {
            resolved = try resolve(config: config, choice: source ?? config.catalogSource, progress: progress)
        } catch let error as DownloadError {
            throw ToolError(error.description)
        }
        let refresher = CatalogRefresher(store: store, downloadLockPath: paths.downloadLockURL.path)
        switch resolved {
        case .app(let appSource):
            do {
                let result = try refresher.refresh(from: appSource, origin: .app, now: now)
                return CatalogRefreshOutcome(origin: .app, mode: .full, result: result, changed: 0, removed: 0)
            } catch let error as CatalogError {
                throw ToolError("\(error)\(Self.appIndexHint)")
            } catch let error as SQLiteError {
                throw ToolError("The Amazon Photos index could not be read: \(error.message)")
            }
        case .web(let webSource):
            defer { webSource.invalidate() }
            do {
                return try await refresher.refresh(web: webSource, full: full, now: now)
            } catch let error as DownloadError {
                throw ToolError(error.description)
            } catch let error as CatalogError {
                throw ToolError(error.description)
            }
        }
    }

    static let appIndexHint =
        ". Open the Amazon Photos desktop app once, or point Rainbarrel at the index with `rainbarrel config set-index <path>`."

    private func resolve(
        config: Config, choice: CatalogSourceChoice, progress: (@Sendable (CatalogProgress) -> Void)?
    ) throws -> Resolved {
        switch choice {
        case .app:
            return try resolveApp(config)
        case .web:
            return .web(try webSource(config, progress: progress))
        case .auto:
            do {
                return .app(try appSource(config))
            } catch let error as CatalogError {
                // Only a missing index hands over to the web API; a broken one is reported.
                guard case .indexNotFound = error else { throw ToolError("\(error)\(Self.appIndexHint)") }
                do {
                    return .web(try webSource(config, progress: progress))
                } catch DownloadError.notSignedIn {
                    throw ToolError("""
                        \(error). Open the Amazon Photos desktop app once, point Rainbarrel at its index with \
                        `rainbarrel config set-index <path>`, or sign in with `rainbarrel auth import <cookies file>` \
                        to read the catalog through Amazon's web API instead.
                        """)
                } catch let webError as DownloadError {
                    throw ToolError(webError.description)
                }
            }
        }
    }

    /// The app index, with its failures as readable errors.
    private func resolveApp(_ config: Config) throws -> Resolved {
        do {
            return .app(try appSource(config))
        } catch let error as CatalogError {
            throw ToolError("\(error)\(Self.appIndexHint)")
        }
    }

    private func webSource(
        _ config: Config, progress: (@Sendable (CatalogProgress) -> Void)?
    ) throws -> WebAPICatalogSource {
        guard let session = try sessionStore.load() else { throw DownloadError.notSignedIn }
        guard session.isUsable() else { throw DownloadError.sessionExpired }
        return try WebAPICatalogSource.make(session: session, config: config, environment: environment, onProgress: progress)
    }
}
