using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Portability;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class UrlImporterTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public UrlImporterTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-urlimport-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
        _repo = new EntryRepository(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    // ─── Parse: scheme filter + comment/blank stripping ──────────────────

    [Fact]
    public void Parse_StripsBlankAndCommentLines()
    {
        var (accepted, rejected) = UrlImporter.Parse(
            "\n  \nhttps://a.example/\n# a comment\n#another\n   https://b.example/  \n\n");
        Assert.Equal(new[] { "https://a.example/", "https://b.example/" }, accepted);
        Assert.Empty(rejected);
    }

    [Theory]
    [InlineData("https://ok.example/",  true)]
    [InlineData("http://ok.example/",   true)]
    [InlineData("file:///C:/notes.txt", true)]
    [InlineData("ftp://no.example/",    false)]
    [InlineData("mailto:a@b.com",       false)]
    [InlineData("javascript:alert(1)",  false)]
    [InlineData("not a url",            false)]
    public void Parse_AcceptsOnlyHttpHttpsFile(string line, bool accepted)
    {
        var (acc, rej) = UrlImporter.Parse(line);
        if (accepted)
        {
            Assert.Single(acc);
            Assert.Empty(rej);
        }
        else
        {
            Assert.Empty(acc);
            Assert.Single(rej);
            Assert.Equal(line, rej[0].Line);
            Assert.False(string.IsNullOrEmpty(rej[0].Reason));
        }
    }

    [Fact]
    public void Parse_RejectionReasonNamesTheScheme()
    {
        var (_, rej) = UrlImporter.Parse("ftp://x.example/");
        Assert.Contains("ftp", rej[0].Reason);
        Assert.Contains("not http/https/file", rej[0].Reason);
    }

    [Fact]
    public void Parse_UnparseableLineGetsUnparseableReason()
    {
        var (_, rej) = UrlImporter.Parse("h ttp://broken");
        Assert.Single(rej);
        Assert.Equal("unparseable", rej[0].Reason);
    }

    // ─── Run: ingest + kind=link + importer attribution ──────────────────

    [Fact]
    public void Run_IngestsAcceptedUrlsAsKindLink()
    {
        var result = UrlImporter.Run(
            "https://example.com/a\nhttps://example.com/b\n# skip\nbogus://x",
            _ingestor, _device);

        Assert.Equal(2, result.AcceptedCount);
        Assert.Equal(2, result.Inserted);
        Assert.Equal(0, result.Bumped);
        Assert.Single(result.Rejected);

        var rows = _repo.Recent();
        Assert.Equal(2, rows.Count);
        Assert.All(rows, r => Assert.Equal("link", r.Kind));
    }

    [Fact]
    public void Run_AttributesToSyntheticImporterApp()
    {
        UrlImporter.Run("https://example.com/x", _ingestor, _device);

        var row = _repo.Recent().Single();
        Assert.Equal(UrlImporter.ImporterApp.BundleId, row.AppBundleId);
        Assert.Equal(UrlImporter.ImporterApp.Name, row.AppName);
        Assert.Equal("cpdb import", row.AppName);
    }

    [Fact]
    public void Run_DuplicateUrlBumpsNotDoubleInserts()
    {
        var r1 = UrlImporter.Run("https://dup.example/", _ingestor, _device);
        var r2 = UrlImporter.Run("https://dup.example/", _ingestor, _device);

        Assert.Equal(1, r1.Inserted);
        Assert.Equal(0, r2.Inserted);
        Assert.Equal(1, r2.Bumped);
        Assert.Single(_repo.Recent());
    }

    [Fact]
    public void Run_EmptyAcceptedSet_NoIngest()
    {
        var result = UrlImporter.Run("# only comments\n\n  \n", _ingestor, _device);
        Assert.Equal(0, result.AcceptedCount);
        Assert.Equal(0, result.Inserted);
        Assert.Empty(_repo.Recent());
    }

    // ─── spreadSeconds backdates captured_at oldest-first ────────────────

    [Fact]
    public void Run_SpreadSeconds_BackdatesCapturedAtOldestFirst()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        // 4 URLs, 300s spread → step = 75s. Line 0 (first) is oldest:
        // offset = 75 * (4-1-0) = 225s before now. Line 3 (last) =
        // offset 0 = now.
        UrlImporter.Run(
            "https://e/0\nhttps://e/1\nhttps://e/2\nhttps://e/3",
            _ingestor, _device, spreadSeconds: 300, now: now);

        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            SELECT text_preview, captured_at FROM entries
            WHERE deleted_at IS NULL ORDER BY captured_at ASC
            """;
        using var r = cmd.ExecuteReader();
        var ordered = new List<(string url, double ts)>();
        while (r.Read()) ordered.Add((r.GetString(0), r.GetDouble(1)));

        Assert.Equal(4, ordered.Count);
        // Oldest captured_at = the first line in the file.
        Assert.Equal("https://e/0", ordered[0].url);
        Assert.Equal("https://e/3", ordered[3].url);
        // First line is 225s before `now`; last line is exactly `now`.
        var nowSec = now.ToUnixTimeMilliseconds() / 1000.0;
        Assert.Equal(nowSec - 225, ordered[0].ts, precision: 3);
        Assert.Equal(nowSec, ordered[3].ts, precision: 3);
    }

    [Fact]
    public void Snapshot_HasUrlAndPlainTextFlavors()
    {
        var snap = UrlImporter.Snapshot("https://example.com/");
        Assert.Equal(2, snap.Flavors.Count);
        Assert.Contains(snap.Flavors, f => f.Uti == "public.url");
        Assert.Contains(snap.Flavors, f => f.Uti == "public.utf8-plain-text");
        // Both flavors carry the URL bytes verbatim.
        Assert.All(snap.Flavors,
            f => Assert.Equal("https://example.com/",
                Encoding.UTF8.GetString(f.Data.Span)));
    }
}
