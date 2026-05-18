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

        // Parse: trim, drop blanks + #-comments, keep only http(s)/file.
        let candidates: [String] = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var accepted: [String] = []
        var rejected: [(String, String)] = []
        for line in candidates {
            guard let u = URL(string: line), let scheme = u.scheme?.lowercased() else {
                rejected.append((line, "unparseable"))
                continue
            }
            guard scheme == "http" || scheme == "https" || scheme == "file" else {
                rejected.append((line, "scheme '\(scheme)' not http/https/file"))
                continue
            }
            accepted.append(line)
        }

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
        let deviceId = try DeviceIdentity.ensureLocalDevice(in: store)
        let ingestor = Ingestor(store: store)

        // Spread captured_at backwards from now so the import doesn't
        // collapse into a single instant (which would make the popup
        // ordering arbitrary). Oldest line → oldest timestamp.
        let now = Date()
        let step = accepted.isEmpty ? 0 : (spreadSeconds / Double(max(accepted.count, 1)))

        var inserted = 0
        var bumped = 0
        var skipped = 0
        for (idx, line) in accepted.enumerated() {
            // captured_at: line 0 is oldest. With spread=0 they all
            // land at `now` (insertion order still gives stable ids).
            let offset = step * Double(accepted.count - 1 - idx)
            let capturedAt = now.addingTimeInterval(-offset)
            let snapshot = Self.snapshot(for: line, capturedAt: capturedAt)
            let outcome = try ingestor.ingest(
                snapshot,
                sourceApp: .importer,
                deviceId: deviceId
            )
            switch outcome {
            case .inserted: inserted += 1
            case .bumped:   bumped += 1
            case .skipped:  skipped += 1
            }
        }
        print("done: inserted=\(inserted) bumped=\(bumped) skipped=\(skipped)")
        if inserted > 0 {
            print("link entries will get titles + thumbnails on the next backfill cycle")
            print("(or run `cpdb fetch-link-titles` to enrich now)")
        }
    }

    /// Build a synthetic pasteboard snapshot for a URL string. We
    /// attach both `public.url` (so the kind classifier resolves
    /// it to .link) and `public.utf8-plain-text` (so search +
    /// text_preview behave like a real browser copy).
    static func snapshot(for urlString: String, capturedAt: Date) -> PasteboardSnapshot {
        let bytes = Data(urlString.utf8)
        let flavors = [
            CanonicalHash.Flavor(uti: "public.url", data: bytes),
            CanonicalHash.Flavor(uti: "public.utf8-plain-text", data: bytes),
        ]
        return PasteboardSnapshot(
            items: [PasteboardSnapshot.Item(flavors: flavors)],
            capturedAt: capturedAt
        )
    }
}
#endif
