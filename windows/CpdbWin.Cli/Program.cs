using CpdbWin.Core.Analysis;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Maintenance;
using CpdbWin.Core.Portability;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using DbHelper = CpdbWin.Core.Store.Database;

namespace CpdbWin.Cli;

/// <summary>
/// Argv dispatcher for the `cpdb-win` maintenance CLI. Mirrors the
/// macOS <c>cpdb</c> subcommands documented in
/// <c>docs/parity.md § CLI surface</c>.
///
/// <para>
/// Usage:
/// <code>
/// cpdb-win reclassify-kinds
/// cpdb-win backfill-titles --retry-empty | --refetch-all
/// cpdb-win analyze-images [--force]
/// cpdb-win dedupe --links-all-time
/// cpdb-win --help | -h
/// </code>
/// </para>
///
/// Reads + writes the same SQLite database the GUI app uses
/// (<c>%LOCALAPPDATA%\cpdb\cpdb.db</c>). WAL mode means a running GUI
/// won't block CLI commands — both serialize on the SQLite locks.
/// </summary>
public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length == 0
            || args[0] is "--help" or "-h" or "help")
        {
            PrintUsage();
            return args.Length == 0 ? 1 : 0;
        }

        try
        {
            return Dispatch(args);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"cpdb-win: {ex.Message}");
            return 1;
        }
    }

    private static int Dispatch(string[] args)
    {
        var paths = AppPaths.Initialize();
        if (!File.Exists(paths.Database))
        {
            Console.Error.WriteLine(
                $"cpdb-win: no database at {paths.Database} — has the GUI app run yet?");
            return 1;
        }
        using var db = DbHelper.Open(paths.Database);

        return args[0] switch
        {
            "reclassify-kinds"   => RunReclassify(db),
            "backfill-titles"    => RunBackfillTitles(db, args[1..]),
            "analyze-images"     => RunAnalyzeImages(db, paths, args[1..]),
            "dedupe"             => RunDedupe(db, args[1..]),
            "import-urls"        => RunImportUrls(db, paths, args[1..]),
            "export"             => RunExport(db, args[1..]),
            "evict"              => RunEvict(db, paths, args[1..]),
            "storage"            => RunStorage(db, paths),
            "fixture"            => RunFixture(paths, args[1..]),
            _                    => UnknownCommand(args[0]),
        };
    }

    /// <summary>
    /// <c>cpdb-win fixture {snapshot|list|env|path|delete}</c> —
    /// test-data scaffolding. See
    /// <see cref="CpdbWin.Core.Store.FixtureManager"/> for the storage
    /// contract (sibling-of-cpdb layout, WAL-checkpoint before copy,
    /// name validation).
    /// </summary>
    private static int RunFixture(AppPaths.Resolved paths, string[] rest)
    {
        if (rest.Length == 0)
        {
            Console.Error.WriteLine("cpdb-win fixture: missing subcommand");
            Console.Error.WriteLine("  usage: cpdb-win fixture {snapshot NAME [--overwrite] | list | env NAME [--powershell] | path NAME | delete NAME [--force]}");
            return 2;
        }
        var mgr = FixtureManager.Default(paths);
        try
        {
            return rest[0] switch
            {
                "snapshot" => RunFixtureSnapshot(mgr, rest[1..]),
                "list"     => RunFixtureList(mgr),
                "env"      => RunFixtureEnv(mgr, rest[1..]),
                "path"     => RunFixturePath(mgr, rest[1..]),
                "delete"   => RunFixtureDelete(mgr, rest[1..]),
                _          => FixtureUnknown(rest[0]),
            };
        }
        catch (FixtureExistsException ex)
        {
            Console.Error.WriteLine($"cpdb-win fixture: {ex.Message}");
            Console.Error.WriteLine("  pass --overwrite to replace");
            return 1;
        }
        catch (FixtureNotFoundException ex)
        {
            Console.Error.WriteLine($"cpdb-win fixture: {ex.Message}");
            return 1;
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine($"cpdb-win fixture: {ex.Message}");
            return 2;
        }
    }

    private static int RunFixtureSnapshot(FixtureManager mgr, string[] rest)
    {
        var name = rest.FirstOrDefault(a => !a.StartsWith("--"));
        if (name is null)
        {
            Console.Error.WriteLine("cpdb-win fixture snapshot: missing NAME");
            return 2;
        }
        var overwrite = rest.Contains("--overwrite");
        var result = mgr.Snapshot(name, overwrite);
        Console.WriteLine($"snapshot '{result.Name}' -> {result.Path}");
        Console.WriteLine($"  {FormatBytes(result.BytesCopied)} copied");
        return 0;
    }

    private static int RunFixtureList(FixtureManager mgr)
    {
        var items = mgr.List();
        if (items.Count == 0)
        {
            Console.WriteLine("(no fixtures)");
            return 0;
        }
        // Two aligned columns: name + size. Widths derived from the
        // data so nothing wraps on a normal terminal.
        int nameWidth = Math.Max(4, items.Max(i => i.Name.Length));
        foreach (var i in items)
            Console.WriteLine($"  {i.Name.PadRight(nameWidth)}   {FormatBytes(i.Bytes)}");
        return 0;
    }

    private static int RunFixtureEnv(FixtureManager mgr, string[] rest)
    {
        var name = rest.FirstOrDefault(a => !a.StartsWith("--"));
        if (name is null)
        {
            Console.Error.WriteLine("cpdb-win fixture env: missing NAME");
            return 2;
        }
        var shell = rest.Contains("--powershell") ? FixtureShell.PowerShell : FixtureShell.Cmd;
        Console.WriteLine(mgr.EnvSnippet(name, shell));
        return 0;
    }

    private static int RunFixturePath(FixtureManager mgr, string[] rest)
    {
        var name = rest.FirstOrDefault(a => !a.StartsWith("--"));
        if (name is null)
        {
            Console.Error.WriteLine("cpdb-win fixture path: missing NAME");
            return 2;
        }
        FixtureManager.ValidateName(name);
        var path = mgr.PathFor(name);
        if (!Directory.Exists(path))
        {
            Console.Error.WriteLine($"cpdb-win fixture: no fixture named '{name}' (looked in {path})");
            return 1;
        }
        Console.WriteLine(path);
        return 0;
    }

    private static int RunFixtureDelete(FixtureManager mgr, string[] rest)
    {
        var name = rest.FirstOrDefault(a => !a.StartsWith("--"));
        if (name is null)
        {
            Console.Error.WriteLine("cpdb-win fixture delete: missing NAME");
            return 2;
        }
        var force = rest.Contains("--force");
        if (!force)
        {
            // Match Mac: prompt-to-confirm unless --force. In a script,
            // the caller passes --force; interactively, this is the
            // "type y to confirm" safety net.
            Console.Write($"delete fixture '{name}'? [y/N] ");
            var answer = Console.ReadLine()?.Trim();
            if (!string.Equals(answer, "y", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine("aborted");
                return 0;
            }
        }
        mgr.Delete(name);
        Console.WriteLine($"deleted '{name}'");
        return 0;
    }

    private static int FixtureUnknown(string sub)
    {
        Console.Error.WriteLine($"cpdb-win fixture: unknown subcommand '{sub}'");
        Console.Error.WriteLine("  usage: cpdb-win fixture {snapshot NAME [--overwrite] | list | env NAME [--powershell] | path NAME | delete NAME [--force]}");
        return 2;
    }

    /// <summary>
    /// <c>cpdb-win storage</c> — read-only tier-by-tier breakdown of
    /// DB + blob store usage. Mirrors macOS <c>cpdb storage</c> plus a
    /// Windows-only line for the SQLite file trio (`.db`/`-wal`/`-shm`)
    /// so the CLI output matches what Explorer / Task Manager reports.
    /// No flags in v1 — matches Mac.
    /// </summary>
    private static int RunStorage(SqliteConnection db, AppPaths.Resolved paths)
    {
        var blobs = new BlobStore(paths.Blobs);
        var report = StorageReporter.Report(db, blobs, paths.Database);
        Console.WriteLine(StorageReporter.Formatted(report));
        Console.WriteLine();
        Console.WriteLine($"Database path: {paths.Database}");
        Console.WriteLine($"Blob store   : {paths.Blobs}");
        return 0;
    }

    /// <summary>
    /// <c>cpdb-win evict --before-days N [--dry-run]</c> — body-evict
    /// entries older than N days. See
    /// <see cref="CpdbWin.Core.Store.EntryEvictor"/> for the contract
    /// (pinned skip, body-only vs tombstone, blob two-phase cleanup).
    /// Dry-run prints the candidate count and exits without writing.
    /// </summary>
    private static int RunEvict(SqliteConnection db, AppPaths.Resolved paths, string[] rest)
    {
        int days = EntryEvictor.DefaultDays;
        var daysIdx = Array.IndexOf(rest, "--before-days");
        if (daysIdx >= 0)
        {
            if (daysIdx + 1 >= rest.Length || !int.TryParse(rest[daysIdx + 1], out days))
            {
                Console.Error.WriteLine("cpdb-win evict: --before-days requires an integer argument");
                Console.Error.WriteLine("  usage: cpdb-win evict [--before-days N] [--dry-run]");
                return 2;
            }
        }
        var dryRun = rest.Contains("--dry-run");

        var blobs = new BlobStore(paths.Blobs);
        var evictor = new EntryEvictor(db, blobs);

        IReadOnlyList<long> candidates;
        try
        {
            candidates = evictor.CandidatesOlderThan(days);
        }
        catch (ArgumentOutOfRangeException ex)
        {
            // Bounds checks live in EntryEvictor — surface the reason
            // to the user so they know min/max rather than a bare
            // "invalid argument".
            Console.Error.WriteLine($"cpdb-win evict: {ex.Message}");
            return 2;
        }

        if (dryRun)
        {
            Console.WriteLine($"found {candidates.Count} entries older than {days} days with bodies present");
            Console.WriteLine("dry run — no changes written");
            return 0;
        }

        if (candidates.Count == 0)
        {
            Console.WriteLine($"nothing to evict (no entries older than {days} days with bodies present)");
            return 0;
        }

        var report = evictor.Evict(candidates);
        Console.WriteLine($"evicted {report.EntryCount} entries");
        Console.WriteLine($"  inline bytes freed: {FormatBytes(report.InlineFlavorBytesFreed)}");
        Console.WriteLine($"  blob bytes freed:   {FormatBytes(report.BlobBytesFreed)}  ({report.BlobsRemoved} blobs)");
        Console.WriteLine($"  total:              {FormatBytes(report.InlineFlavorBytesFreed + report.BlobBytesFreed)}");
        return 0;
    }

    /// <summary>Compact byte formatter for CLI output. Not culture-
    /// aware on purpose (matches the rest of the CLI's invariant
    /// output shape).</summary>
    private static string FormatBytes(long bytes)
    {
        if (bytes < 1024)         return $"{bytes} B";
        if (bytes < 1024 * 1024)  return $"{bytes / 1024.0:F1} KB";
        if (bytes < 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024):F1} MB";
        return $"{bytes / (1024.0 * 1024 * 1024):F2} GB";
    }

    private static int RunImportUrls(SqliteConnection db, AppPaths.Resolved paths, string[] rest)
    {
        // First positional that isn't a flag is the file path.
        var file = rest.FirstOrDefault(a => !a.StartsWith("--"));
        if (file is null)
        {
            Console.Error.WriteLine("cpdb-win import-urls: missing FILE argument");
            Console.Error.WriteLine("  usage: cpdb-win import-urls FILE [--dry-run] [--spread-seconds N]");
            return 2;
        }
        if (!File.Exists(file))
        {
            Console.Error.WriteLine($"cpdb-win import-urls: file not found: {file}");
            return 1;
        }

        var dryRun = rest.Contains("--dry-run");
        double spread = 0;
        var spreadIdx = Array.IndexOf(rest, "--spread-seconds");
        if (spreadIdx >= 0 && spreadIdx + 1 < rest.Length
            && double.TryParse(rest[spreadIdx + 1],
                System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var s))
        {
            spread = s;
        }

        var raw = File.ReadAllText(file);

        if (dryRun)
        {
            var (accepted, rejected) = UrlImporter.Parse(raw);
            Console.WriteLine($"import-urls --dry-run: {accepted.Count} URL(s) would be imported"
                + (spread > 0 ? $", spread over {spread:0}s" : "")
                + $"; {rejected.Count} line(s) rejected");
            foreach (var rj in rejected.Take(20))
                Console.WriteLine($"  rejected: {rj.Line}  ({rj.Reason})");
            if (rejected.Count > 20)
                Console.WriteLine($"  … and {rejected.Count - 20} more");
            return 0;
        }

        var blobs = new BlobStore(paths.Blobs);
        var ingestor = new Ingestor(db, blobs);
        var device = DeviceIdentity.Read();
        var result = UrlImporter.Run(raw, ingestor, device, spread);
        Console.WriteLine(
            $"import-urls: {result.AcceptedCount} accepted "
            + $"({result.Inserted} new, {result.Bumped} re-copied, {result.Skipped} skipped); "
            + $"{result.Rejected.Count} rejected");
        foreach (var rj in result.Rejected.Take(20))
            Console.WriteLine($"  rejected: {rj.Line}  ({rj.Reason})");
        if (result.Rejected.Count > 20)
            Console.WriteLine($"  … and {result.Rejected.Count - 20} more");
        return 0;
    }

    private static int RunExport(SqliteConnection db, string[] rest)
    {
        var fmtIdx = Array.IndexOf(rest, "--format");
        if (fmtIdx < 0 || fmtIdx + 1 >= rest.Length)
        {
            Console.Error.WriteLine("cpdb-win export: --format md|csv|html required");
            Console.Error.WriteLine("  usage: cpdb-win export --format md|csv|html "
                + "[--output FILE] [--limit N] [--include-evicted]");
            return 2;
        }
        if (!HistoryExporter.TryParseFormat(rest[fmtIdx + 1], out var format))
        {
            Console.Error.WriteLine($"cpdb-win export: unknown format '{rest[fmtIdx + 1]}' (md|csv|html)");
            return 2;
        }

        int limit = int.MaxValue;
        var limitIdx = Array.IndexOf(rest, "--limit");
        if (limitIdx >= 0 && limitIdx + 1 < rest.Length
            && int.TryParse(rest[limitIdx + 1], out var l) && l > 0)
        {
            limit = l;
        }

        var includeEvicted = rest.Contains("--include-evicted");

        var (doc, count) = HistoryExporter.Export(db, format, limit, includeEvicted);

        var outIdx = Array.IndexOf(rest, "--output");
        if (outIdx >= 0 && outIdx + 1 < rest.Length)
        {
            var path = rest[outIdx + 1];
            File.WriteAllText(path, doc);
            Console.Error.WriteLine($"export: wrote {count} entries to {path}");
        }
        else
        {
            // No --output: stream to stdout so it pipes / redirects.
            Console.Out.Write(doc);
            Console.Error.WriteLine($"export: {count} entries");
        }
        return 0;
    }

    private static int RunReclassify(SqliteConnection db)
    {
        var r = MaintenanceCommands.ReclassifyKinds(db);
        Console.WriteLine(
            $"reclassify-kinds: scanned {r.Scanned}, reclassified {r.Reclassified}, " +
            $"link state reset on {r.LinkStateReset}");
        return 0;
    }

    private static int RunBackfillTitles(SqliteConnection db, string[] flags)
    {
        bool retryEmpty = flags.Contains("--retry-empty");
        bool refetchAll = flags.Contains("--refetch-all");
        if (!retryEmpty && !refetchAll)
        {
            Console.Error.WriteLine(
                "cpdb-win backfill-titles: pass --retry-empty (re-fetch only " +
                "links that came back blank) or --refetch-all (wipe every " +
                "link's stored title and re-fetch — useful to pick up newer " +
                "fetcher rules, e.g. the v1.30.0 WordPress preference).");
            return 2;
        }
        if (retryEmpty && refetchAll)
        {
            Console.Error.WriteLine(
                "cpdb-win backfill-titles: --retry-empty and --refetch-all " +
                "are mutually exclusive.");
            return 2;
        }
        if (retryEmpty)
        {
            var r = MaintenanceCommands.RetryEmptyLinks(db);
            Console.WriteLine(
                $"backfill-titles --retry-empty: cleared link state on " +
                $"{r.LinkStateReset} row(s). Restart cpdb-win to pick them " +
                "up in the next backfill cycle.");
        }
        else
        {
            var r = MaintenanceCommands.RefetchAllLinks(db);
            Console.WriteLine(
                $"backfill-titles --refetch-all: wiped + re-armed " +
                $"{r.LinkStateReset} link title(s). Restart cpdb-win " +
                "to drain the backfill loop under current fetcher rules.");
        }
        return 0;
    }

    private static int RunAnalyzeImages(SqliteConnection db, AppPaths.Resolved paths, string[] flags)
    {
        // Self-sufficient like macOS `cpdb analyze-images`: this process
        // actually runs the OCR (Windows.Media.Ocr is available here too
        // — same TFM as the app), not just re-arm state for the GUI.
        bool force = flags.Contains("--force");
        if (force)
        {
            var r = MaintenanceCommands.ResetImageAnalysis(db);
            Console.WriteLine($"analyze-images --force: re-armed {r.LinkStateReset} image(s).");
        }

        var blobs = new BlobStore(paths.Blobs);
        var entries = new EntryRepository(db, blobs);
        using var svc = new ImageAnalysisService(entries);
        var n = svc.DrainAsync().GetAwaiter().GetResult();
        Console.WriteLine(
            n == 0
                ? "analyze-images: nothing to do (no un-analyzed images)."
                : $"analyze-images: OCR'd {n} image(s); text folded into the FTS5 index.");
        return 0;
    }

    private static int RunDedupe(SqliteConnection db, string[] flags)
    {
        if (flags.Length == 0 || !flags.Contains("--links-all-time"))
        {
            Console.Error.WriteLine(
                "cpdb-win dedupe: only --links-all-time is supported in v1.");
            return 2;
        }
        var r = MaintenanceCommands.DedupeLinksAllTime(db);
        Console.WriteLine(
            $"dedupe --links-all-time: collapsed {r.Scanned} URL group(s); " +
            $"salvaged title for {r.Reclassified} survivor(s); " +
            $"tombstoned {r.LinkStateReset} sibling row(s).");
        return 0;
    }

    private static int UnknownCommand(string cmd)
    {
        Console.Error.WriteLine($"cpdb-win: unknown command '{cmd}'");
        PrintUsage();
        return 2;
    }

    private static void PrintUsage()
    {
        Console.WriteLine("""
            cpdb-win — maintenance CLI for cpdb-win

            Usage:
              cpdb-win reclassify-kinds
                  Re-apply the current kind classifier to every live
                  entry. Updates rows whose stored kind disagrees with
                  the current rules; on text→link drift, also clears
                  link backfill state so the row re-enters the
                  candidate pool.

              cpdb-win backfill-titles --retry-empty
                  Clear link_fetched_at + retry counters for
                  kind=link rows that settled with no title (link_title
                  NULL or empty). Restart the GUI app to fire the
                  next backfill cycle.

              cpdb-win backfill-titles --refetch-all
                  Wipe link_title + link_fetched_at on EVERY live
                  kind=link row and re-arm them for the backfill loop.
                  Stronger than --retry-empty (which only re-fetches
                  blanks). Use to pick up newer fetcher rules — e.g.
                  the v1.30.0 WordPress-aware precedence — on rows
                  that already settled under older logic.

              cpdb-win analyze-images [--force]
                  On-device OCR (Windows.Media.Ocr) of image entries
                  that haven't been analyzed yet; recognised text is
                  folded into the FTS5 index so screenshots become
                  searchable. --force re-OCRs every image (clears
                  analyzed_at first). Safe while the GUI is running.

              cpdb-win dedupe --links-all-time
                  For each text_preview URL with multiple live
                  kind=link rows, keep the newest and tombstone the
                  rest. Salvages link_title from a sibling first if
                  the survivor lacks one.

              cpdb-win import-urls FILE [--dry-run] [--spread-seconds N]
                  Bulk-seed from a URL list (one per line; blank +
                  #-comment lines skipped; http/https/file only).
                  Each accepted line is ingested as a synthetic
                  clipboard capture so links enrich via the normal
                  backfill. --spread-seconds backdates captured_at
                  so the import doesn't collapse to one timestamp.

              cpdb-win fixture snapshot NAME [--overwrite]
              cpdb-win fixture list
              cpdb-win fixture env NAME [--powershell]
              cpdb-win fixture path NAME
              cpdb-win fixture delete NAME [--force]
                  Test-data scaffolding. `snapshot` WAL-checkpoints
                  the live DB then copies cpdb.db + blobs/ tree into
                  %LOCALAPPDATA%\cpdb-fixtures\NAME\. `env` emits a
                  shell snippet setting CPDB_SUPPORT_DIR so a fresh
                  shell can run against the fixture instead of the
                  live DB (`set` for cmd, `--powershell` for
                  $env:CPDB_SUPPORT_DIR = "…"). `delete` prompts
                  unless --force.

              cpdb-win storage
                  Print a tier-by-tier breakdown of disk usage:
                  SQLite trio (db + wal + shm), metadata, thumbnails,
                  flavor bodies (inline + on-disk blobs), plus counts
                  of live / pinned / body-evicted entries. Read-only.

              cpdb-win evict [--before-days N] [--dry-run]
                  Body-evict entries older than N days (default 90):
                  drops flavor bytes + stamps body_evicted_at, but
                  the row survives with its metadata (title, preview,
                  chips, thumbnails, FTS index). --dry-run prints the
                  candidate count without writing. Pinned entries are
                  always skipped. N must be in [7, 3650]. Missed
                  blob files are cleaned up by the periodic Gc sweep.

              cpdb-win export --format md|csv|html [--output FILE]
                              [--limit N] [--include-evicted]
                  Render clipboard history (metadata + text, no
                  flavor bytes), newest-first. Without --output the
                  document streams to stdout. --include-evicted
                  keeps body-evicted rows.

              cpdb-win --help
                  Print this message.

            All commands operate on %LOCALAPPDATA%\cpdb\cpdb.db.
            """);
    }
}

