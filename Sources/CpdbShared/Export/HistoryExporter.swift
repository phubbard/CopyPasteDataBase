import Foundation
import GRDB

/// Renders the live clipboard history to a portable document
/// (Markdown / CSV / HTML). Metadata + text only — flavor bytes and
/// thumbnails are not exported (a clipboard archive is a
/// reading/searching artifact, not a restore image).
///
/// Factored out of the `cpdb export` CLI command so the Preferences
/// "Export…" button and the CLI share one implementation. Only
/// depends on `Store` + GRDB, so it lives in CpdbShared and is
/// reachable from the app, the CLI, and (later) iOS.
public enum HistoryExporter {

    public enum Format: String, Sendable, CaseIterable {
        case md, csv, html

        public var fileExtension: String {
            switch self {
            case .md:   return "md"
            case .csv:  return "csv"
            case .html: return "html"
            }
        }
    }

    public struct Row: Sendable {
        public let id: Int64
        public let createdAt: Double
        public let capturedAt: Double
        public let kind: String
        public let title: String?
        public let textPreview: String?
        public let linkTitle: String?
        public let pinned: Bool
        public let evicted: Bool
        public let ocrText: String?
        public let imageTags: String?
        public let appName: String?
        public let deviceName: String?

        /// Best human-readable headline: link title > title >
        /// text preview > "(kind)". Mirrors the popup card's
        /// snippet logic so the export reads the way the app looks.
        var headline: String {
            if let lt = linkTitle, !lt.isEmpty { return lt }
            if let t = title, !t.isEmpty { return t }
            if let tp = textPreview, !tp.isEmpty { return tp }
            return "(\(kind))"
        }
    }

    /// Fetch + render in one call. `limit` caps newest-first;
    /// `includeEvicted` keeps body-evicted entries (metadata still
    /// present). Returns the rendered document string + the row
    /// count (for the caller's "exported N entries" confirmation).
    @discardableResult
    public static func export(
        from store: Store,
        format: Format,
        limit: Int = Int.max,
        includeEvicted: Bool = true
    ) throws -> (document: String, count: Int) {
        let rows = try fetch(from: store, limit: limit, includeEvicted: includeEvicted)
        let doc: String
        switch format {
        case .md:   doc = renderMarkdown(rows)
        case .csv:  doc = renderCSV(rows)
        case .html: doc = renderHTML(rows)
        }
        return (doc, rows.count)
    }

    public static func fetch(
        from store: Store,
        limit: Int = Int.max,
        includeEvicted: Bool = true
    ) throws -> [Row] {
        try store.dbQueue.read { db in
            var sql = """
                SELECT e.id, e.created_at, e.captured_at, e.kind, e.title,
                       e.text_preview, e.link_title, e.pinned, e.body_evicted_at,
                       e.ocr_text, e.image_tags,
                       a.name AS app_name, d.name AS device_name
                FROM entries e
                LEFT JOIN apps a ON a.id = e.source_app_id
                LEFT JOIN devices d ON d.id = e.source_device_id
                WHERE e.deleted_at IS NULL
            """
            if !includeEvicted {
                sql += " AND e.body_evicted_at IS NULL"
            }
            sql += " ORDER BY e.created_at DESC LIMIT ?"
            let limitArg = limit == Int.max ? Int64.max : Int64(limit)
            return try GRDB.Row.fetchAll(db, sql: sql, arguments: [limitArg]).map { r in
                Row(
                    id: r["id"],
                    createdAt: r["created_at"],
                    capturedAt: r["captured_at"],
                    kind: r["kind"],
                    title: r["title"],
                    textPreview: r["text_preview"],
                    linkTitle: r["link_title"],
                    pinned: (r["pinned"] as Int64? ?? 0) != 0,
                    evicted: (r["body_evicted_at"] as Double?) != nil,
                    ocrText: r["ocr_text"],
                    imageTags: r["image_tags"],
                    appName: r["app_name"],
                    deviceName: r["device_name"]
                )
            }
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func ts(_ epoch: Double) -> String {
        iso.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// Normalise embedded clipboard text to LF. Captured content
    /// routinely carries CRLF (Windows source apps) or lone CR
    /// (legacy Mac); our own separators are LF, so without this the
    /// exported file has mixed line endings and editors prompt to
    /// "fix" it. Apply to every field that originates from captured
    /// data (text_preview, ocr_text, link_title, image_tags, title,
    /// headline).
    private static func lf(_ s: String?) -> String {
        guard let s = s else { return "" }
        return s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Markdown (a paragraph per entry)

    public static func renderMarkdown(_ rows: [Row]) -> String {
        var out = "# cpdb clipboard export\n\n"
        out += "_\(rows.count) entries · generated \(ts(Date().timeIntervalSince1970))_\n\n"
        for r in rows {
            let pin = r.pinned ? "📌 " : ""
            out += "## \(pin)\(lf(r.headline))\n\n"
            var meta: [String] = ["**\(r.kind)**"]
            if let app = r.appName { meta.append(lf(app)) }
            if let dev = r.deviceName { meta.append(lf(dev)) }
            meta.append(ts(r.createdAt))
            if r.evicted { meta.append("_(body evicted)_") }
            out += meta.joined(separator: " · ") + "\n\n"
            if let tp = r.textPreview, !tp.isEmpty, lf(tp) != lf(r.headline) {
                out += "```\n\(lf(tp))\n```\n\n"
            }
            // Enrichment block — the metadata cpdb gleans that isn't
            // in the raw clipboard payload. Explicitly labelled so
            // it's obvious what was derived vs. captured. OCR is NOT
            // truncated — the whole point of exporting is to keep
            // the searchable text.
            if let lt = r.linkTitle, !lf(lt).isEmpty {
                out += "- **Fetched title:** \(lf(lt))\n"
            }
            if let tags = r.imageTags, !lf(tags).isEmpty {
                out += "- **Image tags:** \(lf(tags))\n"
            }
            if let ocr = r.ocrText, !lf(ocr).isEmpty {
                out += "\n**OCR text:**\n\n```\n\(lf(ocr))\n```\n"
            }
            out += "\n---\n\n"
        }
        return out
    }

    // MARK: - CSV (RFC 4180)

    public static func renderCSV(_ rows: [Row]) -> String {
        // Quote per RFC-4180 when needed; embedded newlines are
        // already LF-normalised by `lf()`, and a quoted field with
        // LF newlines is valid RFC-4180 (it permits CRLF or LF as
        // the in-field break; we keep the whole file LF for editor
        // sanity).
        func cell(_ s: String?) -> String {
            let v = lf(s)
            if v.contains(",") || v.contains("\"") || v.contains("\n") {
                return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return v
        }
        // link_title is now its own column (was only folded into
        // headline). image_tags + the FULL ocr_text are kept so the
        // export carries every enrichment field.
        var out = "id,kind,pinned,evicted,created_at,captured_at,source_app,device,headline,fetched_title,text_preview,ocr_text,image_tags\n"
        for r in rows {
            let cols = [
                String(r.id),
                r.kind,
                r.pinned ? "1" : "0",
                r.evicted ? "1" : "0",
                ts(r.createdAt),
                ts(r.capturedAt),
                cell(r.appName),
                cell(r.deviceName),
                cell(r.headline),
                cell(r.linkTitle),
                cell(r.textPreview),
                cell(r.ocrText),
                cell(r.imageTags),
            ]
            out += cols.joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: - HTML (self-contained, no external assets)

    public static func renderHTML(_ rows: [Row]) -> String {
        func esc(_ s: String?) -> String {
            lf(s)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var out = """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <title>cpdb clipboard export</title>
        <style>
          body { font: 15px/1.5 -apple-system, system-ui, sans-serif; max-width: 760px; margin: 2rem auto; padding: 0 1rem; color: #1a1a1a; }
          h1 { font-size: 1.4rem; }
          .meta { color: #666; font-size: 0.85rem; margin-bottom: 2rem; }
          .entry { border-bottom: 1px solid #e5e5e5; padding: 1rem 0; }
          .headline { font-weight: 600; font-size: 1.05rem; }
          .badges { color: #666; font-size: 0.8rem; margin: 0.25rem 0; }
          .badge { display: inline-block; background: #f0f0f0; border-radius: 4px; padding: 1px 6px; margin-right: 4px; }
          pre { background: #f7f7f7; border-radius: 6px; padding: 0.6rem; overflow-x: auto; font-size: 0.85rem; }
          .pin { color: #d08700; }
          .enrich { color: #444; font-size: 0.85rem; margin: 0.25rem 0; }
          .enrich b { color: #666; }
          @media (prefers-color-scheme: dark) {
            body { background:#1a1a1a; color:#e5e5e5; } pre,.badge{background:#2a2a2a;} .entry{border-color:#333;} .enrich,.enrich b{color:#aaa;}
          }
        </style></head><body>
        <h1>cpdb clipboard export</h1>
        <div class="meta">\(rows.count) entries · generated \(ts(Date().timeIntervalSince1970))</div>

        """
        for r in rows {
            out += "<div class=\"entry\">\n"
            let pin = r.pinned ? "<span class=\"pin\">📌</span> " : ""
            out += "  <div class=\"headline\">\(pin)\(esc(r.headline))</div>\n"
            var badges = "<span class=\"badge\">\(esc(r.kind))</span>"
            if let app = r.appName { badges += "<span class=\"badge\">\(esc(app))</span>" }
            if let dev = r.deviceName { badges += "<span class=\"badge\">\(esc(dev))</span>" }
            badges += "<span class=\"badge\">\(ts(r.createdAt))</span>"
            if r.evicted { badges += "<span class=\"badge\">body evicted</span>" }
            out += "  <div class=\"badges\">\(badges)</div>\n"
            if let tp = r.textPreview, !tp.isEmpty, lf(tp) != lf(r.headline) {
                out += "  <pre>\(esc(tp))</pre>\n"
            }
            // Enrichment — explicitly labelled, OCR untruncated.
            if let lt = r.linkTitle, !lf(lt).isEmpty {
                out += "  <div class=\"enrich\"><b>Fetched title:</b> \(esc(lt))</div>\n"
            }
            if let tags = r.imageTags, !lf(tags).isEmpty {
                out += "  <div class=\"enrich\"><b>Image tags:</b> \(esc(tags))</div>\n"
            }
            if let ocr = r.ocrText, !lf(ocr).isEmpty {
                out += "  <div class=\"enrich\"><b>OCR text:</b></div>\n  <pre>\(esc(ocr))</pre>\n"
            }
            out += "</div>\n"
        }
        out += "</body></html>\n"
        return out
    }
}
