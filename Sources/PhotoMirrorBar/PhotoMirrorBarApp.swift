import AppKit
import MirrorCore
import SwiftUI

@main
enum Launcher {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-snapshot") {
            guard index + 1 < arguments.count else {
                FileHandle.standardError.write(Data("--render-snapshot needs an output path\n".utf8))
                exit(2)
            }
            let output = arguments[index + 1]
            let dark = arguments.contains("--dark")
            MainActor.assumeIsolated { SnapshotRenderer.run(output: output, dark: dark) }
        }
        PhotoMirrorBarApp.main()
    }
}

struct PhotoMirrorBarApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("PhotoMirror Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

/// Connects the popover to the scene environment (opening the settings window).
private struct PopoverRoot: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PopoverView(model: model, openSettings: {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        })
    }
}
