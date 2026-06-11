import Foundation
import GRDB

/// Merge same-identity sibling entries onto one survivor, preserving
/// everything user-visible or expensively derived: pins, pinboard
/// memberships, link enrichment, OCR/image analysis, preview thumbnails,
/// and rich flavors the survivor lacks.
///
/// This is the SHARED coalesce path (docs/canonical-hash-v2.md §4.3 step 3
/// + §5.3): the identity-cutover collision merge, the pull-side uuid-merge
/// (Step 4), and `cpdb dedupe` (Step 5) all call it so a merged entry
/// looks the same no matter which path collapsed it. The bare "tombstone
/// the loser and bump" alternative was rejected by adversarial review —
/// it silently destroyed pins, pinboard memberships, and previews.
///
/// What it does NOT do (callers own these):
///   - tombstoning the losers or touching their content_hash/hash_version
///   - PushQueue enqueues
///   - choosing the survivor (callers use: earliest created_at, tie-break
///     smallest uuid — synced fields, so every device picks the same one)
public enum EntryCoalesce {

    /// Coalesce `losers` onto `survivor` inside the caller's write
    /// transaction. All ids must reference existing rows.
    public static func merge(
        db: Database,
        survivorId: Int64,
        loserIds: [Int64],
        now: Double
    ) throws {
        guard !loserIds.isEmpty else { return }
        let idList = loserIds.map(String.init).joined(separator: ",")
        let allList = ([survivorId] + loserIds).map(String.init).joined(separator: ",")

        // Pinned = OR(group); created_at = MAX(group) (bump-recency
        // semantics — the merged entry floats to where its most recent
        // copy was).
        try db.execute(
            sql: """
                UPDATE entries SET
                    pinned = (SELECT MAX(pinned) FROM entries WHERE id IN (\(allList))),
                    created_at = (SELECT MAX(created_at) FROM entries WHERE id IN (\(allList)))
                WHERE id = ?
                """,
            arguments: [survivorId]
        )

        // Scalar salvage: fill survivor NULLs from the losers. Link title
        // prefers the most recently fetched donor; analysis fields take
        // any non-NULL donor (they're deterministic re-derivations of the
        // same content, so "which donor" doesn't matter).
        let survivor = try Row.fetchOne(
            db,
            sql: """
                SELECT title, text_preview, link_title, link_fetched_at,
                       ocr_text, image_tags, analyzed_at, body_evicted_at
                FROM entries WHERE id = ?
                """,
            arguments: [survivorId]
        )
        let survivorEvicted = (survivor?["body_evicted_at"] as Double?) != nil
        if (survivor?["link_title"] as String?)?.isEmpty != false {
            if let donor = try Row.fetchOne(
                db,
                sql: """
                    SELECT link_title, link_fetched_at FROM entries
                    WHERE id IN (\(idList)) AND link_title IS NOT NULL AND link_title != ''
                    ORDER BY link_fetched_at DESC LIMIT 1
                    """
            ) {
                try db.execute(
                    sql: """
                        UPDATE entries SET link_title = ?,
                            link_fetched_at = COALESCE(link_fetched_at, ?)
                        WHERE id = ?
                        """,
                    arguments: [donor["link_title"] as String?, donor["link_fetched_at"] as Double?, survivorId]
                )
            }
        }
        for (col, current) in [("ocr_text", survivor?["ocr_text"] as String?),
                               ("image_tags", survivor?["image_tags"] as String?),
                               ("title", survivor?["title"] as String?),
                               ("text_preview", survivor?["text_preview"] as String?)]
        where current == nil {
            try db.execute(
                sql: """
                    UPDATE entries SET \(col) =
                        (SELECT \(col) FROM entries WHERE id IN (\(idList)) AND \(col) IS NOT NULL LIMIT 1)
                    WHERE id = ? AND \(col) IS NULL
                    """,
                arguments: [survivorId]
            )
        }
        if (survivor?["analyzed_at"] as Double?) == nil {
            try db.execute(
                sql: """
                    UPDATE entries SET analyzed_at =
                        (SELECT MAX(analyzed_at) FROM entries WHERE id IN (\(idList)))
                    WHERE id = ? AND analyzed_at IS NULL
                    """,
                arguments: [survivorId]
            )
        }

        // Preview thumbnails: keep survivor's; if it has none, re-point
        // the first loser's row (previews PK is entry_id, so UPDATE OR
        // IGNORE moves at most one and silently skips if the survivor
        // gained one mid-loop).
        let survivorHasPreview = try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM previews WHERE entry_id = ?)",
            arguments: [survivorId]
        ) ?? false
        if !survivorHasPreview {
            try db.execute(
                sql: """
                    UPDATE OR IGNORE previews SET entry_id = ?
                    WHERE entry_id = (SELECT entry_id FROM previews WHERE entry_id IN (\(idList)) LIMIT 1)
                    """,
                arguments: [survivorId]
            )
        }

        // Pinboard memberships: re-point, dropping duplicates (PK is
        // (pinboard_id, entry_id)); whatever still references a loser
        // afterwards IS a duplicate — remove it so tombstoned losers
        // don't linger in pinboards.
        try db.execute(sql: "UPDATE OR IGNORE pinboard_entries SET entry_id = ? WHERE entry_id IN (\(idList))",
                       arguments: [survivorId])
        try db.execute(sql: "DELETE FROM pinboard_entries WHERE entry_id IN (\(idList))")

        // Flavors: adopt UTIs the survivor lacks (union — same rule as the
        // Ingestor's union bump). Loser rows stay in place (their blob_key
        // references keep the refcount honest until eviction/GC); the
        // INSERT OR IGNORE copy adds a second reference for adopted
        // spilled flavors, which the content-addressed blob store handles
        // by design. Same-UTI conflicts: survivor wins (quantified cost:
        // 5 of 441 audit clusters, all formatting-engine noise).
        //
        // SKIPPED when the survivor's body has been evicted: its flavor
        // rows were deliberately discarded (EntryEvictor), and re-adding a
        // partial set from a loser would leave body_evicted_at set while
        // flavors exist — an incoherent state. Mirrors the Ingestor's
        // union-bump guard. Scalar/pin/pinboard/preview salvage above
        // still runs (that's metadata, unaffected by eviction).
        if !survivorEvicted {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO entry_flavors (entry_id, uti, size, data, blob_key)
                    SELECT ?, uti, size, data, blob_key FROM entry_flavors WHERE entry_id IN (\(idList))
                    """,
                arguments: [survivorId]
            )
            try db.execute(
                sql: """
                    UPDATE entries SET total_size =
                        (SELECT COALESCE(SUM(size), 0) FROM entry_flavors WHERE entry_id = ?)
                    WHERE id = ?
                    """,
                arguments: [survivorId, survivorId]
            )
        }

        // FTS: losers out, survivor reindexed with post-salvage values
        // (the FTS table has no triggers — without this, merged-in OCR
        // text / link titles would be unsearchable indefinitely).
        for loser in loserIds {
            try FtsIndex.removeEntry(db: db, entryId: loser)
        }
        let post = try Row.fetchOne(
            db,
            sql: """
                SELECT e.title, e.text_preview, e.ocr_text, e.image_tags, e.link_title,
                       a.name AS app_name
                FROM entries e LEFT JOIN apps a ON a.id = e.source_app_id
                WHERE e.id = ?
                """,
            arguments: [survivorId]
        )
        try FtsIndex.indexEntry(
            db: db,
            entryId: survivorId,
            title: post?["title"],
            text: post?["text_preview"],
            appName: post?["app_name"],
            ocrText: post?["ocr_text"],
            imageTags: post?["image_tags"],
            linkTitle: post?["link_title"]
        )
    }
}
