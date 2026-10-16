import ArgumentParser
import Foundation
import MirrorCore

struct RefreshCatalog: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh-catalog",
        abstract: "Copy the cloud catalog from the Amazon Photos app index into the state database.",
        discussion: "The app's own database is never opened; a private snapshot is read instead.")

    func run() throws {
        let context = try AppContext.open()
        let result = try context.refreshCatalog()
        let report = try context.reconciler().report(driveRoot: context.config.driveRoot)
        print("Catalog refreshed from \(result.sourceDescription)")
        print("  Photos and videos:  \(Format.number(report.photosVideos.count))  (\(Format.bytes(report.photosVideos.bytes)))")
        print("  Distinct MD5s:      \(Format.number(report.distinctMD5))")
        print("  Live Photo videos:  \(Format.number(report.liveVideos.count))  (\(Format.bytes(report.liveVideos.bytes)))")
        print("  Catalog as of:      \(Format.dateTime(result.sourceModifiedAt)) (\(Format.age(of: result.sourceModifiedAt)))")
    }
}

struct ImportHashes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-hashes",
        abstract: "Import MD5s from a CSV with the header path,size,md5,result.",
        discussion: """
            The path column is relative to <driveRoot>/<prefix>. Imported rows count as hashed; the \
            next scan keeps their hash and only fills in the file's modification time.
            """)

    @Argument(help: "CSV file to import.")
    var csv: String

    @Option(help: "Folder below the drive root that the CSV paths are relative to.")
    var prefix: String = ""

    func run() throws {
        let context = try AppContext.open()
        let url = URL(fileURLWithPath: absolutePath(csv))
        let result = try HashSeedImporter.importCSV(at: url, prefix: prefix, into: context.store)
        print("Imported \(Format.number(result.imported)) hashes from \(Format.number(result.rows)) rows")
        print("  With errors, no MD5:  \(Format.number(result.errorRows))")
        print("  Ignored housekeeping files (desktop.ini, Thumbs.db, ...):  \(Format.number(result.excluded))")
        print("  Skipped (malformed):  \(Format.number(result.skipped))")
        if result.removedExisting > 0 {
            print("  Removed \(Format.number(result.removedExisting)) existing housekeeping rows")
        }
    }
}
