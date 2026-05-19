using Microsoft.Data.Sqlite;
using System.Globalization;
using System.Text;

namespace CpdbWin.Core.Portability;

/// <summary>
/// Renders live clipboard history to a portable document (Markdown /
/// CSV / HTML). Metadata + text only — flavor bytes and thumbnails
/// are not exported (a clipboard archive is a reading/searching
/// artifact, not a restore image).
///
/// One implementation shared by <c>cpdb-win export</c> and the WinUI
/// Preferences "Export…" button — per
/// <c>docs/parity.md § Data portability</c>. Newest-first by
/// <c>created_at</c>. Mirrors the macOS v2.9.6 <c>HistoryExporter</c>
/// contract byte-for-byte: every enrichment field (fetched_title,
/// full ocr_text, image_tags) is carried explicitly-labelled; all
/// embedded captured text is LF-normalised; CSV is RFC-4180 with
/// exactly the 13 columns below in order; HTML is self-contained
/// with a dark-mode <c>@media</c> block and no external assets;
/// Markdown is a paragraph per entry. Timestamps are ISO-8601.
/// </summary>
public static class HistoryExporter
{
    public enum Format { Md, Csv, Html }

    public static string FileExtension(Format f) => f switch
    {
        Format.Md   => "md",
        Format.Csv  => "csv",
        Format.Html => "html",
        _           => "txt",
    };

    public static bool TryParseFormat(string s, out Format format)
    {
        switch (s?.Trim().ToLowerInvariant())
        {
            case "md":   format = Format.Md;   return true;
            case "csv":  format = Format.Csv;  return true;
            case "html": format = Format.Html; return true;
            default:     format = Format.Md;   return false;
        }
    }

    public sealed class Row
    {
        public long Id { get; init; }
        public double CreatedAt { get; init; }
        public double CapturedAt { get; init; }
        public string Kind { get; init; } = "";
        public string? Title { get; init; }
        public string? TextPreview { get; init; }
        public string? LinkTitle { get; init; }
        public bool Pinned { get; init; }
        public bool Evicted { get; init; }
        public string? OcrText { get; init; }
        public string? ImageTags { get; init; }
        public string? AppName { get; init; }
        public string? DeviceName { get; init; }

        /// <summary>
        /// Best human-readable headline: link_title › title ›
        /// text_preview › "(kind)". Mirrors the popup card snippet
        /// logic so the export reads the way the app looks.
        /// </summary>
        public string Headline =>
            !string.IsNullOrEmpty(LinkTitle)   ? LinkTitle!
          : !string.IsNullOrEmpty(Title)       ? Title!
          : !string.IsNullOrEmpty(TextPreview) ? TextPreview!
          : $"({Kind})";
    }

    /// <summary>
    /// Fetch + render in one call. <paramref name="limit"/> caps
    /// newest-first; <paramref name="includeEvicted"/> keeps
    /// body-evicted entries (metadata still present). Returns the
    /// rendered document + row count for the caller's confirmation.
    /// </summary>
    public static (string Document, int Count) Export(
        SqliteConnection db,
        Format format,
        int limit = int.MaxValue,
        bool includeEvicted = true)
    {
        var rows = Fetch(db, limit, includeEvicted);
        var doc = format switch
        {
            Format.Md   => RenderMarkdown(rows),
            Format.Csv  => RenderCsv(rows),
            Format.Html => RenderHtml(rows),
            _           => RenderMarkdown(rows),
        };
        return (doc, rows.Count);
    }

    public static List<Row> Fetch(
        SqliteConnection db,
        int limit = int.MaxValue,
        bool includeEvicted = true)
    {
        var sql = new StringBuilder("""
            SELECT e.id, e.created_at, e.captured_at, e.kind, e.title,
                   e.text_preview, e.link_title, e.pinned, e.body_evicted_at,
                   e.ocr_text, e.image_tags,
                   a.name AS app_name, d.name AS device_name
            FROM entries e
            LEFT JOIN apps a ON a.id = e.source_app_id
            LEFT JOIN devices d ON d.id = e.source_device_id
            WHERE e.deleted_at IS NULL
            """);
        if (!includeEvicted) sql.Append("\n  AND e.body_evicted_at IS NULL");
        sql.Append("\nORDER BY e.created_at DESC LIMIT $limit");

        using var cmd = db.CreateCommand();
        cmd.CommandText = sql.ToString();
        cmd.Parameters.AddWithValue("$limit",
            limit == int.MaxValue ? long.MaxValue : limit);

        var rows = new List<Row>();
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            rows.Add(new Row
            {
                Id          = r.GetInt64(0),
                CreatedAt   = r.GetDouble(1),
                CapturedAt  = r.GetDouble(2),
                Kind        = r.GetString(3),
                Title       = r.IsDBNull(4)  ? null : r.GetString(4),
                TextPreview = r.IsDBNull(5)  ? null : r.GetString(5),
                LinkTitle   = r.IsDBNull(6)  ? null : r.GetString(6),
                Pinned      = !r.IsDBNull(7) && r.GetInt64(7) != 0,
                Evicted     = !r.IsDBNull(8),
                OcrText     = r.IsDBNull(9)  ? null : r.GetString(9),
                ImageTags   = r.IsDBNull(10) ? null : r.GetString(10),
                AppName     = r.IsDBNull(11) ? null : r.GetString(11),
                DeviceName  = r.IsDBNull(12) ? null : r.GetString(12),
            });
        }
        return rows;
    }

    private static string Ts(double epochSeconds) =>
        DateTimeOffset.FromUnixTimeMilliseconds((long)(epochSeconds * 1000))
            .UtcDateTime
            .ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);

    private static string NowTs() =>
        DateTimeOffset.UtcNow.UtcDateTime
            .ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);

    /// <summary>
    /// Normalise embedded clipboard text to LF. Captured content
    /// routinely carries CRLF (Windows source apps) or lone CR, while
    /// our own separators are LF — without this the exported file has
    /// mixed line endings and editors prompt to "fix" it. Applied to
    /// every field that originates from captured data (text_preview,
    /// ocr_text, link_title, image_tags, title, headline, app/device).
    /// Mirrors the macOS v2.9.6 <c>lf()</c> contract.
    /// </summary>
    private static string Lf(string? s) =>
        s is null ? "" : s.Replace("\r\n", "\n").Replace("\r", "\n");

    // ─── Markdown (a paragraph per entry) ────────────────────────────────

    public static string RenderMarkdown(IReadOnlyList<Row> rows)
    {
        var o = new StringBuilder();
        o.Append("# cpdb clipboard export\n\n");
        o.Append($"_{rows.Count} entries · generated {NowTs()}_\n\n");
        foreach (var r in rows)
        {
            var pin = r.Pinned ? "📌 " : "";
            o.Append($"## {pin}{Lf(r.Headline)}\n\n");
            var meta = new List<string> { $"**{r.Kind}**" };
            if (r.AppName is not null)    meta.Add(Lf(r.AppName));
            if (r.DeviceName is not null) meta.Add(Lf(r.DeviceName));
            meta.Add(Ts(r.CreatedAt));
            if (r.Evicted) meta.Add("_(body evicted)_");
            o.Append(string.Join(" · ", meta) + "\n\n");
            if (!string.IsNullOrEmpty(r.TextPreview) && Lf(r.TextPreview) != Lf(r.Headline))
            {
                o.Append($"```\n{Lf(r.TextPreview)}\n```\n\n");
            }
            // Enrichment block — the metadata cpdb gleans that isn't
            // in the raw clipboard payload. Explicitly labelled so
            // it's obvious what was derived vs. captured. OCR is NOT
            // truncated — the whole point of exporting is to keep the
            // searchable text. Mirrors macOS v2.9.6 byte-for-byte.
            if (!string.IsNullOrEmpty(Lf(r.LinkTitle)))
            {
                o.Append($"- **Fetched title:** {Lf(r.LinkTitle)}\n");
            }
            if (!string.IsNullOrEmpty(Lf(r.ImageTags)))
            {
                o.Append($"- **Image tags:** {Lf(r.ImageTags)}\n");
            }
            if (!string.IsNullOrEmpty(Lf(r.OcrText)))
            {
                o.Append($"\n**OCR text:**\n\n```\n{Lf(r.OcrText)}\n```\n");
            }
            o.Append("\n---\n\n");
        }
        return Lf(o.ToString());  // guarantee uniform LF (zero CR) per v2.9.6
    }

    // ─── CSV (RFC 4180) ──────────────────────────────────────────────────

    public static string RenderCsv(IReadOnlyList<Row> rows)
    {
        // Quote per RFC-4180 when needed; embedded newlines are
        // already LF-normalised by Lf(), and a quoted field with LF
        // newlines is valid RFC-4180 (it permits CRLF or LF as the
        // in-field break; we keep the whole file LF for editor sanity).
        static string Cell(string? s)
        {
            var v = Lf(s);
            if (v.Contains(',') || v.Contains('"') || v.Contains('\n'))
            {
                return "\"" + v.Replace("\"", "\"\"") + "\"";
            }
            return v;
        }
        var o = new StringBuilder();
        // link_title is now its own column (was only folded into
        // headline). image_tags + the FULL ocr_text are kept so the
        // export carries every enrichment field — 13 cols.
        o.Append("id,kind,pinned,evicted,created_at,captured_at,source_app,device,headline,fetched_title,text_preview,ocr_text,image_tags\n");
        foreach (var r in rows)
        {
            var cols = new[]
            {
                r.Id.ToString(CultureInfo.InvariantCulture),
                r.Kind,
                r.Pinned ? "1" : "0",
                r.Evicted ? "1" : "0",
                Ts(r.CreatedAt),
                Ts(r.CapturedAt),
                Cell(r.AppName),
                Cell(r.DeviceName),
                Cell(r.Headline),
                Cell(r.LinkTitle),
                Cell(r.TextPreview),
                Cell(r.OcrText),
                Cell(r.ImageTags),
            };
            o.Append(string.Join(",", cols) + "\n");
        }
        return Lf(o.ToString());  // guarantee uniform LF (zero CR) per v2.9.6
    }

    // ─── HTML (self-contained, no external assets) ───────────────────────

    public static string RenderHtml(IReadOnlyList<Row> rows)
    {
        static string Esc(string? s) =>
            Lf(s)
                .Replace("&", "&amp;")
                .Replace("<", "&lt;")
                .Replace(">", "&gt;")
                .Replace("\"", "&quot;");

        var o = new StringBuilder();
        o.Append("""
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

            """);
        o.Append($"<div class=\"meta\">{rows.Count} entries · generated {NowTs()}</div>\n\n");
        foreach (var r in rows)
        {
            o.Append("<div class=\"entry\">\n");
            var pin = r.Pinned ? "<span class=\"pin\">📌</span> " : "";
            o.Append($"  <div class=\"headline\">{pin}{Esc(r.Headline)}</div>\n");
            var badges = $"<span class=\"badge\">{Esc(r.Kind)}</span>";
            if (!string.IsNullOrEmpty(r.AppName))    badges += $"<span class=\"badge\">{Esc(r.AppName)}</span>";
            if (!string.IsNullOrEmpty(r.DeviceName)) badges += $"<span class=\"badge\">{Esc(r.DeviceName)}</span>";
            badges += $"<span class=\"badge\">{Ts(r.CreatedAt)}</span>";
            if (r.Evicted) badges += "<span class=\"badge\">body evicted</span>";
            o.Append($"  <div class=\"badges\">{badges}</div>\n");
            if (!string.IsNullOrEmpty(r.TextPreview) && Lf(r.TextPreview) != Lf(r.Headline))
            {
                o.Append($"  <pre>{Esc(r.TextPreview)}</pre>\n");
            }
            // Enrichment — explicitly labelled, OCR untruncated.
            // Mirrors macOS v2.9.6 markup byte-for-byte.
            if (!string.IsNullOrEmpty(Lf(r.LinkTitle)))
            {
                o.Append($"  <div class=\"enrich\"><b>Fetched title:</b> {Esc(r.LinkTitle)}</div>\n");
            }
            if (!string.IsNullOrEmpty(Lf(r.ImageTags)))
            {
                o.Append($"  <div class=\"enrich\"><b>Image tags:</b> {Esc(r.ImageTags)}</div>\n");
            }
            if (!string.IsNullOrEmpty(Lf(r.OcrText)))
            {
                o.Append($"  <div class=\"enrich\"><b>OCR text:</b></div>\n  <pre>{Esc(r.OcrText)}</pre>\n");
            }
            o.Append("</div>\n");
        }
        o.Append("</body></html>\n");
        return Lf(o.ToString());  // guarantee uniform LF (zero CR) per v2.9.6
    }
}
