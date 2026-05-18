using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// Startup forensics for the one failure we could neither explain nor
/// recover from: a non-empty clipboard history that came up empty with
/// no proven cause and no backup.
///
/// <para>
/// Two responsibilities, both append-only and best-effort:
/// </para>
/// <list type="number">
/// <item><b>Gc audit log.</b> <see cref="Gc"/> returns a
///   <see cref="Gc.Stats"/> describing what it tombstoned / hard-deleted
///   / orphaned; until now that value was discarded, so a destructive
///   sweep left no trace. <see cref="LogGc"/> writes it to
///   <c>%LOCALAPPDATA%\cpdb\gc.log</c> next to the rest of the
///   diagnostic logs.</item>
/// <item><b>Empty-DB circuit breaker.</b> Each clean boot records the
///   live-entry count to a <c>.entrycount</c> sidecar. If the next boot
///   finds the DB went from non-empty → zero live entries, that is
///   <see cref="IsSuspectedDataLoss">suspected data loss</see>: we skip
///   Gc (never compound a loss with a sweep), skip starting capture
///   (freeze the DB for forensics), and drop a loud
///   <c>DATA-LOSS-WARNING.txt</c>. It is a <i>one-shot</i> guard — the
///   marker is rewritten to the current count so a deliberate
///   "clear history" doesn't lock the app out forever; a genuine loss
///   still gets one hard stop + a written record.</item>
/// </list>
/// </summary>
public static class BootDiagnostics
{
    private const string MarkerFileName = ".entrycount";
    private const string GcLogFileName = "gc.log";
    private const string WarningFileName = "DATA-LOSS-WARNING.txt";

    /// <summary>Live (non-tombstoned) row count, or 0 on any error.</summary>
    public static int LiveEntryCount(SqliteConnection db)
    {
        try
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL";
            return Convert.ToInt32(cmd.ExecuteScalar());
        }
        catch
        {
            return 0;
        }
    }

    /// <summary>
    /// Last live-entry count recorded by a previous clean boot, or
    /// <c>null</c> if there is no marker (first ever run, or the file was
    /// removed). A non-integer / unreadable marker also reads as
    /// <c>null</c> — we never treat a corrupt marker as "0 entries".
    /// </summary>
    public static int? ReadEntryMarker(string root)
    {
        try
        {
            var path = Path.Combine(root, MarkerFileName);
            if (!File.Exists(path)) return null;
            var raw = File.ReadAllText(path).Trim();
            return int.TryParse(raw, out var n) ? n : (int?)null;
        }
        catch
        {
            return null;
        }
    }

    public static void WriteEntryMarker(string root, int count)
    {
        try
        {
            Directory.CreateDirectory(root);
            File.WriteAllText(Path.Combine(root, MarkerFileName), count.ToString());
        }
        catch
        {
            /* best effort — a missing marker just means "first run" next time */
        }
    }

    /// <summary>
    /// Pure guard. Suspected data loss iff a prior boot recorded a
    /// positive live count and this boot sees zero. No marker (first
    /// run) or a prior count of zero is never suspicious.
    /// </summary>
    public static bool IsSuspectedDataLoss(int? previousMarker, int currentLiveCount)
        => previousMarker is int prev && prev > 0 && currentLiveCount == 0;

    public static void LogGc(string root, Gc.Stats stats, int liveBefore, int liveAfter)
        => Log(root,
            $"Gc: liveBefore={liveBefore} liveAfter={liveAfter} "
          + $"tombstoned={stats.TombstonedExtras} "
          + $"hardDeleted={stats.HardDeleted} "
          + $"orphanBlobs={stats.OrphanBlobs}");

    public static void Log(string root, string message)
    {
        try
        {
            Directory.CreateDirectory(root);
            var path = Path.Combine(root, GcLogFileName);
            if (File.Exists(path) && new FileInfo(path).Length > 1_000_000)
                File.WriteAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] (rotated)\n");
            File.AppendAllText(path,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}\n");
        }
        catch
        {
            /* diagnostics must never break boot */
        }
    }

    /// <summary>
    /// Drop a human-readable warning at the cpdb root so the loss is
    /// impossible to miss even for a user who never opens a log file.
    /// </summary>
    public static void WriteDataLossWarning(string root, int previousMarker)
    {
        try
        {
            Directory.CreateDirectory(root);
            var path = Path.Combine(root, WarningFileName);
            File.WriteAllText(path,
                $"cpdb-win — SUSPECTED DATA LOSS — {DateTime.Now:yyyy-MM-dd HH:mm:ss}\n"
              + "\n"
              + $"The previous clean run recorded {previousMarker} live clipboard\n"
              + "entries. This run found the database EMPTY (0 live entries).\n"
              + "\n"
              + "As a safety measure cpdb-win has, for this launch only:\n"
              + "  * NOT run garbage collection (so an existing loss is not\n"
              + "    compounded by a sweep), and\n"
              + "  * NOT started clipboard capture (so the database is frozen\n"
              + "    in its current state for inspection).\n"
              + "\n"
              + "What to do:\n"
              + $"  1. Look for a backup near the database under {root}\n"
              + "     (files named cpdb.backup-* / cpdb.db). If you find one,\n"
              + "     quit cpdb-win, restore it over cpdb.db, then relaunch.\n"
              + "  2. If you intentionally cleared your history, no action is\n"
              + "     needed — the next launch resumes capture normally.\n"
              + "\n"
              + "This is a ONE-SHOT guard: the next launch will not stop again\n"
              + "(it records the current count as the new baseline). Delete\n"
              + "this file once you've dealt with it.\n");
        }
        catch
        {
            /* best effort */
        }
    }
}
