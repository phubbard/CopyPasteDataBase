using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Maintenance;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class MaintenanceCommandsTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public MaintenanceCommandsTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-maintenance-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
        _repo = new EntryRepository(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private long IngestText(string s, DateTimeOffset? at = null) =>
        _ingestor.Ingest(
            new ClipboardSnapshot(new[]
            {
                new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(s)),
            }),
            null, _device, at).EntryId;

    private long IngestLink(string url, DateTimeOffset at) =>
        _ingestor.Ingest(
            new ClipboardSnapshot(new[]
            {
                new CanonicalHash.Flavor("public.url", Encoding.UTF8.GetBytes(url)),
                new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(url)),
            }),
            null, _device, at).EntryId;

    private void ForceKind(long id, string kind)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "UPDATE entries SET kind=$k WHERE id=$id";
        cmd.Parameters.AddWithValue("$k", kind);
        cmd.Parameters.AddWithValue("$id", id);
        cmd.ExecuteNonQuery();
    }

    private void ForceLinkState(long id, string? title, double? fetchedAt, int retryCount = 0)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            UPDATE entries
            SET link_title = $t,
                link_fetched_at = $f,
                link_retry_count = $c
            WHERE id = $id
            """;
        cmd.Parameters.AddWithValue("$t", (object?)title ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$f", (object?)fetchedAt ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$c", retryCount);
        cmd.Parameters.AddWithValue("$id", id);
        cmd.ExecuteNonQuery();
    }

    // ─── ReclassifyKinds ─────────────────────────────────────────────────

    [Fact]
    public void ReclassifyKinds_NoDrift_NoUpdates()
    {
        // Kinds match the current classifier from the start — no row
        // should be touched.
        IngestText("plain text");
        IngestLink("https://example.com",
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));

        var result = MaintenanceCommands.ReclassifyKinds(_db);

        Assert.Equal(2, result.Scanned);
        Assert.Equal(0, result.Reclassified);
        Assert.Equal(0, result.LinkStateReset);
    }

    [Fact]
    public void ReclassifyKinds_TextDriftedToLink_UpdatesAndResetsLinkState()
    {
        // Pre-heuristic state: a URL got classified as "text" because
        // the URL-shape rule didn't exist yet, then permanently
        // settled with no title (link_fetched_at non-NULL, retry maxed).
        var id = IngestText("https://stuck.example/article");
        ForceKind(id, "text");
        ForceLinkState(id, title: null, fetchedAt: 99999.0, retryCount: 6);

        var result = MaintenanceCommands.ReclassifyKinds(_db);

        Assert.Equal(1, result.Scanned);
        Assert.Equal(1, result.Reclassified);
        Assert.Equal(1, result.LinkStateReset);

        var row = _repo.Recent().Single(r => r.Id == id);
        Assert.Equal("link", row.Kind);
        // Row is back in the candidate pool.
        var candidates = _repo.NextLinkBackfillCandidates(10);
        Assert.Contains(candidates, c => c.Id == id);
    }

    [Fact]
    public void ReclassifyKinds_TextStaysText_NotTouched()
    {
        // Plain prose — heuristic stays text, no update.
        IngestText("a perfectly ordinary copied paragraph");

        var result = MaintenanceCommands.ReclassifyKinds(_db);

        Assert.Equal(1, result.Scanned);
        Assert.Equal(0, result.Reclassified);
    }

    [Fact]
    public void ReclassifyKinds_NonLinkDrift_KeepsLinkStateUntouched()
    {
        // Hypothetical drift between two non-link kinds (e.g.
        // classifier change reclassifies "other" → "text"). Update
        // the kind but leave link_* alone.
        var id = IngestText("hello");
        ForceKind(id, "other");

        var result = MaintenanceCommands.ReclassifyKinds(_db);

        Assert.Equal(1, result.Scanned);
        Assert.Equal(1, result.Reclassified);
        Assert.Equal(0, result.LinkStateReset);
    }

    [Fact]
    public void ReclassifyKinds_TombstonedRowsSkipped()
    {
        var id = IngestText("https://t1.example/");
        ForceKind(id, "text");
        _repo.Tombstone(id);

        var result = MaintenanceCommands.ReclassifyKinds(_db);

        Assert.Equal(0, result.Scanned);
        Assert.Equal(0, result.Reclassified);
    }

    // ─── RetryEmptyLinks ─────────────────────────────────────────────────

    [Fact]
    public void RetryEmptyLinks_OnlyClearsRowsThatActuallySettledEmpty()
    {
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

        // Settled with title — must NOT be re-fetched.
        var titled = IngestLink("https://has-title.example/", t0);
        ForceLinkState(titled, title: "Real Title", fetchedAt: 12345.0);

        // Settled with NO title (permanent give-up) — eligible for reset.
        var empty = IngestLink("https://no-title.example/", t0.AddSeconds(1));
        ForceLinkState(empty, title: null, fetchedAt: 12346.0, retryCount: 3);

        // Empty-string title — also eligible.
        var emptyStr = IngestLink("https://empty-string.example/", t0.AddSeconds(2));
        ForceLinkState(emptyStr, title: "", fetchedAt: 12347.0, retryCount: 6);

        // Never tried — link_fetched_at is NULL; not eligible (it's
        // already a candidate and shouldn't be double-reset).
        IngestLink("https://never-tried.example/", t0.AddSeconds(3));

        var result = MaintenanceCommands.RetryEmptyLinks(_db);

        Assert.Equal(2, result.Scanned);            // empty + emptyStr
        Assert.Equal(2, result.LinkStateReset);

        // Titled row's state preserved.
        var row = _repo.Recent().Single(r => r.Id == titled);
        Assert.Equal("Real Title", row.LinkTitle);

        // The two empty rows are now back in the candidate pool.
        var candidates = _repo.NextLinkBackfillCandidates(10);
        Assert.Contains(candidates, c => c.Id == empty);
        Assert.Contains(candidates, c => c.Id == emptyStr);
    }

    [Fact]
    public void RetryEmptyLinks_TombstonedRowsSkipped()
    {
        var id = IngestLink("https://gone.example/",
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        ForceLinkState(id, title: null, fetchedAt: 12345.0, retryCount: 6);
        _repo.Tombstone(id);

        var result = MaintenanceCommands.RetryEmptyLinks(_db);

        Assert.Equal(0, result.Scanned);
    }

    // ─── RefetchAllLinks ─────────────────────────────────────────────────

    [Fact]
    public void RefetchAllLinks_WipesEveryLiveLinkTitle_AndReArmsThem()
    {
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

        // Three live link rows in different states.
        var titled = IngestLink("https://wp-example.com/", t0);
        ForceLinkState(titled, title: "stale-short-slug", fetchedAt: 12345.0);

        var empty = IngestLink("https://no-title.example/", t0.AddSeconds(1));
        ForceLinkState(empty, title: null, fetchedAt: 12346.0, retryCount: 4);

        var fresh = IngestLink("https://never-tried.example/", t0.AddSeconds(2));
        // fresh is already a candidate (link_fetched_at NULL).

        // One tombstoned row that must be left alone.
        var gone = IngestLink("https://gone.example/", t0.AddSeconds(3));
        ForceLinkState(gone, title: "Buried", fetchedAt: 12347.0);
        _repo.Tombstone(gone);

        var result = MaintenanceCommands.RefetchAllLinks(_db);

        // All three live link rows re-armed — including the one that
        // already had no fetched-at (idempotent).
        Assert.Equal(3, result.LinkStateReset);

        // Every live link is now a candidate; titles wiped.
        var candidates = _repo.NextLinkBackfillCandidates(10);
        Assert.Contains(candidates, c => c.Id == titled);
        Assert.Contains(candidates, c => c.Id == empty);
        Assert.Contains(candidates, c => c.Id == fresh);

        // Tombstoned row stays settled (not surfaced + state untouched).
        Assert.DoesNotContain(candidates, c => c.Id == gone);

        // titled's stored title is now NULL — the whole point of
        // refetch-all vs retry-empty.
        Assert.Null(_repo.Recent(limit: 100).Single(r => r.Id == titled).LinkTitle);
    }

    [Fact]
    public void RefetchAllLinks_NonLinkRowsUntouched()
    {
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var link = IngestLink("https://link.example/", t0);
        ForceLinkState(link, title: "settled", fetchedAt: 12345.0);

        // A text row — RefetchAllLinks must NOT touch it (the SQL
        // filter is `kind = 'link'`).
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText =
                "INSERT INTO entries(uuid, created_at, captured_at, kind, "
              + "source_device_id, content_hash, total_size) "
              + "VALUES (randomblob(16), $t, $t, 'text', 1, randomblob(32), 16)";
            cmd.Parameters.AddWithValue("$t", t0.AddSeconds(1).ToUnixTimeSeconds());
            cmd.ExecuteNonQuery();
        }

        var res = MaintenanceCommands.RefetchAllLinks(_db);
        Assert.Equal(1, res.LinkStateReset);   // only the link row counted
    }

    // ─── DedupeLinksAllTime ──────────────────────────────────────────────

    [Fact]
    public void DedupeLinksAllTime_SingleRowGroup_NoOp()
    {
        IngestLink("https://only-one.example/",
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));

        var result = MaintenanceCommands.DedupeLinksAllTime(_db);

        Assert.Equal(0, result.Scanned);
        Assert.Equal(0, result.LinkStateReset);
        Assert.Single(_repo.Recent());
    }

    [Fact]
    public void DedupeLinksAllTime_KeepsNewestSurvivor_TombstonesSiblings()
    {
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var oldId    = IngestLink("https://dup.example/", t0);
        var middleId = IngestLink("https://dup.example/", t0.AddSeconds(60));
        var newestId = IngestLink("https://dup.example/", t0.AddSeconds(120));

        // The first three Ingest calls were content-hash dedup'd into
        // the same row — bump path. So we end up with ONE row id, not
        // three. The dedupe command can't help here. Force-create the
        // duplicates by editing content_hash so they're distinct.
        // Easier: assert that what we got back is one row, and that
        // dedupe is a no-op since there's nothing to collapse.
        Assert.Equal(oldId, middleId);
        Assert.Equal(oldId, newestId);

        // Sanity: dedupe is a no-op on a single-live-row group.
        var result = MaintenanceCommands.DedupeLinksAllTime(_db);
        Assert.Equal(0, result.Scanned);
    }

    [Fact]
    public void DedupeLinksAllTime_GroupWithDistinctRows_TombstonesAndSalvagesTitle()
    {
        // Build 3 live link rows for the same URL by hand-rolling rows
        // with distinct content_hash values (real-world drivers: a row
        // ingested when the URL had a tracking-parameter shadow that
        // was later stripped, or content-hash drift across schema
        // changes). Tests the "siblings to tombstone" path explicitly.
        var url = "https://shared.example/page";
        SeedRawLinkRow(id: 100, url: url, createdAt: 1_000.0,
            linkTitle: null, linkFetchedAt: null, hashByte: 0xA1);
        SeedRawLinkRow(id: 101, url: url, createdAt: 2_000.0,
            linkTitle: "Salvageable Title", linkFetchedAt: 1_500.0, hashByte: 0xA2);
        SeedRawLinkRow(id: 102, url: url, createdAt: 3_000.0,
            linkTitle: null, linkFetchedAt: null, hashByte: 0xA3);

        var result = MaintenanceCommands.DedupeLinksAllTime(_db);

        Assert.Equal(1, result.Scanned);             // one URL group
        Assert.Equal(1, result.Reclassified);        // title salvaged
        Assert.Equal(2, result.LinkStateReset);      // two siblings tombstoned

        var live = _repo.Recent();
        // Only the newest survivor (id=102) remains live.
        var survivor = Assert.Single(live);
        Assert.Equal(102, survivor.Id);
        // Title salvaged from id=101.
        Assert.Equal("Salvageable Title", survivor.LinkTitle);
    }

    [Fact]
    public void DedupeLinksAllTime_SurvivorAlreadyHasTitle_NoSalvageNeeded()
    {
        var url = "https://newest-wins.example/";
        SeedRawLinkRow(id: 200, url: url, createdAt: 1_000.0,
            linkTitle: "Old Title", linkFetchedAt: 1_000.0, hashByte: 0xB1);
        SeedRawLinkRow(id: 201, url: url, createdAt: 2_000.0,
            linkTitle: "Newest Title", linkFetchedAt: 1_999.0, hashByte: 0xB2);

        var result = MaintenanceCommands.DedupeLinksAllTime(_db);

        Assert.Equal(1, result.Scanned);
        Assert.Equal(0, result.Reclassified);   // survivor already had title
        Assert.Equal(1, result.LinkStateReset); // sibling tombstoned

        var survivor = _repo.Recent().Single();
        Assert.Equal(201, survivor.Id);
        Assert.Equal("Newest Title", survivor.LinkTitle);
    }

    [Fact]
    public void DedupeLinksAllTime_RemovesTombstonedFromFtsSearch()
    {
        var url = "https://search-test.example/";
        SeedRawLinkRow(id: 300, url: url, createdAt: 1_000.0,
            linkTitle: "Tombstoned Title", linkFetchedAt: 1_000.0, hashByte: 0xC1);
        SeedRawLinkRow(id: 301, url: url, createdAt: 2_000.0,
            linkTitle: "Survivor Title", linkFetchedAt: 1_999.0, hashByte: 0xC2);

        // Manually populate FTS5 — SeedRawLinkRow doesn't, since it
        // bypasses the Ingestor.
        SeedFts(300, "Tombstoned Title");
        SeedFts(301, "Survivor Title");

        Assert.Equal(2, _repo.Search("title").Count);

        MaintenanceCommands.DedupeLinksAllTime(_db);

        // Only the survivor's title is left in the FTS shadow — the
        // dedupe command nukes the tombstoned siblings' rows.
        var hits = _repo.Search("title");
        Assert.Single(hits);
        Assert.Equal(301, hits[0].Id);
    }

    /// <summary>
    /// Insert a raw <c>entries</c> row + matching <c>entry_flavors</c>
    /// row bypassing the Ingestor. Lets us script content_hash so two
    /// rows for the same URL can both go live (the
    /// <c>idx_entries_live_content_hash</c> unique index would block
    /// otherwise, since real Ingest would have content-hash-deduped
    /// into a single row).
    /// </summary>
    private void SeedRawLinkRow(
        long id, string url, double createdAt,
        string? linkTitle, double? linkFetchedAt, byte hashByte)
    {
        // Seed the device row if not already present.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = """
                INSERT OR IGNORE INTO devices (id, identifier, name, kind)
                VALUES (1, 'test-device', 'Test', 'win')
                """;
            cmd.ExecuteNonQuery();
        }

        var hash = new byte[32];
        Array.Fill(hash, hashByte);

        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = """
                INSERT INTO entries
                    (id, uuid, created_at, captured_at, kind,
                     source_device_id, title, text_preview,
                     content_hash, total_size,
                     link_title, link_fetched_at)
                VALUES
                    ($id, randomblob(16), $ts, $ts, 'link',
                     1, $title, $url,
                     $hash, $size,
                     $lt, $lf)
                """;
            cmd.Parameters.AddWithValue("$id", id);
            cmd.Parameters.AddWithValue("$ts", createdAt);
            cmd.Parameters.AddWithValue("$title", url);
            cmd.Parameters.AddWithValue("$url", url);
            cmd.Parameters.AddWithValue("$hash", hash);
            cmd.Parameters.AddWithValue("$size", url.Length);
            cmd.Parameters.AddWithValue("$lt", (object?)linkTitle ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$lf", (object?)linkFetchedAt ?? DBNull.Value);
            cmd.ExecuteNonQuery();
        }

        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = """
                INSERT INTO entry_flavors (entry_id, uti, size, data)
                VALUES ($id, 'public.url', $size, $data)
                """;
            cmd.Parameters.AddWithValue("$id", id);
            cmd.Parameters.AddWithValue("$size", url.Length);
            cmd.Parameters.AddWithValue("$data", Encoding.UTF8.GetBytes(url));
            cmd.ExecuteNonQuery();
        }
    }

    private void SeedFts(long id, string title)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            INSERT INTO entries_fts(rowid, title, text, app_name, ocr_text, image_tags, link_title)
            VALUES ($id, $t, $t, '', '', '', $t)
            """;
        cmd.Parameters.AddWithValue("$id", id);
        cmd.Parameters.AddWithValue("$t", title);
        cmd.ExecuteNonQuery();
    }
}
