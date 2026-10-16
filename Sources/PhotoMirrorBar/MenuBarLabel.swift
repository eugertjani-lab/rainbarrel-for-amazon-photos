import MirrorCore
import SwiftUI

/// The symbol and short text shown in the menu bar.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        switch model.barState {
        case .loading:
            Image(systemName: "icloud")
        case .scanning(let seen):
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                if seen > 0 { Text(DisplayFormat.compactCount(seen)) }
            }
        case .warning:
            Image(systemName: "exclamationmark.triangle")
        case .synced:
            Image(systemName: "checkmark.icloud")
        case .onlineOnly(let count):
            HStack(spacing: 3) {
                Image(systemName: "icloud.and.arrow.down")
                Text(DisplayFormat.compactCount(count))
            }
        }
    }
}
