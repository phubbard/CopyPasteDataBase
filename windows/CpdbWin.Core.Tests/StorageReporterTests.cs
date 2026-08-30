using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Coverage for <see cref="StorageReporter"/>. Numbers on the report
/// are derived (page_size × page_count minus sub-tiers), so the tests
/// pin the invariants that matter — sub-tier sums add up, counts
/// respect deleted_at / pinned / body_evicted_at — rather than
/// asserting exact byte totals (which drift with SQLite's page layout).
/// </summary>
public class StorageReporterTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly string _dbPath;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly EntryEvictor _evictor;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    private static readonly DateTimeOffset Now =
        DateTimeOffset.FromUnixTimeSeconds(1_780_531_200);

    public StorageReporterTests()
    {
        // Real on-disk SQLite (not :memory:) so PRAGMA page_count
        // reflects a persistent file the same way production does.
        _dbPath = Path.Combine(Path.GetTempPath(),
            "cpdb-storage-tests-" + Guid.NewGuid().ToString("N") + ".db");
        _db = new SqliteConnection($"Data Source={_dbPath}");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-storage-blobs-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
        _repo = new EntryRepository(_db, _blobs);
        _evictor = new EntryEvictor(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { File.Delete(_dbPath); } catch { }
        try { File.Delete(_dbPath + "-wal"); } catch { }
        try { File.Delete(_dbPath + "-shm"); } catch { }
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private static ClipboardSnapshot TextSnapshot(string s) =>
        new(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(s)) });

    [Fact]
    public void EmptyDb_ReportsZeroEntries_AndNonZeroDbSize()
    {
        var r = StorageReporter.Report(_db, _blobs, _dbPath);

        Assert.Equal(0, r.LiveEntryCount);
        Assert.Equal(0, r.PinnedEntryCount);
        Assert.Equal(0, r.BodyEvictedEntryCount);
        Assert.Equal(0, r.InlineFlavorBytes);
        Assert.Equal(0, r.BlobBytes);
        // Even an empty DB has the schema pages + FTS internal tables.
        Assert.True(r.DatabaseFileBytes > 0);
        Assert.True(r.MetadataBytes >= 0);
    }

    [Fact]
    public void InlineFlavorBytes_IncludesSmallTextEntries()
    {
        _ingestor.Ingest(TextSnapshot("hello there"), null, _device);
        _ingestor.Ingest(TextSnapshot("second entry"), null, _device);

        var r = StorageReporter.Report(_db, _blobs, _dbPath);

        Assert.Equal(2, r.LiveEntryCount);
        // "hello there" + "second entry" = 23 utf8 bytes; inline
        // path (< 256 KB) so both count against InlineFlavorBytes.
        Assert.True(r.InlineFlavorBytes >= 23);
        // BlobBytes must be zero — nothing crossed the inline threshold.
        Assert.Equal(0, r.BlobBytes);
    }

    [Fact]
    public void BlobBytes_ReflectsLargeFlavorsOnDisk()
    {
        // 300 KB > 256 KB inline threshold, so the flavor is written
        // to the blob store and shows up in BlobBytes, not InlineBytes.
        var big = new string('X', 300_000);
        _ingestor.Ingest(TextSnapshot(big), null, _device);

        var r = StorageReporter.Report(_db, _blobs, _dbPath);

        Assert.True(r.BlobBytes >= 300_000);
        Assert.True(r.InlineFlavorBytes < 300_000);  // not double-counted
    }

    [Fact]
    public void PinnedEntryCount_ExcludesTombstoned()
    {
        var alive = _ingestor.Ingest(TextSnapshot("keeper"), null, _device).EntryId;
        var doomed = _ingestor.Ingest(TextSnapshot("goner"),  null, _device).EntryId;
        _repo.SetPinned(alive, true);
        _repo.SetPinned(doomed, true);
        _repo.Tombstone(doomed);

        var r = StorageReporter.Report(_db, _blobs, _dbPath);

        // Both pinned, but the tombstoned one drops out of the count —
        // matches the SQL predicate `pinned = 1 AND deleted_at IS NULL`.
        Assert.Equal(1, r.LiveEntryCount);
        Assert.Equal(1, r.PinnedEntryCount);
    }

    [Fact]
    public void BodyEvictedEntryCount_IncrementsAfterEvict()
    {
        _ingestor.Ingest(TextSnapshot("old"), null, _device,
            Now.AddDays(-200));
        _ingestor.Ingest(TextSnapshot("young"), null, _device,
            Now.AddDays(-1));

        var before = StorageReporter.Report(_db, _blobs, _dbPath);
        Assert.Equal(0, before.BodyEvictedEntryCount);

        _evictor.EvictOlderThan(90, Now);

        var after = StorageReporter.Report(_db, _blobs, _dbPath);
        Assert.Equal(1, after.BodyEvictedEntryCount);
        // Live count doesn't drop — body eviction preserves the row.
        Assert.Equal(2, after.LiveEntryCount);
    }

    [Fact]
    public void Total_EqualsSumOfThreeTiers()
    {
        _ingestor.Ingest(TextSnapshot("some bytes"), null, _device);

        var r = StorageReporter.Report(_db, _blobs, _dbPath);
        Assert.Equal(r.MetadataBytes + r.ThumbnailBytes + r.FlavorBytes, r.Total);
    }

    [Fact]
    public void FlavorBytes_EqualsInlinePlusBlob()
    {
        _ingestor.Ingest(TextSnapshot("small"), null, _device);
        _ingestor.Ingest(TextSnapshot(new string('Q', 300_000)), null, _device);

        var r = StorageReporter.Report(_db, _blobs, _dbPath);
        Assert.Equal(r.InlineFlavorBytes + r.BlobBytes, r.FlavorBytes);
    }

    [Fact]
    public void Formatted_ContainsExpectedTierLabels()
    {
        _ingestor.Ingest(TextSnapshot("hello"), null, _device);
        var r = StorageReporter.Report(_db, _blobs, _dbPath);

        var text = StorageReporter.Formatted(r);

        // Human-readable output should mention every top-line section
        // — matches Mac's `StorageReport.formatted()` block. Pinning
        // the labels here catches an accidental output-shape rename
        // before it lands in a release.
        Assert.Contains("Library size:", text);
        Assert.Contains("Database",      text);
        Assert.Contains("Metadata",      text);
        Assert.Contains("Thumbnails",    text);
        Assert.Contains("Flavor bodies", text);
        Assert.Contains("inline",        text);
        Assert.Contains("on-disk",       text);
        Assert.Contains("live entries",  text);
    }

    [Fact]
    public void FormatBytes_HandlesUnitBoundaries()
    {
        Assert.Equal("0 B",       StorageReporter.FormatBytes(0));
        Assert.Equal("512 B",     StorageReporter.FormatBytes(512));
        Assert.Equal("1023 B",    StorageReporter.FormatBytes(1023));
        Assert.Equal("1.0 KB",    StorageReporter.FormatBytes(1024));
        Assert.Equal("1.5 KB",    StorageReporter.FormatBytes(1536));
        Assert.Equal("1.0 MB",    StorageReporter.FormatBytes(1024L * 1024));
        Assert.Equal("1.00 GB",   StorageReporter.FormatBytes(1024L * 1024 * 1024));
    }
}
