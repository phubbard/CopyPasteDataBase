using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class IngestorTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingest;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public IngestorTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA foreign_keys = ON";
            cmd.ExecuteNonQuery();
        }
        Schema.Initialize(_db);

        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-ingest-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingest = new Ingestor(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private static ClipboardSnapshot TextSnapshot(string text) =>
        new(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(text)) });

    private static ForegroundApp.Info NotepadApp() =>
        new("win.notepad", "Notepad", @"C:\Windows\System32\notepad.exe");

    private long ScalarLong(string sql, long? entryId = null)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        if (entryId is not null) cmd.Parameters.AddWithValue("$id", entryId.Value);
        return (long)cmd.ExecuteScalar()!;
    }

    private double ScalarDouble(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        return (double)cmd.ExecuteScalar()!;
    }

    private object? ScalarObject(string sql, long entryId)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$id", entryId);
        return cmd.ExecuteScalar();
    }

    [Fact]
    public void Ingest_EmptySnapshot_IsSkipped()
    {
        var outcome = _ingest.Ingest(
            new ClipboardSnapshot(Array.Empty<CanonicalHash.Flavor>()), null, _device);

        Assert.Equal(IngestKind.Skipped, outcome.Kind);
        Assert.Equal(0L, ScalarLong("SELECT COUNT(*) FROM entries"));
    }

    [Fact]
    public void Ingest_FirstSnapshot_PopulatesAllRelatedRows()
    {
        var outcome = _ingest.Ingest(TextSnapshot("hello"), NotepadApp(), _device);

        Assert.Equal(IngestKind.Inserted, outcome.Kind);
        Assert.Equal(1L, ScalarLong("SELECT COUNT(*) FROM entries"));
        Assert.Equal(1L, ScalarLong("SELECT COUNT(*) FROM entry_flavors"));
        Assert.Equal(1L, ScalarLong("SELECT COUNT(*) FROM apps"));
        Assert.Equal(1L, ScalarLong("SELECT COUNT(*) FROM devices"));
        Assert.Equal(1L, ScalarLong("SELECT COUNT(*) FROM entries_fts"));
    }

    [Fact]
    public void Ingest_DuplicateContent_BumpsCreatedAtKeepsCapturedAt()
    {
        var first = _ingest.Ingest(TextSnapshot("hello"), null, _device,
            capturedAt: DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var second = _ingest.Ingest(TextSnapshot("hello"), null, _device,
            capturedAt: DateTimeOffset.FromUnixTimeSeconds(1_700_000_500));

        Assert.Equal(IngestKind.Bumped, second.Kind);
        Assert.Equal(first.EntryId, second.EntryId);
        Assert.Equal(1L, ScalarLong("SELECT COUNT(*) FROM entries"));

        var captured = ScalarDouble("SELECT captured_at FROM entries");
        var created = ScalarDouble("SELECT created_at FROM entries");
        Assert.Equal(1_700_000_000.0, captured);  // unchanged
        Assert.Equal(1_700_000_500.0, created);   // bumped
    }

    [Fact]
    public void Ingest_DifferentContent_InsertsSeparateEntries()
    {
        _ingest.Ingest(TextSnapshot("first"), null, _device);
        _ingest.Ingest(TextSnapshot("second"), null, _device);

        Assert.Equal(2L, ScalarLong("SELECT COUNT(*) FROM entries"));
    }

    [Fact]
    public void Ingest_LargeFlavor_SpillsToBlobStore_DataNullKeySet()
    {
        var bytes = new byte[300 * 1024];
        new Random(42).NextBytes(bytes);
        var snap = new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.png", bytes) });

        var outcome = _ingest.Ingest(snap, null, _device);

        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT data, blob_key, size FROM entry_flavors WHERE entry_id = $id";
        cmd.Parameters.AddWithValue("$id", outcome.EntryId);
        using var reader = cmd.ExecuteReader();
        Assert.True(reader.Read());
        Assert.True(reader.IsDBNull(0));
        Assert.False(reader.IsDBNull(1));
        Assert.Equal((long)bytes.Length, reader.GetInt64(2));

        var key = reader.GetString(1);
        Assert.True(_blobs.Has(key));
        Assert.Equal(bytes, _blobs.Get(key));
    }

    [Fact]
    public void Ingest_SmallFlavor_StaysInline_DataSetKeyNull()
    {
        var bytes = Encoding.UTF8.GetBytes("inline-payload");
        var snap = new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", bytes) });

        var outcome = _ingest.Ingest(snap, null, _device);

        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT data, blob_key FROM entry_flavors WHERE entry_id = $id";
        cmd.Parameters.AddWithValue("$id", outcome.EntryId);
        using var reader = cmd.ExecuteReader();
        Assert.True(reader.Read());
        Assert.False(reader.IsDBNull(0));
        Assert.True(reader.IsDBNull(1));
        Assert.Equal(bytes, (byte[])reader.GetValue(0));
    }

    [Fact]
    public void Ingest_FlavorJustUnderThreshold_StaysInline()
    {
        var bytes = new byte[Ingestor.BlobInlineThresholdBytes - 1];
        var snap = new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", bytes) });
        var outcome = _ingest.Ingest(snap, null, _device);

        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT data IS NULL, blob_key IS NULL FROM entry_flavors WHERE entry_id = $id";
        cmd.Parameters.AddWithValue("$id", outcome.EntryId);
        using var reader = cmd.ExecuteReader();
        reader.Read();
        Assert.Equal(0L, reader.GetInt64(0));   // data NOT NULL
        Assert.Equal(1L, reader.GetInt64(1));   // blob_key IS NULL
    }

    [Fact]
    public void Ingest_FlavorAtThreshold_SpillsToBlob()
    {
        var bytes = new byte[Ingestor.BlobInlineThresholdBytes];
        var snap = new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.png", bytes) });
        var outcome = _ingest.Ingest(snap, null, _device);

        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT data IS NULL, blob_key IS NULL FROM entry_flavors WHERE entry_id = $id";
        cmd.Parameters.AddWithValue("$id", outcome.EntryId);
        using var reader = cmd.ExecuteReader();
        reader.Read();
        Assert.Equal(1L, reader.GetInt64(0));   // data IS NULL
        Assert.Equal(0L, reader.GetInt64(1));   // blob_key NOT NULL
    }

    [Fact]
    public void Ingest_PopulatesContentHash_MatchingSwiftReference()
    {
        var outcome = _ingest.Ingest(TextSnapshot("hello"), null, _device);
        var hash = (byte[])ScalarObject("SELECT content_hash FROM entries WHERE id = $id", outcome.EntryId)!;
        Assert.Equal(
            "b22187611777c1e9c84c3fdd054ed311a47d12f33cba6d1e7761bd3a7314073a",
            CanonicalHash.ToHex(hash));
    }

    [Fact]
    public void Ingest_PopulatesKindFromClassifier()
    {
        var url = new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.url", Encoding.UTF8.GetBytes("https://example.com")),
        });
        var outcome = _ingest.Ingest(url, null, _device);
        Assert.Equal("link", (string)ScalarObject("SELECT kind FROM entries WHERE id = $id", outcome.EntryId)!);
    }

    [Fact]
    public void Ingest_PopulatesTitleAndPreview()
    {
        var snap = TextSnapshot("first line\nsecond line\nthird line");
        var outcome = _ingest.Ingest(snap, null, _device);

        Assert.Equal("first line",
            ScalarObject("SELECT title FROM entries WHERE id = $id", outcome.EntryId));
        Assert.Equal("first line\nsecond line\nthird line",
            ScalarObject("SELECT text_preview FROM entries WHERE id = $id", outcome.EntryId));
    }

    [Fact]
    public void Ingest_NullSourceApp_LeavesAppIdNull()
    {
        var outcome = _ingest.Ingest(TextSnapshot("hi"), null, _device);
        Assert.IsType<DBNull>(ScalarObject("SELECT source_app_id FROM entries WHERE id = $id", outcome.EntryId));
    }

    [Fact]
    public void Ingest_PopulatesTotalSize_AsSumOfFlavorBytes()
    {
        var snap = new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.utf8-plain-text", new byte[100]),
            new CanonicalHash.Flavor("public.html",            new byte[200]),
        });
        var outcome = _ingest.Ingest(snap, null, _device);

        Assert.Equal(300L, ScalarLong("SELECT total_size FROM entries WHERE id = $id", outcome.EntryId));
    }

    [Fact]
    public void Ingest_DeviceUpsert_ReusesExistingRow()
    {
        _ingest.Ingest(TextSnapshot("a"), null, _device);
        _ingest.Ingest(TextSnapshot("b"), null, _device);
        Assert.Equal(1L, ScalarLong("SELECT COUNT(*) FROM devices"));
    }

    [Fact]
    public void Ingest_AppUpsert_ReusesExistingRow()
    {
        var app = NotepadApp();
        _ingest.Ingest(TextSnapshot("a"), app, _device);
        _ingest.Ingest(TextSnapshot("b"), app, _device);
        Assert.Equal(1L, ScalarLong("SELECT COUNT(*) FROM apps"));
    }

    [Fact]
    public void Ingest_FtsRow_IsSearchableByTextAndAppName()
    {
        var outcome = _ingest.Ingest(
            TextSnapshot("the quick brown fox"), NotepadApp(), _device);

        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "SELECT rowid FROM entries_fts WHERE entries_fts MATCH 'brown'";
            Assert.Equal(outcome.EntryId, (long)cmd.ExecuteScalar()!);
        }

        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "SELECT rowid FROM entries_fts WHERE entries_fts MATCH 'app_name:notepad'";
            Assert.Equal(outcome.EntryId, (long)cmd.ExecuteScalar()!);
        }
    }

    [Fact]
    public void Ingest_TombstonedEntry_DoesNotBlockReinsertOfSameContent()
    {
        var first = _ingest.Ingest(TextSnapshot("hello"), null, _device);

        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "UPDATE entries SET deleted_at = 1.0 WHERE id = $id";
            cmd.Parameters.AddWithValue("$id", first.EntryId);
            cmd.ExecuteNonQuery();
        }

        var second = _ingest.Ingest(TextSnapshot("hello"), null, _device);
        Assert.Equal(IngestKind.Inserted, second.Kind);
        Assert.NotEqual(first.EntryId, second.EntryId);
        Assert.Equal(2L, ScalarLong("SELECT COUNT(*) FROM entries"));
    }

    [Fact]
    public void Ingest_UuidIsStoredAsBigEndian16Bytes()
    {
        var outcome = _ingest.Ingest(TextSnapshot("uuid-check"), null, _device);
        var uuid = (byte[])ScalarObject("SELECT uuid FROM entries WHERE id = $id", outcome.EntryId)!;
        Assert.Equal(16, uuid.Length);

        // Round-trip through Guid(big-endian) and back; bytes must match.
        var g = new Guid(uuid, bigEndian: true);
        var back = new byte[16];
        Assert.True(g.TryWriteBytes(back, bigEndian: true, out _));
        Assert.Equal(uuid, back);
    }

    [Fact]
    public void Ingest_MultipleFlavors_AllStoredOneRowPerUti()
    {
        var snap = new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes("hello")),
            new CanonicalHash.Flavor("public.html", Encoding.UTF8.GetBytes("<b>hello</b>")),
        });
        var outcome = _ingest.Ingest(snap, null, _device);

        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT uti FROM entry_flavors WHERE entry_id = $id ORDER BY uti";
        cmd.Parameters.AddWithValue("$id", outcome.EntryId);
        using var reader = cmd.ExecuteReader();
        var utis = new List<string>();
        while (reader.Read()) utis.Add(reader.GetString(0));
        Assert.Equal(new[] { "public.html", "public.utf8-plain-text" }, utis);
    }
}
