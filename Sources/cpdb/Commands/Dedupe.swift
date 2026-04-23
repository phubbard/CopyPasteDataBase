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

    @Option(name: .long, help: "Seconds between captures to be considered duplicates.")
    var window: Double = 5.0

    @Flag(name: .long, help: "Show what would be tombstoned but don't write.")
    var dryRun: Bool = false

    func run() throws {
        let store = try Store.open()
        let now = Date().timeIntervalSince1970

        let groups: [[Int64]] = try store.dbQueue.read { db in
            // Find groups where COUNT(*) > 1, same kind + trimmed text,
            // landing within the rolling window. We bucket by floor(time/window)
            // — coarse but cheap and good enough for cleanup.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        kind,
                        TRIM(COALESCE(text_preview, '')) AS t,
                        CAST(created_at / ? AS INTEGER) AS bucket,
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
