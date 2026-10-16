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
    /// Files are coming in; `percent` is 0...100.
    case downloading(percent: Int)
    /// Amazon no longer accepts the stored sign-in.
    case signInExpired
}

/// State of the menu-bar app. All database, scan and download work runs off the main actor.
@MainActor
@Observable
final class AppModel {
    private(set) var report: SyncReport?
    private(set) var loadError: String?
    private(set) var isRefreshing = false
    /// A line about an explicit catalog refresh ("Reading the catalog… 12,400 items read"), while one runs.
    private(set) var refreshStatus: String?
    private(set) var isScanning = false
    private(set) var scanProgress: ScanProgress?
    private(set) var lastScan: ScanSummary?
    private(set) var scanError: String?
    private(set) var config = Config()

    // Amazon account and downloads
    private(set) var account: AccountState = .unknown
    /// The host the stored session belongs to.
    private(set) var accountHost: String?
    private(set) var queue: QueuePreview?
    /// Whether the backup drive accepts writes; nil when it is not mounted.
    private(set) var driveWritable: Bool?
    private(set) var download: DownloadState = .idle
    /// Set from the moment Pause, Stop or quit cancels the engine until it has stopped.
    private(set) var stopRequest: StopRequest?
    /// A problem that ended or prevented a download, in plain words.
    private(set) var downloadNotice: String?
    /// A problem with signing in or out.
    private(set) var accountNotice: String?

    let tools: RainbarrelTools

    @ObservationIgnored private var cancelFlag: CancelFlag?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var volumeObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored private var lastDisplay = DownloadDisplay()
    /// What earlier segments of a paused and resumed run already did, so the card counts on from there.
    @ObservationIgnored private var carryFiles = 0
    @ObservationIgnored private var carryBytes: Int64 = 0
    @ObservationIgnored private var sessionSavedAt: Date?
    @ObservationIgnored private var rejectedSessionSavedAt: Date?
    @ObservationIgnored private var signInController: SignInWindowController?

    init(tools: RainbarrelTools = RainbarrelTools()) {
        self.tools = tools
    }

    /// A model with a ready-made report, for rendering snapshots. Nothing is read from the
    /// Keychain, the network or the drive.
    static func preview(
        tools: RainbarrelTools = RainbarrelTools(), report: SyncReport, config: Config,
        account: AccountState = .signedIn, download: DownloadState = .idle, queue: QueuePreview? = nil,
        driveWritable: Bool? = true, downloadNotice: String? = nil
    ) -> AppModel {
        let model = AppModel(tools: tools)
        model.report = report
        model.config = config
        model.account = account
        model.accountHost = account == .signedOut ? nil : config.effectiveAmazonHost
        model.download = download
        model.driveWritable = driveWritable
        model.downloadNotice = downloadNotice
        model.queue = queue ?? QueuePreview(
            count: report.onlineOnly.count + report.liveVideosOnlineOnly.count, bytes: report.onlineOnlyDistinctBytes)
        return model
    }

    // MARK: Derived state

    var isDownloadRunning: Bool {
        if case .running = download { return true }
        return false
    }

    /// True while files are being downloaded or a download is paused.
    var isDownloadActive: Bool {
        switch download {
        case .running, .paused: return true
        default: return false
        }
    }

    /// True while a download, scan or refresh uses the catalog and the drive.
    var isBusy: Bool { isRefreshing || isScanning || isDownloadRunning }

    var barState: BarState {
        if case .running(let display) = download { return .downloading(percent: display.percent) }
        if account == .expired { return .signInExpired }
        if isScanning { return .scanning }
        guard let report else { return loadError != nil ? .warning : .loading }
        if !report.driveMounted || loadError != nil || scanError != nil { return .warning }
        let onlineOnly = report.onlineOnly.count + report.liveVideosOnlineOnly.count
        return onlineOnly == 0 ? .synced : .onlineOnly(onlineOnly)
    }

    /// The one state the primary action area of the panel shows.
    var primaryAction: PrimaryAction {
        if case .running(let display) = download { return .downloading(display, stopping: stopRequest) }
        switch account {
        case .unknown: return .none
        case .signedOut: return .signIn
        case .expired: return .signInAgain
        case .signedIn: break
        }
        if case .paused(let display) = download { return .paused(display) }
        guard let report else { return .none }
        if !report.driveMounted { return .driveMissing }
        if driveWritable == false { return .driveReadOnly }
        var note: String?
        if case .finished(let line) = download { note = line }
        guard let queue else { return note.map { .nothingToDownload(note: $0) } ?? .none }
        return queue.count > 0
            ? .ready(count: queue.count, bytes: queue.bytes, note: note)
            : .nothingToDownload(note: note)
    }

    /// The throttle's active hours as "01:00–07:00", or nil when downloads may run at any time.
    var activeHoursText: String? {
        config.throttle.parsedActiveHours.map { "\($0)".replacingOccurrences(of: "-", with: "–") }
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

    /// What one reload brings back from the background.
    private struct Loaded: Sendable {
        var report: SyncReport
        var config: Config
        var queue: QueuePreview?
        var driveWritable: Bool?
    }

    /// Reload the report. `refreshCatalog`: true forces a refresh of the catalog from the configured
    /// source, false never refreshes, nil refreshes only when the last refresh is more than ten
    /// minutes old.
    func reload(refreshCatalog: Bool?) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshStatus = refreshCatalog == true ? "Reading the catalog…" : nil
        defer {
            isRefreshing = false
            refreshStatus = nil
        }
        let tools = self.tools
        let throttle = ProgressThrottle()
        let (outcome, session) = await Self.load(
            tools: tools, refreshCatalog: refreshCatalog, includeQueue: !isDownloadRunning,
            progress: { [weak self] progress in
                guard throttle.shouldForward() else { return }
                Task { @MainActor in self?.showCatalogProgress(progress) }
            })
        switch outcome {
        case .success(let loaded):
            report = loaded.report
            config = loaded.config
            loadError = nil
            applySession(session, config: loaded.config)
            driveWritable = loaded.driveWritable
            if let queue = loaded.queue { self.queue = queue }
        case .failure(let error):
            applySession(session, config: config)
            let problem = Self.catalogProblem(error.message)
            if let state = problem.account { setAccount(state) }
            // Keep showing the previous report when one exists; the sign-in prompt or the warning
            // state still shows.
            loadError = report != nil && problem.account != nil ? nil : problem.text
        }
    }

    private func showCatalogProgress(_ progress: CatalogProgress) {
        guard isRefreshing, refreshStatus != nil else { return }
        let read = DisplayFormat.number(progress.nodes)
        refreshStatus = progress.phase == .changes
            ? "Reading new changes… \(read) items read" : "Reading the catalog… \(read) items read"
    }

    nonisolated private static func load(
        tools: RainbarrelTools, refreshCatalog: Bool?, includeQueue: Bool,
        progress: @escaping @Sendable (CatalogProgress) -> Void
    ) async -> (Result<Loaded, ToolError>, SessionInfo) {
        let session = tools.sessionInfo()
        do {
            let config = try tools.loadConfig()
            if refreshCatalog == true {
                let store = try tools.openStore()
                let service = CatalogRefreshService(
                    paths: tools.paths, sessionStore: tools.sessionStore, environment: tools.downloadEnvironment)
                _ = try await service.refresh(config: config, store: store, progress: progress)
            }
            let report = try await tools.syncStatus(refresh: refreshCatalog == true ? false : refreshCatalog)
            var writable: Bool?
            var queue: QueuePreview?
            if report.driveMounted {
                writable = DownloadEngine.driveLooksWritable(config: config)
                if includeQueue, writable != false {
                    let engine = DownloadEngine(paths: tools.paths, environment: tools.downloadEnvironment)
                    if let plan = try? engine.plan(config: config, options: DownloadOptions()) {
                        queue = QueuePreview(count: plan.count, bytes: plan.reduce(into: Int64(0)) { $0 += $1.size })
                    }
                }
            }
            return (.success(Loaded(report: report, config: config, queue: queue, driveWritable: writable)), session)
        } catch let error as ToolError {
            return (.failure(error), session)
        } catch {
            return (.failure(ToolError("\(error)")), session)
        }
    }

    /// The catalog layer words its sign-in problems for the command line. The panel has a Sign in
    /// button instead, so those messages become plain sentences and set the account state.
    nonisolated static func catalogProblem(_ message: String) -> (text: String, account: AccountState?) {
        if message == DownloadError.sessionExpired.description {
            return ("Your Amazon sign-in expired. Sign in again to read the catalog.", .expired)
        }
        if message == DownloadError.notSignedIn.description {
            return ("Sign in to Amazon to read the catalog from the web.", .signedOut)
        }
        if message.contains("rainbarrel auth import") {
            return (
                "The Amazon Photos app index was not found. Open the app once, or sign in to Amazon to read the catalog from the web.",
                .signedOut)
        }
        return (message, nil)
    }

    func refresh() {
        guard !isBusy else { return }
        Task { await reload(refreshCatalog: true) }
    }

    func saveConfig(_ newConfig: Config) {
        let tools = self.tools
        Task {
            let result: Result<Void, ToolError> = await Self.offMain {
                do {
                    // Switching the catalog source forgets the change-feed checkpoint.
                    if let stored = try? tools.loadConfig(), stored.catalogSource != newConfig.catalogSource {
                        try tools.setCatalogSource(newConfig.catalogSource)
                    }
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

    // MARK: Amazon account

    private func setAccount(_ state: AccountState) {
        account = state
        if state == .expired { rejectedSessionSavedAt = sessionSavedAt }
    }

    private func applySession(_ info: SessionInfo, config: Config) {
        accountHost = info.host
        sessionSavedAt = info.savedAt
        if !info.signedIn {
            account = .signedOut
        } else if !info.usable {
            setAccount(.expired)
        } else if let host = info.host, host != config.effectiveAmazonHost {
            // The session belongs to another Amazon site than the one in the settings.
            account = .signedOut
        } else if info.savedAt != nil, info.savedAt == rejectedSessionSavedAt {
            account = .expired
        } else {
            account = .signedIn
        }
    }

    /// Open the sign-in window.
    func signIn() {
        if let signInController {
            signInController.show()
            return
        }
        accountNotice = nil
        let host = ((try? tools.loadConfig()) ?? config).effectiveAmazonHost
        let controller = SignInWindowController(
            host: host,
            verify: { [weak self] session in try await self?.completeSignIn(session) },
            onClose: { [weak self] in self?.signInController = nil })
        signInController = controller
        controller.show()
    }

    /// Check a fresh sign-in with one call to Amazon, then keep it in the session store.
    fileprivate func completeSignIn(_ session: StoredSession) async throws {
        let client = try AmazonClient(session: session, host: session.host)
        defer { client.invalidate() }
        _ = try await client.verifySession()
        let store = tools.sessionStore
        let saved: Result<Void, any Error> = await Self.offMain {
            do { try store.save(session); return .success(()) } catch { return .failure(error) }
        }
        try saved.get()
        sessionSavedAt = session.savedAt
        rejectedSessionSavedAt = nil
        accountHost = session.host
        account = .signedIn
        accountNotice = nil
        downloadNotice = nil
        let needsCatalog = report == nil || loadError != nil
        Task { await reload(refreshCatalog: needsCatalog ? true : nil) }
    }

    /// Remove the stored session. A running download is stopped first.
    func signOut() {
        if isDownloadRunning {
            requestStop(.stop)
        } else if case .paused = download {
            resetDownload()
        }
        let store = tools.sessionStore
        Task {
            let deleted: Result<Void, any Error> = await Self.offMain {
                do { try store.delete(); return .success(()) } catch { return .failure(error) }
            }
            switch deleted {
            case .success:
                account = .signedOut
                accountHost = nil
                sessionSavedAt = nil
                accountNotice = nil
            case .failure(let error):
                accountNotice = "Could not sign out: \(error)"
            }
        }
    }

    // MARK: Downloading

    func startDownload() {
        guard account == .signedIn, !isBusy else { return }
        if case .paused(let paused) = download {
            carryFiles = paused.filesDone
            carryBytes = paused.bytesDone
        } else {
            carryFiles = 0
            carryBytes = 0
        }
        downloadNotice = nil
        stopRequest = nil
        var starting = DownloadDisplay()
        starting.filesDone = carryFiles
        starting.filesTotal = carryFiles + (queue?.count ?? 0)
        starting.bytesDone = carryBytes
        starting.bytesTotal = carryBytes + (queue?.bytes ?? 0)
        lastDisplay = starting
        download = .running(starting)
        let tools = self.tools
        let throttle = ProgressThrottle()
        let files = carryFiles
        let bytes = carryBytes
        engineTask = Task { [weak self] in
            let result = await Self.runDownload(tools: tools) { progress in
                guard throttle.shouldForward() else { return }
                Task { @MainActor in self?.apply(progress, carryFiles: files, carryBytes: bytes) }
            }
            self?.downloadEnded(result)
        }
    }

    /// Cancel the engine; progress is saved, and Resume continues where it stopped.
    func pauseDownload() { requestStop(.pause) }

    /// Cancel the engine the same way, and go back to the ready state.
    func stopDownload() {
        if case .paused = download {
            resetDownload()
            reloadSoon()
        } else {
            requestStop(.stop)
        }
    }

    func resumeDownload() { startDownload() }

    private func requestStop(_ request: StopRequest) {
        guard isDownloadRunning, stopRequest == nil else { return }
        stopRequest = request
        engineTask?.cancel()
    }

    private func resetDownload() {
        download = .idle
        carryFiles = 0
        carryBytes = 0
        lastDisplay = DownloadDisplay()
    }

    /// Cancel a running download because the app is quitting, and call `completion` once the engine
    /// has stopped (which cleans up its part files) or after ten seconds.
    func stopForQuit(completion: @escaping @MainActor () -> Void) {
        guard let task = engineTask else {
            completion()
            return
        }
        stopRequest = .quit
        task.cancel()
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(10)) }
                await group.next()
                group.cancelAll()
            }
            completion()
        }
    }

    private func apply(_ progress: DownloadProgress, carryFiles: Int, carryBytes: Int64) {
        guard case .running = download else { return }
        let display = DownloadDisplay(progress, carryFiles: carryFiles, carryBytes: carryBytes)
        lastDisplay = display
        download = .running(display)
    }

    nonisolated private static func runDownload(
        tools: RainbarrelTools, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async -> DownloadRunResult {
        do {
            let config = try tools.loadConfig()
            guard config.driveRoot?.isEmpty == false else { return .failed(DownloadError.noDriveConfigured.description) }
            guard let session = try tools.sessionStore.load() else { return .signedOut }
            guard session.isUsable() else { return .sessionExpired }
            let engine = DownloadEngine(paths: tools.paths, environment: tools.downloadEnvironment)
            let summary = try await engine.run(
                config: config, session: session, options: DownloadOptions(), progress: progress)
            return .summary(summary)
        } catch is CancellationError {
            return .cancelled
        } catch let error as DownloadError {
            switch error {
            case .sessionExpired: return .sessionExpired
            case .notSignedIn: return .signedOut
            default: return .failed(error.description)
            }
        } catch {
            return .failed("\(error)")
        }
    }

    private func downloadEnded(_ result: DownloadRunResult) {
        let request = stopRequest
        var paused = lastDisplay
        paused.bytesPerSecond = 0
        paused.currentFile = nil
        paused.waitingForHours = false
        paused.backoffUntil = nil
        paused.message = nil
        engineTask = nil
        stopRequest = nil
        let madeProgress = lastDisplay.filesDone > 0 || lastDisplay.bytesDone > 0

        func cancelled() {
            if request == .stop {
                resetDownload()
            } else {
                download = .paused(paused)
            }
        }

        switch result {
        case .cancelled:
            cancelled()
        case .sessionExpired:
            setAccount(.expired)
            if madeProgress { download = .paused(paused) } else { resetDownload() }
        case .signedOut:
            account = .signedOut
            resetDownload()
        case .failed(let message):
            downloadNotice = message
            resetDownload()
        case .summary(let summary):
            switch summary.stopReason {
            case nil:
                download = .finished(summaryLine(summary))
            case .cancelled?:
                cancelled()
            case .sessionExpired?:
                setAccount(.expired)
                download = .paused(paused)
            case .driveUnavailable?:
                downloadNotice = DownloadError.driveUnavailable.description
                download = .paused(paused)
            case .some:
                download = .finished(summaryLine(summary))
            }
        }
        if request != .quit { reloadSoon() }
    }

    /// Reload once a reload that is already running has finished, so the counts after a download are current.
    private func reloadSoon() {
        Task {
            var waited = 0
            while isRefreshing, waited < 40 {
                try? await Task.sleep(for: .milliseconds(250))
                waited += 1
            }
            await reload(refreshCatalog: false)
        }
    }

    /// "Downloaded 1,204 files · 8.3 GB. 3 could not be downloaded. The daily download limit is reached."
    private func summaryLine(_ summary: DownloadSummary) -> String {
        let files = carryFiles + summary.filesDownloaded + summary.filesAdopted
        let bytes = carryBytes + summary.bytesDownloaded
        var parts: [String] = []
        if files > 0 {
            let noun = files == 1 ? "file" : "files"
            parts.append("Downloaded \(DisplayFormat.number(files)) \(noun) · \(DisplayFormat.bytesShort(bytes)).")
        } else if summary.stopReason == nil {
            parts.append("Nothing was left to download.")
        }
        if summary.filesFailed > 0 {
            parts.append("\(DisplayFormat.number(summary.filesFailed)) could not be downloaded.")
        }
        if let reason = summary.stopReason { parts.append(reason.description) }
        return parts.joined(separator: " ")
    }

    // MARK: Scanning

    func startScan() {
        guard !isScanning, !isDownloadRunning else { return }
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
