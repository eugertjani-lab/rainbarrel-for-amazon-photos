import AppKit
import RainbarrelCore
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
            let years = arguments.contains("--years")
            let menuBar = arguments.contains("--menubar")
            let settings = arguments.contains("--settings")
            var state: String?
            if let stateIndex = arguments.firstIndex(of: "--state") {
                guard stateIndex + 1 < arguments.count else {
                    FileHandle.standardError.write(Data("--state needs a name\n".utf8))
                    exit(2)
                }
                state = arguments[stateIndex + 1]
            }
            MainActor.assumeIsolated {
                SnapshotRenderer.run(
                    output: output, dark: dark, years: years, state: state, menuBar: menuBar, settings: settings)
            }
        }
        RainbarrelBarApp.main()
    }
}

/// Lets a running download stop cleanly before the app quits, so its part files are removed.
@MainActor
final class BarAppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.isDownloadRunning else { return .terminateNow }
        model.stopForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Opening the app again while it runs shows the panel in a normal window. The menu-bar icon
    /// can be hidden (a full menu bar, the camera notch, or macOS menu bar settings), and this
    /// keeps the app reachable.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanelWindow()
        return false
    }

    private var panelWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func showPanelWindow() {
        guard let model = Self.model else { return }
        if panelWindow == nil {
            let view = PopoverView(model: model, openSettings: { [weak self] in self?.showSettingsWindow() })
                .frame(width: 360, height: 720)
            panelWindow = Self.makeWindow(title: "Rainbarrel", content: view, size: NSSize(width: 360, height: 720))
        }
        Self.bringForward(panelWindow)
    }

    func showSettingsWindow() {
        guard let model = Self.model else { return }
        if settingsWindow == nil {
            settingsWindow = Self.makeWindow(
                title: "Rainbarrel Settings", content: SettingsView(model: model).frame(minWidth: 520, minHeight: 640),
                size: NSSize(width: 560, height: 760))
        }
        Self.bringForward(settingsWindow)
    }

    private static func makeWindow(title: String, content: some View, size: NSSize) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private static func bringForward(_ window: NSWindow?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RainbarrelBarApp: App {
    @NSApplicationDelegateAdaptor(BarAppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        BarAppDelegate.model = model
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Rainbarrel Settings", id: "settings") {
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
