using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Coverage for <see cref="EntryRepository.Neighbors"/> — the primitive
/// behind v1.48.0 time-pivot mode. Ports macOS's
/// <c>Tests/CpdbCoreTests/EntryRepositoryNeighborsTests.swift</c>
/// (6 fixtures) plus a couple of Windows-only edge cases.
/// </summary>
public class NeighborsTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    // 2026-01-01 00:00:00 UTC — every fixture derives from this so the
    // relative offsets are legible in the SQL trace when debugging.
    private const double Anchor = 1_767_225_600.0;

    public NeighborsTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-neighbors-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
        _repo = new EntryRepository(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private long IngestAt(string text, double capturedAt) =>
        _ingestor.Ingest(TextSnapshot(text), null, _device,
            DateTimeOffset.FromUnixTimeMilliseconds((long)(capturedAt * 1000))).EntryId;

    private static ClipboardSnapshot TextSnapshot(string s) =>
        new(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(s)) });

    [Fact]
    public void ReturnsWithinWindow_Chronological()
    {
        // 5 rows spread ±90s; ±30s window should return the 3 in the
        // middle in ascending captured_at order (chronological — the
        // strip reads left-to-right as time flowing forward, matching
        // Mac's ORDER BY captured_at ASC).
        IngestAt("t-90", Anchor -  90);
        IngestAt("t-20", Anchor -  20);
        IngestAt("anchor", Anchor);
        IngestAt("t+20", Anchor +  20);
        IngestAt("t+90", Anchor +  90);

        var rows = _repo.Neighbors(Anchor, windowSeconds: 30);

        Assert.Equal(3, rows.Count);
        Assert.Equal("t-20",   rows[0].Title);
        Assert.Equal("anchor", rows[1].Title);
        Assert.Equal("t+20",   rows[2].Title);
    }

    [Fact]
    public void BoundariesInclusive()
    {
        // A row captured exactly at anchor - window (or exactly at
        // anchor + window) is included. Not just a numerical nicety —
        // it means the anchor itself always appears at window=0, which
        // the UI relies on to show "anchor is here" as the sole card.
        IngestAt("edge-lo",  Anchor - 60);
        IngestAt("edge-hi",  Anchor + 60);
        IngestAt("outside",  Anchor - 61);

        var rows = _repo.Neighbors(Anchor, windowSeconds: 60);
        Assert.Equal(2, rows.Count);
        Assert.Equal("edge-lo", rows[0].Title);
        Assert.Equal("edge-hi", rows[1].Title);
    }

    [Fact]
    public void ZeroWindow_ReturnsAnchorAlone()
    {
        // Degenerate but useful — a zero-second window still finds the
        // anchor row (since bounds are inclusive) and nothing else.
        IngestAt("before", Anchor - 1);
        var anchorId = IngestAt("anchor", Anchor);
        IngestAt("after",  Anchor + 1);

        var rows = _repo.Neighbors(Anchor, windowSeconds: 0);
        var single = Assert.Single(rows);
        Assert.Equal(anchorId, single.Id);
    }

    [Fact]
    public void TombstonedRowsExcluded()
    {
        // Deleted rows never appear in a pivot, even when in-window.
        // Matches Recent()/Search() semantics — the whole popup is
        // built on "live" == deleted_at IS NULL.
        IngestAt("alive",  Anchor);
        var doomed = IngestAt("buried", Anchor + 5);
        _repo.Tombstone(doomed);

        var rows = _repo.Neighbors(Anchor, windowSeconds: 60);
        var single = Assert.Single(rows);
        Assert.Equal("alive", single.Title);
    }

    [Fact]
    public void KindAgnostic()
    {
        // A pivot is "what else was on the clipboard around then?" — no
        // kind filter. Text + link + image rows all appear together.
        IngestAt("plain text",           Anchor - 5);
        _ingestor.Ingest(
            new ClipboardSnapshot(new[] {
                new CanonicalHash.Flavor("public.url", Encoding.UTF8.GetBytes("https://example.com/x")),
                new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes("https://example.com/x")),
            }),
            sourceApp: null, _device,
            DateTimeOffset.FromUnixTimeMilliseconds((long)(Anchor * 1000)));

        var rows = _repo.Neighbors(Anchor, windowSeconds: 30);
        Assert.Equal(2, rows.Count);
        var kinds = rows.Select(r => r.Kind).ToHashSet();
        Assert.Contains("text", kinds);
        Assert.Contains("link", kinds);
    }

    [Fact]
    public void Empty_WhenNothingInWindow()
    {
        IngestAt("far-past",   Anchor - 1_000_000);
        IngestAt("far-future", Anchor + 1_000_000);

        Assert.Empty(_repo.Neighbors(Anchor, windowSeconds: 60));
    }

    [Fact]
    public void LimitCapsResultSize()
    {
        // A day-wide pivot on a chatty clipboard can return thousands.
        // The 500 default cap keeps that survivable; explicit lower
        // limits are honored.
        for (int i = 0; i < 20; i++)
            IngestAt($"row-{i}", Anchor + i);  // 20 rows @ 1-second spacing

        var rows = _repo.Neighbors(Anchor, windowSeconds: 60, limit: 5);
        Assert.Equal(5, rows.Count);
        // Ascending order preserved under LIMIT — we get the earliest 5.
        Assert.Equal("row-0", rows[0].Title);
        Assert.Equal("row-4", rows[4].Title);
    }

    [Fact]
    public void MatchSource_IsNull()
    {
        // Neighbors() doesn't run FTS — the MatchSource field must stay
        // null so the UI doesn't render stray OCR/TAG pills on pivot
        // rows (which would be misleading — the row isn't a "search
        // hit", it's a "temporally-adjacent capture").
        IngestAt("adjacent", Anchor);
        var row = Assert.Single(_repo.Neighbors(Anchor, windowSeconds: 60));
        Assert.Null(row.MatchSource);
    }

    [Fact]
    public void CapturedAtIsAnchor_NotCreatedAt()
    {
        // Dedup bumps created_at on re-capture but leaves captured_at
        // untouched (per docs/schema.md § Captured-at). A row re-copied
        // 10 minutes after original capture must still show up in a
        // pivot anchored to its ORIGINAL time — because that's when
        // the content actually landed on the clipboard first.
        var originalId = IngestAt("recopied-text", Anchor);

        // Re-ingest same content 10 minutes later. Dedup fires; same
        // row, created_at bumped, captured_at unchanged.
        var bumped = _ingestor.Ingest(TextSnapshot("recopied-text"), null, _device,
            DateTimeOffset.FromUnixTimeMilliseconds((long)((Anchor + 600) * 1000)));
        Assert.Equal(IngestKind.Bumped, bumped.Kind);
        Assert.Equal(originalId, bumped.EntryId);

        // Anchored to the ORIGINAL capture time, tight window: the
        // row is present (captured_at still equals Anchor).
        var atOriginal = _repo.Neighbors(Anchor, windowSeconds: 60);
        Assert.Single(atOriginal);

        // Anchored to the RE-COPY time, same tight window: the row
        // is absent — captured_at is 10 min away, well outside ±60s.
        var atRecopy = _repo.Neighbors(Anchor + 600, windowSeconds: 60);
        Assert.Empty(atRecopy);
    }
}
