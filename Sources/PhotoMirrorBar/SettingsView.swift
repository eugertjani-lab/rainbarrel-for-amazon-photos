import AppKit
import MirrorCore
import SwiftUI

/// Drive folder, scan subpath and optional Amazon index override.
struct SettingsView: View {
    let model: AppModel

    @State private var driveRoot = ""
    @State private var scanSubpath = ""
    @State private var indexPath = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Backup drive") {
                HStack {
                    TextField("Drive folder", text: $driveRoot, prompt: Text("/Volumes/MyBackupDrive"))
                    Button("Choose…") { if let path = chooseFolder(startingAt: driveRoot) { driveRoot = path } }
                }
                TextField("Scan subpath", text: $scanSubpath, prompt: Text("Optional folder on the drive"))
                Text("Scans only walk this folder. Leave it empty to track the whole drive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Amazon Photos index") {
                HStack {
                    TextField("Index file", text: $indexPath, prompt: Text("Detected automatically"))
                    Button("Choose…") { if let path = chooseFile() { indexPath = path } }
                }
                Text("Only needed when the automatic detection picks the wrong file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Folder") {
                    Text(model.tools.paths.dataDirectory.path)
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                Button("Open data folder") {
                    NSWorkspace.shared.open(model.tools.paths.dataDirectory)
                }
            }
            HStack {
                Spacer()
                Button("Revert") { load() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
        .onAppear { if !loaded { load() } }
    }

    private func load() {
        let config = model.config
        driveRoot = config.driveRoot ?? ""
        scanSubpath = config.scanSubpath ?? ""
        indexPath = config.amazonIndexPath ?? ""
        loaded = true
    }

    private func save() {
        func clean(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        model.saveConfig(Config(
            driveRoot: clean(driveRoot), scanSubpath: clean(scanSubpath), amazonIndexPath: clean(indexPath)))
    }

    private func chooseFolder(startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: path.isEmpty ? "/Volumes" : path)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func chooseFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AmazonAppIndexSource.defaultSupportDirectory()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
