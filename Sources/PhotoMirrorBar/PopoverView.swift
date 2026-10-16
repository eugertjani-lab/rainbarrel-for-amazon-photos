import AppKit
import MirrorCore
import SwiftUI

/// The content of the menu-bar popover: the overview, or the year map that replaces it in place.
struct PopoverView: View {
    let model: AppModel
    var openSettings: () -> Void = {}
    var quit: () -> Void = { NSApplication.shared.terminate(nil) }

    @State private var showingYears: Bool
    @Environment(\.isSnapshot) private var isSnapshot

    /// The panel never grows taller than this; longer content scrolls.
    static let maxHeight: CGFloat = 680

    init(
        model: AppModel,
        showYears: Bool = false,
        openSettings: @escaping () -> Void = {},
        quit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.model = model
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
                ScrollView { content }
                    .frame(maxHeight: Self.maxHeight)
            }
        }
        .frame(width: 360)
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
            if !report.years.isEmpty {
                GapsSection(years: report.years, showAll: { showingYears = true })
            }
            DriveCard(report: report, name: model.driveName)
            FooterMeta(report: report)
        } else if let error = model.loadError {
            PanelHeader(driveName: model.driveName, mounted: nil)
            ProblemView(message: error)
        } else {
            PanelHeader(driveName: model.driveName, mounted: nil)
            Text("Reading the catalog…").font(.system(size: 12)).foregroundStyle(.secondary)
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

        VStack(spacing: 8) {
            ButtonRow(model: model, openSettings: openSettings, quit: quit)
            Text("Downloads arrive in a later version.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
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
            Text("PhotoMirror").font(.system(size: 15, weight: .semibold))
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
        let fraction = report.inSyncFraction
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

private struct ButtonRow: View {
    let model: AppModel
    let openSettings: () -> Void
    let quit: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        HStack(spacing: 8) {
            if model.isScanning {
                ScanningBlock(progress: model.scanProgress)
                Button { model.stopScan() } label: {
                    Text("Stop").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(PanelButtonStyle(kind: .secondary))
            } else {
                Button { model.startScan() } label: {
                    Text("Scan drive").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(PanelButtonStyle(kind: .primary, accent: palette.buttonFill))
                .disabled(model.isRefreshing || model.report?.driveMounted != true)
            }
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(PanelButtonStyle(kind: .icon))
            .disabled(model.isRefreshing || model.isScanning)
            .accessibilityLabel("Refresh")
            .help("Refresh")
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
                Button("Quit PhotoMirror", action: quit)
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
