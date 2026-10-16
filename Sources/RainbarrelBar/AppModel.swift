import AppKit
import Dispatch
import Foundation
import RainbarrelCore
import Observation

/// Thread-safe flag for stopping a scan from the main actor while it runs on a background thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Lets a background thread forward progress to the main actor at most a few times per second.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldForward(minimumInterval: TimeInterval = 0.25) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= minimumInterval else { return false }
        last = now
        return true
    }
}

/// What the menu-bar label shows.
enum BarState: Equatable {
    case loading
    /// A scan is running. The scanner does not know the total number of files in advance, so there
    /// is no percentage to show.
    case scanning
    /// The drive is not mounted, the catalog cannot be read, or a refresh or scan failed.
    case warning
    case synced
    /// Photos, videos and Live Photo videos that exist only in the cloud.
    case onlineOnly(Int)
}

/// State of the menu-bar app. All database and scan work runs off the main actor.
@MainActor
@Observable
final class AppModel {
    private(set) var report: SyncReport?
    private(set) var loadError: String?
    private(set) var isRefreshing = false
    private(set) var isScanning = false
    private(set) var scanProgress: ScanProgress?
    private(set) var lastScan: ScanSummary?
    private(set) var scanError: String?
    private(set) var config = Config()

    let tools: RainbarrelTools

    @ObservationIgnored private var cancelFlag: CancelFlag?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var volumeObservers: [any NSObjectProtocol] = []

    init(tools: RainbarrelTools = RainbarrelTools()) {
        self.tools = tools
    }

    /// A model with a ready-made report, for rendering snapshots.
    static func preview(tools: RainbarrelTools = RainbarrelTools(), report: SyncReport, config: Config) -> AppModel {
        let model = AppModel(tools: tools)
        model.report = report
        model.config = config
        return model
    }

    // MARK: Derived state

    var barState: BarState {
        if isScanning { return .scanning }
        guard let report else { return loadError != nil ? .warning : .loading }
        if !report.driveMounted || loadError != nil || scanError != nil { return .warning }
        let onlineOnly = report.onlineOnly.count + report.liveVideosOnlineOnly.count
        return onlineOnly == 0 ? .synced : .onlineOnly(onlineOnly)
    }

    /// The volume's own name while it is mounted, otherwise a name taken from the configured path.
    var driveName: String {
        if let name = report?.driveSpace?.volumeName { return name }
        guard let root = report?.driveRoot ?? config.driveRoot, !root.isEmpty else { return "No drive set" }
        return DriveSpace.volumeName(forPath: root)
    }

    // MARK: Lifecycle

    func start() {
        config = (try? tools.loadConfig()) ?? Config()
        Task { await reload(refreshCatalog: nil) }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                await self?.reload(refreshCatalog: nil)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.volumesChanged() }
            }
            volumeObservers.append(observer)
        }
    }

    /// Mount and unmount notifications arrive in bursts; wait a moment, then reload once.
    private func volumesChanged() {
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.reload(refreshCatalog: false)
        }
    }

    // MARK: Loading

    /// Reload the report. `refreshCatalog`: true forces a refresh of the Amazon index, false never
    /// refreshes, nil refreshes only when the last refresh is more than ten minutes old.
    func reload(refreshCatalog: Bool?) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let tools = self.tools
        let outcome: Result<(SyncReport, Config), ToolError> = await Self.offMain {
            do {
                let config = try tools.loadConfig()
                return .success((try tools.syncStatus(refresh: refreshCatalog), config))
            } catch let error as ToolError {
                return .failure(error)
            } catch {
                return .failure(ToolError("\(error)"))
            }
        }
        switch outcome {
        case .success(let (report, config)):
            self.report = report
            self.config = config
            loadError = nil
        case .failure(let error):
            loadError = error.message
            // Keep showing the previous report when one exists; the warning state still shows.
        }
    }

    func refresh() {
        Task { await reload(refreshCatalog: true) }
    }

    func saveConfig(_ newConfig: Config) {
        let tools = self.tools
        Task {
            let result: Result<Void, ToolError> = await Self.offMain {
                do {
                    try tools.saveConfig(newConfig)
                    return .success(())
                } catch {
                    return .failure(ToolError("Could not save the settings: \(error)"))
                }
            }
            if case .failure(let error) = result { loadError = error.message; return }
            config = newConfig
            await reload(refreshCatalog: false)
        }
    }

    // MARK: Scanning

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        scanProgress = nil
        let flag = CancelFlag()
        cancelFlag = flag
        let throttle = ProgressThrottle()
        let tools = self.tools
        scanTask = Task { [weak self] in
            guard let model = self else { return }
            let result: Result<ScanSummary, ToolError> = await Self.offMain {
                do {
                    let summary = try tools.scanDrive(
                        hash: true, limit: nil,
                        progress: { progress in
                            guard throttle.shouldForward() else { return }
                            Task { @MainActor in model.scanProgress = progress }
                        },
                        isCancelled: { flag.isCancelled })
                    return .success(summary)
                } catch let error as ToolError {
                    return .failure(error)
                } catch {
                    return .failure(ToolError("\(error)"))
                }
            }
            switch result {
            case .success(let summary): model.lastScan = summary
            case .failure(let error): model.scanError = error.message
            }
            model.isScanning = false
            model.scanProgress = nil
            model.cancelFlag = nil
            await model.reload(refreshCatalog: false)
        }
    }

    func stopScan() {
        cancelFlag?.cancel()
    }

    // MARK: Helpers

    /// Run blocking work on a background queue and resume on the caller's actor.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}
