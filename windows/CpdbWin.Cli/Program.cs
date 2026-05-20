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
            _                    => UnknownCommand(args[0]),
        };
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

