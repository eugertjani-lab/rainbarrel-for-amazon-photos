import AppKit
import Darwin

/// Offers to move the app into the Applications folder when it runs from a mounted disk image,
/// an App Translocation path or the Downloads folder, then opens the copy and quits this instance.
@MainActor
enum MoveToApplications {
    /// UserDefaults key that holds the answer to "Do not ask again".
    static let suppressionKey = "MoveToApplicationsSuppressed"

    private static let appName = "Rainbarrel.app"

    private struct MoveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Asks once per launch, and only for a bundle that sits somewhere it should not stay.
    /// Returns true when the app is relaunching from its new place and the caller should do nothing more.
    @discardableResult
    static func offerIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: suppressionKey) else { return false }
        let bundleURL = Bundle.main.bundleURL
        guard needsMove(bundleURL) else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Rainbarrel to the Applications folder?"
        alert.informativeText =
            "Rainbarrel then opens from Launchpad and the Applications folder, and it keeps working after you eject the disk image or clean up Downloads."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressionKey)
        }
        guard response == .alertFirstButtonReturn else { return false }

        do {
            let destination = try move(from: bundleURL)
            relaunch(at: destination)
            return true
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Rainbarrel could not be moved to Applications"
            failure.informativeText = error.localizedDescription
            failure.runModal()
            return false
        }
    }

    /// True for a translocated app, an app on a read-only volume (a disk image) or an app in Downloads.
    static func needsMove(_ bundleURL: URL) -> Bool {
        let path = bundleURL.path
        if path.contains("/AppTranslocation/") { return true }
        if (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return true }
        return isInDownloads(bundleURL)
    }

    private static func isInDownloads(_ url: URL) -> Bool {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return false
        }
        let folder = downloads.resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(folder + "/")
    }

    /// Copies the bundle to /Applications (or ~/Applications when that is not writable), clears the
    /// quarantine flag on the copy and, for a download, trashes the original. Returns the new location.
    private static func move(from source: URL) throws -> URL {
        let manager = FileManager.default
        let destination = try destinationURL()
        if manager.fileExists(atPath: destination.path) {
            try quitInstances(at: destination)
            try manager.trashItem(at: destination, resultingItemURL: nil)
        }
        try manager.copyItem(at: source, to: destination)
        clearQuarantine(at: destination)
        let isDiskImageOrTranslocated =
            source.path.contains("/AppTranslocation/")
            || (try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        if !isDiskImageOrTranslocated, isInDownloads(source) {
            try? manager.trashItem(at: source, resultingItemURL: nil)
        }
        return destination
    }

    private static func destinationURL() throws -> URL {
        let manager = FileManager.default
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if manager.isWritableFile(atPath: system.path) {
            return system.appendingPathComponent(appName)
        }
        let user = manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try manager.createDirectory(at: user, withIntermediateDirectories: true)
        return user.appendingPathComponent(appName)
    }

    /// Terminates another instance that runs from `url` and waits up to five seconds for it to exit.
    private static func quitInstances(at url: URL) throws {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let target = url.resolvingSymlinksInPath().path
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.bundleURL?.resolvingSymlinksInPath().path == target && $0 != NSRunningApplication.current
        }
        guard !running.isEmpty else { return }
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if running.contains(where: { !$0.isTerminated }) {
            throw MoveError(message: "The copy of Rainbarrel in the Applications folder is still running. Quit it and try again.")
        }
    }

    /// Removes `com.apple.quarantine` from the bundle and everything inside it. A missing attribute
    /// is fine, and any other failure leaves a flag the user can clear by hand.
    private static func clearQuarantine(at url: URL) {
        _ = removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        while let relative = enumerator?.nextObject() as? String {
            _ = removexattr(url.appendingPathComponent(relative).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// Opens the copy as a new instance and quits this one once it has launched.
    private static func relaunch(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            // If the copy did not open, this instance keeps running so the app stays reachable.
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
