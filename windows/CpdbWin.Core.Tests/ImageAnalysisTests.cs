using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Maintenance;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// DB-level coverage for the image-analysis backfill: candidate
/// selection, the OCR settle (incl. FTS5 fold-in), and the force
/// re-arm. The OCR engine itself (<c>ImageOcr</c> → Windows.Media.Ocr)
/// is environment-dependent (needs a language pack) and is verified
/// manually, not here.
/// </summary>
public class ImageAnalysisTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public ImageAnalysisTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-imgocr-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
        _repo = new EntryRepository(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private int _seq;

    // 24-bit DIB → PNG (same shape as IngestorThumbnailTests): varied
    // pixels so the encoded image clears KindClassifier's 1 KB floor.
    // `seed` perturbs the pixels so successive images are distinct —
    // otherwise the canonical content-hash dedups them into one row.
    private static byte[] BuildPng(int width, int height, int seed)
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
                w.Write((byte)((x + seed) & 0xFF));
                w.Write((byte)((y + seed) & 0xFF));
                w.Write((byte)((x + y + seed) & 0xFF));
            }
            int pad = rowStride - width * 3;
            for (int i = 0; i < pad; i++) w.Write((byte)0);
        }
        return DibToPng.Convert(ms.ToArray())!;
    }

    private long IngestImage() =>
        _ingestor.Ingest(new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.png", BuildPng(400, 300, ++_seq)),
        }), null, _device).EntryId;

    private long IngestText(string s) =>
        _ingestor.Ingest(new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.utf8-plain-text",
                System.Text.Encoding.UTF8.GetBytes(s)),
        }), null, _device).EntryId;

    [Fact]
    public void Candidates_AreUnanalyzedImagesOnly()
    {
        var img1 = IngestImage();
        var img2 = IngestImage();
        IngestText("not an image");                       // wrong kind
        var analyzed = IngestImage();
        _repo.SettleImageOcr(analyzed, "already done");    // analyzed_at set

        var ids = _repo.NextImageAnalysisCandidates(10);

        Assert.Contains(img1, ids);
        Assert.Contains(img2, ids);
        Assert.DoesNotContain(analyzed, ids);              // analyzed_at not null
        Assert.Equal(2, ids.Count);                        // text row excluded
    }

    [Fact]
    public void Candidates_ExcludeTombstoned()
    {
        var img = IngestImage();
        _repo.Tombstone(img);
        Assert.DoesNotContain(img, _repo.NextImageAnalysisCandidates(10));
    }

    [Fact]
    public void SettleImageOcr_WithText_StampsAnalyzed_AndIsSearchable()
    {
        var img = IngestImage();
        _repo.SettleImageOcr(img, "INVOICE total 4815 Acme widgets");

        // No longer a candidate (analyzed_at stamped).
        Assert.DoesNotContain(img, _repo.NextImageAnalysisCandidates(10));

        // ocr_text persisted.
        using (var c = _db.CreateCommand())
        {
            c.CommandText = "SELECT ocr_text, analyzed_at FROM entries WHERE id=$id";
            c.Parameters.AddWithValue("$id", img);
            using var r = c.ExecuteReader();
            Assert.True(r.Read());
            Assert.Equal("INVOICE total 4815 Acme widgets", r.GetString(0));
            Assert.False(r.IsDBNull(1));                    // analyzed_at set
        }

        // Folded into FTS5 — the screenshot is now findable by its text.
        var hit = _repo.Search("Acme*");
        Assert.Contains(hit, e => e.Id == img);
    }

    [Fact]
    public void SettleImageOcr_NoText_StillStampsAnalyzed()
    {
        var img = IngestImage();
        _repo.SettleImageOcr(img, null);   // "we looked, no text"

        Assert.DoesNotContain(img, _repo.NextImageAnalysisCandidates(10));
        using var c = _db.CreateCommand();
        c.CommandText = "SELECT ocr_text, analyzed_at FROM entries WHERE id=$id";
        c.Parameters.AddWithValue("$id", img);
        using var r = c.ExecuteReader();
        Assert.True(r.Read());
        Assert.True(r.IsDBNull(0));         // ocr_text NULL
        Assert.False(r.IsDBNull(1));        // analyzed_at still stamped
    }

    [Fact]
    public void Recent_HasOcrFlag_TracksOcrText()
    {
        var img = IngestImage();
        Assert.False(_repo.Recent().First(r => r.Id == img).HasOcr);  // pre-OCR

        _repo.SettleImageOcr(img, "some recognised words");
        Assert.True(_repo.Recent().First(r => r.Id == img).HasOcr);   // text present

        _repo.SettleImageOcr(img, null);                              // "no text"
        Assert.False(_repo.Recent().First(r => r.Id == img).HasOcr);  // flag clears
    }

    [Fact]
    public void GetOcrText_RoundTrips_NullsCleanly()
    {
        var img = IngestImage();
        Assert.Null(_repo.GetOcrText(img));                           // un-analyzed

        _repo.SettleImageOcr(img, "  hello world  ");
        Assert.Equal("  hello world  ", _repo.GetOcrText(img));        // exact bytes

        _repo.SettleImageOcr(img, null);
        Assert.Null(_repo.GetOcrText(img));                           // back to null
    }

    [Fact]
    public void ResetImageAnalysis_ReArmsImagesOnly()
    {
        var img = IngestImage();
        var txt = IngestText("plain text row");
        _repo.SettleImageOcr(img, "some ocr");
        Assert.DoesNotContain(img, _repo.NextImageAnalysisCandidates(10));

        var res = MaintenanceCommands.ResetImageAnalysis(_db);

        Assert.Equal(1, res.LinkStateReset);                       // one image re-armed
        Assert.Contains(img, _repo.NextImageAnalysisCandidates(10)); // candidate again
        // The text row was never an image candidate and is untouched.
        Assert.DoesNotContain(txt, _repo.NextImageAnalysisCandidates(10));
    }
}
