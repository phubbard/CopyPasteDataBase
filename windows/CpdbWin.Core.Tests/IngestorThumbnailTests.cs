using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class IngestorThumbnailTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public IngestorThumbnailTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-thumb-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
        _repo = new EntryRepository(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private static byte[] BuildPng(int width, int height)
    {
        int rowStride = ((width * 3 + 3) / 4) * 4;
        int pixelBytes = rowStride * height;
        using var ms = new MemoryStream();
        var w = new BinaryWriter(ms);
        w.Write(40); w.Write(width); w.Write(height);
        w.Write((short)1); w.Write((short)24);
        w.Write(0); w.Write(pixelBytes);
        w.Write(0); w.Write(0); w.Write(0); w.Write(0);
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                // Varied pixels so the encoded PNG is unambiguously above
                // KindClassifier.MinImageBytes (1024). Solid colour
                // compresses below that and gets classified as "other".
                w.Write((byte)(x & 0xFF));
                w.Write((byte)(y & 0xFF));
                w.Write((byte)((x + y) & 0xFF));
            }
            int pad = rowStride - width * 3;
            for (int i = 0; i < pad; i++) w.Write((byte)0);
        }
        return DibToPng.Convert(ms.ToArray())!;
    }

    [Fact]
    public void Ingest_ImageEntry_PopulatesPreviewsRow()
    {
        var png = BuildPng(400, 300);
        var snap = new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.png", png) });

        var outcome = _ingestor.Ingest(snap, null, _device);
        Assert.Equal(IngestKind.Inserted, outcome.Kind);

        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT thumb_small, thumb_large FROM previews WHERE entry_id = $id";
        cmd.Parameters.AddWithValue("$id", outcome.EntryId);
        using var reader = cmd.ExecuteReader();
        Assert.True(reader.Read());
        Assert.False(reader.IsDBNull(0));
        Assert.False(reader.IsDBNull(1));
        var small = (byte[])reader.GetValue(0);
        var large = (byte[])reader.GetValue(1);
        Assert.Equal(0xFF, small[0]); Assert.Equal(0xD8, small[1]);  // JPEG SOI
        Assert.Equal(0xFF, large[0]); Assert.Equal(0xD8, large[1]);
    }

    [Fact]
    public void Ingest_TextEntry_HasNoPreviewsRow()
    {
        _ingestor.Ingest(new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.utf8-plain-text", "hello"u8.ToArray()),
        }), null, _device);

        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM previews";
        Assert.Equal(0L, (long)cmd.ExecuteScalar()!);
    }

    [Fact]
    public void GetThumbLarge_ReturnsBytesForImageEntries()
    {
        var png = BuildPng(400, 400);
        var img = _ingestor.Ingest(
            new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.png", png) }),
            null, _device);

        var large = _repo.GetThumbLarge(img.EntryId);
        Assert.NotNull(large);
        Assert.Equal(0xFF, large![0]);
        Assert.Equal(0xD8, large[1]);
    }

    [Fact]
    public void GetThumbLarge_NullForTextEntries()
    {
        var txt = _ingestor.Ingest(
            new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", "hi"u8.ToArray()) }),
            null, _device);
        Assert.Null(_repo.GetThumbLarge(txt.EntryId));
    }

    [Fact]
    public void Recent_ReturnsThumbSmall_OnlyForImageEntries()
    {
        var png = BuildPng(400, 400);
        Assert.True(png.Length >= 1024,
            "test fixture must exceed KindClassifier.MinImageBytes");
        var img = _ingestor.Ingest(
            new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.png", png) }),
            null, _device);
        var txt = _ingestor.Ingest(
            new ClipboardSnapshot(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", "hi"u8.ToArray()) }),
            null, _device);

        var rows = _repo.Recent();
        Assert.Equal(2, rows.Count);

        var imgRow = rows.Single(r => r.Id == img.EntryId);
        var txtRow = rows.Single(r => r.Id == txt.EntryId);
        Assert.NotNull(imgRow.ThumbSmall);
        Assert.Null(txtRow.ThumbSmall);
    }
}
