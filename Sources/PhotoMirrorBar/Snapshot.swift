import AppKit
import MirrorCore
import SwiftUI

/// `PhotoMirrorBar --render-snapshot out.png [--dark]`: draws the popover with the real current
/// report through `ImageRenderer` at 2x and exits. Used to check the layout without clicking.
@MainActor
enum SnapshotRenderer {
    static func run(output: String, dark: Bool) -> Never {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let tools = MirrorTools()
        let report: SyncReport
        let config: Config
        do {
            config = try tools.loadConfig()
            report = try tools.syncStatus(refresh: false)
        } catch {
            FileHandle.standardError.write(Data("Cannot read the report: \(error)\n".utf8))
            exit(1)
        }
        let model = AppModel.preview(tools: tools, report: report, config: config)
        // Dynamic colors must be resolved under the chosen appearance before ImageRenderer draws them.
        var background = Color.gray
        (NSApp.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            background = Color(cgColor: NSColor.windowBackgroundColor.cgColor)
        }
        let content = PopoverView(model: model)
            .environment(\.isSnapshot, true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(background)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 360, height: nil)
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("ImageRenderer produced no image\n".utf8))
            exit(1)
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Could not encode the PNG\n".utf8))
            exit(1)
        }
        do {
            let url = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("Could not write \(output): \(error)\n".utf8))
            exit(1)
        }
        print("Wrote \(output) (\(image.width)x\(image.height) px, \(dark ? "dark" : "light"))")
        exit(0)
    }
}
