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
        case .downloading(let percent, let bytesPerSecond):
            DownloadingGlyph(percent: percent, bytesPerSecond: bytesPerSecond)
        }
    }
}

/// The current download speed. A run of this app adds a small progress ring in front of it; a download
/// by another process has no known progress, so the down-arrow symbol stands there instead. The ring
/// is a template image, so the system tints it for light and dark menu bars like the symbols above.
struct DownloadingGlyph: View {
    let percent: Int?
    let bytesPerSecond: Double

    var body: some View {
        HStack(spacing: 3) {
            if let percent {
                Image(nsImage: Self.ring(progress: Double(percent) / 100))
            } else {
                Image(systemName: "icloud.and.arrow.down")
            }
            Text(DisplayFormat.speed(bytesPerSecond: bytesPerSecond)).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rainbarrel, downloading, \(Self.spoken(bytesPerSecond))")
    }

    /// "14.2 megabytes per second", for VoiceOver.
    static func spoken(_ bytesPerSecond: Double) -> String {
        DisplayFormat.speed(bytesPerSecond: bytesPerSecond)
            .replacingOccurrences(of: "KB/s", with: "kilobytes per second")
            .replacingOccurrences(of: "MB/s", with: "megabytes per second")
            .replacingOccurrences(of: "GB/s", with: "gigabytes per second")
            .replacingOccurrences(of: "B/s", with: "bytes per second")
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
