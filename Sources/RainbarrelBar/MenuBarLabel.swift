import AppKit
import RainbarrelCore
import SwiftUI

/// The symbol and short text shown in the menu bar. All symbols are template images, so the system
/// tints them for light and dark menu bars.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        switch model.barState {
        case .loading:
            Image(systemName: "icloud")
                .accessibilityLabel("Rainbarrel, reading the catalog")
        case .scanning:
            Image(systemName: "arrow.triangle.2.circlepath")
                .accessibilityLabel("Rainbarrel, scanning the drive")
        case .warning:
            Image(systemName: "externaldrive.badge.exclamationmark")
                .accessibilityLabel("Rainbarrel, needs attention")
        case .signInExpired:
            Image(systemName: "externaldrive.badge.exclamationmark")
                .accessibilityLabel("Rainbarrel, sign-in expired")
        case .synced:
            Image(systemName: "checkmark.icloud")
                .accessibilityLabel("Rainbarrel, everything is on the drive")
        case .onlineOnly(let count):
            HStack(spacing: 3) {
                Image(systemName: "icloud.and.arrow.down")
                Text(DisplayFormat.compactCount(count))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rainbarrel, \(DisplayFormat.number(count)) files only in the cloud")
        case .downloading(let percent):
            DownloadingGlyph(percent: percent)
        }
    }
}

/// A small progress ring with the percent next to it. The ring is a template image, so the system
/// tints it for light and dark menu bars like the symbols above.
struct DownloadingGlyph: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: Self.ring(progress: Double(percent) / 100))
            Text("\(percent)%").monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rainbarrel, downloading, \(percent) percent")
    }

    /// A ring of 16 pt: a faint track and an arc from 12 o'clock clockwise.
    static func ring(progress: Double) -> NSImage {
        let amount = min(max(progress, 0), 1)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let line: CGFloat = 2.4
            let box = rect.insetBy(dx: line / 2 + 1, dy: line / 2 + 1)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = box.width / 2
            let track = NSBezierPath(ovalIn: box)
            track.lineWidth = line
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if amount > 0 {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(amount),
                    clockwise: true)
                arc.lineWidth = line
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
