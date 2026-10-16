import AppKit
import RainbarrelCore
import SwiftUI

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while a view is drawn by `ImageRenderer`, which cannot draw AppKit-backed controls.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

extension Color {
    /// A colour from a 24-bit sRGB hex value such as 0x2F6FE0.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

/// The colours that carry meaning in the panel: blue is what is on the drive, orange is what is
/// only in the cloud. Everything else uses semantic system colours. The palette is chosen from the
/// colour scheme in the environment, which also holds while `ImageRenderer` draws a snapshot.
struct Palette {
    let isDark: Bool

    init(_ scheme: ColorScheme) {
        isDark = scheme == .dark
    }

    /// "On the drive".
    var onDrive: Color { isDark ? Color(hex: 0x5B9BFF) : Color(hex: 0x2F6FE0) }
    /// Fill of the primary button. It stays the light-mode blue in dark mode too, because the
    /// dark-mode blue is too light for a white label (about 2.8:1 against 4.7:1).
    var buttonFill: Color { Color(hex: 0x2F6FE0) }
    /// Orange for text ("only in the cloud"), readable on the panel background.
    var cloudText: Color { isDark ? Color(hex: 0xFFAA55) : Color(hex: 0xB25500) }
    /// Orange for bars and fills.
    var cloudFill: Color { isDark ? Color(hex: 0xFFAA55) : Color(hex: 0xD9822B) }
    /// Track behind an orange bar, and the tint of a year cell.
    var cloudTrack: Color { isDark ? Color(hex: 0xFFAA55).opacity(0.22) : Color(hex: 0xF0C9A3) }
    /// Background of a year cell: the track colour in light mode, a stronger tint in dark mode where
    /// the translucent track would turn muddy brown.
    var cloudCell: Color { isDark ? Color(hex: 0xFFAA55).opacity(0.34) : Color(hex: 0xF0C9A3) }
    /// Small label drawn on top of a coloured cell, so its text contrasts with any fill below it.
    var chipBackground: Color { isDark ? Color(white: 0.08).opacity(0.85) : Color.white.opacity(0.9) }
    var chipText: Color { isDark ? Color.white : Color(white: 0.1) }
}

/// Buttons drawn entirely in SwiftUI (so snapshots can draw them): a full-width primary button, a
/// secondary one that fits its label, a secondary one that shares the row's width, and a square icon
/// button. All are at least 44 pt high.
struct PanelButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, secondaryFill, icon }

    let kind: Kind
    var accent: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, kind: kind, accent: accent)
    }
}

private struct PanelButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: PanelButtonStyle.Kind
    let accent: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            switch kind {
            case .primary:
                configuration.label
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(shape.fill(accent))
            case .secondary:
                configuration.label
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(shape.fill(Color.primary.opacity(0.09)))
            case .secondaryFill:
                configuration.label
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(shape.fill(Color.primary.opacity(0.09)))
            case .icon:
                configuration.label
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .background(shape.fill(Color.primary.opacity(0.09)))
            }
        }
        .contentShape(shape)
        .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

/// A thin horizontal bar made of two segments, drawn with shapes only.
struct SplitBar: View {
    var fraction: Double  // share of the first segment, 0...1
    var first: Color
    var second: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let split = width * CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(second)
                Capsule().fill(first).frame(width: max(split, fraction > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

/// A ring gauge: a track, a progress arc with round caps that starts at 12 o'clock, and a
/// percentage with a caption in the middle.
struct RingGauge: View {
    var fraction: Double?  // 0...1, nil when there is nothing to measure
    var percentText: String
    var caption: String
    var accent: Color
    var diameter: CGFloat = 120
    var lineWidth: CGFloat = 12

    var body: some View {
        let progress = min(max(fraction ?? 0, 0), 1)
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(.quaternary, lineWidth: lineWidth)
            if progress > 0 {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(percentText)
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, lineWidth + 4)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(percentText) \(caption)")
    }
}

/// The one folder chooser the settings window and the panel share.
@MainActor
enum FolderPicker {
    /// Runs an open panel for directories only and returns the chosen path, or nil when cancelled.
    /// It starts at `path`, or at /Volumes when that is empty.
    static func choose(
        startingAt path: String, prompt: String, message: String? = nil, canCreateDirectories: Bool = false
    ) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreateDirectories
        panel.prompt = prompt
        if let message { panel.message = message }
        panel.directoryURL = URL(fileURLWithPath: path.isEmpty ? "/Volumes" : path)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
