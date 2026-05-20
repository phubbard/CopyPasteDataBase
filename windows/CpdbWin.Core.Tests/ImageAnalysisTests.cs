using CpdbWin.Core.Analysis;
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

    /// <summary>Project candidates → ids for the Assert.Contains assertions.</summary>
    private IReadOnlyList<long> CandidateIds(int n = 10) =>
        _repo.NextImageAnalysisCandidates(n).Select(c => c.Id).ToList();

    [Fact]
    public void Candidates_AreUnanalyzedImagesOnly()
    {
        var img1 = IngestImage();
        var img2 = IngestImage();
        IngestText("not an image");                              // wrong kind
        var analyzed = IngestImage();
        // Fully settle both passes — ocr_at + tags_at both set, so the
        // row drops out of NextImageAnalysisCandidates entirely.
        _repo.SettleImageAnalysis(analyzed, "already done", "laptop, keyboard, mouse");

        var ids = CandidateIds();

        Assert.Contains(img1, ids);
        Assert.Contains(img2, ids);
        Assert.DoesNotContain(analyzed, ids);                    // both sentinels stamped
        Assert.Equal(2, ids.Count);                              // text row excluded
    }

    [Fact]
    public void Candidates_ExcludeTombstoned()
    {
        var img = IngestImage();
        _repo.Tombstone(img);
        Assert.DoesNotContain(img, CandidateIds());
    }

    [Fact]
    public void SettleImageOcr_StampsOcrSentinelOnly_TagsRowStillCandidate()
    {
        var img = IngestImage();
        _repo.SettleImageOcr(img, "INVOICE total 4815 Acme widgets");

        // ocr_text persisted + ocr_at stamped; analyzed_at stamped too.
        using (var c = _db.CreateCommand())
        {
            c.CommandText =
                "SELECT ocr_text, ocr_at, tags_at, analyzed_at FROM entries WHERE id=$id";
            c.Parameters.AddWithValue("$id", img);
            using var r = c.ExecuteReader();
            Assert.True(r.Read());
            Assert.Equal("INVOICE total 4815 Acme widgets", r.GetString(0));
            Assert.False(r.IsDBNull(1));                          // ocr_at set
            Assert.True(r.IsDBNull(2));                           // tags_at NULL (per-pass!)
            Assert.False(r.IsDBNull(3));                          // analyzed_at set
        }

        // Folded into FTS5 — searchable by the OCR text.
        Assert.Contains(_repo.Search("Acme*"), e => e.Id == img);

        // Row is still a candidate — for tags (NeedsOcr=false, NeedsTags=true).
        // This is the whole point of per-pass settle: a Preferences
        // "Re-OCR images" reset doesn't need to also re-tag.
        var c2 = _repo.NextImageAnalysisCandidates(10).First(x => x.Id == img);
        Assert.False(c2.NeedsOcr);
        Assert.True(c2.NeedsTags);
    }

    [Fact]
    public void SettleImageOcr_NoText_StillStampsOcrSentinel()
    {
        var img = IngestImage();
        _repo.SettleImageOcr(img, null);   // "we looked, no text"

        using var c = _db.CreateCommand();
        c.CommandText = "SELECT ocr_text, ocr_at FROM entries WHERE id=$id";
        c.Parameters.AddWithValue("$id", img);
        using var r = c.ExecuteReader();
        Assert.True(r.Read());
        Assert.True(r.IsDBNull(0));            // ocr_text NULL
        Assert.False(r.IsDBNull(1));           // ocr_at stamped → not an OCR candidate
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
    public void SettleImageAnalysis_PersistsOcrAndTags_BothFtsSearchable()
    {
        var img = IngestImage();
        _repo.SettleImageAnalysis(img, "RECEIPT total $42", "laptop keyboard");

        using (var c = _db.CreateCommand())
        {
            c.CommandText =
                "SELECT ocr_text, image_tags, analyzed_at FROM entries WHERE id=$id";
            c.Parameters.AddWithValue("$id", img);
            using var r = c.ExecuteReader();
            Assert.True(r.Read());
            Assert.Equal("RECEIPT total $42", r.GetString(0));
            Assert.Equal("laptop keyboard", r.GetString(1));
            Assert.False(r.IsDBNull(2));
        }

        // Both OCR and tag columns fold into FTS5 — search by a word
        // from each independently and the same row matches.
        Assert.Contains(_repo.Search("RECEIPT*"), e => e.Id == img);
        Assert.Contains(_repo.Search("laptop*"),  e => e.Id == img);
    }

    [Fact]
    public void Classifier_BundledModelLoads()
    {
        // Smoke check that the Models\ files were CopyToOutputDirectory
        // -ied into the test bin and ONNX Runtime + the native libs
        // resolve under net8.0-windows on this host. If this ever fails
        // in CI on a fresh runner, the package's runtimes/ propagation
        // is the first thing to check.
        Assert.True(ImageClassifier.IsAvailable,
            "MobileNetV2 model + labels failed to load — bundled files "
          + "missing from output, or ONNX Runtime native libs didn't resolve.");
    }

    [Theory]
    [InlineData(null,                                new string[0])]
    [InlineData("",                                  new string[0])]
    [InlineData("   ",                               new string[0])]
    // Canonical v1.25.0+ form: comma+space. Multi-word labels survive.
    [InlineData("great white shark, laptop, mouse",  new[] { "great white shark", "laptop", "mouse" })]
    // Legacy v1.24.0 space-only form (only correct for single-word labels).
    [InlineData("laptop keyboard mouse",             new[] { "laptop", "keyboard", "mouse" })]
    // Single tag, no separator — round-trips as one label.
    [InlineData("laptop",                            new[] { "laptop" })]
    public void ImageTags_Parse(string? raw, string[] expected)
        => Assert.Equal(expected, ImageTags.Parse(raw));

    [Fact]
    public void SettleImageAnalysis_CommaSeparatedTags_AllTokensSearchable()
    {
        // The classifier now stores comma+space ("great white shark,
        // laptop"); FTS5's unicode61 tokenizer splits on both ',' and
        // whitespace, so a multi-word label still indexes each token.
        var img = IngestImage();
        _repo.SettleImageAnalysis(img, ocrText: null,
            imageTags: "great white shark, laptop, mouse");

        // The multi-word label's *components* are independently
        // searchable (the whole point of comma-separating).
        Assert.Contains(_repo.Search("shark*"),  e => e.Id == img);
        Assert.Contains(_repo.Search("laptop*"), e => e.Id == img);
        Assert.Contains(_repo.Search("mouse*"),  e => e.Id == img);

        // And the row reads back the raw string for UI display.
        Assert.Equal("great white shark, laptop, mouse",
            _repo.Recent().First(r => r.Id == img).ImageTags);
    }

    [Fact]
    public void ResetImageAnalysis_ReArmsImagesOnly_BothPasses()
    {
        var img = IngestImage();
        var txt = IngestText("plain text row");
        _repo.SettleImageAnalysis(img, "some ocr", "laptop, mouse");
        Assert.DoesNotContain(img, CandidateIds());

        var res = MaintenanceCommands.ResetImageAnalysis(_db);

        Assert.Equal(1, res.LinkStateReset);                       // one image re-armed
        var c = _repo.NextImageAnalysisCandidates(10).First(x => x.Id == img);
        Assert.True(c.NeedsOcr);                                   // both passes re-armed
        Assert.True(c.NeedsTags);
        // The text row was never an image candidate and is untouched.
        Assert.DoesNotContain(txt, CandidateIds());
    }

    [Fact]
    public void ResetImageOcr_ReArmsOcrOnly_KeepsTagsSentinel()
    {
        // Per-pass independence: a "Re-OCR images" reset must re-arm
        // ONLY the OCR pass. Existing classifier tags must survive.
        var img = IngestImage();
        _repo.SettleImageAnalysis(img, "some ocr", "laptop, mouse");
        Assert.DoesNotContain(img, CandidateIds());

        var res = MaintenanceCommands.ResetImageOcr(_db);
        Assert.Equal(1, res.LinkStateReset);

        var c = _repo.NextImageAnalysisCandidates(10).First(x => x.Id == img);
        Assert.True(c.NeedsOcr);                                   // OCR re-armed
        Assert.False(c.NeedsTags);                                 // tags untouched

        // image_tags value is preserved (the column wasn't cleared,
        // just the sentinel — the actual tags remain visible in the UI
        // until the classifier overwrites them on the next run).
        Assert.Equal("laptop, mouse",
            _repo.Recent().First(r => r.Id == img).ImageTags);
    }

    [Fact]
    public void ResetImageTags_ReArmsTagsOnly_KeepsOcrSentinel()
    {
        // Mirror of the above: "Re-tag images" doesn't re-OCR.
        var img = IngestImage();
        _repo.SettleImageAnalysis(img, "OCR text", "laptop, mouse");
        Assert.DoesNotContain(img, CandidateIds());

        var res = MaintenanceCommands.ResetImageTags(_db);
        Assert.Equal(1, res.LinkStateReset);

        var c = _repo.NextImageAnalysisCandidates(10).First(x => x.Id == img);
        Assert.False(c.NeedsOcr);                                  // OCR untouched
        Assert.True(c.NeedsTags);                                  // tags re-armed

        // ocr_text value is preserved on disk + in the row.
        Assert.Equal("OCR text", _repo.GetOcrText(img));
    }
}
