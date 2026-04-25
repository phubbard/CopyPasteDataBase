using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Service;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class CaptureServiceTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public CaptureServiceTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-capsvc-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
    }

    public void Dispose()
    {
        TestClipboardWriter.Empty();
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    [Fact]
    public void Lifecycle_StartAndDispose_IsClean()
    {
        using var svc = new CaptureService(_ingestor, _device);
        svc.Start();
        // Implicit assertion: Dispose joins cleanly.
    }

    [Fact]
    public void Start_TwiceThrows()
    {
        using var svc = new CaptureService(_ingestor, _device);
        svc.Start();
        Assert.Throws<InvalidOperationException>(() => svc.Start());
    }

    [Fact]
    public void ClipboardWrite_FiresIngestedEvent_WithEntryRowInDb()
    {
        using var svc = new CaptureService(_ingestor, _device);
        using var fired = new ManualResetEventSlim(false);
        IngestOutcome? captured = null;
        svc.Ingested += (_, outcome) =>
        {
            captured = outcome;
            fired.Set();
        };
        svc.Start();

        var unique = $"capture-svc-{Guid.NewGuid()}";
        TestClipboardWriter.SetUnicodeText(unique);

        Assert.True(fired.Wait(TimeSpan.FromSeconds(2)),
            "Ingested event was not raised within 2s of clipboard write");
        Assert.NotNull(captured);
        Assert.Equal(IngestKind.Inserted, captured!.Value.Kind);

        // The entry should be queryable.
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT title FROM entries WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", captured.Value.EntryId);
        Assert.Equal(unique, cmd.ExecuteScalar() as string);
    }
}
