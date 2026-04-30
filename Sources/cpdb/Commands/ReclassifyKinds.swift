#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import GRDB
import Foundation

/// `cpdb reclassify-kinds` — one-shot migration to fix entries that
/// were classified under an older heuristic. v2.7.11 added "URL-
/// shaped plain text → kind=link"; rows captured before that ship
/// (and rows that were bumped under the old code path before
/// v2.7.14's reclassify-on-bump fix) stay misclassified as
/// `kind=text`, so they never enter the link-title backfill queue.
///
/// This command finds every `kind=text` row whose `text_preview` is
/// a single http(s):// URL and switches it to `kind=link`, clearing
/// `link_fetched_at` so the next backfill cycle picks it up.
/// Idempotent — re-running is a no-op once everything's classified.
struct ReclassifyKinds: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reclassify-kinds",
        abstract: "Reclassify text entries that are actually URLs as kind=link."
    )

    @Flag(name: .long, help: "Show what would change without writing.")
    var dryRun: Bool = false

    func run() throws {
        let store = try Store.open()
        let now = Date().timeIntervalSince1970
        let candidates: [(id: Int64, url: String)] = try store.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, text_preview FROM entries
                    WHERE kind = 'text' AND deleted_at IS NULL
                      AND (text_preview LIKE 'http://%' OR text_preview LIKE 'https://%')
                """
            )
            // Mirror the Swift-side heuristic in PasteboardSnapshot.kind:
            //   - whitespace-trimmed, length ≤ 2048
            //   - no embedded whitespace
            //   - URL(string:) parses with a non-nil host
            return rows.compactMap { row -> (Int64, String)? in
                let id: Int64 = row["id"]
                guard let raw = row["text_preview"] as String? else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count <= 2048,
                      !trimmed.contains(where: { $0.isWhitespace }),
                      URL(string: trimmed)?.host != nil
                else { return nil }
                return (id, trimmed)
            }
        }

        print("\(candidates.count) text entries would be reclassified as link")
        if dryRun {
            for c in candidates.prefix(20) {
                print("  id=\(c.id)  \(c.url.prefix(80))")
            }
            if candidates.count > 20 {
                print("  … and \(candidates.count - 20) more")
            }
            return
        }
        guard !candidates.isEmpty else { return }

        try store.dbQueue.write { db in
            for c in candidates {
                try db.execute(
                    sql: """
                        UPDATE entries
                        SET kind = 'link', link_fetched_at = NULL
                        WHERE id = ?
                    """,
                    arguments: [c.id]
                )
                // Push the kind change so other devices see it too.
                try PushQueue.enqueue(entryId: c.id, in: db, now: now)
            }
        }
        print("reclassified \(candidates.count) entries")
        print("the daemon's next backfill cycle (or `cpdb fetch-link-titles`) will enrich them")
    }
}
#endif
