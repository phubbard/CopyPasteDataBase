using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Pure-function coverage for the highlight-sentinel classifier plus
/// end-to-end coverage that <see cref="EntryRepository.Search"/> stamps
/// the right <see cref="MatchSource"/> on each hit. Ports the two Mac
/// parity fixtures (<c>matchSourceOcr</c>, <c>matchSourceTag</c>) and
/// adds Windows-only cases for <see cref="MatchSource.Multiple"/> and
/// the <see cref="MatchSource.Text"/> fall-through.
/// </summary>
public class MatchSourceClassifierTests
{
    private const string S = "";  // FTS5 highlight() start sentinel
    private const string E = "";  // FTS5 highlight() end sentinel

    [Fact]
    public void OcrOnly_ClassifiesAsOcr()
    {
        var source = EntryRepository.ClassifyMatchSource(
            hlText: "no match here",
            hlOcr:  $"the {S}receipt{E} totals",
            hlTags: "no match here");
        Assert.Equal(MatchSource.Ocr, source);
    }

    [Fact]
    public void TagOnly_ClassifiesAsTag()
    {
        var source = EntryRepository.ClassifyMatchSource(
            hlText: "no match",
            hlOcr:  "no match",
            hlTags: $"{S}laptop{E}, computer");
        Assert.Equal(MatchSource.Tag, source);
    }

    [Fact]
    public void OcrAndTag_ClassifiesAsMultiple()
    {
        var source = EntryRepository.ClassifyMatchSource(
            hlText: "no match",
            hlOcr:  $"the {S}laptop{E} screen",
            hlTags: $"{S}laptop{E}, computer");
        Assert.Equal(MatchSource.Multiple, source);
    }

    [Fact]
    public void TextOnly_ClassifiesAsText()
    {
        // The most common case — a plain-text or title hit. We
        // deliberately fall through to .Text rather than distinguishing
        // "title-only" vs "body-only" etc., mirroring Mac's UX
        // decision to render no badge on text-column hits (badge
        // noise for the modal case).
        var source = EntryRepository.ClassifyMatchSource(
            hlText: $"the {S}brown{E} fox",
            hlOcr:  "no match",
            hlTags: "no match");
        Assert.Equal(MatchSource.Text, source);
    }

    [Fact]
    public void NoSentinels_Anywhere_ClassifiesAsText()
    {
        // Belt-and-braces: if none of the three columns has a sentinel
        // (shouldn't happen — FTS5 wouldn't have returned the row —
        // but if it did, .Text is the safest fall-through and matches
        // Mac's default arm).
        var source = EntryRepository.ClassifyMatchSource(
            hlText: "no match", hlOcr: "no match", hlTags: "no match");
        Assert.Equal(MatchSource.Text, source);
    }

    [Fact]
    public void EmptyColumns_ClassifyAsText()
    {
        // Empty strings are what NULL FTS5 columns render as after our
        // IsDBNull null-coalesce; must not throw and must produce
        // .Text.
        var source = EntryRepository.ClassifyMatchSource("", "", "");
        Assert.Equal(MatchSource.Text, source);
    }

    [Fact]
    public void SentinelConstants_MatchMacBytes()
    {
        // If either sentinel drifts, Mac's parity fixture ports break
        // + the cross-platform column contract fractures. Pin the
        // exact bytes.
        Assert.Equal('', EntryRepository.HighlightSentinelStart);
        Assert.Equal('', EntryRepository.HighlightSentinelEnd);
    }
}

/// <summary>
/// End-to-end: an ingested + OCR-settled image row that matches on
/// its OCR text carries <see cref="MatchSource.Ocr"/> back through
/// <see cref="EntryRepository.Search"/>; a tag-only hit carries
/// <see cref="MatchSource.Tag"/>; and a plain-text row carries
/// <see cref="MatchSource.Text"/>. Peer of
/// <c>Tests/CpdbCoreTests/FtsIndexTests.swift matchSourceOcr /
/// matchSourceTag</c>.
/// </summary>
public class MatchSourceSearchTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public MatchSourceSearchTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-matchsource-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
        _repo = new EntryRepository(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private static ClipboardSnapshot TextSnapshot(string s) =>
        new(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(s)) });

    private static ClipboardSnapshot ImageSnapshot() =>
        // Synthetic 24-byte "PNG" is enough to route the ingest through
        // the image kind classifier; we're never going to decode it
        // because we settle OCR text manually via the repository.
        new(new[] { new CanonicalHash.Flavor("public.png",
            new byte[] { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
                         1,2,3,4,5,6,7,8, 9,10,11,12,13,14,15,16 }) });

    [Fact]
    public void Search_OcrOnlyHit_ReturnsMatchSourceOcr()
    {
        var img = _ingestor.Ingest(ImageSnapshot(), null, _device);
        _repo.SettleImageOcr(img.EntryId, "Sale Receipt: total $42.00");

        var rows = _repo.Search("receipt");
        var row = Assert.Single(rows);
        Assert.Equal(MatchSource.Ocr, row.MatchSource);
    }

    [Fact]
    public void Search_TagOnlyHit_ReturnsMatchSourceTag()
    {
        var img = _ingestor.Ingest(ImageSnapshot(), null, _device);
        _repo.SettleImageTags(img.EntryId, "laptop, computer, keyboard");

        var rows = _repo.Search("laptop");
        var row = Assert.Single(rows);
        Assert.Equal(MatchSource.Tag, row.MatchSource);
    }

    [Fact]
    public void Search_OcrAndTagBothHit_ReturnsMatchSourceMultiple()
    {
        // OCR text and classifier tags both contain "screen" — the
        // classifier saw a monitor, the OCR read "screen brightness".
        // Mac's Multiple bucket handles this so the badge is honest
        // ("this matched more than one thing") rather than picking one
        // arbitrarily.
        var img = _ingestor.Ingest(ImageSnapshot(), null, _device);
        _repo.SettleImageOcr (img.EntryId, "adjust screen brightness in Settings");
        _repo.SettleImageTags(img.EntryId, "screen, monitor, display");

        var rows = _repo.Search("screen");
        var row = Assert.Single(rows);
        Assert.Equal(MatchSource.Multiple, row.MatchSource);
    }

    [Fact]
    public void Search_TextRow_ReturnsMatchSourceText()
    {
        _ingestor.Ingest(TextSnapshot("the quick brown fox"), null, _device);

        var rows = _repo.Search("brown");
        var row = Assert.Single(rows);
        Assert.Equal(MatchSource.Text, row.MatchSource);
    }

    [Fact]
    public void Recent_LeavesMatchSourceNull()
    {
        // Recent() doesn't run the FTS pipeline — the MatchSource
        // field must stay null so the UI knows to render no badge.
        // Prevents a stray "OCR" pill from lighting up on the initial
        // popup (no query yet).
        _ingestor.Ingest(TextSnapshot("no search yet"), null, _device);

        var rows = _repo.Recent();
        var row = Assert.Single(rows);
        Assert.Null(row.MatchSource);
    }

    [Fact]
    public void Search_PrefixQuery_StillAttributesCorrectly()
    {
        // MainWindow appends "*" to every user query for prefix search
        // (see MainWindow.xaml.cs:216); make sure attribution still
        // works — the FTS5 highlight() sentinel is inserted for
        // prefix matches too.
        var img = _ingestor.Ingest(ImageSnapshot(), null, _device);
        _repo.SettleImageOcr(img.EntryId, "receipts are here");

        var rows = _repo.Search("receip*");
        var row = Assert.Single(rows);
        Assert.Equal(MatchSource.Ocr, row.MatchSource);
    }
}
