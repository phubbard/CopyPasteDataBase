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

    public struct EntryRow: Sendable, Equatable {
        public var entry: Entry
        public var appName: String?
        public var appBundleId: String?
        public var deviceName: String?

        // Swift's synthesized memberwise init is only `internal` even
        // for an all-public struct, so cross-module callers (e.g.
        // CpdbApp's App Intents, which build an `EntryRow` from a bare
        // `Entry` with no joined app/device columns) need this
        // explicit one.
        public init(entry: Entry, appName: String? = nil, appBundleId: String? = nil, deviceName: String? = nil) {
            self.entry = entry
            self.appName = appName
            self.appBundleId = appBundleId
            self.deviceName = deviceName
        }
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
                SELECT e.*, a.name AS app_name_, a.bundle_id AS app_bundle_id_, d.name AS device_name_
                FROM entries e
                LEFT JOIN apps a ON a.id = e.source_app_id
                LEFT JOIN devices d ON d.id = e.source_device_id
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
                    appBundleId: row["app_bundle_id_"],
                    deviceName: row["device_name_"]
                )
            }
        }
    }

    /// Entries captured within ±`windowSeconds` of `anchorCapturedAt`,
    /// ordered chronologically (oldest first inside the window — so
    /// the strip reads left-to-right as time flowing forward).
    /// Powers the popup's time-pivot mode (⌘T on a selected card).
    ///
    /// The anchor is `captured_at`, not `created_at` — see
    /// `docs/parity.md` § Time-pivot for the rationale: `created_at`
    /// re-bumps on dedup, so "neighbors of this thing in time"
    /// should pivot on the original capture moment, not the most
    /// recent re-paste. CloudKit-pulled entries preserve the
    /// originating device's `captured_at`, so cross-device pivots
    /// still make sense.
    ///
    /// No FTS overlay — caller surfaces a different mode for that.
    /// No kind filter — neighbors-in-time is intentionally
    /// kind-agnostic (you want to see screenshots, links, and text
    /// you copied near the anchor moment together).
    ///
    /// Includes tombstoned-but-recent entries? No — `deleted_at IS
    /// NULL`. Pinned entries: not bumped to top; chronological
    /// ordering only. (Pin status still surfaced on the card.)
    public func neighbors(
        ofCapturedAt anchorCapturedAt: Double,
        windowSeconds: TimeInterval,
        limit: Int = 500
    ) throws -> [EntryRow] {
        let lo = anchorCapturedAt - windowSeconds
        let hi = anchorCapturedAt + windowSeconds
        return try store.dbQueue.read { db in
            let sql = """
                SELECT e.*, a.name AS app_name_, a.bundle_id AS app_bundle_id_, d.name AS device_name_
                FROM entries e
                LEFT JOIN apps a ON a.id = e.source_app_id
                LEFT JOIN devices d ON d.id = e.source_device_id
                WHERE e.deleted_at IS NULL
                  AND e.captured_at BETWEEN ? AND ?
                ORDER BY e.captured_at ASC
                LIMIT ?
            """
            return try Row.fetchAll(db, sql: sql, arguments: [lo, hi, limit]).map { row in
                let entry = try Entry(row: row)
                return EntryRow(
                    entry: entry,
                    appName: row["app_name_"],
                    appBundleId: row["app_bundle_id_"],
                    deviceName: row["device_name_"]
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
                        SELECT e.*, a.name AS app_name_, a.bundle_id AS app_bundle_id_, d.name AS device_name_
                        FROM entries e
                        LEFT JOIN apps a ON a.id = e.source_app_id
                        LEFT JOIN devices d ON d.id = e.source_device_id
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
                    row: EntryRow(
                        entry: entry,
                        appName: row["app_name_"],
                        appBundleId: row["app_bundle_id_"],
                        deviceName: row["device_name_"]
                    ),
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
            // The non-force WHERE clause has two extra terms beyond
            // "never fetched":
            //   - link_retry_after IS NULL OR link_retry_after < now
            //     respects the v9 exponential-backoff schedule. Rows
            //     in their cool-off period don't enter the queue.
            //   - link_retry_count < maxRetries gives up on rows
            //     that have failed too many times in a row, freeing
            //     queue capacity for newer captures.
            let now = Date().timeIntervalSince1970
            let whereClause: String
            var args: StatementArguments = []
            if force {
                whereClause = "kind = 'link' AND deleted_at IS NULL"
            } else {
                whereClause = """
                    kind = 'link' AND deleted_at IS NULL AND link_fetched_at IS NULL
                      AND (link_retry_after IS NULL OR link_retry_after < ?)
                      AND link_retry_count < ?
                """
                args += [now, EntryRepository.linkBackfillMaxRetries]
            }
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
                arguments: args + [limit]
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
    /// Maximum consecutive transient-failure attempts before the
    /// backfill gives up on a row and stamps it
    /// fetched-with-empty. After this many tries, the row falls out
    /// of the retry queue; the user can still resurrect it with the
    /// "Retry empties" button or `cpdb fetch-link-titles --retry-empty`.
    public static let linkBackfillMaxRetries: Int = 6

    public func setLinkMetadata(entryId: Int64, title: String?) throws {
        let now = Date().timeIntervalSince1970
        try store.dbQueue.write { db in
            // Resetting retry_count + retry_after is part of the
            // "settled" semantics: a successful fetch (or a permanent
            // failure that calls this with title=nil) clears the
            // backoff state so the row is in a consistent terminal
            // state. Future user-driven retries (clear link_fetched_at)
            // start the count fresh.
            try db.execute(
                sql: """
                    UPDATE entries
                    SET link_title = ?, link_fetched_at = ?,
                        link_retry_count = 0, link_retry_after = NULL
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
    /// Record a transient failure for a link backfill attempt.
    /// Increments `link_retry_count` and schedules
    /// `link_retry_after` according to an exponential-backoff
    /// curve (1 min, 2, 4, 8, 16, 32 — capped at 60 min).
    /// `link_fetched_at` stays NULL so the row remains a candidate;
    /// the WHERE clause in `linksNeedingMetadata` enforces both the
    /// retry-after gate and the max-retries cap.
    ///
    /// Returns the new retry_count so the caller can log progress.
    @discardableResult
    public func recordLinkFetchTransientFailure(entryId: Int64) throws -> Int {
        let now = Date().timeIntervalSince1970
        return try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE entries
                    SET link_retry_count = link_retry_count + 1,
                        link_retry_after = ? + (60.0 * MIN(60, 1 << link_retry_count))
                    WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [now, entryId]
            )
            return try Int.fetchOne(
                db,
                sql: "SELECT link_retry_count FROM entries WHERE id = ?",
                arguments: [entryId]
            ) ?? 0
        }
    }

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
            // Also reset the retry state. A user-driven "refetch"
            // means "try again from scratch" — preserving a stale
            // retry_count would mean an old hammered URL gets
            // queued, fails, and gives up immediately.
            try db.execute(
                sql: """
                    UPDATE entries
                    SET link_fetched_at = NULL,
                        link_retry_count = 0, link_retry_after = NULL
                    WHERE kind = 'link' AND deleted_at IS NULL
                """
            )
        }
    }

    /// Targeted variant of `resetLinkFetchedAt`: only clears
    /// sentinels for rows that came back empty (fetched_at IS NOT
    /// NULL but link_title is null/empty). Use this to retry the
    /// failed/rate-limited/genuinely-empty subset without re-hitting
    /// the network for the thousands of links that already have
    /// titles. Returns the number of rows cleared so the UI can show
    /// a meaningful confirmation.
    @discardableResult
    public func resetLinkFetchedAtForEmptyTitles() throws -> Int {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE entries
                    SET link_fetched_at = NULL,
                        link_retry_count = 0, link_retry_after = NULL
                    WHERE kind = 'link' AND deleted_at IS NULL
                      AND link_fetched_at IS NOT NULL
                      AND (link_title IS NULL OR link_title = '')
                """
            )
            return db.changesCount
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
                    SET pinned = ?, modified_at = ?
                    WHERE id = ? AND deleted_at IS NULL AND pinned != ?
                """,
                arguments: [pinned ? 1 : 0, now, id, pinned ? 1 : 0]
            )
            // Only push if we actually changed state.
            if db.changesCount > 0 {
                try PushQueue.enqueue(entryId: id, in: db, now: now)
            }
        }
    }

    /// Current pin state of a live entry (for undo bookkeeping). Returns
    /// nil if the entry is missing or tombstoned.
    public func pinnedState(id: Int64) throws -> Bool? {
        try store.dbQueue.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT pinned FROM entries WHERE id = ? AND deleted_at IS NULL", arguments: [id])
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
                    SET deleted_at = ?, modified_at = ?
                    WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [now, now, id]
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

    /// Undo a tombstone — clear `deleted_at`, re-index FTS, bump
    /// `modified_at` (newer than the delete, so the un-delete wins the
    /// last-writer-wins race on sibling devices), and re-enqueue for
    /// push. Idempotent: restoring a live row no-ops. The blobs were
    /// never removed (gc only touches tombstoned rows), so nothing has
    /// to be re-fetched.
    public func restore(id: Int64) throws {
        let now = Date().timeIntervalSince1970
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE entries SET deleted_at = NULL, modified_at = ? WHERE id = ? AND deleted_at IS NOT NULL",
                arguments: [now, id]
            )
            guard db.changesCount > 0 else { return }
            // Re-index FTS from the row's current fields.
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT e.title, e.text_preview, e.ocr_text, e.image_tags, e.link_title,
                           a.name AS app_name
                    FROM entries e LEFT JOIN apps a ON a.id = e.source_app_id
                    WHERE e.id = ?
                    """,
                arguments: [id]
            ) {
                try FtsIndex.indexEntry(
                    db: db, entryId: id,
                    title: row["title"], text: row["text_preview"], appName: row["app_name"],
                    ocrText: row["ocr_text"], imageTags: row["image_tags"], linkTitle: row["link_title"])
            }
            try PushQueue.enqueue(entryId: id, in: db, now: now)
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

    // MARK: - Image analysis sweep

    /// Live, still-embodied image entries that have never been through
    /// `ImageIndexer.analyzeAndStore`, newest first. Used by
    /// `ImageAnalysisSweeper` (the Mac daemon's periodic + capture-wake
    /// self-heal) to find work: pull-synced images (analysis only ever
    /// runs on the *capturing* device — see `ImageIndexer`'s doc
    /// comment) and any local capture whose capture-time analysis Task
    /// never finished (app quit mid-Vision-call, etc).
    ///
    /// `body_evicted_at IS NULL` excludes entries whose flavor bytes
    /// were already discarded by an eviction policy — there's nothing
    /// left to analyze, and they'd otherwise wedge the front of every
    /// future candidate batch forever.
    public func imagesNeedingAnalysis(limit: Int) throws -> [Int64] {
        try store.dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT id FROM entries
                    WHERE kind = 'image' AND deleted_at IS NULL
                      AND body_evicted_at IS NULL AND analyzed_at IS NULL
                    ORDER BY created_at DESC
                    LIMIT ?
                """,
                arguments: [limit]
            )
        }
    }

    /// True iff a live entry still has `analyzed_at IS NULL`. The
    /// sweeper re-checks this immediately before doing the (expensive)
    /// Vision work for each candidate, since the candidate list was
    /// built moments earlier and a sibling Mac's result — or this
    /// Mac's own capture-time analysis — may have arrived via CloudKit
    /// pull in the meantime. Returns false for a missing/tombstoned
    /// entry so the sweeper skips it rather than analyzing a row
    /// that's gone.
    public func isImageUnanalyzed(entryId: Int64) throws -> Bool {
        try store.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT analyzed_at FROM entries WHERE id = ? AND deleted_at IS NULL",
                arguments: [entryId]
            ) else {
                return false
            }
            let analyzedAt: Double? = row["analyzed_at"]
            return analyzedAt == nil
        }
    }

    /// Load the bytes of an entry's best image flavor (inline or
    /// spilled to the blob store), or nil if it has none. Priority
    /// order mirrors `PasteboardSnapshot.imageFlavorData` so the
    /// sweeper analyzes the same bytes capture-time analysis would
    /// have used.
    ///
    /// The SQLite read only fetches the (small) inline bytes or blob
    /// key; the potentially-multi-megabyte blob-store file read happens
    /// AFTER the `dbQueue.read` closure returns. `Store` uses a single
    /// serialized `DatabaseQueue` (see `Database.swift`), so holding
    /// that closure open across a slow disk read would block every
    /// other read/write on the process — including capture and paste —
    /// for the duration of the read.
    public func loadImageFlavorData(entryId: Int64, blobs: BlobStore) throws -> Data? {
        let flavorRow: (data: Data?, blobKey: String?)? = try store.dbQueue.read { db in
            for uti in Self.imageUtiPriority {
                if let row = try Row.fetchOne(
                    db,
                    sql: "SELECT data, blob_key FROM entry_flavors WHERE entry_id = ? AND uti = ?",
                    arguments: [entryId, uti]
                ) {
                    return (row["data"] as Data?, row["blob_key"] as String?)
                }
            }
            return nil
        }
        guard let flavorRow else { return nil }
        return try blobs.load(inline: flavorRow.data, blobKey: flavorRow.blobKey)
    }

    private static let imageUtiPriority = [
        "public.png",
        "public.jpeg",
        "public.tiff",
        "public.heic",
        "public.image",
    ]

    // MARK: - Semantic enrichment (v12)

    /// A stored embedding vector for one entry, exactly as persisted in
    /// `entry_embeddings`. `vector` is `dims` × Float32, little-endian,
    /// L2-normalized.
    public struct EmbeddingRow: Sendable, Equatable {
        public var entryId: Int64
        public var modelId: String
        public var revision: Int64
        public var dims: Int64
        public var vector: Data
        public var embeddedAt: Double

        public init(entryId: Int64, modelId: String, revision: Int64, dims: Int64, vector: Data, embeddedAt: Double) {
            self.entryId = entryId
            self.modelId = modelId
            self.revision = revision
            self.dims = dims
            self.vector = vector
            self.embeddedAt = embeddedAt
        }
    }

    /// Upsert an entry's embedding row. Unlike every other writer in this
    /// file, this takes the caller's `Database` directly instead of
    /// opening its own `store.dbQueue.write` — it needs to compose inside
    /// an existing transaction, most importantly `CloudKitSyncer.upsert`,
    /// which persists the pulled entry row and its embedding atomically.
    /// Mirrors `PushQueue`'s `in db:` convention for the same reason.
    ///
    /// Deliberately does NOT enqueue a CloudKit push and does NOT touch
    /// `entries.modified_at` — this is enrichment, not a mutable-state
    /// change (mirrors `setLinkMetadata`'s doc comment on that point).
    /// Skipping the push-enqueue also matters for the pull path
    /// specifically: `CloudKitSyncer.upsert` calls this to apply an
    /// embedding it just pulled, and re-enqueueing that unchanged state
    /// would push it right back for no reason. A future local writer
    /// (e.g. a background embedder) that wants its result synced should
    /// call `PushQueue.enqueue` itself in the same transaction, the same
    /// way callers compose with `PushQueue` elsewhere.
    public static func saveEmbedding(
        entryId: Int64,
        modelId: String,
        revision: Int64,
        dims: Int64,
        vector: Data,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO entry_embeddings (entry_id, model_id, revision, dims, vector, embedded_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(entry_id) DO UPDATE SET
                    model_id    = excluded.model_id,
                    revision    = excluded.revision,
                    dims        = excluded.dims,
                    vector      = excluded.vector,
                    embedded_at = excluded.embedded_at
            """,
            arguments: [entryId, modelId, revision, dims, vector, Date().timeIntervalSince1970]
        )
    }

    /// The current embedding row for an entry, or nil if it hasn't been
    /// embedded yet.
    public func embedding(entryId: Int64) throws -> EmbeddingRow? {
        try store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT entry_id, model_id, revision, dims, vector, embedded_at
                    FROM entry_embeddings WHERE entry_id = ?
                """,
                arguments: [entryId]
            ).map { row in
                EmbeddingRow(
                    entryId: row["entry_id"],
                    modelId: row["model_id"],
                    revision: row["revision"],
                    dims: row["dims"],
                    vector: row["vector"],
                    embeddedAt: row["embedded_at"]
                )
            }
        }
    }

    /// Live text/link entries that need a (re-)embed: either they have no
    /// `entry_embeddings` row yet, or their existing row doesn't match
    /// the caller's current `modelId`/`revision` (a model upgrade or a
    /// revision bump). Newest-first, mirroring `imagesNeedingAnalysis` —
    /// the background embedder works through recent captures first.
    public func entriesNeedingEmbedding(modelId: String, revision: Int64, limit: Int) throws -> [Int64] {
        try store.dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT e.id FROM entries e
                    LEFT JOIN entry_embeddings v ON v.entry_id = e.id
                    WHERE e.kind IN ('text', 'link') AND e.deleted_at IS NULL
                      AND (v.entry_id IS NULL OR v.model_id != ? OR v.revision != ?)
                    ORDER BY e.created_at DESC
                    LIMIT ?
                """,
                arguments: [modelId, revision, limit]
            )
        }
    }

    /// Persist the data-chip scan result for an entry. `json` is the
    /// serialized chip array; pass nil for "not yet scanned" (the
    /// column's own default) — a scan that found nothing should pass an
    /// explicit `"[]"` so it's distinguishable from never having run.
    /// Enrichment, not a mutable-state change: does not bump
    /// `modified_at` (mirrors `setLinkMetadata`). Enqueues for CloudKit
    /// push so siblings adopt the scan result instead of re-scanning.
    public func setChips(entryId: Int64, json: String?) throws {
        let now = Date().timeIntervalSince1970
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE entries SET chips_json = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [json, entryId]
            )
            if db.changesCount > 0 {
                try PushQueue.enqueue(entryId: entryId, in: db, now: now)
            }
        }
    }

    /// Persist Foundation-Models-generated title + summary for an entry.
    /// Enrichment, not a mutable-state change: does not bump
    /// `modified_at` (mirrors `setLinkMetadata`). Enqueues for CloudKit
    /// push so siblings adopt the result instead of re-summarizing.
    public func setAITitleSummary(entryId: Int64, title: String?, summary: String?) throws {
        let now = Date().timeIntervalSince1970
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE entries SET ai_title = ?, ai_summary = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [title, summary, entryId]
            )
            if db.changesCount > 0 {
                try PushQueue.enqueue(entryId: entryId, in: db, now: now)
            }
        }
    }
}
