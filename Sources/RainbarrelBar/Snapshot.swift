import AppKit
import RainbarrelCore
import SwiftUI

/// `RainbarrelBar --render-snapshot out.png [--dark] [--years] [--state <name>] [--menubar]`: draws
/// the popover (or, with `--years`, the year map) through `ImageRenderer` at 2x and exits. Used to
/// check the layout without clicking.
///
/// Without `--state` it draws the real current report. With `--state` (signed-out, ready,
/// downloading, waiting, paused, read-only, no-drive, drive-missing, expired or finished) it draws fixture data
/// and touches neither the network, the Keychain nor the data folder. `--menubar` draws the
/// menu-bar label of that state instead of the panel.
@MainActor
enum SnapshotRenderer {
    static func run(
        output: String, dark: Bool, years: Bool, state: String?, menuBar: Bool = false, settings: Bool = false
    ) -> Never {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let tools = RainbarrelTools()
        let model: AppModel
        if let state {
            guard let scenario = PanelScenario(rawValue: state) else {
                let names = PanelScenario.allCases.map(\.rawValue).joined(separator: ", ")
                FileHandle.standardError.write(Data("Unknown state \(state). Use one of: \(names)\n".utf8))
                exit(2)
            }
            model = SnapshotFixture.model(for: scenario, tools: tools)
        } else {
            let report: SyncReport
            let config: Config
            do {
                config = try tools.loadConfig()
                report = try tools.currentReport()
            } catch {
                FileHandle.standardError.write(Data("Cannot read the report: \(error)\n".utf8))
                exit(1)
            }
            model = AppModel.preview(tools: tools, report: report, config: config)
        }
        // Dynamic colors must be resolved under the chosen appearance before ImageRenderer draws them.
        var background = Color.gray
        (NSApp.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            background = Color(cgColor: NSColor.windowBackgroundColor.cgColor)
        }
        if settings { renderSettings(model: model, output: output, dark: dark) }
        let renderer: ImageRenderer<AnyView>
        if menuBar {
            let strip = MenuBarLabel(model: model)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.primary.opacity(0.06))
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(background)
            renderer = ImageRenderer(content: AnyView(strip))
            renderer.proposedSize = .unspecified
        } else {
            let content = PopoverView(model: model, showYears: years)
                .environment(\.isSnapshot, true)
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(background)
            renderer = ImageRenderer(content: AnyView(content))
            renderer.proposedSize = ProposedViewSize(width: 360, height: nil)
        }
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("ImageRenderer produced no image\n".utf8))
            exit(1)
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Could not encode the PNG\n".utf8))
            exit(1)
        }
        do {
            let url = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("Could not write \(output): \(error)\n".utf8))
            exit(1)
        }
        print("Wrote \(output) (\(image.width)x\(image.height) px, \(dark ? "dark" : "light")\(years ? ", years" : "")\(state.map { ", state \($0)" } ?? ""))")
        exit(0)
    }
}

extension SnapshotRenderer {
    /// The settings window, drawn from a real (off-screen) view hierarchy, because `ImageRenderer`
    /// cannot draw a grouped form.
    static func renderSettings(model: AppModel, output: String, dark: Bool) -> Never {
        // Taller than the real window (which scrolls), so that every section can be checked in one picture.
        let hosting = NSHostingView(rootView: SettingsView(model: model, height: 1350))
        let size = NSSize(width: 520, height: 1350)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("Could not draw the settings window\n".utf8))
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            let url = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("Could not write \(output): \(error)\n".utf8))
            exit(1)
        }
        print("Wrote \(output) (settings, \(dark ? "dark" : "light"))")
        exit(0)
    }
}

/// Fixture data for the panel states: made-up numbers, a made-up drive, no personal data.
@MainActor
enum SnapshotFixture {
    static func model(for scenario: PanelScenario, tools: RainbarrelTools) -> AppModel {
        var report = makeReport()
        var config = Config(driveRoot: "/Volumes/Backup Drive/Amazon Photos")
        let queue = QueuePreview(count: 5_712, bytes: 39_200_000_000)
        var account = AccountState.signedIn
        var download = DownloadState.idle
        var writable: Bool? = true
        var currentQueue: QueuePreview? = queue

        var running = DownloadDisplay()
        running.filesDone = 1_204
        running.filesTotal = 5_712
        running.bytesDone = 8_300_000_000
        running.bytesTotal = 39_200_000_000
        running.bytesPerSecond = 14_200_000
        running.currentFile = DisplayFormat.displayFileName("IMG_20190728_183045_PORTRAIT_edited_final_version_2.jpg", maxLength: 40)

        switch scenario {
        case .ready:
            break
        case .signedOut:
            account = .signedOut
        case .expired:
            account = .expired
        case .downloading:
            download = .running(running)
        case .waiting:
            config.throttle.activeHours = "01:00-07:00"
            running.bytesPerSecond = 0
            running.currentFile = nil
            running.waitingForHours = true
            download = .running(running)
        case .paused:
            running.bytesPerSecond = 0
            running.currentFile = nil
            download = .paused(running)
        case .readOnly:
            writable = false
        case .noDrive:
            config.driveRoot = nil
            report.driveRoot = nil
            report.driveMounted = false
            report.driveSpace = nil
            writable = nil
        case .driveMissing:
            report.driveMounted = false
            report.driveSpace = nil
            writable = nil
        case .finished:
            download = .finished("Downloaded 5,709 files · 39.2 GB. 3 could not be downloaded.")
            currentQueue = QueuePreview(count: 3, bytes: 12_400_000)
        }
        return AppModel.preview(
            tools: tools, report: report, config: config, account: account, download: download,
            queue: currentQueue, driveWritable: writable)
    }

    /// A report decoded from JSON, because `SyncReport` is built by the core library only.
    private static func makeReport() -> SyncReport {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let cloud = [1800, 2600, 3100, 3400, 3900, 4600, 5200, 5600, 5100, 4700, 4300, 3600, 312]
        let online = [0, 0, 12, 0, 148, 980, 1240, 1610, 410, 380, 132, 90, 110]
        let years: [[String: Any]] = cloud.indices.map { index in
            [
                "year": 2014 + index, "cloudCount": cloud[index], "inSync": cloud[index] - online[index],
                "onlineOnly": online[index], "cloudBytes": cloud[index] * 4_900_000,
            ]
        }
        func counted(_ count: Int, _ bytes: Int) -> [String: Any] { ["count": count, "bytes": bytes] }
        let json: [String: Any] = [
            "generatedAt": iso.string(from: now),
            "photosVideos": counted(48_212, 236_000_000_000),
            "distinctMD5": 47_900,
            "inSync": counted(43_100, 197_600_000_000),
            "onlineOnly": counted(5_112, 38_400_000_000),
            "onlineOnlyDistinctBytes": 39_200_000_000,
            "liveVideos": counted(6_000, 12_000_000_000),
            "liveVideosInSync": counted(5_400, 10_800_000_000),
            "liveVideosOnlineOnly": counted(600, 1_200_000_000),
            "driveOnly": counted(120, 400_000_000),
            "driveHashedFiles": 48_500,
            "driveUnhashedFiles": 0,
            "driveFilesWithErrors": 0,
            "years": years,
            "catalogSource": "web",
            "catalogFreshness": iso.string(from: now.addingTimeInterval(-12 * 60)),
            "catalogRefreshedAt": iso.string(from: now.addingTimeInterval(-12 * 60)),
            "driveRoot": "/Volumes/Backup Drive/Amazon Photos",
            "driveMounted": true,
            "lastScanAt": iso.string(from: now.addingTimeInterval(-3 * 3600)),
            "driveSpace": [
                "volumeName": "Backup Drive", "totalBytes": 2_000_000_000_000, "availableBytes": 1_200_000_000_000,
            ] as [String: Any],
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? JSONSerialization.data(withJSONObject: json),
            let report = try? decoder.decode(SyncReport.self, from: data)
        else {
            FileHandle.standardError.write(Data("The snapshot fixture does not decode\n".utf8))
            exit(1)
        }
        return report
    }
}
