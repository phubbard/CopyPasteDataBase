using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class BootDiagnosticsTests : IDisposable
{
    private readonly string _root;

    public BootDiagnosticsTests()
    {
        _root = Path.Combine(Path.GetTempPath(),
            "cpdb-bootdiag-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    // ─── IsSuspectedDataLoss: the whole truth table ──────────────────────

    [Theory]
    [InlineData(null, 0, false)]   // first ever run — never suspicious
    [InlineData(null, 7, false)]   // first run with data — fine
    [InlineData(0, 0, false)]      // empty stayed empty — fine
    [InlineData(0, 5, false)]      // empty grew — fine
    [InlineData(5, 5, false)]      // steady state — fine
    [InlineData(5, 9, false)]      // grew — fine
    [InlineData(9, 3, false)]      // shrank but not to zero — not flagged
    [InlineData(5, 0, true)]       // non-empty → empty — SUSPECTED
    [InlineData(1, 0, true)]       // even one → zero — SUSPECTED
    public void IsSuspectedDataLoss_TruthTable(int? prev, int now, bool expected)
        => Assert.Equal(expected, BootDiagnostics.IsSuspectedDataLoss(prev, now));

    // ─── Marker round-trip ───────────────────────────────────────────────

    [Fact]
    public void ReadEntryMarker_NullWhenMissing()
        => Assert.Null(BootDiagnostics.ReadEntryMarker(_root));

    [Fact]
    public void WriteThenReadEntryMarker_RoundTrips()
    {
        BootDiagnostics.WriteEntryMarker(_root, 42);
        Assert.Equal(42, BootDiagnostics.ReadEntryMarker(_root));
    }

    [Fact]
    public void WriteEntryMarker_OverwritesPrevious()
    {
        BootDiagnostics.WriteEntryMarker(_root, 100);
        BootDiagnostics.WriteEntryMarker(_root, 0);
        Assert.Equal(0, BootDiagnostics.ReadEntryMarker(_root));
    }

    [Fact]
    public void ReadEntryMarker_NullWhenCorrupt()
    {
        // A garbage marker must read as "no marker", never as 0 —
        // otherwise a corrupt file would masquerade as data loss.
        File.WriteAllText(Path.Combine(_root, ".entrycount"), "not-a-number");
        Assert.Null(BootDiagnostics.ReadEntryMarker(_root));
    }

    // ─── LiveEntryCount ──────────────────────────────────────────────────

    [Fact]
    public void LiveEntryCount_ZeroOnFreshSchema()
    {
        using var db = new SqliteConnection("Data Source=:memory:");
        db.Open();
        Schema.Initialize(db);
        Assert.Equal(0, BootDiagnostics.LiveEntryCount(db));
    }

    [Fact]
    public void LiveEntryCount_CountsOnlyLiveRows()
    {
        using var db = new SqliteConnection("Data Source=:memory:");
        db.Open();
        Schema.Initialize(db);

        using (var dev = db.CreateCommand())
        {
            dev.CommandText =
                "INSERT INTO devices (id, identifier, name, kind) "
              + "VALUES (1, 'test-dev', 'TestPC', 'win')";
            dev.ExecuteNonQuery();
        }

        Ins(db, "u1", 1000, null);
        Ins(db, "u2", 1001, null);
        Ins(db, "u3", 1002, 1003);   // tombstoned — must NOT count

        Assert.Equal(2, BootDiagnostics.LiveEntryCount(db));
    }

    // ─── Diagnostic file emission ────────────────────────────────────────

    [Fact]
    public void LogGc_AppendsAuditLine()
    {
        BootDiagnostics.LogGc(_root, new Gc.Stats(3, 1, 2), liveBefore: 50, liveAfter: 47);
        var log = File.ReadAllText(Path.Combine(_root, "gc.log"));
        Assert.Contains("liveBefore=50", log);
        Assert.Contains("liveAfter=47", log);
        Assert.Contains("tombstoned=3", log);
        Assert.Contains("hardDeleted=1", log);
        Assert.Contains("orphanBlobs=2", log);
    }

    [Fact]
    public void WriteDataLossWarning_WritesNamedFile()
    {
        BootDiagnostics.WriteDataLossWarning(_root, previousMarker: 18);
        var path = Path.Combine(_root, "DATA-LOSS-WARNING.txt");
        Assert.True(File.Exists(path));
        Assert.Contains("18 live clipboard", File.ReadAllText(path));
    }

    private static void Ins(SqliteConnection db, string uuid, double createdAt, double? deletedAt)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText =
            "INSERT INTO entries "
          + "(uuid, created_at, captured_at, kind, source_device_id, "
          + " content_hash, total_size, deleted_at) "
          + "VALUES ($u, $c, $c, 'text', 1, $h, 1, $d)";
        cmd.Parameters.AddWithValue("$u", System.Text.Encoding.UTF8.GetBytes(uuid));
        cmd.Parameters.AddWithValue("$c", createdAt);
        cmd.Parameters.AddWithValue("$h", System.Text.Encoding.UTF8.GetBytes(uuid));
        cmd.Parameters.AddWithValue("$d", (object?)deletedAt ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }
}
