import Foundation
import GRDB

/// High-level fetches used by both CLI and app.
///
/// Everything here is a thin wrapper around `store.dbQueue.read`, but
/// putting them in one place keeps the SQL out of command/UI code and makes
/// it easier to add `ValueObservation`-based streams later.
public struct EntryRepository {
    public let store: Store

    public init(store: Store) {
        self.store = store
    }

    public struct EntryRow: Sendable {
        public var entry: Entry
        public var appName: String?
        public var appBundleId: String?
    }

    /// N most recent live entries, most recent first. Optionally filtered
    /// by one kind (legacy single-kind path, kept for callers like the
    /// CLI) or by a set of kinds (used by the popup's chip filter).
    /// `kinds` takes precedence when both are supplied. An empty set is
    /// treated the same as nil — "match any kind" — so callers don't
    /// accidentally hide everything by clearing the UI.
    public func recent(
        limit: Int,
        kind: EntryKind? = nil,
        kinds: Set<EntryKind>? = nil
    ) throws -> [EntryRow] {
        try store.dbQueue.read { db in
            var sql = """
                SELECT e.*, a.name AS app_name_, a.bundle_id AS app_bundle_id_
                FROM entries e
                LEFT JOIN apps a ON a.id = e.source_app_id
                WHERE e.deleted_at IS NULL
            """
            var args: StatementArguments = []
            if let kinds = kinds,
               !kinds.isEmpty,
               kinds.count < EntryKind.allCases.count
            {
                let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
                sql += " AND e.kind IN (\(placeholders))"
                for k in kinds { args += [k.rawValue] }
            } else if let kind = kind {
                sql += " AND e.kind = ?"
                args += [kind.rawValue]
            }
            // Pinned-first ordering: SQLite ORDER BY interprets boolean
            // expressions as 0/1, so `pinned DESC` puts pinned (1)
            // ahead of unpinned (0). Within each group, newest first.
            sql += " ORDER BY e.pinned DESC, e.created_at DESC LIMIT ?"
            args += [limit]
            return try Row.fetchAll(db, sql: sql, arguments: args).map { row in
                let entry = try Entry(row: row)
                return EntryRow(
                    entry: entry,
                    appName: row["app_name_"],
                    appBundleId: row["app_bundle_id_"]
                )
            }
        }
    }

    /// A search hit with the fully-hydrated entry row + FTS snippet + the
    /// source column that actually matched (text / OCR / tag).
    public struct SearchHit: Sendable {
        public var row: EntryRow
        public var snippet: String
        public var source: FtsIndex.MatchSource
    }

    /// FTS5 search that returns fully-hydrated rows (not just hits).
    /// Preserves BM25 rank order and joins through to the live entry row.
    public func search(
        query: String,
        scope: FtsIndex.SearchScope = .all,
        kinds: Set<EntryKind>? = nil,
        limit: Int
    ) throws -> [SearchHit] {
        try store.dbQueue.read { db in
            // Fetch more than we need when kind-filtering, since post-
            // filter may discard rows. Cheap — FTS5 hits are tiny.
            let fetchLimit = (kinds?.isEmpty == false && kinds!.count < EntryKind.allCases.count)
                ? limit * 3
                : limit
            let hits = try FtsIndex.search(db: db, query: query, scope: scope, limit: fetchLimit)
            guard !hits.isEmpty else { return [] }
            var results: [SearchHit] = []
            results.reserveCapacity(hits.count)
            for hit in hits {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT e.*, a.name AS app_name_, a.bundle_id AS app_bundle_id_
                        FROM entries e
                        LEFT JOIN apps a ON a.id = e.source_app_id
                        WHERE e.id = ? AND e.deleted_at IS NULL
                    """,
                    arguments: [hit.entryId]
                ) else { continue }
                let entry = try Entry(row: row)
                // Apply the kind filter post-hoc — FTS5 doesn't carry
                // e.kind, and joining back just to filter would be
                // wasteful for the common case (no filter).
                if let kinds = kinds,
                   !kinds.isEmpty,
                   kinds.count < EntryKind.allCases.count,
                   !kinds.contains(entry.kind)
                {
                    continue
                }
                results.append(SearchHit(
                    row: EntryRow(entry: entry, appName: row["app_name_"], appBundleId: row["app_bundle_id_"]),
                    snippet: hit.snippet,
                    source: hit.source
                ))
                if results.count >= limit { break }
            }
            return results
        }
    }

    /// Fetch one entry by id (for detail views or restore).
    public func fetch(id: Int64) throws -> Entry? {
        try store.dbQueue.read { db in
            try Entry.fetchOne(db, key: id)
        }
    }

    /// One row from the link-metadata backfill query: just enough
    /// to drive a fetch (the URL string + the local id we need to
    /// write back to).
    public struct LinkBackfillRow: Sendable {
        public let entryId: Int64
        public let url: String
    }

    /// Live link-kind entries that haven't had their metadata
    /// fetched yet (or that the user explicitly wants retried).
    /// Used by the daemon's periodic backfill task and the
    /// `cpdb fetch-link-titles` CLI.
    ///
    /// `force = true` includes already-fetched rows — used by the
    /// "Refetch link titles" Preferences button after a user
    /// returns from being offline.
    public func linksNeedingMetadata(limit: Int = 200, force: Bool = false) throws -> [LinkBackfillRow] {
        try store.dbQueue.read { db in
            let whereClause = force
                ? "kind = 'link' AND deleted_at IS NULL"
                : "kind = 'link' AND deleted_at IS NULL AND link_fetched_at IS NULL"
            // The URL-prefix check used to live in the post-filter
            // below, but that meant rows like `mailto:foo@bar` would
            // pass the SQL query, get dropped by the swift filter,
            // and then sit at the top of `created_at DESC` forever
            // because we never marked them fetched. By pushing the
            // prefix filter into SQL we skip them at query time
            // instead — they stay un-fetched in the DB but never
            // crowd out real http(s) candidates from the batch.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, COALESCE(text_preview, title) AS url
                    FROM entries
                    WHERE \(whereClause)
                      AND COALESCE(text_preview, title) IS NOT NULL
                      AND (
                          COALESCE(text_preview, title) LIKE 'http://%'
                       OR COALESCE(text_preview, title) LIKE 'https://%'
                      )
                    ORDER BY created_at DESC
                    LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { row in
                let id: Int64 = row["id"]
                let raw: String? = row["url"]
                guard let raw = raw,
                      let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else {
                    return nil
                }
                return LinkBackfillRow(entryId: id, url: url.absoluteString)
            }
        }
    }

    /// Persist a fetched (or attempted-and-failed) link title.
    /// Always sets `link_fetched_at = now()` so the row stops
    /// showing up in future `linksNeedingMetadata` queries — even
    /// when the title is nil. The companion FTS row is updated so
    /// search picks up the new text immediately.
    /// Enqueues for CloudKit push so siblings learn the title and
    /// don't re-fetch.
    public func setLinkMetadata(entryId: Int64, title: String?) throws {
        let now = Date().timeIntervalSince1970
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE entries
                    SET link_title = ?, link_fetched_at = ?
                    WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [title, now, entryId]
            )
            // Re-index FTS so the new title is searchable. Pull
            // current scalar columns rather than risk a stale read.
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT title, text_preview, ocr_text, image_tags
                    FROM entries WHERE id = ?
                """,
                arguments: [entryId]
            ) {
                let appName: String? = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT a.name FROM entries e
                        LEFT JOIN apps a ON a.id = e.source_app_id
                        WHERE e.id = ?
                    """,
                    arguments: [entryId]
                )?["name"] as String?
                try FtsIndex.indexEntry(
                    db: db,
                    entryId: entryId,
                    title: row["title"] as String?,
                    text: row["text_preview"] as String?,
                    appName: appName,
                    ocrText: row["ocr_text"] as String?,
                    imageTags: row["image_tags"] as String?,
                    linkTitle: title
                )
            }
            try PushQueue.enqueue(entryId: entryId, in: db, now: now)
        }
    }

    /// Persist preview thumbnails for a link entry. Stored in the
    /// same `previews` table the image-kind path uses, so the UI
    /// rendering layer doesn't need a separate code path —
    /// LinkCard just queries `previews.thumb_small/thumb_large`
    /// like ImageCard does, and CloudKit syncs the bytes via the
    /// existing thumbSmall/thumbLarge CKAsset fields.
    ///
    /// Idempotent: re-running with the same entry id replaces the
    /// existing previews row.
    public func setLinkPreviewThumbnails(
        entryId: Int64,
        small: Data?,
        large: Data?
    ) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO previews (entry_id, thumb_small, thumb_large)
                    VALUES (?, ?, ?)
                    ON CONFLICT (entry_id) DO UPDATE SET
                        thumb_small = excluded.thumb_small,
                        thumb_large = excluded.thumb_large
                """,
                arguments: [entryId, small, large]
            )
            // The link_title push enqueue (if present) already covers
            // CloudKit propagation — the syncer reads thumbnail bytes
            // from the previews table when building the entry record.
            // Re-enqueueing here would be redundant, but cheap; do it
            // so a thumbnail-only update (no title fetch) still pushes.
            try PushQueue.enqueue(entryId: entryId, in: db, now: Date().timeIntervalSince1970)
        }
    }

    /// Wipe link_fetched_at sentinels so the next backfill retries
    /// every link. Used by the Preferences "Refetch link titles"
    /// button. Doesn't touch existing link_title values — those
    /// stay until overwritten by the next successful fetch, which
    /// avoids a temporary "blank cards" period during the retry.
    public func resetLinkFetchedAt() throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE entries
                    SET link_fetched_at = NULL
                    WHERE kind = 'link' AND deleted_at IS NULL
                """
            )
        }
    }

    /// Toggle (or explicitly set) the pinned state of a single
    /// entry. Pinned entries skip future eviction policies and float
    /// to the top of the popup. Idempotent — pinning an already-
    /// pinned row no-ops. Enqueues for CloudKit push so the pin
    /// state propagates across devices.
    public func setPinned(id: Int64, pinned: Bool) throws {
        let now = Date().timeIntervalSince1970
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE entries
                    SET pinned = ?
                    WHERE id = ? AND deleted_at IS NULL AND pinned != ?
                """,
                arguments: [pinned ? 1 : 0, id, pinned ? 1 : 0]
            )
            // Only push if we actually changed state.
            if db.changesCount > 0 {
                try PushQueue.enqueue(entryId: id, in: db, now: now)
            }
        }
    }

    /// Tombstone a single entry (user-initiated delete). Sets
    /// `deleted_at` on the row, removes the FTS shadow, and enqueues
    /// for CloudKit push so the tombstone propagates to iOS and
    /// sibling Macs. Idempotent — tombstoning an already-tombstoned
    /// row no-ops. Blob cleanup is handled by `cpdb gc` out of band.
    public func tombstone(id: Int64) throws {
        let now = Date().timeIntervalSince1970
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE entries
                    SET deleted_at = ?
                    WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [now, id]
            )
            // db.execute returns Void; row count comes from the
            // separate changesCount property. Skip the FTS + push
            // work when the UPDATE was a no-op (already tombstoned).
            if db.changesCount > 0 {
                // Remove from FTS so the deleted row stops showing
                // up in search results. The entries row itself stays
                // (with deleted_at set) until `cpdb gc` clears it.
                try db.execute(
                    sql: "DELETE FROM entries_fts WHERE rowid = ?",
                    arguments: [id]
                )
                try PushQueue.enqueue(entryId: id, in: db, now: now)
            }
        }
    }

    /// Total live entry count — used by the popup header and stats.
    public func totalLiveCount() throws -> Int {
        try store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL"
            ) ?? 0
        }
    }
}
