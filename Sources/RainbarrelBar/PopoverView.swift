import AppKit
import RainbarrelCore
import SwiftUI

/// The content of the menu-bar popover: the overview, or the year map that replaces it in place.
struct PopoverView: View {
    let model: AppModel
    var openSettings: () -> Void = {}
    var quit: () -> Void = { NSApplication.shared.terminate(nil) }
    /// True for the menu-bar panel, whose window does not shrink on its own when the content does.
    var resizesWindow = false

    @State private var showingYears: Bool
    @State private var contentHeight: CGFloat = 0
    @Environment(\.isSnapshot) private var isSnapshot

    /// The panel never grows taller than this; longer content scrolls. It follows the screen, within
    /// 680 and 900 points, so the buttons at the bottom stay in view on most displays.
    static var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(max(screen - 60, 680), 900)
    }

    init(
        model: AppModel,
        showYears: Bool = false,
        resizesWindow: Bool = false,
        openSettings: @escaping () -> Void = {},
        quit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.model = model
        self.resizesWindow = resizesWindow
        self.openSettings = openSettings
        self.quit = quit
        _showingYears = State(initialValue: showYears)
    }

    var body: some View {
        Group {
            if isSnapshot {
                // ImageRenderer cannot draw an AppKit scroll view, so snapshots show the full content.
                content
            } else {
                // A menu-bar window takes the ideal height of its content, and a scroll view has
                // almost none, so the panel opened as a thin strip. The scroll view gets the measured
                // height of the content instead, up to the maximum.
                ScrollView {
                    content.background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                        })
                }
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
                .frame(height: panelHeight)
                .background {
                    // A menu-bar window grows with its content but keeps its old height when the
                    // content shrinks, which left a transparent strip below the panel.
                    if resizesWindow { PanelWindowSizer(contentSize: NSSize(width: 360, height: panelHeight)) }
                }
            }
        }
        .frame(width: 360)
    }

    private var panelHeight: CGFloat { min(max(contentHeight, 1), Self.maxHeight) }

    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showingYears, let report = model.report {
                YearMapView(report: report, back: { showingYears = false })
            } else {
                overview
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .topLeading)
    }

    @ViewBuilder
    private var overview: some View {
        if let report = model.report {
            PanelHeader(driveName: model.driveName, mounted: report.driveMounted)
            RingRow(report: report)
            PrimaryActionArea(model: model)
            // The list is as old as the last report, so it would only mislead while files arrive.
            if !report.years.isEmpty, !model.isDownloadActive {
                GapsSection(years: report.years, showAll: { showingYears = true })
            }
            DriveCard(report: report, name: model.driveName)
            FooterMeta(report: report)
        } else if let error = model.loadError {
            PanelHeader(driveName: model.driveName, mounted: nil)
            ProblemView(message: error)
            PrimaryActionArea(model: model)
        } else {
            PanelHeader(driveName: model.driveName, mounted: nil)
            Text("Reading the catalog…").font(.system(size: 12)).foregroundStyle(.secondary)
            PrimaryActionArea(model: model)
        }

        if model.report != nil, let error = model.loadError {
            ProblemView(message: error)
        }
        if !model.isScanning {
            if let error = model.scanError {
                ProblemView(message: error)
            } else if let scan = model.lastScan, !scan.walkedEverything {
                Text(scan.message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        if let status = model.refreshStatus {
            Text(status)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }

        ButtonRow(model: model, openSettings: openSettings, quit: quit)
    }
}

// MARK: Header and ring

private struct PanelHeader: View {
    let driveName: String
    /// nil hides the status dot (no report yet).
    let mounted: Bool?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityHidden(true)
            Text("Rainbarrel").font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            if let mounted {
                Circle().fill(mounted ? Color.green : Color.orange).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(driveName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RingRow: View {
    let report: SyncReport
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        let fraction = report.inSyncByteFraction
        HStack(alignment: .center, spacing: 20) {
            RingGauge(
                fraction: fraction,
                percentText: fraction == nil ? "–" : DisplayFormat.percent(fraction),
                caption: "in sync",
                accent: palette.onDrive)
            VStack(alignment: .leading, spacing: 14) {
                StatBlock(
                    title: "On your drive",
                    value: "\(DisplayFormat.number(report.inSync.count)) · \(DisplayFormat.bytesShort(report.inSync.bytes))")
                StatBlock(
                    title: "Only in the cloud",
                    value: "\(DisplayFormat.number(report.onlineOnly.count)) · \(DisplayFormat.bytesShort(report.onlineOnly.bytes))",
                    tint: report.onlineOnly.count > 0 ? palette.cloudText : nil)
                StatBlock(
                    title: "Live Photo videos",
                    value: "\(DisplayFormat.number(report.liveVideosInSync.count)) of \(DisplayFormat.number(report.liveVideos.count))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StatBlock: View {
    let title: String
    let value: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(tint ?? Color.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Biggest gaps

private struct GapsSection: View {
    let years: [YearRow]
    let showAll: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        let gaps = YearMap.biggestGaps(years)
        let longest = gaps.first?.onlineOnly ?? 0
        VStack(alignment: .leading, spacing: 6) {
            Text("Biggest gaps")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if gaps.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.onDrive)
                    Text("Every year is on the drive")
                }
                .font(.system(size: 13))
                .frame(height: 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(gaps, id: \.year) { row in
                        GapRow(row: row, longest: longest)
                    }
                }
            }
            Button(action: showAll) {
                HStack(spacing: 3) {
                    Text("All \(years.count) years")
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.onDrive)
                .frame(minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All \(years.count) years")
            .accessibilityHint("Shows every year as a map")
        }
    }
}

private struct GapRow: View {
    let row: YearRow
    let longest: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        HStack(spacing: 10) {
            Text(String(row.year))
                .font(.system(size: 12))
                .monospacedDigit()
                .frame(width: 40, alignment: .leading)
            SplitBar(
                fraction: YearMap.relativeLength(row.onlineOnly, maximum: longest),
                first: palette.cloudFill, second: palette.cloudTrack, height: 6)
            Text(DisplayFormat.number(row.onlineOnly))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.cloudText)
                .frame(width: 56, alignment: .trailing)
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.year): \(DisplayFormat.number(row.onlineOnly)) only in the cloud")
    }
}

// MARK: Drive space card

private struct DriveCard: View {
    let report: SyncReport
    let name: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            if report.driveMounted, let space = report.driveSpace {
                let fit = space.fit(needBytes: report.onlineOnlyDistinctBytes)
                Text("Connected · \(DisplayFormat.bytesShort(space.availableBytes)) free of \(DisplayFormat.bytesShort(space.totalBytes))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                CapacityBar(fit: fit)
                Text(fit.caption)
                    .font(.system(size: 12))
                    .foregroundStyle(fit.fits ? AnyShapeStyle(.secondary) : AnyShapeStyle(palette.cloudText))
                    .fixedSize(horizontal: false, vertical: true)
            } else if report.driveMounted {
                Text("Connected · free space is not available")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("Not connected").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Connect the drive to see free space.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// The whole volume as a 6 pt bar: space in use (blue), what a full mirror still needs (striped
/// orange) and the free space that is left (track).
private struct CapacityBar: View {
    let fit: MirrorFit
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        let segments = fit.segments
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                HStack(spacing: 0) {
                    Rectangle().fill(palette.onDrive).frame(width: width * segments.used)
                    StripedFill(color: palette.cloudFill).frame(width: width * segments.need)
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drive space")
        .accessibilityValue(
            "\(DisplayFormat.bytesShort(fit.usedBytes)) used, \(DisplayFormat.bytesShort(fit.needBytes)) needed for a full mirror, \(DisplayFormat.bytesShort(fit.freeBytes)) free")
    }
}

/// Diagonal stripes on a light tint of the same colour.
private struct StripedFill: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.35)))
            var x = -size.height
            while x < size.width {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(stripe, with: .color(color), lineWidth: 2)
                x += 5
            }
        }
    }
}

// MARK: Footer

private struct FooterMeta: View {
    let report: SyncReport

    private func files(_ count: Int) -> String {
        "\(DisplayFormat.number(count)) file\(count == 1 ? "" : "s")"
    }

    private var checkLine: String? {
        let unchecked = report.driveUnhashedFiles
        let errors = report.driveFilesWithErrors
        if unchecked == 0 && errors == 0 { return nil }
        if unchecked == 0 { return "\(files(errors)) could not be read" }
        let base = "\(files(unchecked)) not checked yet"
        return errors > 0 ? "\(base) (\(DisplayFormat.number(errors)) could not be read)" : base
    }

    var body: some View {
        let catalog = report.catalogFreshness.map { "Catalog updated \(DisplayFormat.age(of: $0))" }
            ?? "Catalog age unknown"
        let scan = report.lastScanAt.map { "Last scan \(DisplayFormat.timeOrDate($0))" } ?? "Drive not scanned yet"
        VStack(alignment: .leading, spacing: 4) {
            Text("\(catalog) · \(scan)")
            if report.driveOnly.count > 0 {
                let count = report.driveOnly.count
                Text("\(files(count)) on the drive \(count == 1 ? "is" : "are") not in the cloud")
            }
            if let checkLine { Text(checkLine) }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Problems and buttons

private struct ProblemView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Icon and title of a panel button, with a spinner in place of the icon while its action runs.
private struct LabeledButtonFace: View {
    let title: String
    let symbol: String
    let running: Bool
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 5) {
            if running && !isSnapshot {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 16, height: 16)
            } else {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium))
            }
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct ButtonRow: View {
    let model: AppModel
    let openSettings: () -> Void
    let quit: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 8) {
            if model.isScanning {
                ScanningBlock(progress: model.scanProgress)
                Button { model.stopScan() } label: {
                    Text("Stop").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(PanelButtonStyle(kind: .secondary))
            } else {
                Button { model.startScan() } label: {
                    LabeledButtonFace(title: "Scan drive", symbol: "externaldrive", running: false)
                }
                .buttonStyle(PanelButtonStyle(kind: .secondaryFill, horizontalPadding: 8))
                .disabled(model.isBusy || model.report?.driveMounted != true)
                .accessibilityLabel("Scan drive")
                .help("Look for new or changed files on the backup drive")
                Button { model.refresh() } label: {
                    LabeledButtonFace(
                        title: model.isRefreshing ? "Refreshing…" : "Refresh Amazon",
                        symbol: "arrow.clockwise.icloud", running: model.isRefreshing)
                }
                .buttonStyle(PanelButtonStyle(kind: .secondaryFill, horizontalPadding: 8))
                .disabled(model.isBusy)
                .accessibilityLabel(model.isRefreshing ? "Refreshing Amazon catalog" : "Refresh Amazon")
                .help("Read the latest list of photos and videos from Amazon Photos")
            }
            moreMenu
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        let icon = Image(systemName: "gearshape").font(.system(size: 16, weight: .medium))
        if isSnapshot {
            // ImageRenderer cannot draw an AppKit-backed Menu, so snapshots draw the button face only.
            Button {} label: { icon }
                .buttonStyle(PanelButtonStyle(kind: .icon))
                .accessibilityLabel("More")
        } else {
            Menu {
                Button("Settings…", action: openSettings)
                Button("Open data folder") { NSWorkspace.shared.open(model.tools.paths.dataDirectory) }
                Divider()
                Button("Quit Rainbarrel", action: quit)
            } label: {
                icon
            }
            .menuStyle(.button)
            .buttonStyle(PanelButtonStyle(kind: .icon))
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
            .help("Settings and more")
        }
    }
}

/// Shown in place of the Scan button while a scan runs. The scanner does not know in advance how
/// many files it will visit, so the bar is indeterminate.
private struct ScanningBlock: View {
    let progress: ScanProgress?
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        let text = progress.map { "Scanning… \(DisplayFormat.number($0.filesSeen)) files" } ?? "Scanning…"
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if isSnapshot {
                Capsule().fill(palette.onDrive.opacity(0.35)).frame(height: 4)
            } else {
                ProgressView().progressViewStyle(.linear).tint(palette.onDrive)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.onDrive.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: Primary action area

/// The one state of the download side of the panel: a sign-in prompt, a note about the drive, the
/// Download button, the progress card, or the paused card.
private struct PrimaryActionArea: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        let action = model.primaryAction
        let notices = [model.downloadNotice, model.accountNotice].compactMap { $0 }
        if case .none = action, notices.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                switch action {
                case .none:
                    EmptyView()
                case .signIn:
                    Button { model.signIn() } label: {
                        Text("Sign in to Amazon").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary, accent: palette.buttonFill))
                    Text("You sign in on Amazon's own page. Rainbarrel never sees your password.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .signInAgain:
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sign-in expired").font(.system(size: 13, weight: .semibold))
                            Text("Amazon needs you to sign in again. Your progress is saved.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Button { model.signIn() } label: {
                        Text("Sign in again").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary, accent: palette.buttonFill))
                case .noDriveSet:
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Choose the backup drive where Rainbarrel keeps your photos and videos.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Button { model.chooseDrive() } label: {
                        Text("Choose Backup Drive…").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary, accent: palette.buttonFill))
                case .driveMissing:
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Connect the backup drive to download.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Button { model.chooseDrive() } label: {
                        Text("Choose Another Drive…").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(PanelButtonStyle(kind: .secondaryFill))
                case .driveReadOnly:
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DownloadError.readOnlyMessage)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Downloads need a drive formatted as APFS or exFAT.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                case .ready(let count, let bytes, let note):
                    if let note { RunNote(text: note) }
                    Button { model.startDownload() } label: {
                        Text("Download \(DisplayFormat.number(count)) missing · \(DisplayFormat.bytesShort(bytes))")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary, accent: palette.buttonFill))
                    .disabled(model.isBusy)
                case .nothingToDownload(let note):
                    if let note { RunNote(text: note) }
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.onDrive)
                            .accessibilityHidden(true)
                        Text("Nothing to download").font(.system(size: 13))
                    }
                    .frame(minHeight: 24)
                    .accessibilityElement(children: .combine)
                case .downloading(let display, let stopping):
                    ProgressCard(
                        display: display, activeHours: model.activeHoursText, mode: .downloading(stopping: stopping),
                        model: model)
                case .paused(let display):
                    ProgressCard(display: display, activeHours: model.activeHoursText, mode: .paused, model: model)
                }
                ForEach(notices, id: \.self) { ProblemView(message: $0) }
            }
        }
    }
}

/// The line about the run that just ended, above the Download button.
private struct RunNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Files and bytes done, speed, time left and the file in flight, with Pause and Stop (or Resume and Stop).
private struct ProgressCard: View {
    enum Mode: Equatable {
        case downloading(stopping: StopRequest?)
        case paused
    }

    let display: DownloadDisplay
    let activeHours: String?
    let mode: Mode
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    private var stopping: StopRequest? {
        if case .downloading(let request) = mode { return request }
        return nil
    }

    private var title: String {
        switch mode {
        case .paused: return "Paused"
        case .downloading(let request):
            switch request {
            case .pause?: return "Pausing…"
            case .stop?, .quit?: return "Stopping…"
            case nil: return "Downloading"
            }
        }
    }

    /// The line under the bytes: why nothing moves, how long it takes, or what is saved.
    private var statusLine: String {
        if mode == .paused { return "Progress is saved. Resume to carry on." }
        if stopping != nil { return "Finishing the files in flight." }
        if display.waitingForHours {
            return activeHours.map { "Waiting for active hours (\($0))" } ?? "Waiting for active hours"
        }
        if let until = display.backoffUntil {
            return "Amazon is limiting requests. Continuing at \(DisplayFormat.timeOrDate(until))."
        }
        if let message = display.message { return message }
        return display.timeLeft ?? "Estimating the time left…"
    }

    private var showsSpeed: Bool {
        mode != .paused && stopping == nil && !display.waitingForHours && display.backoffUntil == nil
    }

    var body: some View {
        let palette = Palette(scheme)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(DisplayFormat.number(display.filesDone)) of \(DisplayFormat.number(display.filesTotal)) files")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            SplitBar(
                fraction: display.fraction, first: palette.onDrive, second: Color.primary.opacity(0.10), height: 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(display.percent) percent")
            HStack(alignment: .firstTextBaseline) {
                Text("\(DisplayFormat.bytesShort(display.bytesDone)) of \(DisplayFormat.bytesShort(display.bytesTotal))")
                Spacer(minLength: 8)
                if showsSpeed { Text(DisplayFormat.speed(bytesPerSecond: display.bytesPerSecond)) }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            Text(statusLine)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let name = display.currentFile, mode != .paused {
                HStack(spacing: 6) {
                    Image(systemName: "photo").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Current file \(name)")
            }
            HStack(spacing: 8) {
                switch mode {
                case .downloading:
                    Button { model.pauseDownload() } label: {
                        Text("Pause").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(PanelButtonStyle(kind: .secondaryFill))
                    .disabled(stopping != nil)
                    Button { model.stopDownload() } label: {
                        Text("Stop").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(PanelButtonStyle(kind: .secondaryFill))
                    .disabled(stopping != nil)
                case .paused:
                    Button { model.resumeDownload() } label: {
                        Text("Resume").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary, accent: palette.buttonFill))
                    .disabled(model.isBusy)
                    Button { model.stopDownload() } label: {
                        Text("Stop").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(PanelButtonStyle(kind: .secondary))
                }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
