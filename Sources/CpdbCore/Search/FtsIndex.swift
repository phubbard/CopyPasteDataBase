import Foundation
import GRDB

/// FTS5 index maintenance + querying.
///
/// The virtual table has five columns since v2:
///
/// - `title`      (column 0) — derived headline for every entry
/// - `text`       (column 1) — `text_preview` (plain text)
/// - `app_name`   (column 2) — joined from `apps.name`
/// - `ocr_text`   (column 3) — Vision OCR extract for image entries
/// - `image_tags` (column 4) — Vision classifier tags, comma-separated
///
/// We populate all five explicitly rather than wiring triggers from
/// `entries` / `apps` — the sources live in multiple tables and the
/// indexer path is centralised here anyway.
public enum FtsIndex {

    // MARK: - Indexing

    /// Insert or update the FTS row for an entry. Call after insert/update.
    public static func indexEntry(
        db: Database,
        entryId: Int64,
        title: String?,
        text: String?,
        appName: String?,
        ocrText: String? = nil,
        imageTags: String? = nil
    ) throws {
        try db.execute(
            sql: "DELETE FROM entries_fts WHERE rowid = ?",
            arguments: [entryId]
        )
        try db.execute(
            sql: """
                INSERT INTO entries_fts(rowid, title, text, app_name, ocr_text, image_tags)
                VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                entryId,
                title ?? "",
                text ?? "",
                appName ?? "",
                ocrText ?? "",
                imageTags ?? "",
            ]
        )
    }

    /// Remove an entry's FTS row. Called on hard delete.
    public static func removeEntry(db: Database, entryId: Int64) throws {
        try db.execute(
            sql: "DELETE FROM entries_fts WHERE rowid = ?",
            arguments: [entryId]
        )
    }

    // MARK: - Search

    /// Which columns the search should consider. Title and app name are
    /// always included — the toggles only gate the content-ish columns
    /// (`text`, `ocr_text`, `image_tags`) because those are what produce
    /// meaningful distinct match sources.
    public struct SearchScope: Sendable, Equatable, Codable {
        public var text: Bool
        public var ocr: Bool
        public var tags: Bool

        public init(text: Bool = true, ocr: Bool = true, tags: Bool = true) {
            self.text = text
            self.ocr = ocr
            self.tags = tags
        }

        public static let all = SearchScope(text: true, ocr: true, tags: true)

        /// True if at least one of the three toggles is on — the caller
        /// can short-circuit a "no results, all scope off" search.
        public var isEnabled: Bool { text || ocr || tags }
    }

    public enum MatchSource: String, Sendable, Codable {
        case text         // matched text_preview (or fell through from title/app_name)
        case ocr          // matched ocr_text
        case tag          // matched image_tags
        case multiple     // matched more than one of the above
    }

    public struct Hit: Sendable {
        public var entryId: Int64
        public var snippet: String
        public var source: MatchSource
    }

    /// Run a user query against the FTS5 index. Accepts plain-token input;
    /// we escape for FTS5 syntax ourselves.
    public static func search(
        db: Database,
        query: String,
        scope: SearchScope = .all,
        limit: Int = 50
    ) throws -> [Hit] {
        guard scope.isEnabled else { return [] }
        let tokens = escapeForFts5(query)
        // Build the column-scoped expression: `{col1 col2 ...}: tokens`.
        // FTS5 column filters take an entire match expression on the RHS,
        // so we combine all tokens once and apply the filter out front.
        var cols = ["title", "app_name"]
        if scope.text { cols.append("text") }
        if scope.ocr  { cols.append("ocr_text") }
        if scope.tags { cols.append("image_tags") }
        let scoped = "{" + cols.joined(separator: " ") + "} : " + tokens

        // Sentinel markers for the per-column highlight() calls — NUL and
        // SOH can't legitimately appear in stored text, so we can detect
        // them in post-processing to attribute match sources.
        let startMark = "\u{1}"
        let endMark   = "\u{2}"

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT rowid,
                       snippet(entries_fts, -1, '[', ']', '…', 32) AS snip,
                       highlight(entries_fts, 1, ?, ?) AS t_hl,
                       highlight(entries_fts, 3, ?, ?) AS o_hl,
                       highlight(entries_fts, 4, ?, ?) AS g_hl
                FROM entries_fts
                WHERE entries_fts MATCH ?
                ORDER BY bm25(entries_fts)
                LIMIT ?
            """,
            arguments: [
                startMark, endMark,   // column 1 (text)
                startMark, endMark,   // column 3 (ocr_text)
                startMark, endMark,   // column 4 (image_tags)
                scoped,
                limit,
            ]
        )

        return rows.map { row in
            let entryId: Int64 = row["rowid"]
            let snippet: String = row["snip"] ?? ""
            let tHit = ((row["t_hl"] as String?) ?? "").contains(startMark)
            let oHit = ((row["o_hl"] as String?) ?? "").contains(startMark)
            let gHit = ((row["g_hl"] as String?) ?? "").contains(startMark)
            let hits = [tHit, oHit, gHit].filter { $0 }.count
            let source: MatchSource
            switch (hits, tHit, oHit, gHit) {
            case (0, _, _, _): source = .text   // fell through via title/app_name
            case (1, true, _, _): source = .text
            case (1, _, true, _): source = .ocr
            case (1, _, _, true): source = .tag
            default: source = .multiple
            }
            return Hit(entryId: entryId, snippet: snippet, source: source)
        }
    }

    /// Quote user input so FTS5 treats it as literal terms. Users who want
    /// advanced MATCH syntax can route through a future raw-query path.
    static func escapeForFts5(_ query: String) -> String {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        if tokens.isEmpty { return "\"\"" }
        return tokens.map { token in
            let doubled = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(doubled)\""
        }.joined(separator: " ")
    }
}
