#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import GRDB
import Foundation

/// One-shot cleanup for near-duplicate captures that slipped past the
/// content-hash dedup. Some source apps (notably Xcode's debug
/// console) publish a pasteboard with one flavor set and then rewrite
/// it with a slightly different flavor set milliseconds later — the
/// bytes differ, the hash differs, we get two rows with identical
/// displayed text seconds apart.
///
/// The Ingestor now has a within-window text-dedup guard that prevents
/// new occurrences. This command cleans up the historical pile.
///
/// Dedup rule: rows are considered the same if they share the same
/// kind AND the same trimmed text_preview AND were created within
/// `--window` seconds of each other. The oldest row in each group is
/// kept (preserving stable local IDs); the rest get tombstoned so
/// CloudKit propagates the deletion.
struct Dedupe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dedupe",
        abstract: "Merge near-duplicate entries captured within a short window."
    )

    @Option(name: .long, help: "Seconds between captures to be considered duplicates (text/image/etc).")
    var window: Double = 5.0

    @Flag(name: .long, help: "For kind=link, dedupe across all time (ignores --window). The URL itself is the identity, so multi-day phantom captures (loginwindow on screen unlock, multi-Mac sync drift) collapse to one row.")
    var linksAllTime: Bool = false

    @Flag(name: .long, help: "Show what would be tombstoned but don't write.")
    var dryRun: Bool = false

    func run() throws {
        let store = try Store.open()
        let now = Date().timeIntervalSince1970

        let groups: [[Int64]] = try store.dbQueue.read { db in
            // Find groups where COUNT(*) > 1, same kind + trimmed text,
            // landing within the rolling window. We bucket by floor(time/window)
            // — coarse but cheap and good enough for cleanup.
            //
            // When --links-all-time is set, kind=link rows skip the
            // time bucket entirely — group key is just (kind='link',
            // trimmed text_preview). Other kinds still respect the
            // window (you don't want 'OK' you typed 6 months apart
            // collapsed into one entry).
            let bucketExpr = linksAllTime
                ? "CASE WHEN kind = 'link' THEN 0 ELSE CAST(created_at / ? AS INTEGER) END"
                : "CAST(created_at / ? AS INTEGER)"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        kind,
                        TRIM(COALESCE(text_preview, '')) AS t,
                        \(bucketExpr) AS bucket,
                        GROUP_CONCAT(id, ',') AS ids,
                        COUNT(*) AS n
                    FROM entries
                    WHERE deleted_at IS NULL
                      AND text_preview IS NOT NULL
                      AND TRIM(COALESCE(text_preview, '')) != ''
                    GROUP BY kind, t, bucket
                    HAVING COUNT(*) > 1
                    ORDER BY MAX(created_at) DESC
                """,
                arguments: [window]
            )
            return rows.compactMap { row -> [Int64]? in
                let ids = (row["ids"] as String? ?? "").split(separator: ",").compactMap { Int64($0) }
                return ids.count > 1 ? ids : nil
            }
        }

        var toTombstone: [Int64] = []
        var keepCount = 0
        for ids in groups {
            // Keep the lowest id (oldest row), tombstone the rest.
            let sorted = ids.sorted()
            let keep = sorted.first!
            let drop = sorted.dropFirst()
            keepCount += 1
            toTombstone.append(contentsOf: drop)
            print("group (\(sorted.count) rows): keep id=\(keep), tombstone \(Array(drop))")
        }

        print("---")
        print("\(groups.count) duplicate group(s) found")
        print("\(toTombstone.count) row(s) would be tombstoned")
        print("\(keepCount) row(s) kept")

        guard !dryRun, !toTombstone.isEmpty else {
            if dryRun { print("dry run — no changes written") }
            return
        }

        try store.dbQueue.write { db in
            // Before tombstoning, salvage link_title from siblings.
            // If the kept row has no link_title but one of its
            // about-to-be-tombstoned dupes does, copy the title onto
            // the kept row so the deduplication doesn't lose the
            // backfill work. Same for link_fetched_at.
            for ids in groups {
                let sorted = ids.sorted()
                guard let keep = sorted.first else { continue }
                let drops = Array(sorted.dropFirst())
                let kept = try Row.fetchOne(db,
                    sql: "SELECT kind, link_title, link_fetched_at FROM entries WHERE id = ?",
                    arguments: [keep])
                guard kept?["kind"] as String? == "link" else { continue }
                let keptTitle = kept?["link_title"] as String?
                if keptTitle?.isEmpty != false {
                    if let donor = try Row.fetchOne(db,
                        sql: """
                            SELECT link_title, link_fetched_at FROM entries
                            WHERE id IN (\(drops.map { "\($0)" }.joined(separator: ",")))
                              AND link_title IS NOT NULL AND link_title != ''
                            ORDER BY link_fetched_at DESC LIMIT 1
                        """) {
                        try db.execute(
                            sql: "UPDATE entries SET link_title = ?, link_fetched_at = COALESCE(link_fetched_at, ?) WHERE id = ?",
                            arguments: [donor["link_title"] as String?, donor["link_fetched_at"] as Double?, keep]
                        )
                        try PushQueue.enqueue(entryId: keep, in: db, now: now)
                    }
                }
            }
            for id in toTombstone {
                try db.execute(
                    sql: "UPDATE entries SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                    arguments: [now, id]
                )
                // Enqueue for CloudKit push so other devices tombstone too.
                try PushQueue.enqueue(entryId: id, in: db, now: now)
            }
        }
        print("tombstoned \(toTombstone.count) row(s)")
    }
}
#endif
