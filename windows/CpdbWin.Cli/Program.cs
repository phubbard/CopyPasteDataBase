using CpdbWin.Core.Maintenance;
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
/// cpdb-win backfill-titles --retry-empty
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
            "dedupe"             => RunDedupe(db, args[1..]),
            _                    => UnknownCommand(args[0]),
        };
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
        if (flags.Length == 0 || !flags.Contains("--retry-empty"))
        {
            Console.Error.WriteLine(
                "cpdb-win backfill-titles: only --retry-empty is supported in v1. " +
                "(see CHANGELOG / docs/parity.md § CLI surface for the full Mac surface.)");
            return 2;
        }
        var r = MaintenanceCommands.RetryEmptyLinks(db);
        Console.WriteLine(
            $"backfill-titles --retry-empty: cleared link state on {r.LinkStateReset} row(s). " +
            "Restart cpdb-win to pick them up in the next backfill cycle.");
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

              cpdb-win dedupe --links-all-time
                  For each text_preview URL with multiple live
                  kind=link rows, keep the newest and tombstone the
                  rest. Salvages link_title from a sibling first if
                  the survivor lacks one.

              cpdb-win --help
                  Print this message.

            All commands operate on %LOCALAPPDATA%\cpdb\cpdb.db.
            """);
    }
}

