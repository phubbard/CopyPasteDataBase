using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Coverage for <see cref="FixtureManager"/>. Uses real on-disk paths
/// (not <c>:memory:</c>) so the WAL-checkpoint + file-copy path is
/// exercised end-to-end — the whole point of the fixture flow is to
/// produce a standalone snapshot that opens fresh.
/// </summary>
public class FixtureManagerTests : IDisposable
{
    private readonly string _liveRoot;
    private readonly string _fixturesRoot;
    private readonly string _liveDb;
    private readonly string _liveBlobs;
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly Ingestor _ingestor;
    private readonly FixtureManager _mgr;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public FixtureManagerTests()
    {
        var scratch = Path.Combine(Path.GetTempPath(),
            "cpdb-fixture-tests-" + Guid.NewGuid().ToString("N"));
        _liveRoot     = Path.Combine(scratch, "cpdb");
        _fixturesRoot = Path.Combine(scratch, "cpdb-fixtures");
        _liveDb       = Path.Combine(_liveRoot, AppPaths.DbFileName);
        _liveBlobs    = Path.Combine(_liveRoot, AppPaths.BlobsDirName);
        Directory.CreateDirectory(_liveRoot);
        Directory.CreateDirectory(_liveBlobs);

        _db = new SqliteConnection($"Data Source={_liveDb}");
        _db.Open();
        Schema.Initialize(_db);
        _blobs = new BlobStore(_liveBlobs);
        _ingestor = new Ingestor(_db, _blobs);
        _mgr = new FixtureManager(_liveRoot, _fixturesRoot);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(Path.GetDirectoryName(_liveRoot)!, recursive: true); } catch { }
    }

    private static ClipboardSnapshot TextSnapshot(string s) =>
        new(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(s)) });

    [Fact]
    public void Snapshot_CopiesDbAndBlobs()
    {
        // Seed one text row + one big-flavor row so both inline and
        // blob-store paths get exercised.
        _ingestor.Ingest(TextSnapshot("hello"), null, _device);
        _ingestor.Ingest(TextSnapshot(new string('X', 300_000)), null, _device);

        var result = _mgr.Snapshot("baseline");

        Assert.Equal("baseline", result.Name);
        Assert.True(File.Exists(Path.Combine(result.Path, AppPaths.DbFileName)));
        Assert.True(Directory.Exists(Path.Combine(result.Path, AppPaths.BlobsDirName)));
        // Bytes-copied includes both the DB file and the blob tree —
        // sanity-check the number is at least the big flavor.
        Assert.True(result.BytesCopied > 300_000);
    }

    [Fact]
    public void Snapshot_OpensCleanWithFreshHandle()
    {
        // The critical property: a fixture DB must be self-contained
        // after checkpoint — opening it with a fresh SQLite handle
        // should surface all the rows that were live at snapshot time.
        _ingestor.Ingest(TextSnapshot("uniquetoken"), null, _device);

        var result = _mgr.Snapshot("openable");

        var fixtureDb = Path.Combine(result.Path, AppPaths.DbFileName);
        using var conn = new SqliteConnection($"Data Source={fixtureDb};Mode=ReadOnly");
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM entries WHERE title LIKE 'uniquetoken%'";
        Assert.Equal(1L, (long)cmd.ExecuteScalar()!);
    }

    [Fact]
    public void Snapshot_RefusesToOverwrite_ByDefault()
    {
        _ingestor.Ingest(TextSnapshot("v1"), null, _device);
        _mgr.Snapshot("dupe");

        // Second call without --overwrite must throw a typed exception
        // the CLI can distinguish from a name-validation error (which
        // exits 2 vs. 1 in the CLI dispatch).
        Assert.Throws<FixtureExistsException>(() => _mgr.Snapshot("dupe"));
    }

    [Fact]
    public void Snapshot_Overwrite_ReplacesExisting()
    {
        _ingestor.Ingest(TextSnapshot("first"), null, _device);
        _mgr.Snapshot("swap");

        // Add another row + snapshot again with overwrite.
        _ingestor.Ingest(TextSnapshot("second"), null, _device);
        var result = _mgr.Snapshot("swap", overwrite: true);

        var fixtureDb = Path.Combine(result.Path, AppPaths.DbFileName);
        using var conn = new SqliteConnection($"Data Source={fixtureDb};Mode=ReadOnly");
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM entries";
        // Both rows in the newer snapshot.
        Assert.Equal(2L, (long)cmd.ExecuteScalar()!);
    }

    [Fact]
    public void List_EmptyWhenNoFixtures()
    {
        Assert.Empty(_mgr.List());
    }

    [Fact]
    public void List_ReturnsAlphabeticalNamesAndSizes()
    {
        _ingestor.Ingest(TextSnapshot("seed"), null, _device);
        _mgr.Snapshot("charlie");
        _mgr.Snapshot("alpha");
        _mgr.Snapshot("bravo");

        var listing = _mgr.List();
        Assert.Equal(3, listing.Count);
        // Alphabetical by name — stable, greppable order.
        Assert.Equal("alpha",   listing[0].Name);
        Assert.Equal("bravo",   listing[1].Name);
        Assert.Equal("charlie", listing[2].Name);
        // Non-zero sizes (each has at least a DB file with schema).
        Assert.All(listing, i => Assert.True(i.Bytes > 0));
    }

    [Fact]
    public void Delete_RemovesTheDirectory()
    {
        _ingestor.Ingest(TextSnapshot("seed"), null, _device);
        var result = _mgr.Snapshot("goner");
        Assert.True(Directory.Exists(result.Path));

        _mgr.Delete("goner");
        Assert.False(Directory.Exists(result.Path));
    }

    [Fact]
    public void Delete_ThrowsNotFound_ForMissing()
    {
        Assert.Throws<FixtureNotFoundException>(() => _mgr.Delete("never-created"));
    }

    [Fact]
    public void EnvSnippet_CmdFormat()
    {
        _ingestor.Ingest(TextSnapshot("seed"), null, _device);
        var result = _mgr.Snapshot("named");

        var snippet = _mgr.EnvSnippet("named", FixtureShell.Cmd);
        // `set NAME=value` — no quoting, matches cmd's set syntax.
        Assert.Equal($"set CPDB_SUPPORT_DIR={result.Path}", snippet);
    }

    [Fact]
    public void EnvSnippet_PowerShellFormat()
    {
        _ingestor.Ingest(TextSnapshot("seed"), null, _device);
        var result = _mgr.Snapshot("named");

        var snippet = _mgr.EnvSnippet("named", FixtureShell.PowerShell);
        // $env: syntax with quoted value.
        Assert.Equal($"$env:CPDB_SUPPORT_DIR = \"{result.Path}\"", snippet);
    }

    [Fact]
    public void EnvSnippet_ThrowsNotFound_ForMissing()
    {
        // Emitting an env snippet for a nonexistent fixture would be
        // actively misleading — the shell would set an env var to a
        // path that doesn't exist. Fail loudly.
        Assert.Throws<FixtureNotFoundException>(
            () => _mgr.EnvSnippet("nope", FixtureShell.Cmd));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(".")]
    [InlineData("..")]
    [InlineData("has/slash")]
    [InlineData("has\\backslash")]
    [InlineData("has:colon")]
    [InlineData("has|pipe")]
    [InlineData("has*star")]
    [InlineData("has?question")]
    public void ValidateName_RejectsPathTraversalAndReservedChars(string bad)
    {
        // A fixture name is user input; defence-in-depth against a
        // CLI arg like `../../Windows/System32` accidentally
        // resolving outside the fixtures root. Reject cheaply before
        // any Directory.Create fires.
        Assert.Throws<ArgumentException>(() => FixtureManager.ValidateName(bad));
    }

    [Theory]
    [InlineData("simple")]
    [InlineData("with-dash")]
    [InlineData("with_underscore")]
    [InlineData("with.dot")]
    [InlineData("with space")]
    [InlineData("MixedCase")]
    [InlineData("2026-08-30")]
    public void ValidateName_AcceptsReasonableNames(string good)
    {
        FixtureManager.ValidateName(good);  // no throw
    }

    [Fact]
    public void PathFor_JoinsUnderFixturesRoot()
    {
        var path = _mgr.PathFor("child");
        Assert.Equal(Path.Combine(_fixturesRoot, "child"), path);
    }
}

/// <summary>
/// Coverage for <see cref="AppPaths.DefaultRoot"/>'s v1.53 env-var
/// override — <c>CPDB_SUPPORT_DIR</c> wins over the default
/// <c>%LOCALAPPDATA%\cpdb</c> so <c>fixture env</c> can retarget
/// the whole app / CLI for a shell session.
/// </summary>
public class AppPathsEnvOverrideTests : IDisposable
{
    private readonly string? _priorEnv;

    public AppPathsEnvOverrideTests()
    {
        _priorEnv = Environment.GetEnvironmentVariable(AppPaths.SupportDirEnvVar);
    }

    public void Dispose()
    {
        Environment.SetEnvironmentVariable(AppPaths.SupportDirEnvVar, _priorEnv);
    }

    [Fact]
    public void DefaultRoot_UsesEnvVarWhenSet()
    {
        var overridePath = Path.Combine(Path.GetTempPath(),
            "cpdb-env-override-" + Guid.NewGuid().ToString("N"));
        Environment.SetEnvironmentVariable(AppPaths.SupportDirEnvVar, overridePath);

        Assert.Equal(overridePath, AppPaths.DefaultRoot());
    }

    [Fact]
    public void DefaultRoot_IgnoresEmptyOrWhitespace()
    {
        // Empty string in an env var is a common footgun (a shell
        // that unset via `set VAR=` instead of `set VAR=`). Treat
        // it as unset so the real default kicks in.
        Environment.SetEnvironmentVariable(AppPaths.SupportDirEnvVar, "");
        Assert.EndsWith(AppPaths.AppDirName, AppPaths.DefaultRoot());

        Environment.SetEnvironmentVariable(AppPaths.SupportDirEnvVar, "   ");
        Assert.EndsWith(AppPaths.AppDirName, AppPaths.DefaultRoot());
    }
}
