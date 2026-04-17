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

    /// N most recent live entries, most recent first. Optionally filtered by
    /// kind.
    public func recent(limit: Int, kind: EntryKind? = nil) throws -> [EntryRow] {
        try store.dbQueue.read { db in
            var sql = """
                SELECT e.*, a.name AS app_name_, a.bundle_id AS app_bundle_id_
                FROM entries e
                LEFT JOIN apps a ON a.id = e.source_app_id
                WHERE e.deleted_at IS NULL
            """
            var args: StatementArguments = []
            if let kind = kind {
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
        limit: Int
    ) throws -> [SearchHit] {
        try store.dbQueue.read { db in
            let hits = try FtsIndex.search(db: db, query: query, scope: scope, limit: limit)
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
                results.append(SearchHit(
                    row: EntryRow(entry: entry, appName: row["app_name_"], appBundleId: row["app_bundle_id_"]),
                    snippet: hit.snippet,
                    source: hit.source
                ))
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
