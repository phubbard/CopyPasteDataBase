using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class EntryRepositoryTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public EntryRepositoryTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-repo-tests-" + Guid.NewGuid().ToString("N"));
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

    private static ForegroundApp.Info Notepad() =>
        new("win.notepad", "Notepad", @"C:\Windows\System32\notepad.exe");

    [Fact]
    public void Recent_ReturnsLiveEntriesNewestFirst()
    {
        _ingestor.Ingest(TextSnapshot("first"),  null, _device,
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        _ingestor.Ingest(TextSnapshot("second"), null, _device,
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_500));

        var rows = _repo.Recent();
        Assert.Equal(2, rows.Count);
        Assert.Equal("second", rows[0].Title);
        Assert.Equal("first",  rows[1].Title);
    }

    [Fact]
    public void Recent_HidesTombstonedEntries()
    {
        var first = _ingestor.Ingest(TextSnapshot("alive"),  null, _device);
        var second = _ingestor.Ingest(TextSnapshot("buried"), null, _device);

        _repo.Tombstone(second.EntryId);

        var rows = _repo.Recent();
        Assert.Single(rows);
        Assert.Equal(first.EntryId, rows[0].Id);
    }

    [Fact]
    public void Search_MatchesFtsTokensAcrossText()
    {
        _ingestor.Ingest(TextSnapshot("the quick brown fox"),    Notepad(), _device);
        _ingestor.Ingest(TextSnapshot("lazy dog sleeps quietly"), Notepad(), _device);

        var rows = _repo.Search("brown");
        Assert.Single(rows);
        Assert.Equal("the quick brown fox", rows[0].Title);
    }

    [Fact]
    public void Search_TombstonedEntriesNotReturned()
    {
        var hit = _ingestor.Ingest(TextSnapshot("findable text"), null, _device);
        _repo.Tombstone(hit.EntryId);
        Assert.Empty(_repo.Search("findable"));
    }

    [Fact]
    public void Recent_PopulatesAppFieldsWhenSourceAppKnown()
    {
        _ingestor.Ingest(TextSnapshot("with-app"), Notepad(), _device);
        var rows = _repo.Recent();
        Assert.Equal("win.notepad", rows[0].AppBundleId);
        Assert.Equal("Notepad",     rows[0].AppName);
    }

    [Fact]
    public void Flavors_ReturnsRowPerStoredFlavor()
    {
        var snap = new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes("hi")),
            new CanonicalHash.Flavor("public.html", Encoding.UTF8.GetBytes("<b>hi</b>")),
        });
        var entry = _ingestor.Ingest(snap, null, _device);

        var flavors = _repo.Flavors(entry.EntryId);
        Assert.Equal(2, flavors.Count);
        Assert.Equal(new[] { "public.html", "public.utf8-plain-text" },
            flavors.Select(f => f.Uti).ToArray());
        Assert.All(flavors, f => Assert.True(f.IsInline));
        Assert.All(flavors, f => Assert.Null(f.BlobKey));
    }

    [Fact]
    public void GetFlavorBytes_RoundsTripsInlineData()
    {
        var bytes = Encoding.UTF8.GetBytes("inline-content");
        var entry = _ingestor.Ingest(
            new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", bytes) }),
            null, _device);

        var got = _repo.GetFlavorBytes(entry.EntryId, "public.utf8-plain-text");
        Assert.Equal(bytes, got);
    }

    [Fact]
    public void GetFlavorBytes_ReadsFromBlobStoreForLargeFlavors()
    {
        var bytes = new byte[300 * 1024];
        new Random(1).NextBytes(bytes);
        var entry = _ingestor.Ingest(
            new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.png", bytes) }),
            null, _device);

        var got = _repo.GetFlavorBytes(entry.EntryId, "public.png");
        Assert.Equal(bytes, got);
    }

    [Fact]
    public void GetFlavorBytes_NullForMissingEntry() =>
        Assert.Null(_repo.GetFlavorBytes(99999, "public.utf8-plain-text"));

    [Fact]
    public void TombstoneMany_SoftDeletesAllRequestedRows()
    {
        var ids = new List<long>();
        for (int i = 0; i < 4; i++)
            ids.Add(_ingestor.Ingest(TextSnapshot($"e-{i}"), null, _device).EntryId);

        _repo.TombstoneMany(new[] { ids[0], ids[2] });

        var alive = _repo.Recent().Select(r => r.Id).ToHashSet();
        Assert.DoesNotContain(ids[0], alive);
        Assert.Contains(ids[1], alive);
        Assert.DoesNotContain(ids[2], alive);
        Assert.Contains(ids[3], alive);
    }

    [Fact]
    public void TombstoneMany_RemovesFtsRowsForAll()
    {
        var a = _ingestor.Ingest(TextSnapshot("dog walking notes"), null, _device).EntryId;
        var b = _ingestor.Ingest(TextSnapshot("dog grooming tips"), null, _device).EntryId;
        var c = _ingestor.Ingest(TextSnapshot("cat behaviour"),     null, _device).EntryId;

        _repo.TombstoneMany(new[] { a, b });

        // Searches that hit the tombstoned ones should now be empty.
        Assert.Empty(_repo.Search("walking"));
        Assert.Empty(_repo.Search("grooming"));
        // The unaffected entry survives.
        Assert.Single(_repo.Search("behaviour"));
    }

    [Fact]
    public void TombstoneMany_EmptyInput_IsNoOp()
    {
        _ingestor.Ingest(TextSnapshot("untouched"), null, _device);
        _repo.TombstoneMany(Array.Empty<long>());
        Assert.Single(_repo.Recent());
    }

    [Fact]
    public void LiveCount_TracksLiveAndTombstoned()
    {
        Assert.Equal(0, _repo.LiveCount());

        var a = _ingestor.Ingest(TextSnapshot("a"), null, _device).EntryId;
        var b = _ingestor.Ingest(TextSnapshot("b"), null, _device).EntryId;
        _ingestor.Ingest(TextSnapshot("c"), null, _device);
        Assert.Equal(3, _repo.LiveCount());

        _repo.Tombstone(a);
        _repo.Tombstone(b);
        Assert.Equal(1, _repo.LiveCount());
    }
}
