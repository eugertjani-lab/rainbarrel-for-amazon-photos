import AppKit
import MirrorCore
import SwiftUI

/// The content of the menu-bar popover.
struct PopoverView: View {
    let model: AppModel
    var openSettings: () -> Void = {}
    var quit: () -> Void = { NSApplication.shared.terminate(nil) }

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let report = model.report {
                Header(report: report)
                StatRows(report: report)
                StatusLines(report: report, driveName: model.driveName, lastScan: model.lastScan)
                if !report.years.isEmpty { YearList(years: report.years.reversed()) }
            } else if let error = model.loadError {
                ProblemView(message: error)
            } else {
                Text("Reading the catalog…").foregroundStyle(.secondary)
            }

            if model.report != nil, let error = model.loadError {
                ProblemView(message: error)
            }
            if model.isScanning {
                ScanSection(progress: model.scanProgress)
            } else if let error = model.scanError {
                ProblemView(message: error)
            } else if let scan = model.lastScan, !scan.walkedEverything {
                Text(scan.message).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Buttons(model: model, openSettings: openSettings, quit: quit)
            Text("Amazon sign-in: coming in the downloads milestone")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 360)
    }
}

private struct Header: View {
    let report: SyncReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("In sync")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(DisplayFormat.percent(report.inSyncFraction))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            SplitBar(
                fraction: report.inSyncFraction ?? 0,
                first: .green, second: Color.primary.opacity(0.14), height: 8)
            Text("\(DisplayFormat.number(report.inSync.count)) of \(DisplayFormat.number(report.photosVideos.count)) photos & videos on drive")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().foregroundStyle(tint)
        }
        .font(.system(size: 12))
    }
}

private struct StatRows: View {
    let report: SyncReport

    var body: some View {
        VStack(spacing: 5) {
            StatRow(
                label: "Online only",
                value: "\(DisplayFormat.number(report.onlineOnly.count)) · \(DisplayFormat.bytes(report.onlineOnly.bytes))",
                tint: report.onlineOnly.count > 0 ? .orange : .primary)
            StatRow(
                label: "Live Photo videos",
                value: "\(DisplayFormat.number(report.liveVideosInSync.count)) of \(DisplayFormat.number(report.liveVideos.count)) on drive")
            StatRow(
                label: "Drive only",
                value: report.driveOnly.count == 0
                    ? "0" : "\(DisplayFormat.number(report.driveOnly.count)) · \(DisplayFormat.bytes(report.driveOnly.bytes))")
            StatRow(label: "Not hashed yet", value: DisplayFormat.number(report.driveUnhashedFiles))
            StatRow(
                label: "Files with errors", value: DisplayFormat.number(report.driveFilesWithErrors),
                tint: report.driveFilesWithErrors > 0 ? .red : .primary)
        }
    }
}

private struct StatusLines: View {
    let report: SyncReport
    let driveName: String
    let lastScan: ScanSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive").frame(width: 14)
                Text(driveName)
                Text("·").foregroundStyle(.tertiary)
                Circle().fill(report.driveMounted ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(report.driveMounted ? "Mounted" : "Not mounted")
                    .foregroundStyle(report.driveMounted ? Color.secondary : Color.orange)
            }
            HStack(spacing: 6) {
                Image(systemName: "icloud").frame(width: 14)
                Text("Catalog updated \(DisplayFormat.age(of: report.catalogFreshness))")
            }
            HStack(spacing: 6) {
                Image(systemName: "clock").frame(width: 14)
                Text(report.lastScanAt.map { "Last scan \(DisplayFormat.dateTime($0))" } ?? "Drive not scanned yet")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

private struct YearList: View {
    let years: [YearRow]
    @Environment(\.isSnapshot) private var isSnapshot

    private var rowHeight: CGFloat { 20 }
    private var listHeight: CGFloat { min(CGFloat(years.count), 8) * rowHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By year")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if isSnapshot {
                // ImageRenderer cannot draw an AppKit scroll view, so show the rows that fit.
                rows.frame(height: listHeight, alignment: .top).clipped()
            } else {
                ScrollView { rows }.frame(height: listHeight)
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(years, id: \.year) { row in
                HStack(spacing: 8) {
                    Text(String(row.year))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 36, alignment: .leading)
                    SplitBar(
                        fraction: row.cloudCount == 0 ? 0 : Double(row.inSync) / Double(row.cloudCount),
                        first: .green.opacity(0.85), second: .orange.opacity(0.85), height: 5)
                    Text(row.onlineOnly == 0 ? "–" : DisplayFormat.number(row.onlineOnly))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(row.onlineOnly == 0 ? Color.secondary : Color.orange)
                        .frame(width: 52, alignment: .trailing)
                }
                .frame(height: rowHeight)
            }
        }
    }
}

private struct ScanSection: View {
    let progress: ScanProgress?
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if !isSnapshot { ProgressView().controlSize(.small) }
                Text("Scanning drive").font(.system(size: 12, weight: .medium))
            }
            if let progress {
                Text("\(DisplayFormat.number(progress.filesSeen)) files seen · \(DisplayFormat.number(progress.filesHashed)) hashed · \(DisplayFormat.bytes(progress.bytesHashed))")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                if let path = progress.currentPath {
                    Text(path).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                if progress.errors > 0 {
                    Text("\(progress.errors) errors so far").font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
    }
}

private struct ProblemView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Buttons: View {
    let model: AppModel
    let openSettings: () -> Void
    let quit: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 6) {
            button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                .disabled(model.isRefreshing || model.isScanning)
            if model.isScanning {
                button("Stop", systemImage: "stop.fill") { model.stopScan() }
            } else {
                button("Scan drive", systemImage: "externaldrive.badge.checkmark") { model.startScan() }
                    .disabled(model.isRefreshing || model.report?.driveMounted != true)
            }
            Spacer(minLength: 0)
            button("Settings…", systemImage: nil, action: openSettings)
            button("Quit", systemImage: nil, action: quit)
        }
    }

    @ViewBuilder
    private func button(_ title: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        let label = Group {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .lineLimit(1)
        .fixedSize()
        if isSnapshot {
            Button(action: action) { label }.buttonStyle(FlatButtonStyle())
        } else {
            Button(action: action) { label }.controlSize(.small)
        }
    }
}
