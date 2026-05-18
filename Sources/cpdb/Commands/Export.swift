#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import GRDB
import Foundation

/// `cpdb export --format {md,csv,html}` — dump the live clipboard
/// history to a portable document. Metadata + text only; flavor
/// bytes and thumbnails are not exported (a clipboard archive is
/// a reading/searching artifact, not a restore image — use
/// CloudKit / the relay for that).
///
/// Ordering is newest-first by `created_at`, matching the popup.
/// Pinned state, source app, device, and timestamps are surfaced
/// in every format.
struct Export: ParsableCommand {
    enum Format: String, ExpressibleByArgument, CaseIterable {
        case md, csv, html
    }

    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export clipboard history as Markdown, CSV, or HTML."
    )

    @Option(name: .long, help: "Output format: md | csv | html.")
    var format: Format = .md

    @Option(name: .long, help: "Write to this path instead of stdout.")
    var output: String?

    @Option(name: .long, help: "Max entries to export (newest first). Default: all.")
    var limit: Int = Int.max

    @Flag(name: .long, help: "Include entries whose flavor bodies were evicted (metadata still present).")
    var includeEvicted: Bool = true

    func run() throws {
        let store = try Store.open()
        let rows: [ExportRow] = try store.dbQueue.read { db in
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
            return try Row.fetchAll(db, sql: sql, arguments: [limitArg]).map { r in
                ExportRow(
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

        let document: String
        switch format {
        case .md:   document = Self.renderMarkdown(rows)
        case .csv:  document = Self.renderCSV(rows)
        case .html: document = Self.renderHTML(rows)
        }

        if let output = output {
            let path = (output as NSString).expandingTildeInPath
            try document.write(toFile: path, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("exported \(rows.count) entries → \(path)\n".utf8))
        } else {
            print(document)
        }
    }

    struct ExportRow {
        let id: Int64
        let createdAt: Double
        let capturedAt: Double
        let kind: String
        let title: String?
        let textPreview: String?
        let linkTitle: String?
        let pinned: Bool
        let evicted: Bool
        let ocrText: String?
        let imageTags: String?
        let appName: String?
        let deviceName: String?

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

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func ts(_ epoch: Double) -> String {
        iso.string(from: Date(timeIntervalSince1970: epoch))
    }

    // MARK: - Markdown (a paragraph per entry)

    static func renderMarkdown(_ rows: [ExportRow]) -> String {
        var out = "# cpdb clipboard export\n\n"
        out += "_\(rows.count) entries · generated \(ts(Date().timeIntervalSince1970))_\n\n"
        for r in rows {
            let pin = r.pinned ? "📌 " : ""
            out += "## \(pin)\(r.headline)\n\n"
            var meta: [String] = ["**\(r.kind)**"]
            if let app = r.appName { meta.append(app) }
            if let dev = r.deviceName { meta.append(dev) }
            meta.append(ts(r.createdAt))
            if r.evicted { meta.append("_(body evicted)_") }
            out += meta.joined(separator: " · ") + "\n\n"
            // Body: full text preview when it differs from the
            // headline (links show the URL beneath their title).
            if let tp = r.textPreview, !tp.isEmpty, tp != r.headline {
                out += "```\n\(tp)\n```\n\n"
            }
            if let ocr = r.ocrText, !ocr.isEmpty {
                out += "> OCR: \(ocr.prefix(500))\n\n"
            }
            if let tags = r.imageTags, !tags.isEmpty {
                out += "> Tags: \(tags)\n\n"
            }
            out += "---\n\n"
        }
        return out
    }

    // MARK: - CSV (RFC 4180)

    static func renderCSV(_ rows: [ExportRow]) -> String {
        func esc(_ s: String?) -> String {
            let v = s ?? ""
            if v.contains(",") || v.contains("\"") || v.contains("\n") {
                return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return v
        }
        var out = "id,kind,pinned,evicted,created_at,captured_at,source_app,device,headline,text_preview,ocr_text,image_tags\n"
        for r in rows {
            let cols = [
                String(r.id),
                r.kind,
                r.pinned ? "1" : "0",
                r.evicted ? "1" : "0",
                ts(r.createdAt),
                ts(r.capturedAt),
                esc(r.appName),
                esc(r.deviceName),
                esc(r.headline),
                esc(r.textPreview),
                esc(r.ocrText),
                esc(r.imageTags),
            ]
            out += cols.joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: - HTML (self-contained, no external assets)

    static func renderHTML(_ rows: [ExportRow]) -> String {
        func esc(_ s: String?) -> String {
            (s ?? "")
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
          @media (prefers-color-scheme: dark) {
            body { background:#1a1a1a; color:#e5e5e5; } pre,.badge{background:#2a2a2a;} .entry{border-color:#333;}
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
            if let tp = r.textPreview, !tp.isEmpty, tp != r.headline {
                out += "  <pre>\(esc(tp))</pre>\n"
            }
            if let ocr = r.ocrText, !ocr.isEmpty {
                out += "  <div class=\"badges\">OCR: \(esc(String(ocr.prefix(500))))</div>\n"
            }
            out += "</div>\n"
        }
        out += "</body></html>\n"
        return out
    }
}
#endif
