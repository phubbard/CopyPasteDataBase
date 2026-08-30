using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Body-eviction contract coverage. Ports macOS's
/// <c>Tests/CpdbCoreTests/EntryEvictorTests.swift</c> 7 fixtures verbatim
/// plus a Windows-only integration test for the blob-store two-phase
/// unlink.
/// </summary>
public class EntryEvictorTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly EntryEvictor _evictor;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    // 2026-06-01 00:00:00 UTC — the "now" every test uses. All ages
    // are expressed as "days before this instant" so ports of Mac
    // fixtures don't drift with wall time.
    private static readonly DateTimeOffset Now =
        DateTimeOffset.FromUnixTimeSeconds(1_780_531_200);

    public EntryEvictorTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-evictor-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
        _repo = new EntryRepository(_db, _blobs);
        _evictor = new EntryEvictor(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private long IngestDaysAgo(string text, int daysAgo)
    {
        var when = Now.AddDays(-daysAgo);
        return _ingestor.Ingest(TextSnapshot(text), null, _device, when).EntryId;
    }

    private static ClipboardSnapshot TextSnapshot(string s) =>
        new(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(s)) });

    private long BodyEvictedAt(long id)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT body_evicted_at FROM entries WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", id);
        var v = cmd.ExecuteScalar();
        return v is null or DBNull ? 0 : (long)Math.Round((double)v);
    }

    private int FlavorCount(long id)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM entry_flavors WHERE entry_id = $id";
        cmd.Parameters.AddWithValue("$id", id);
        return Convert.ToInt32(cmd.ExecuteScalar()!);
    }

    [Fact]
    public void CandidatesOlderThan_RespectsCutoff()
    {
        var old = IngestDaysAgo("old",     100);
        var mid = IngestDaysAgo("mid",      45);
        var young = IngestDaysAgo("young",   3);

        var over90 = _evictor.CandidatesOlderThan(90, Now);
        Assert.Single(over90);
        Assert.Equal(old, over90[0]);

        var over30 = _evictor.CandidatesOlderThan(30, Now);
        Assert.Equal(2, over30.Count);
        Assert.Contains(old, over30);
        Assert.Contains(mid, over30);
        Assert.DoesNotContain(young, over30);
    }

    [Fact]
    public void CandidatesOlderThan_SkipsPinned()
    {
        // Pinning is the user's escape valve — even a 5-year-old
        // pinned entry must survive. docs/schema.md §Pinning.
        var pinnedOld  = IngestDaysAgo("keep-me", 365);
        var unpinnedOld = IngestDaysAgo("evict-me", 365);
        _repo.SetPinned(pinnedOld, true);

        var candidates = _evictor.CandidatesOlderThan(90, Now);
        Assert.Single(candidates);
        Assert.Equal(unpinnedOld, candidates[0]);
    }

    [Fact]
    public void CandidatesOlderThan_SkipsTombstoned()
    {
        // A soft-deleted row's flavors are already targeted by the
        // Gc pass — no point re-evicting them. Predicate must exclude
        // deleted_at IS NOT NULL rows.
        var doomed = IngestDaysAgo("already-deleted", 365);
        _repo.Tombstone(doomed);

        Assert.Empty(_evictor.CandidatesOlderThan(90, Now));
    }

    [Fact]
    public void CandidatesOlderThan_SkipsAlreadyEvicted()
    {
        // Idempotency guard: an entry we already body-evicted must
        // not re-appear as a candidate. Without this, a nightly job
        // would double-count the "entry_count" report every run.
        var id = IngestDaysAgo("evict-once", 100);
        _evictor.Evict(new[] { id }, Now);

        Assert.Empty(_evictor.CandidatesOlderThan(90, Now));
    }

    [Fact]
    public void Evict_DropsFlavorsAndStampsSentinel()
    {
        var id = IngestDaysAgo("hello", 100);
        Assert.True(FlavorCount(id) > 0);
        Assert.Equal(0, BodyEvictedAt(id));

        var report = _evictor.Evict(new[] { id }, Now);

        Assert.Equal(1, report.EntryCount);
        Assert.True(report.InlineFlavorBytesFreed > 0);  // "hello" utf8 bytes
        Assert.Equal(0, FlavorCount(id));
        Assert.Equal(Now.ToUnixTimeSeconds(), BodyEvictedAt(id));
    }

    [Fact]
    public void Evict_PreservesMetadataAndFts()
    {
        // The whole point of body-eviction (vs tombstone) — the row
        // stays live + searchable. Confirms EntryRepository.Recent
        // still returns it and Search still finds it.
        var id = IngestDaysAgo("uniquefindable", 100);

        _evictor.Evict(new[] { id }, Now);

        var rows = _repo.Recent();
        Assert.Contains(rows, r => r.Id == id);
        var hits = _repo.Search("uniquefindable*");
        Assert.Contains(hits, r => r.Id == id);
    }

    [Fact]
    public void Evict_IsIdempotent()
    {
        var id = IngestDaysAgo("one-shot", 100);

        var first  = _evictor.Evict(new[] { id }, Now);
        var second = _evictor.Evict(new[] { id }, Now);

        Assert.Equal(1, first.EntryCount);
        // Second call runs the SQL but the guard predicate matches
        // zero rows (body_evicted_at IS NULL is false the second
        // time), so nothing changes and the report is zero-valued.
        Assert.Equal(0, second.EntryCount);
        Assert.Equal(0, second.InlineFlavorBytesFreed);
    }

    [Fact]
    public void EvictOlderThan_EndToEnd()
    {
        IngestDaysAgo("old-1", 100);
        IngestDaysAgo("old-2", 200);
        IngestDaysAgo("young",   3);

        var report = _evictor.EvictOlderThan(90, Now);

        Assert.Equal(2, report.EntryCount);
        Assert.True(report.InlineFlavorBytesFreed > 0);
    }

    [Fact]
    public void EvictOlderThan_ValidatesDaysBounds()
    {
        // Fat-fingering `--before-days 0` shouldn't wipe the DB.
        // Same for a wildly-large value (10001 == past the Mac cap).
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            _evictor.EvictOlderThan(0, Now));
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            _evictor.EvictOlderThan(6, Now));   // just below MinDays
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            _evictor.EvictOlderThan(3651, Now));  // just above MaxDays
    }

    [Fact]
    public void Evict_LargeFlavor_UnlinksBlobFile()
    {
        // Force out-of-line storage by ingesting > 256 KB. Verifies
        // the two-phase blob cleanup: after evict, the flavor row is
        // gone, body_evicted_at is set, AND the physical blob file
        // has been unlinked (because no surviving flavor references
        // its key).
        var bigText = new string('X', 300_000);  // > 256 KB inline threshold
        var id = _ingestor.Ingest(TextSnapshot(bigText), null, _device,
            Now.AddDays(-100)).EntryId;

        // Confirm the blob file exists pre-evict.
        var key = BlobKeyFor(id);
        Assert.NotNull(key);
        Assert.True(File.Exists(_blobs.PathFor(key!)));

        var report = _evictor.Evict(new[] { id }, Now);

        Assert.Equal(1, report.EntryCount);
        Assert.Equal(1, report.BlobsRemoved);
        Assert.True(report.BlobBytesFreed >= 300_000);
        Assert.False(File.Exists(_blobs.PathFor(key!)));
    }

    [Fact]
    public void Evict_SharedBlob_KeepsFileWhenAnotherFlavorReferencesIt()
    {
        // Setup: one large-flavor entry that gets evicted, plus a
        // second, independently-ingested entry with byte-different
        // content — we then patch the second entry's flavor row to
        // point at the first entry's blob_key directly via SQL. This
        // sidesteps the content-hash-v2 dedup (which would collapse
        // two identical-primary-content ingests into one row) while
        // still exercising the per-key "still referenced?" re-check
        // inside Evict.
        var bigText = new string('Y', 300_000);
        var oldId = _ingestor.Ingest(TextSnapshot(bigText), null, _device,
            Now.AddDays(-200)).EntryId;
        var oldKey = BlobKeyFor(oldId);
        Assert.NotNull(oldKey);

        var youngId = _ingestor.Ingest(TextSnapshot("distinct young content"), null, _device,
            Now.AddDays(-3)).EntryId;
        Assert.NotEqual(oldId, youngId);

        // Inject a synthetic flavor row on youngId pointing at oldKey
        // — same blob-store file, different entry. UTI kept unique so
        // it doesn't collide with the young entry's existing plain-
        // text flavor (entry_id + uti is the PK).
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = """
                INSERT INTO entry_flavors(entry_id, uti, size, data, blob_key)
                VALUES($e, 'public.test-sidecar', 300000, NULL, $k)
                """;
            cmd.Parameters.AddWithValue("$e", youngId);
            cmd.Parameters.AddWithValue("$k", oldKey);
            cmd.ExecuteNonQuery();
        }

        var report = _evictor.Evict(new[] { oldId }, Now);

        // Old row body-evicted, but the shared blob file survives —
        // the young row's synthetic sidecar flavor still references
        // it. Blob file must still exist on disk; report.BlobsRemoved
        // must be zero.
        Assert.Equal(1, report.EntryCount);
        Assert.Equal(0, report.BlobsRemoved);
        Assert.Equal(0, report.BlobBytesFreed);
        Assert.True(File.Exists(_blobs.PathFor(oldKey!)));
    }

    private string? BlobKeyFor(long entryId)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            SELECT blob_key FROM entry_flavors
            WHERE entry_id = $id AND blob_key IS NOT NULL
            LIMIT 1
            """;
        cmd.Parameters.AddWithValue("$id", entryId);
        var v = cmd.ExecuteScalar();
        return v is null or DBNull ? null : (string)v;
    }
}
