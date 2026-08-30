using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Unit-level coverage for <see cref="TransientGuard.ShouldReject"/>
/// and end-to-end coverage that a snapshot carrying the transient
/// marker gets dropped at <see cref="Ingestor"/> with the right
/// reason string and zero side effects. The Win32
/// <see cref="TransientGuard.ProbeOpenClipboard"/> path isn't
/// exercised here — that would need a real clipboard write with
/// registered format IDs and would race the actual OS clipboard.
/// It's covered end-to-end by the live-capture smoke test the
/// user runs against a password-manager sample.
/// </summary>
public class TransientGuardTests
{
    private static ClipboardSnapshot TextSnapshot(string s, bool transient = false) =>
        new(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(s)) }, transient);

    [Fact]
    public void ShouldReject_TrueWhenSnapshotFlagged()
    {
        Assert.True(TransientGuard.ShouldReject(TextSnapshot("secret", transient: true)));
    }

    [Fact]
    public void ShouldReject_FalseWhenSnapshotClean()
    {
        Assert.False(TransientGuard.ShouldReject(TextSnapshot("hello", transient: false)));
    }

    [Fact]
    public void ShouldReject_FalseOnEmptySnapshot()
    {
        // Empty flavors + no marker — the empty-snapshot check upstream
        // handles this case; the guard itself just returns false so
        // it doesn't double-skip with a misleading reason.
        var empty = new ClipboardSnapshot(Array.Empty<CanonicalHash.Flavor>(), HasTransientMarker: false);
        Assert.False(TransientGuard.ShouldReject(empty));
    }

    [Fact]
    public void FormatNames_MatchMicrosoftDocumentedStrings()
    {
        // If either constant drifts, every password-manager write
        // becomes silently uncatchable. Byte-exact match is the
        // contract with the OS — assert directly.
        Assert.Equal("ExcludeClipboardContentFromMonitorProcessing", TransientGuard.ExcludeFormatName);
        Assert.Equal("CanIncludeInClipboardHistory",                 TransientGuard.CanIncludeFormatName);
    }
}

/// <summary>
/// End-to-end: a snapshot with <c>HasTransientMarker = true</c> gets
/// skipped at <see cref="Ingestor.Ingest"/> with the expected reason
/// and writes nothing to the database. Peer of
/// <see cref="IngestorWithIgnoredAppsTests"/> — same shape, different
/// skip class.
/// </summary>
public class IngestorWithTransientMarkerTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public IngestorWithTransientMarkerTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-transient-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private static ClipboardSnapshot TransientTextSnapshot(string s) =>
        new(new[] { new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(s)) },
            HasTransientMarker: true);

    [Fact]
    public void Ingest_TransientSnapshot_IsSkipped_AndNothingIsWritten()
    {
        var ingest = new Ingestor(_db, _blobs);
        // No sourceApp — proves this is a content-based skip, not the
        // app-attribution IgnoredApps path (which returns "ignored
        // app: <bundleId>" and requires a non-null app info).
        var outcome = ingest.Ingest(TransientTextSnapshot("super-secret-token"), sourceApp: null, _device);

        Assert.Equal(IngestKind.Skipped, outcome.Kind);
        Assert.NotNull(outcome.Reason);
        Assert.Contains("transient", outcome.Reason!, StringComparison.OrdinalIgnoreCase);

        // Zero rows anywhere — confirms we never see the payload in
        // any table (entries, entry_flavors, entries_fts).
        Assert.Equal(0L, ScalarLong("SELECT COUNT(*) FROM entries"));
        Assert.Equal(0L, ScalarLong("SELECT COUNT(*) FROM entry_flavors"));
        Assert.Equal(0L, ScalarLong("SELECT COUNT(*) FROM entries_fts"));
    }

    [Fact]
    public void Ingest_TransientSnapshot_SkippedEvenFromKnownGoodApp()
    {
        // Notepad (not on the ignore list) writing a transient-marked
        // clip is still skipped. Content-based markers win over
        // app-attribution allow-lists — the source app opted its own
        // clip out.
        var ingest = new Ingestor(_db, _blobs);
        var notepad = new ForegroundApp.Info("win.notepad", "Notepad", @"C:\notepad.exe");

        var outcome = ingest.Ingest(TransientTextSnapshot("marked"), notepad, _device);

        Assert.Equal(IngestKind.Skipped, outcome.Kind);
        Assert.Contains("transient", outcome.Reason!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Ingest_CleanSnapshot_ProceedsNormally()
    {
        // The counter-test: identical shape but transient=false ⇒
        // normal insert path. Guards against a stray always-skip bug.
        var ingest = new Ingestor(_db, _blobs);
        var clean = new ClipboardSnapshot(
            new[] { new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes("hello")) },
            HasTransientMarker: false);

        var outcome = ingest.Ingest(clean, sourceApp: null, _device);

        Assert.Equal(IngestKind.Inserted, outcome.Kind);
    }

    [Fact]
    public void Ingest_TransientMarkerBeatsIgnoredAppReason()
    {
        // Both skip conditions hit at once (1Password writing a
        // transient-marked clip). Ordering: transient check runs
        // first (see Ingestor.cs), so the reason should be
        // "transient/..." not "ignored app: win.1password". Not a
        // correctness invariant — both skip — but pins the
        // observability behavior we want (the reason line surfaces
        // the more informative cause).
        var ingest = new Ingestor(_db, _blobs);
        var onePassword = new ForegroundApp.Info("win.1password", "1Password", @"C:\1Password.exe");

        var outcome = ingest.Ingest(TransientTextSnapshot("password123"), onePassword, _device);

        Assert.Equal(IngestKind.Skipped, outcome.Kind);
        Assert.Contains("transient", outcome.Reason!, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("ignored app", outcome.Reason!, StringComparison.OrdinalIgnoreCase);
    }

    private long ScalarLong(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        return (long)cmd.ExecuteScalar()!;
    }
}
