using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Portability;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class HistoryExporterTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public HistoryExporterTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-export-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private long IngestText(string s, DateTimeOffset at, ForegroundApp.Info? app = null) =>
        _ingestor.Ingest(
            new ClipboardSnapshot(new[]
            {
                new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(s)),
            }),
            app, _device, at).EntryId;

    private static ForegroundApp.Info Notepad() =>
        new("win.notepad", "Notepad", @"C:\Windows\System32\notepad.exe");

    // ─── Format parsing + extension ──────────────────────────────────────

    [Theory]
    [InlineData("md",   HistoryExporter.Format.Md,   "md")]
    [InlineData("csv",  HistoryExporter.Format.Csv,  "csv")]
    [InlineData("html", HistoryExporter.Format.Html, "html")]
    [InlineData("HTML", HistoryExporter.Format.Html, "html")]
    public void TryParseFormat_And_Extension(string s, HistoryExporter.Format expected, string ext)
    {
        Assert.True(HistoryExporter.TryParseFormat(s, out var f));
        Assert.Equal(expected, f);
        Assert.Equal(ext, HistoryExporter.FileExtension(f));
    }

    [Fact]
    public void TryParseFormat_UnknownReturnsFalse()
    {
        Assert.False(HistoryExporter.TryParseFormat("pdf", out _));
        Assert.False(HistoryExporter.TryParseFormat("", out _));
    }

    // ─── Newest-first ordering ───────────────────────────────────────────

    [Fact]
    public void Fetch_ReturnsNewestFirst()
    {
        IngestText("oldest",  DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        IngestText("middle",  DateTimeOffset.FromUnixTimeSeconds(1_700_000_500));
        IngestText("newest",  DateTimeOffset.FromUnixTimeSeconds(1_700_001_000));

        var rows = HistoryExporter.Fetch(_db);
        Assert.Equal(3, rows.Count);
        Assert.Equal("newest", rows[0].Headline);
        Assert.Equal("oldest", rows[2].Headline);
    }

    [Fact]
    public void Fetch_LimitCapsNewestFirst()
    {
        for (int i = 0; i < 5; i++)
            IngestText($"e{i}", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000 + i));

        var rows = HistoryExporter.Fetch(_db, limit: 2);
        Assert.Equal(2, rows.Count);
        Assert.Equal("e4", rows[0].Headline);
        Assert.Equal("e3", rows[1].Headline);
    }

    [Fact]
    public void Fetch_ExcludesTombstoned()
    {
        var keep = IngestText("keep", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var gone = IngestText("gone", DateTimeOffset.FromUnixTimeSeconds(1_700_000_500));
        new EntryRepository(_db, _blobs).Tombstone(gone);

        var rows = HistoryExporter.Fetch(_db);
        Assert.Single(rows);
        Assert.Equal(keep, rows[0].Id);
    }

    // ─── headline precedence: link_title › title › text_preview › (kind) ─

    [Fact]
    public void Headline_PrefersLinkTitleThenTitleThenPreviewThenKind()
    {
        var lt = new HistoryExporter.Row { Kind = "link", LinkTitle = "LT", Title = "T", TextPreview = "P" };
        Assert.Equal("LT", lt.Headline);

        var t = new HistoryExporter.Row { Kind = "text", LinkTitle = null, Title = "T", TextPreview = "P" };
        Assert.Equal("T", t.Headline);

        var p = new HistoryExporter.Row { Kind = "text", Title = null, TextPreview = "P" };
        Assert.Equal("P", p.Headline);

        var k = new HistoryExporter.Row { Kind = "image" };
        Assert.Equal("(image)", k.Headline);
    }

    // ─── CSV: RFC-4180 12-column contract ────────────────────────────────

    [Fact]
    public void Csv_HeaderIsExactly13ColumnsInContractOrder()
    {
        // v2.9.6 contract: fetched_title is its own column, inserted
        // immediately after headline.
        var csv = HistoryExporter.RenderCsv(Array.Empty<HistoryExporter.Row>());
        var header = csv.Split('\n')[0];
        Assert.Equal(
            "id,kind,pinned,evicted,created_at,captured_at,source_app,device,headline,fetched_title,text_preview,ocr_text,image_tags",
            header);
        Assert.Equal(13, header.Split(',').Length);
    }

    [Fact]
    public void Csv_EscapesCommasQuotesNewlines_RFC4180()
    {
        var row = new HistoryExporter.Row
        {
            Id = 1, Kind = "text",
            CreatedAt = 1_700_000_000, CapturedAt = 1_700_000_000,
            TextPreview = "has,comma \"quote\" and\nnewline",
            Title = "plain",
        };
        var csv = HistoryExporter.RenderCsv(new[] { row });
        // Can't split on '\n' to isolate the row — the field itself
        // legitimately contains a newline (that's the point of RFC-4180
        // quoting). Assert against the whole document: the text_preview
        // field must be wrapped in quotes with the inner quote doubled
        // and the embedded comma/newline preserved verbatim inside.
        Assert.Contains("\"has,comma \"\"quote\"\" and\nnewline\"", csv);
    }

    [Fact]
    public void Csv_TimestampsAreIso8601()
    {
        IngestText("x", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var (doc, count) = HistoryExporter.Export(_db, HistoryExporter.Format.Csv);
        Assert.Equal(1, count);
        // 1_700_000_000 = 2023-11-14T22:13:20Z
        Assert.Contains("2023-11-14T22:13:20Z", doc);
    }

    [Fact]
    public void Csv_PinnedAndEvictedAreOneOrZero()
    {
        var id = IngestText("p", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        new EntryRepository(_db, _blobs).SetPinned(id, true);

        var (doc, _) = HistoryExporter.Export(_db, HistoryExporter.Format.Csv);
        var data = doc.Split('\n')[1].Split(',');
        // columns: id,kind,pinned,evicted,...
        Assert.Equal("1", data[2]);   // pinned
        Assert.Equal("0", data[3]);   // evicted
    }

    // ─── Markdown shape ──────────────────────────────────────────────────

    [Fact]
    public void Markdown_HasHeaderAndParagraphPerEntry()
    {
        IngestText("first entry",  DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), Notepad());
        IngestText("second entry", DateTimeOffset.FromUnixTimeSeconds(1_700_000_500), Notepad());

        var (doc, count) = HistoryExporter.Export(_db, HistoryExporter.Format.Md);
        Assert.Equal(2, count);
        Assert.StartsWith("# cpdb clipboard export", doc);
        Assert.Contains("## first entry", doc);
        Assert.Contains("## second entry", doc);
        Assert.Contains("Notepad", doc);
        // paragraph separator
        Assert.Contains("---", doc);
    }

    // ─── HTML self-contained + dark mode ─────────────────────────────────

    [Fact]
    public void Html_IsSelfContainedWithDarkModeMedia()
    {
        IngestText("entry", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var (doc, _) = HistoryExporter.Export(_db, HistoryExporter.Format.Html);

        Assert.StartsWith("<!DOCTYPE html>", doc);
        Assert.Contains("@media (prefers-color-scheme: dark)", doc);
        // No external assets — no <link rel=stylesheet> / <script src>.
        Assert.DoesNotContain("<link rel=\"stylesheet\"", doc);
        Assert.DoesNotContain("<script src=", doc);
        Assert.EndsWith("</html>\n", doc);
    }

    [Fact]
    public void Html_EscapesAngleBracketsAndAmpersands()
    {
        IngestText("<script>alert('x&y')</script>",
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var (doc, _) = HistoryExporter.Export(_db, HistoryExporter.Format.Html);

        Assert.DoesNotContain("<script>alert", doc);
        Assert.Contains("&lt;script&gt;", doc);
        Assert.Contains("&amp;y", doc);
    }

    [Fact]
    public void Export_NoFlavorBytes_TextOnly()
    {
        // A 300 KB PNG would spill to the blob store; export must not
        // pull bytes — only metadata + text columns.
        var bytes = new byte[300 * 1024];
        new Random(7).NextBytes(bytes);
        _ingestor.Ingest(
            new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.png", bytes) }),
            null, _device, DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));

        var (doc, count) = HistoryExporter.Export(_db, HistoryExporter.Format.Md);
        Assert.Equal(1, count);
        // kind=image, no text — headline falls to "(image)".
        Assert.Contains("## (image)", doc);
        // Sanity: the doc is small (no 300 KB blob inlined).
        Assert.True(doc.Length < 4096, $"doc unexpectedly large: {doc.Length} bytes");
    }

    // ─── Enrichment: full OCR + image tags in every format ───────────────

    private void SetEnrichment(long entryId, string? ocr, string? tags, string? linkTitle = null)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText =
            "UPDATE entries SET ocr_text = $o, image_tags = $t, link_title = $l WHERE id = $id";
        cmd.Parameters.AddWithValue("$o", (object?)ocr ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$t", (object?)tags ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$l", (object?)linkTitle ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$id", entryId);
        cmd.ExecuteNonQuery();
    }

    [Fact]
    public void Markdown_HasLabelledEnrichmentBlock_OcrNotTruncated()
    {
        var id = IngestText("https://youtu.be/x", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        // > 500 chars to prove the old 500-char cap is gone.
        var ocr = string.Join("\n", Enumerable.Range(0, 40)
            .Select(i => $"recovered text line {i} with enough words to exceed five hundred characters total"));
        SetEnrichment(id, ocr, "cat, laptop, sticky-note", linkTitle: "Rick Astley - Never Gonna Give You Up");

        var (doc, _) = HistoryExporter.Export(_db, HistoryExporter.Format.Md);

        Assert.True(ocr.Length > 500);
        // v2.9.6 explicit labelled enrichment block.
        Assert.Contains("- **Fetched title:** Rick Astley - Never Gonna Give You Up", doc);
        Assert.Contains("- **Image tags:** cat, laptop, sticky-note", doc);
        Assert.Contains("**OCR text:**\n\n```\n", doc);
        Assert.Contains("recovered text line 0", doc);
        Assert.Contains("recovered text line 39", doc);   // full tail, not truncated
    }

    [Fact]
    public void Html_HasLabelledEnrichRows_OcrNotTruncated()
    {
        var id = IngestText("https://youtu.be/x", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var ocr = new string('A', 700) + " END";
        SetEnrichment(id, ocr, "dog & <fox>", linkTitle: "Title & <b>");

        var (doc, _) = HistoryExporter.Export(_db, HistoryExporter.Format.Html);

        Assert.Contains("<b>Fetched title:</b> Title &amp; &lt;b&gt;", doc);
        Assert.Contains("<b>Image tags:</b> dog &amp; &lt;fox&gt;", doc);
        Assert.Contains("<b>OCR text:</b>", doc);
        Assert.Contains(new string('A', 700) + " END", doc);   // not truncated at 500
    }

    [Fact]
    public void Csv_HasFetchedTitleColumn_AndFullOcr()
    {
        var id = IngestText("https://youtu.be/x", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var ocr = "line one\nline two with, comma and \"quote\"";
        SetEnrichment(id, ocr, "tag1;tag2", linkTitle: "Fetched YT Title");

        var (doc, _) = HistoryExporter.Export(_db, HistoryExporter.Format.Csv);

        // fetched_title is its own column now; full quoted OCR retained.
        Assert.Contains("Fetched YT Title", doc);
        Assert.Contains("\"line one\nline two with, comma and \"\"quote\"\"\"", doc);
        Assert.Contains("tag1;tag2", doc);
    }

    [Theory]
    [InlineData(HistoryExporter.Format.Md)]
    [InlineData(HistoryExporter.Format.Csv)]
    [InlineData(HistoryExporter.Format.Html)]
    public void AllFormats_AreLfOnly_NoCarriageReturns(HistoryExporter.Format fmt)
    {
        // Captured clipboard text from Windows apps carries CRLF;
        // v2.9.6 requires the exported document be uniformly LF.
        var id = IngestText("first line\r\nsecond line\rthird",
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        SetEnrichment(id, "ocr l1\r\nocr l2", "tagA\r\ntagB", linkTitle: "ti\r\ntle");

        var (doc, _) = HistoryExporter.Export(_db, fmt);

        Assert.DoesNotContain('\r', doc);
    }
}
