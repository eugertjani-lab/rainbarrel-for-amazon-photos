import AppKit
import RainbarrelCore
import SwiftUI

/// Backup drive, Amazon account, catalog source, download limits and the optional Amazon index override.
struct SettingsView: View {
    let model: AppModel
    /// The window's height; the form scrolls inside it. Snapshots pass a taller one.
    var height: CGFloat = 680

    @State private var driveRoot = ""
    @State private var scanSubpath = ""
    @State private var indexPath = ""
    @State private var catalogSource: CatalogSourceChoice = .auto
    @State private var concurrency = 2
    @State private var requestsPerMinute = "60"
    @State private var bandwidth = "0"
    @State private var pauseMs = "0"
    @State private var limitHours = false
    @State private var hoursFrom = SettingsView.date(minutes: 60)
    @State private var hoursTo = SettingsView.date(minutes: 7 * 60)
    @State private var dailyLimit = "0"
    @State private var minFree = "5"
    /// The throttle as it was loaded, so that a save changes it only when a field was edited.
    @State private var loadedThrottle = ThrottleConfig()
    @State private var problem: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Backup drive") {
                HStack {
                    TextField("Drive folder", text: $driveRoot, prompt: Text("/Volumes/MyBackupDrive"))
                    Button("Choose…") { if let path = chooseFolder(startingAt: driveRoot) { driveRoot = path } }
                }
                TextField("Scan subpath", text: $scanSubpath, prompt: Text("Optional folder on the drive"))
                Text("Scans only walk this folder. Leave it empty to track the whole drive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            accountSection
            Section("Catalog source") {
                Picker("Read the catalog from", selection: $catalogSource) {
                    Text("Automatic").tag(CatalogSourceChoice.auto)
                    Text("Amazon Photos app").tag(CatalogSourceChoice.app)
                    Text("Amazon web").tag(CatalogSourceChoice.web)
                }
                Text(catalogSourceHint).font(.caption).foregroundStyle(.secondary)
            }
            Section("Amazon Photos index") {
                HStack {
                    TextField("Index file", text: $indexPath, prompt: Text("Detected automatically"))
                    Button("Choose…") { if let path = chooseFile() { indexPath = path } }
                }
                Text("Only needed when the automatic detection picks the wrong file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            downloadsSection
            Section("Data") {
                LabeledContent("Folder") {
                    Text(model.tools.paths.dataDirectory.path)
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                Button("Open data folder") {
                    NSWorkspace.shared.open(model.tools.paths.dataDirectory)
                }
            }
            HStack {
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Revert") { load() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: height)
        .onAppear { if !loaded { load() } }
    }

    // MARK: Amazon account

    private var accountSection: some View {
        Section("Amazon account") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol).foregroundStyle(statusColor).accessibilityHidden(true)
                    Text(statusText)
                }
            }
            HStack {
                Button(model.account == .signedIn ? "Sign in again…" : "Sign in…") { model.signIn() }
                if model.account == .signedIn || model.account == .expired {
                    Button("Sign out") { model.signOut() }
                }
            }
            if let notice = model.accountNotice {
                Text(notice).font(.caption).foregroundStyle(.red)
            }
            Text("You sign in on Amazon's own page. Rainbarrel never sees your password. The sign-in is kept in the macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch model.account {
        case .unknown: return "Checking…"
        case .signedOut: return "Not signed in"
        case .signedIn: return model.accountHost.map { "Signed in to \($0)" } ?? "Signed in"
        case .expired: return "Sign-in expired"
        }
    }

    private var statusSymbol: String {
        switch model.account {
        case .signedIn: return "checkmark.circle.fill"
        case .expired: return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch model.account {
        case .signedIn: return .green
        case .expired: return .orange
        default: return .secondary
        }
    }

    private var catalogSourceHint: String {
        switch catalogSource {
        case .auto: return "Uses the Amazon Photos app when it is found, and Amazon's web API otherwise."
        case .app: return "Reads the index file of the Amazon Photos desktop app."
        case .web: return "Reads your library from Amazon with your sign-in. Needs no desktop app."
        }
    }

    // MARK: Downloads

    private var downloadsSection: some View {
        Section("Downloads") {
            LabeledContent("Concurrent downloads") {
                HStack(spacing: 8) {
                    Text("\(concurrency)").monospacedDigit()
                    Stepper("Concurrent downloads", value: $concurrency, in: ThrottleConfig.concurrencyRange)
                        .labelsHidden()
                }
            }
            numberField("Requests per minute", text: $requestsPerMinute, prompt: "60")
            numberField("Speed limit (MB/s)", text: $bandwidth, prompt: "0", hint: "0 means unlimited.")
            numberField("Pause between files (ms)", text: $pauseMs, prompt: "0")
            Toggle("Only start files during set hours", isOn: $limitHours)
            if limitHours {
                DatePicker("From", selection: $hoursFrom, displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: $hoursTo, displayedComponents: .hourAndMinute)
                hintText("Files in flight finish after the window closes. The window may cross midnight.")
            }
            numberField(
                "Daily limit (GB)", text: $dailyLimit, prompt: "0",
                hint: "0 means unlimited. The count restarts at midnight.")
            numberField(
                "Keep this much free (GB)", text: $minFree, prompt: "5",
                hint: "A file is not started when it would leave less space on the drive.")
        }
    }

    private func numberField(_ title: String, text: Binding<String>, prompt: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField(title, text: text, prompt: Text(prompt))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
            }
            if let hint { hintText(hint) }
        }
    }

    private func hintText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Loading and saving

    private func load() {
        let config = (try? model.tools.loadConfig()) ?? model.config
        driveRoot = config.driveRoot ?? ""
        scanSubpath = config.scanSubpath ?? ""
        indexPath = config.amazonIndexPath ?? ""
        catalogSource = config.catalogSource
        var throttle = config.throttle.normalized
        // Compare hours in the form the pickers write, so an untouched window never counts as an edit.
        throttle.activeHours = throttle.parsedActiveHours.map { "\($0)" }
        loadedThrottle = throttle
        concurrency = throttle.maxConcurrentDownloads
        requestsPerMinute = String(throttle.maxRequestsPerMinute)
        bandwidth = Self.numberText(throttle.maxBandwidthMBps)
        pauseMs = String(throttle.pauseBetweenFilesMs)
        dailyLimit = Self.numberText(throttle.dailyLimitGB)
        minFree = Self.numberText(throttle.minFreeSpaceGB)
        if let hours = throttle.parsedActiveHours {
            limitHours = true
            hoursFrom = Self.date(minutes: hours.startMinute)
            hoursTo = Self.date(minutes: hours.endMinute)
        } else {
            limitHours = false
        }
        problem = nil
        loaded = true
    }

    private func save() {
        func clean(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let throttle: ThrottleConfig
        do {
            throttle = try editedThrottle()
        } catch {
            problem = Self.friendly("\(error)")
            return
        }
        problem = nil
        // Start from the stored config so the fields this window does not edit (the Amazon host)
        // survive the save, and the throttle is replaced only when a field was edited.
        var config = (try? model.tools.loadConfig()) ?? model.config
        config.driveRoot = clean(driveRoot)
        config.scanSubpath = clean(scanSubpath)
        config.amazonIndexPath = clean(indexPath)
        config.catalogSource = catalogSource
        if throttle != loadedThrottle {
            config.throttle = throttle
            loadedThrottle = throttle
        }
        model.saveConfig(config)
    }

    /// The throttle the fields describe, checked with the same rules as `config set-throttle`.
    private func editedThrottle() throws -> ThrottleConfig {
        func double(_ text: String, _ name: String) throws -> Double {
            let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if trimmed.isEmpty { return 0 }
            guard let value = Double(trimmed), value.isFinite else {
                throw ToolError("\(name) must be a number.")
            }
            return value
        }
        func integer(_ text: String, _ name: String) throws -> Int {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return 0 }
            guard let value = Int(trimmed) else { throw ToolError("\(name) must be a whole number.") }
            return value
        }
        var throttle = loadedThrottle
        throttle.maxConcurrentDownloads = concurrency
        throttle.maxRequestsPerMinute = try integer(requestsPerMinute, "Requests per minute")
        throttle.maxBandwidthMBps = try double(bandwidth, "The speed limit")
        throttle.pauseBetweenFilesMs = try integer(pauseMs, "The pause between files")
        throttle.dailyLimitGB = try double(dailyLimit, "The daily limit")
        throttle.minFreeSpaceGB = try double(minFree, "The free space")
        throttle.activeHours = limitHours ? Self.hoursText(from: hoursFrom, to: hoursTo) : nil
        try throttle.validate()
        return throttle
    }

    /// The core's messages name the settings by their file names; the window uses its own labels.
    private static func friendly(_ message: String) -> String {
        let names = [
            "maxConcurrentDownloads": "Concurrent downloads",
            "maxRequestsPerMinute": "Requests per minute",
            "maxBandwidthMBps": "The speed limit",
            "pauseBetweenFilesMs": "The pause between files",
            "dailyLimitGB": "The daily limit",
            "minFreeSpaceGB": "The free space",
        ]
        var text = message
        for (key, label) in names { text = text.replacingOccurrences(of: key, with: label) }
        return text
    }

    private static func numberText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Today at `minutes` past midnight, for the time pickers.
    private static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    private static func hoursText(from start: Date, to end: Date) -> String {
        func text(_ date: Date) -> String {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        return text(start) + "-" + text(end)
    }

    private func chooseFolder(startingAt path: String) -> String? {
        FolderPicker.choose(startingAt: path, prompt: "Choose")
    }

    private func chooseFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AmazonAppIndexSource.defaultSupportDirectory()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
