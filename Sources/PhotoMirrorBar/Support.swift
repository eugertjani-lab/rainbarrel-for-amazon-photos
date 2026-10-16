import AppKit
import MirrorCore
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

/// A button drawn entirely in SwiftUI, used for snapshots in place of the AppKit-backed bordered style.
struct FlatButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? Color.accentColor : Color.primary.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
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
