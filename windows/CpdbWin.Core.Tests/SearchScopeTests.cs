using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Pure-function coverage for <see cref="EntryRepository.BuildScopedFtsQuery"/> —
/// FTS5 query-string rewriting given a scope. Ports Mac's
/// <c>Sources/CpdbShared/Search/FtsIndex.swift</c> escape rules so
/// query strings stay behavior-equivalent across platforms.
/// </summary>
public class ScopedFtsQueryBuilderTests
{
    [Fact]
    public void AllScope_WrapsQueryWithAllContentColumns()
    {
        var q = EntryRepository.BuildScopedFtsQuery("hello", SearchScope.All);
        // Always-in-scope columns bracket the toggleable ones — title
        // and app_name lead, link_title trails. Order matters only for
        // FTS5 legibility, not correctness.
        Assert.Equal("{title app_name text ocr_text image_tags link_title} : \"hello\"*", q);
    }

    [Fact]
    public void TextOnly_DropsOcrAndTagsColumns()
    {
        var q = EntryRepository.BuildScopedFtsQuery("hello", new SearchScope(Text: true, Ocr: false, Tags: false));
        Assert.Equal("{title app_name text link_title} : \"hello\"*", q);
    }

    [Fact]
    public void OcrOnly_KeepsOcrDropsRest()
    {
        var q = EntryRepository.BuildScopedFtsQuery("hello", new SearchScope(Text: false, Ocr: true, Tags: false));
        Assert.Equal("{title app_name ocr_text link_title} : \"hello\"*", q);
    }

    [Fact]
    public void TagsOnly_KeepsTagsDropsRest()
    {
        var q = EntryRepository.BuildScopedFtsQuery("hello", new SearchScope(Text: false, Ocr: false, Tags: true));
        Assert.Equal("{title app_name image_tags link_title} : \"hello\"*", q);
    }

    [Fact]
    public void AllToggleableOff_ReturnsNull()
    {
        // Empty scope short-circuits — caller renders zero results
        // rather than silently ignoring the scope and returning
        // everything. Matches Mac's `SearchScope.isEnabled` guard.
        var q = EntryRepository.BuildScopedFtsQuery("hello",
            new SearchScope(Text: false, Ocr: false, Tags: false));
        Assert.Null(q);
    }

    [Fact]
    public void EmptyOrWhitespaceQuery_ReturnsNull()
    {
        Assert.Null(EntryRepository.BuildScopedFtsQuery("", SearchScope.All));
        Assert.Null(EntryRepository.BuildScopedFtsQuery("   ", SearchScope.All));
        Assert.Null(EntryRepository.BuildScopedFtsQuery("\t\n", SearchScope.All));
    }

    [Fact]
    public void MultiTokenQuery_QuotesAndAsterisksEachToken()
    {
        // Every token independently prefix-matched. The AND-implicit
        // semantics come from FTS5's default operator; matches Mac.
        var q = EntryRepository.BuildScopedFtsQuery("hello world", SearchScope.All);
        Assert.Equal("{title app_name text ocr_text image_tags link_title} : \"hello\"* \"world\"*", q);
    }

    [Fact]
    public void EmbeddedDoubleQuote_IsEscapedByDoubling()
    {
        // FTS5 literal-string escape: `"` → `""` inside the quoted
        // wrapper. Without this a payload of `he "said" hi` blows up
        // the parser mid-token.
        var q = EntryRepository.BuildScopedFtsQuery("hello\"world", SearchScope.All);
        Assert.Equal("{title app_name text ocr_text image_tags link_title} : \"hello\"\"world\"*", q);
    }

    [Fact]
    public void OperatorCharsInQuery_AreDefusedByQuoteWrap()
    {
        // `*` `-` `(` etc. are FTS5 operators; without the quote wrap
        // a search for `foo-bar` would parse as "foo NOT bar" or fail.
        // Quoted, they're treated as literal token characters.
        var q = EntryRepository.BuildScopedFtsQuery("foo-bar", SearchScope.All);
        Assert.Contains("\"foo-bar\"*", q);
    }

    [Fact]
    public void SearchScope_All_HasAllThreeTrue()
    {
        var s = SearchScope.All;
        Assert.True(s.Text);
        Assert.True(s.Ocr);
        Assert.True(s.Tags);
        Assert.True(s.IsAnyEnabled);
    }

    [Fact]
    public void SearchScope_IsAnyEnabled_FalseOnlyWhenAllOff()
    {
        Assert.False(new SearchScope(false, false, false).IsAnyEnabled);
        Assert.True (new SearchScope(true,  false, false).IsAnyEnabled);
        Assert.True (new SearchScope(false, true,  false).IsAnyEnabled);
        Assert.True (new SearchScope(false, false, true ).IsAnyEnabled);
    }
}

/// <summary>
/// End-to-end: with a scope excluding OCR, an OCR-only hit is not
/// returned. Ports Mac's <c>FtsIndexTests.scopeFilterDropsOcr</c>.
/// </summary>
public class SearchScopeEndToEndTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public SearchScopeEndToEndTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-scope-tests-" + Guid.NewGuid().ToString("N"));
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
        new(new[] { new CanonicalHash.Flavor("public.png",
            new byte[] { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
                         1,2,3,4,5,6,7,8, 9,10,11,12,13,14,15,16 }) });

    [Fact]
    public void Scope_TextOnly_ExcludesOcrHit()
    {
        // Two rows: one text with "hello" in its body, one image with
        // "hello" in its OCR text. Full scope returns both; text-only
        // returns just the text row.
        _ingestor.Ingest(TextSnapshot("hello there"), null, _device);
        var img = _ingestor.Ingest(ImageSnapshot(), null, _device);
        _repo.SettleImageOcr(img.EntryId, "hello world");

        var full = _repo.Search(EntryRepository.BuildScopedFtsQuery("hello", SearchScope.All)!);
        Assert.Equal(2, full.Count);

        var textOnly = _repo.Search(EntryRepository.BuildScopedFtsQuery(
            "hello", new SearchScope(Text: true, Ocr: false, Tags: false))!);
        Assert.Single(textOnly);
        Assert.Equal("hello there", textOnly[0].Title);
    }

    [Fact]
    public void Scope_TextOnly_ExcludesTagHit()
    {
        _ingestor.Ingest(TextSnapshot("laptop reviews"), null, _device);
        var img = _ingestor.Ingest(ImageSnapshot(), null, _device);
        _repo.SettleImageTags(img.EntryId, "laptop, computer");

        var textOnly = _repo.Search(EntryRepository.BuildScopedFtsQuery(
            "laptop", new SearchScope(Text: true, Ocr: false, Tags: false))!);
        Assert.Single(textOnly);
        Assert.Equal("laptop reviews", textOnly[0].Title);
    }

    [Fact]
    public void Scope_OcrOnly_KeepsOcrHitDropsTextHit()
    {
        // Use "receipt" — only in the OCR text, not in the text row's
        // title/body. Confirms the scope filter drops the text-column
        // path AND the match-source classifier still stamps Ocr under
        // scope (the filtered-out text-column highlight returns
        // without sentinels, so ClassifyMatchSource sees only the
        // OCR sentinel).
        _ingestor.Ingest(TextSnapshot("hello there"), null, _device);
        var img = _ingestor.Ingest(ImageSnapshot(), null, _device);
        _repo.SettleImageOcr(img.EntryId, "receipt total $42.00");

        var ocrOnly = _repo.Search(EntryRepository.BuildScopedFtsQuery(
            "receipt", new SearchScope(Text: false, Ocr: true, Tags: false))!);
        var row = Assert.Single(ocrOnly);
        Assert.Equal(img.EntryId, row.Id);
        Assert.Equal(MatchSource.Ocr, row.MatchSource);
    }

    [Fact]
    public void Scope_TitleHit_AlwaysReturned_RegardlessOfToggles()
    {
        // Title is never toggleable — a title match should return the
        // row even when every content-column scope is off (as long as
        // at least one toggleable column is on so the search actually
        // runs). Confirms the "title / app_name / link_title always
        // in scope" contract from BuildScopedFtsQuery.
        _ingestor.Ingest(TextSnapshot("distinctive-title-token"), null, _device);

        // Scope is text-only; title token isn't in the visible text
        // (title IS the text for a plain text entry — TitleAndPreview.
        // Derive uses the first line as title). The FTS index
        // populates title separately, so a title-scoped hit is still
        // reachable through the always-in-scope title column even
        // when the caller says "text-only": both columns are searched
        // in the OR-of-columns filter.
        var hits = _repo.Search(EntryRepository.BuildScopedFtsQuery(
            "distinctive-title-token", new SearchScope(Text: true, Ocr: false, Tags: false))!);
        Assert.Single(hits);
    }
}
