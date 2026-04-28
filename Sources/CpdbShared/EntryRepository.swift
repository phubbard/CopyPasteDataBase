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
            sql += " ORDER BY e.created_at DESC LIMIT ?"
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
