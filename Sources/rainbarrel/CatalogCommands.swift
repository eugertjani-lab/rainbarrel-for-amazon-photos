import ArgumentParser
import Foundation
import RainbarrelCore

extension CatalogSourceChoice: ExpressibleByArgument {}

/// `rainbarrel catalog ...`
struct CatalogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "Work with the cloud catalog.",
        subcommands: [Refresh.self]
    )

    struct Refresh: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Refresh the cloud catalog from the Amazon Photos app index or from Amazon's web API.",
            discussion: """
                The source is the one set with `rainbarrel config set-catalog-source` (auto by default: the \
                desktop app's index when it exists, Amazon's web API otherwise). The app's own database is \
                never opened; a private snapshot is read instead. The web API needs a session from \
                `rainbarrel auth import`; its first read lists the whole library, later reads only apply the \
                changes since the last one.
                """)

        @Option(help: "Read from this source this time: app, web or auto.")
        var source: CatalogSourceChoice?

        @Flag(help: "Read the whole catalog from the web API even when its changes could be applied.")
        var full = false

        func run() async throws {
            try await CatalogRefreshReport.run(source: source, full: full)
        }
    }
}

/// The old spelling of `catalog refresh`.
struct RefreshCatalog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh-catalog",
        abstract: "Old name of `catalog refresh`.",
        shouldDisplay: false)

    func run() async throws {
        try await CatalogRefreshReport.run(source: nil, full: false)
    }
}

enum CatalogRefreshReport {
    static func run(source: CatalogSourceChoice?, full: Bool) async throws {
        let context = try AppContext.open()
        let outcome = try await context.refreshCatalog(source: source, full: full)
        let report = try context.reconciler().report(driveRoot: context.config.driveRoot)
        switch outcome.origin {
        case .app:
            print("Catalog refreshed from \(outcome.result.sourceDescription.sanitizedForTerminal)")
        case .web:
            switch outcome.mode {
            case .full:
                print("Catalog refreshed from the Amazon Photos web API (whole library read)")
            case .incremental:
                print("Catalog refreshed from the Amazon Photos web API (\(Format.number(outcome.changed)) changed, "
                    + "\(Format.number(outcome.removed)) removed since the last refresh)")
            }
        }
        print("  Photos and videos:  \(Format.number(report.photosVideos.count))  (\(Format.bytes(report.photosVideos.bytes)))")
        print("  Distinct MD5s:      \(Format.number(report.distinctMD5))")
        print("  Live Photo videos:  \(Format.number(report.liveVideos.count))  (\(Format.bytes(report.liveVideos.bytes)))")
        if outcome.result.skippedCount > 0 {
            print("  Left out (no MD5 or size at Amazon):  \(Format.number(outcome.result.skippedCount))")
        }
        print("  Catalog as of:      \(Format.dateTime(outcome.result.sourceModifiedAt)) (\(Format.age(of: outcome.result.sourceModifiedAt)))")
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
