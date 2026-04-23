#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import GRDB
import Foundation

/// One-shot cleanup for entries whose `title` / `text_preview` got
/// clobbered with a full `file:///...` URL instead of a friendly
/// filename. This was a v2.5.0–2.5.2 regression in
/// `PasteboardSnapshot.plainText`, which fell back to `public.file-url`
/// bytes when no text flavor was present. For screenshot captures
/// (PNG + file-url flavor set), `deriveTitle` then used the URL as
/// the title instead of the filename.
///
/// v2.5.3+ drops the file-url fallback, so new captures are clean.
/// This command rewrites the historical mess: any row whose title
/// or text_preview starts with `file://` gets the filename
/// substituted (url.lastPathComponent). Enqueues each updated row
/// for CloudKit push so the iOS app and other Macs pick up the
/// cleaned values on their next pull.
struct BackfillTitles: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backfill-titles",
        abstract: "Rewrite file:// URLs left in title/text_preview to a plain filename."
    )

    @Flag(name: .long, help: "Show what would change but don't write.")
    var dryRun: Bool = false

    func run() throws {
        let store = try Store.open()
        let now = Date().timeIntervalSince1970

        struct Candidate { let id: Int64; let oldTitle: String?; let oldPreview: String?; let newTitle: String; let newPreview: String? }

        let candidates: [Candidate] = try store.dbQueue.read { db in
            // Any live row whose title OR text_preview LOOKS like a
            // bare file URL. We intentionally ignore rows that have
            // real text around the file URL (those are user-authored
            // strings that happen to contain a file path; leave
            // alone).
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, text_preview
                    FROM entries
                    WHERE deleted_at IS NULL
                      AND (
                        (title IS NOT NULL AND title LIKE 'file://%')
                        OR (text_preview IS NOT NULL AND text_preview LIKE 'file://%')
                      )
                """
            )
            return rows.compactMap { row -> Candidate? in
                let id: Int64 = row["id"]
                let title: String? = row["title"]
                let preview: String? = row["text_preview"]

                // Pick whichever column carries the file URL; if both
                // do, prefer title's URL for filename extraction.
                let rawURL = (title?.hasPrefix("file://") == true ? title : preview) ?? ""
                // Trim in case of accidental whitespace.
                let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only touch rows where the WHOLE value is a file URL,
                // no leading/trailing prose mixed in. This avoids
                // breaking a captured email whose first line starts
                // with `file://`.
                guard trimmed.hasPrefix("file://"),
                      !trimmed.contains(where: { $0.isWhitespace && $0 != " " }),
                      let url = URL(string: trimmed)
                else { return nil }
                let filename = url.lastPathComponent
                    .removingPercentEncoding ?? url.lastPathComponent
                guard !filename.isEmpty else { return nil }

                // New preview: null it out if it WAS the file URL.
                // Keep it if it had legitimate other content.
                let newPreview: String? = (preview?.hasPrefix("file://") == true) ? nil : preview
                return Candidate(
                    id: id,
                    oldTitle: title,
                    oldPreview: preview,
                    newTitle: filename,
                    newPreview: newPreview
                )
            }
        }

        print("found \(candidates.count) row(s) with file:// contamination")
        for c in candidates.prefix(10) {
            print("  id=\(c.id)  \"\(c.oldTitle?.prefix(60) ?? "")\" → \"\(c.newTitle)\"")
        }
        if candidates.count > 10 {
            print("  … and \(candidates.count - 10) more")
        }

        guard !dryRun, !candidates.isEmpty else {
            if dryRun { print("dry run — no changes written") }
            return
        }

        try store.dbQueue.write { db in
            for c in candidates {
                try db.execute(
                    sql: "UPDATE entries SET title = ?, text_preview = ? WHERE id = ?",
                    arguments: [c.newTitle, c.newPreview, c.id]
                )
                // Re-index FTS5 so searching for the filename hits.
                try FtsIndex.indexEntry(
                    db: db,
                    entryId: c.id,
                    title: c.newTitle,
                    text: c.newPreview,
                    appName: nil
                )
                // Push to CloudKit so iOS / other Macs pick up the
                // cleaned values on next pull.
                try PushQueue.enqueue(entryId: c.id, in: db, now: now)
            }
        }
        print("updated \(candidates.count) row(s), enqueued for CloudKit push")
    }
}
#endif
