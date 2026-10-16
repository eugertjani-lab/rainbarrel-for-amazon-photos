import MirrorCore
import SwiftUI

/// The symbol and short text shown in the menu bar. All symbols are template images, so the system
/// tints them for light and dark menu bars.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        switch model.barState {
        case .loading:
            Image(systemName: "icloud")
                .accessibilityLabel("PhotoMirror, reading the catalog")
        case .scanning:
            Image(systemName: "arrow.triangle.2.circlepath")
                .accessibilityLabel("PhotoMirror, scanning the drive")
        case .warning:
            Image(systemName: "externaldrive.badge.exclamationmark")
                .accessibilityLabel("PhotoMirror, needs attention")
        case .synced:
            Image(systemName: "checkmark.icloud")
                .accessibilityLabel("PhotoMirror, everything is on the drive")
        case .onlineOnly(let count):
            HStack(spacing: 3) {
                Image(systemName: "icloud.and.arrow.down")
                Text(DisplayFormat.compactCount(count))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("PhotoMirror, \(DisplayFormat.number(count)) files only in the cloud")
        }
    }
}
