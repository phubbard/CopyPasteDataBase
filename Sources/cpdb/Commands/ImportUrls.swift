#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import Foundation

/// `cpdb import-urls <file>` — bulk-seed the database from a text
/// file of one http(s):// or file:// URL per line, as if each had
/// been copied to the clipboard. Entries are attributed to the
/// synthetic `cpdb import` source app so seeded data is
/// distinguishable from real captures, and they flow through the
/// normal ingest path — so kind=link rows enter the link-metadata
/// backfill queue and get titles + thumbnails enriched in the
/// background just like a real copy.
///
/// Use cases: seeding a fresh install from a bookmarks export,
/// migrating a read-later list, or scripted ingestion.
struct ImportUrls: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-urls",
        abstract: "Seed the database from a file of one URL per line (treated as clipboard captures)."
    )

    @Argument(help: "Path to a UTF-8 text file, one http(s):// or file:// URL per line. Blank lines and #-comments are skipped.")
    var file: String

    @Flag(name: .long, help: "Parse + report what would be imported without writing.")
    var dryRun: Bool = false

    @Option(name: .long, help: "Seconds to spread captured_at over (oldest first), so imported entries don't all collapse to one timestamp. Default 0 = all now.")
    var spreadSeconds: Double = 0

    func run() throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw ValidationError("can't read \(url.path) as UTF-8")
        }

        // Shared parse/ingest logic lives in UrlImporter (CpdbCore)
        // so the Preferences "Import…" button and this command stay
        // byte-for-byte identical in behaviour.
        let (accepted, rejected) = UrlImporter.parse(raw)
        print("\(accepted.count) URL(s) to import, \(rejected.count) rejected")
        for (line, why) in rejected.prefix(10) {
            print("  reject: \(line.prefix(60)) — \(why)")
        }
        if rejected.count > 10 { print("  … and \(rejected.count - 10) more rejected") }

        if dryRun || accepted.isEmpty {
            for u in accepted.prefix(20) { print("  import: \(u.prefix(80))") }
            if accepted.count > 20 { print("  … and \(accepted.count - 20) more") }
            return
        }

        let store = try Store.open()
        let result = try UrlImporter.run(
            rawText: raw,
            into: store,
            spreadSeconds: spreadSeconds
        )
        print("done: inserted=\(result.inserted) bumped=\(result.bumped) skipped=\(result.skipped)")
        if result.inserted > 0 {
            print("link entries will get titles + thumbnails on the next backfill cycle")
            print("(or run `cpdb fetch-link-titles` to enrich now)")
        }
    }
}
#endif
