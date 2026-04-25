using CpdbWin.Core.Store;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Meta-tests that verify the cleanup helper actually scrubs the
/// production DB after a test run. Run last (xunit doesn't guarantee
/// ordering, but the assertion is "no leaked entries", which is a
/// post-condition that should hold after every other test's Dispose).
/// </summary>
public class ProductionDbCleanupTests
{
    [Fact]
    public void NoLiveTestEntriesRemainAfterPreviousTestRuns()
    {
        // Run cleanup defensively so this test passes even when other tests
        // didn't run in this session (e.g. test filter).
        ProductionDbCleanup.TombstoneTestEntries();

        var paths = AppPaths.Initialize();
        if (!File.Exists(paths.Database)) return; // no production install

        using var conn = Database.Open(paths.Database);
        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT COUNT(*) FROM entries
            WHERE deleted_at IS NULL AND text_preview LIKE 'cpdb-test-%'
            """;
        Assert.Equal(0L, (long)cmd.ExecuteScalar()!);
    }

    [Fact]
    public void NoLivePinnedVectorEntriesRemain()
    {
        ProductionDbCleanup.TombstoneTestEntries();

        var paths = AppPaths.Initialize();
        if (!File.Exists(paths.Database)) return;

        using var conn = Database.Open(paths.Database);
        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT COUNT(*) FROM entries
            WHERE deleted_at IS NULL
              AND content_hash IN ($h1, $h2)
            """;
        cmd.Parameters.AddWithValue("$h1",
            Convert.FromHexString("b22187611777c1e9c84c3fdd054ed311a47d12f33cba6d1e7761bd3a7314073a"));
        cmd.Parameters.AddWithValue("$h2",
            Convert.FromHexString("17a95cac0686665cfe5342a3a041d7afedfa4c14a59d6d3c6b7b53a4bf0ad85a"));
        Assert.Equal(0L, (long)cmd.ExecuteScalar()!);
    }
}
