using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class IgnoredAppsTests
{
    [Fact]
    public void Default_ContainsThePlanMdManagers()
    {
        Assert.Contains("win.1password", IgnoredApps.DefaultBundleIds);
        Assert.Contains("win.bitwarden", IgnoredApps.DefaultBundleIds);
        Assert.Contains("win.keepass",   IgnoredApps.DefaultBundleIds);
    }

    [Fact]
    public void ShouldIgnore_MatchesExactBundleId()
    {
        var ignored = new IgnoredApps();
        Assert.True(ignored.ShouldIgnore("win.1password"));
        Assert.False(ignored.ShouldIgnore("win.notepad"));
    }

    [Fact]
    public void ShouldIgnore_IsCaseInsensitive()
    {
        var ignored = new IgnoredApps();
        Assert.True(ignored.ShouldIgnore("WIN.1Password"));
    }

    [Fact]
    public void ShouldIgnore_FalseForNullOrEmpty()
    {
        var ignored = new IgnoredApps();
        Assert.False(ignored.ShouldIgnore((string?)null));
        Assert.False(ignored.ShouldIgnore(""));
    }

    [Fact]
    public void ShouldIgnore_AcceptsForegroundAppInfo()
    {
        var ignored = new IgnoredApps();
        var info = new ForegroundApp.Info("win.bitwarden", "Bitwarden", @"C:\bin\Bitwarden.exe");
        Assert.True(ignored.ShouldIgnore(info));
        Assert.False(ignored.ShouldIgnore((ForegroundApp.Info?)null));
    }

    [Fact]
    public void Custom_Constructor_ReplacesDefaults()
    {
        var ignored = new IgnoredApps(new[] { "win.lastpass" });
        Assert.False(ignored.ShouldIgnore("win.1password"));
        Assert.True(ignored.ShouldIgnore("win.lastpass"));
    }

    [Fact]
    public void WithUserExtras_AddsToDefaults()
    {
        var ignored = IgnoredApps.WithUserExtras(new[] { "win.lastpass", "win.dashlane" });
        Assert.True(ignored.ShouldIgnore("win.1password"));   // default kept
        Assert.True(ignored.ShouldIgnore("win.lastpass"));    // user extra
        Assert.True(ignored.ShouldIgnore("win.dashlane"));    // user extra
        Assert.False(ignored.ShouldIgnore("win.notepad"));
    }
}

public class IngestorWithIgnoredAppsTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public IngestorWithIgnoredAppsTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-ignored-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private static ClipboardSnapshot TextSnapshot(string s) =>
        new(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(s)) });

    [Fact]
    public void Ingest_FromIgnoredApp_IsSkipped_AndNothingIsWritten()
    {
        var ingest = new Ingestor(_db, _blobs);  // default IgnoredApps
        var onePassword = new ForegroundApp.Info("win.1password", "1Password", @"C:\bin\1Password.exe");

        var outcome = ingest.Ingest(TextSnapshot("super-secret-password"), onePassword, _device);

        Assert.Equal(IngestKind.Skipped, outcome.Kind);
        Assert.NotNull(outcome.Reason);
        Assert.Contains("win.1password", outcome.Reason!);

        // No row anywhere — confirms we don't even see the secret in the
        // FTS shadow table.
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM entries";
        Assert.Equal(0L, (long)cmd.ExecuteScalar()!);
    }

    [Fact]
    public void Ingest_FromNonIgnoredApp_ProceedsNormally()
    {
        var ingest = new Ingestor(_db, _blobs);
        var notepad = new ForegroundApp.Info("win.notepad", "Notepad", @"C:\Windows\System32\notepad.exe");

        var outcome = ingest.Ingest(TextSnapshot("hello"), notepad, _device);

        Assert.Equal(IngestKind.Inserted, outcome.Kind);
    }

    [Fact]
    public void Ingest_NullSourceApp_IsNeverIgnored()
    {
        // If we couldn't identify the source app (elevated process, race
        // condition, etc.) we still ingest. The defer list is conservative;
        // it only kicks in when we have positive identification.
        var ingest = new Ingestor(_db, _blobs);
        var outcome = ingest.Ingest(TextSnapshot("hi"), null, _device);
        Assert.Equal(IngestKind.Inserted, outcome.Kind);
    }

    [Fact]
    public void Ingest_CustomIgnoredAppsList_OverridesDefaults()
    {
        // User configured "ignore Notepad". Notepad gets blocked even though
        // it's not in the defaults; 1Password still flows because the
        // custom list replaced the defaults.
        var ingest = new Ingestor(_db, _blobs, new IgnoredApps(new[] { "win.notepad" }));
        var notepad = new ForegroundApp.Info("win.notepad", "Notepad", @"C:\notepad.exe");
        var onePassword = new ForegroundApp.Info("win.1password", "1Password", @"C:\1Password.exe");

        Assert.Equal(IngestKind.Skipped, ingest.Ingest(TextSnapshot("a"), notepad, _device).Kind);
        Assert.Equal(IngestKind.Inserted, ingest.Ingest(TextSnapshot("b"), onePassword, _device).Kind);
    }
}
