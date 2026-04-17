import Foundation
import GRDB

/// FTS5 index maintenance + querying.
///
/// We use an external-content virtual table that we own explicitly (rather
/// than auto-populating triggers). The reason: `text_preview`, title, and app
/// name come from three different rows in our relational schema, and doing
/// this in Swift is clearer than juggling triggers.
public enum FtsIndex {
    /// Insert or update the FTS row for an entry. Call after insert/update of
    /// `entries`.
    public static func indexEntry(
        db: Database,
        entryId: Int64,
        title: String?,
        text: String?,
        appName: String?
    ) throws {
        // FTS5 external-content tables use the `rowid` as the join key. We use
        // the entry's own id directly — they're both INTEGER PKs.
        try db.execute(
            sql: "DELETE FROM entries_fts WHERE rowid = ?",
            arguments: [entryId]
        )
        try db.execute(
            sql: """
                INSERT INTO entries_fts(rowid, title, text, app_name)
                VALUES (?, ?, ?, ?)
            """,
            arguments: [entryId, title ?? "", text ?? "", appName ?? ""]
        )
    }

    /// Remove an entry's FTS row. Called on hard delete.
    public static func removeEntry(db: Database, entryId: Int64) throws {
        try db.execute(
            sql: "DELETE FROM entries_fts WHERE rowid = ?",
            arguments: [entryId]
        )
    }

    public struct Hit: Sendable {
        public var entryId: Int64
        public var snippet: String   // FTS5 snippet() output
    }

    /// Run a user query against the FTS5 index. Accepts raw FTS5 syntax.
    public static func search(
        db: Database,
        query: String,
        limit: Int = 50
    ) throws -> [Hit] {
        let escaped = escapeForFts5(query)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT rowid, snippet(entries_fts, 1, '[', ']', '…', 32) AS snip
                FROM entries_fts
                WHERE entries_fts MATCH ?
                ORDER BY bm25(entries_fts)
                LIMIT ?
            """,
            arguments: [escaped, limit]
        )
        return rows.map { Hit(entryId: $0["rowid"], snippet: $0["snip"] ?? "") }
    }

    /// Quote user input so FTS5 treats it as literal terms, not as its
    /// own query DSL. Users wanting advanced MATCH syntax can pass a raw
    /// query with `--raw` (future flag).
    static func escapeForFts5(_ query: String) -> String {
        // Wrap each whitespace-separated token in double-quotes and escape any
        // embedded quotes by doubling them.
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        if tokens.isEmpty { return "\"\"" }
        return tokens.map { token in
            let doubled = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(doubled)\""
        }.joined(separator: " ")
    }
}
