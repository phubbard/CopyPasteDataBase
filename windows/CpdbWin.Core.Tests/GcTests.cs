using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class GcTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly Gc _gc;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public GcTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-gc-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
        _gc = new Gc(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private long Ingest(string text, long unixSeconds)
    {
        var snap = new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(text)),
        });
        return _ingestor.Ingest(snap, null, _device,
            DateTimeOffset.FromUnixTimeSeconds(unixSeconds)).EntryId;
    }

    [Fact]
    public void Run_NoOpOnEmptyDb()
    {
        var stats = _gc.Run();
        Assert.Equal(new Gc.Stats(0, 0, 0), stats);
    }

    [Fact]
    public void Run_TombstonesEntriesBeyondMaxLive_NewestSurvive()
    {
        var ids = new List<long>();
        for (int i = 0; i < 5; i++)
            ids.Add(Ingest($"entry-{i}", 1_700_000_000 + i));

        var stats = _gc.Run(maxLive: 3,
            now: DateTimeOffset.FromUnixTimeSeconds(1_700_001_000));

        Assert.Equal(2, stats.TombstonedExtras);

        // Live count should be 3 — the three newest by created_at.
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT id FROM entries WHERE deleted_at IS NULL ORDER BY created_at DESC";
        using var reader = cmd.ExecuteReader();
        var live = new List<long>();
        while (reader.Read()) live.Add(reader.GetInt64(0));
        Assert.Equal(new[] { ids[4], ids[3], ids[2] }, live);
    }

    [Fact]
    public void Run_TombstonedEntriesAreRemovedFromFts()
    {
        for (int i = 0; i < 4; i++) Ingest($"sweepable-{i}", 1_700_000_000 + i);

        _gc.Run(maxLive: 1, now: DateTimeOffset.FromUnixTimeSeconds(1_700_001_000));

        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM entries_fts";
        Assert.Equal(1L, (long)cmd.ExecuteScalar()!);
    }

    [Fact]
    public void Run_HardDeletesTombstonesOlderThanRetention()
    {
        var keep   = Ingest("recent-tombstone", 1_700_000_000);
        var purge  = Ingest("old-tombstone",    1_690_000_000);

        // Tombstone times: `keep` was tombstoned recently (within retention),
        // `purge` was tombstoned long enough ago to fall off.
        var nowSec = 1_700_000_000L + 31 * 86400;
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "UPDATE entries SET deleted_at = $t WHERE id = $id";
            cmd.Parameters.AddWithValue("$t", (double)(nowSec - 86400));   // 1 day ago — keep
            cmd.Parameters.AddWithValue("$id", keep);
            cmd.ExecuteNonQuery();
        }
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "UPDATE entries SET deleted_at = $t WHERE id = $id";
            cmd.Parameters.AddWithValue("$t", (double)(nowSec - 60 * 86400));  // 60 days ago — purge
            cmd.Parameters.AddWithValue("$id", purge);
            cmd.ExecuteNonQuery();
        }

        var stats = _gc.Run(
            maxLive: int.MaxValue,
            tombstoneRetention: TimeSpan.FromDays(30),
            now: DateTimeOffset.FromUnixTimeSeconds(nowSec));

        Assert.Equal(1, stats.HardDeleted);

        using var c = _db.CreateCommand();
        c.CommandText = "SELECT id FROM entries";
        using var reader = c.ExecuteReader();
        var remaining = new List<long>();
        while (reader.Read()) remaining.Add(reader.GetInt64(0));
        Assert.Equal(new[] { keep }, remaining);
    }

    [Fact]
    public void Run_CleansOrphanBlobs_KeepsReferencedOnes()
    {
        // Push two large flavors so we definitely spill to the blob store.
        var bigA = new byte[300 * 1024];
        var bigB = new byte[300 * 1024];
        new Random(1).NextBytes(bigA);
        new Random(2).NextBytes(bigB);

        var entry = _ingestor.Ingest(
            new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.png", bigA) }),
            null, _device).EntryId;
        // Plant a totally unreferenced blob on disk (e.g. left over from an
        // earlier crash / tombstoned-then-hard-deleted entry).
        var orphanKey = _blobs.Put(bigB);
        // Sanity: orphan exists and is not referenced.
        Assert.True(_blobs.Has(orphanKey));

        var stats = _gc.Run();

        Assert.Equal(1, stats.OrphanBlobs);
        Assert.False(_blobs.Has(orphanKey));

        // The referenced blob from `entry` is still there.
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT blob_key FROM entry_flavors WHERE entry_id=$id AND blob_key IS NOT NULL";
        cmd.Parameters.AddWithValue("$id", entry);
        var refKey = (string)cmd.ExecuteScalar()!;
        Assert.True(_blobs.Has(refKey));
    }

    [Fact]
    public void Run_HardDeleteCascadesToFlavorsAndPreviews()
    {
        var entry = Ingest("doomed", 1_690_000_000);
        // Tombstone with old deleted_at.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "UPDATE entries SET deleted_at = 1690000000 WHERE id = $id";
            cmd.Parameters.AddWithValue("$id", entry);
            cmd.ExecuteNonQuery();
        }

        _gc.Run(now: DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));

        using var cmd2 = _db.CreateCommand();
        cmd2.CommandText = "SELECT COUNT(*) FROM entry_flavors WHERE entry_id = $id";
        cmd2.Parameters.AddWithValue("$id", entry);
        Assert.Equal(0L, (long)cmd2.ExecuteScalar()!);
    }
}
