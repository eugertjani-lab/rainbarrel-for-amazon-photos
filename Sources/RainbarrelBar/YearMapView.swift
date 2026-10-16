import RainbarrelCore
import SwiftUI

/// Every year as a cell: an orange tint for what is only in the cloud, with a blue fill rising from
/// the bottom to the share that is on the drive. Replaces the overview inside the same panel.
struct YearMapView: View {
    let report: SyncReport
    let back: () -> Void
    @Environment(\.colorScheme) private var scheme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    private var headline: String {
        let count = report.onlineOnly.count
        if report.photosVideos.count == 0 { return "No photos in the catalog yet" }
        if count == 0 { return "Everything is on the drive" }
        return "\(DisplayFormat.number(count)) photo\(count == 1 ? " is" : "s are") only in the cloud"
    }

    var body: some View {
        let palette = Palette(scheme)
        let years = YearMap.gridYears(report.years)
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Text("By year").font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(action: back) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            Text("Overview")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.onDrive)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to overview")
                    Spacer()
                }
            }

            Text(headline)
                .font(.system(size: 20, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                legendItem("On drive", fill: palette.onDrive, border: nil)
                legendItem("Cloud only", fill: palette.cloudCell, border: palette.cloudFill)
            }
            .accessibilityHidden(true)

            if !years.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(years, id: \.year) { row in
                        YearCell(row: row)
                    }
                }
            }
            if let earlier = YearMap.earlierSummary(report.years) {
                Text(earlier).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func legendItem(_ title: String, fill: Color, border: Color?) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(border ?? Color.clear, lineWidth: 1)
                )
                .frame(width: 12, height: 12)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct YearCell: View {
    let row: YearRow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        let fraction = YearMap.onDriveFraction(row)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            palette.cloudCell
            GeometryReader { proxy in
                palette.onDrive
                    .frame(height: proxy.size.height * fraction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 58)
        .clipShape(shape)
        .overlay(alignment: .topLeading) {
            Chip(text: String(row.year), size: 10, weight: .semibold).padding(3)
        }
        .overlay(alignment: .bottomLeading) {
            Chip(text: YearMap.missingChip(row), size: 9, weight: .medium).padding(3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(YearMap.accessibilityLabel(row))
    }
}

/// A small label with its own background, so its text contrasts with whatever colour is below it.
private struct Chip: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        Text(text)
            .font(.system(size: size, weight: weight))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(palette.chipText)
            .padding(.horizontal, 3.5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(palette.chipBackground))
    }
}
