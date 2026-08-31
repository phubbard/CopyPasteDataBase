using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// Test-data scaffolding: snapshot the live DB + blob store into a
/// named fixture directory, list snapshots, delete them. Windows
/// port of macOS's <c>Sources/cpdb/Commands/Fixture.swift</c>.
///
/// <para>
/// <b>Location</b>: fixtures live at
/// <c>%LOCALAPPDATA%\cpdb-fixtures\&lt;name&gt;\</c> — <b>sibling</b>
/// of the live <c>%LOCALAPPDATA%\cpdb\</c> support root, not a child
/// of it. Sibling by design: a fat-fingered <c>fixture delete</c>
/// (or an accidental nuke of the fixtures tree) can never touch the
/// live DB. Mirrors Mac's <c>{bundleId}-fixtures</c> layout.
/// </para>
///
/// <para>
/// <b>Snapshot semantics</b>: <c>PRAGMA wal_checkpoint(TRUNCATE)</c>
/// on the live DB first, then copy only <c>cpdb.db</c> + the entire
/// <c>blobs/</c> tree. The WAL / SHM sidecars are collapsed by the
/// checkpoint and don't need to be copied — a fixture opened later
/// with a fresh SQLite handle rebuilds them. Cleaner than Mac's
/// <c>ditto</c> (which just tells the user "quit cpdb.app first for
/// a fully consistent snapshot") — the checkpoint gives us a
/// consistent snapshot even with the GUI running.
/// </para>
///
/// <para>
/// <b>Env-var handoff</b>: <see cref="EnvSnippet"/> emits a shell
/// snippet setting <see cref="AppPaths.SupportDirEnvVar"/>
/// (<c>CPDB_SUPPORT_DIR</c>) to the fixture path, so
/// <c>cpdb-win fixture env foo</c> paired with
/// <c>set CPDB_SUPPORT_DIR=…</c> in cmd or
/// <c>$env:CPDB_SUPPORT_DIR = "…"</c> in PowerShell retargets the
/// whole app / CLI at the fixture for the current shell session.
/// <see cref="AppPaths.DefaultRoot"/> honors the env var.
/// </para>
/// </summary>
public sealed class FixtureManager
{
    private readonly string _liveRoot;
    private readonly string _fixturesRoot;

    public FixtureManager(string liveRoot, string fixturesRoot)
    {
        _liveRoot     = liveRoot;
        _fixturesRoot = fixturesRoot;
    }

    /// <summary>Convenience: use the app's real live + fixtures paths.</summary>
    public static FixtureManager Default(AppPaths.Resolved paths) =>
        new(paths.Root, AppPaths.FixturesRoot());

    /// <summary>Absolute path to the named fixture directory
    /// (regardless of whether it currently exists).</summary>
    public string PathFor(string name) => Path.Combine(_fixturesRoot, name);

    /// <summary>Copy the live support directory to
    /// <c>%LOCALAPPDATA%\cpdb-fixtures\&lt;name&gt;\</c>. Refuses if
    /// the destination already exists unless <paramref name="overwrite"/>
    /// is true — matches Mac's default. Returns the number of bytes
    /// copied (for the CLI's report line).</summary>
    public FixtureSnapshotResult Snapshot(string name, bool overwrite = false)
    {
        ValidateName(name);
        var dest = PathFor(name);
        if (Directory.Exists(dest))
        {
            if (!overwrite)
                throw new FixtureExistsException($"fixture '{name}' already exists at {dest}");
            Directory.Delete(dest, recursive: true);
        }

        // Checkpoint the live WAL so the .db file on disk is a
        // consistent standalone snapshot. TRUNCATE (rather than FULL
        // or PASSIVE) also zeroes the WAL file so subsequent copies
        // don't pick up stale bytes if the WAL happened to be sized
        // large from a previous session.
        var liveDb = Path.Combine(_liveRoot, AppPaths.DbFileName);
        if (File.Exists(liveDb))
        {
            using var conn = new SqliteConnection($"Data Source={liveDb}");
            conn.Open();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "PRAGMA wal_checkpoint(TRUNCATE)";
            try { cmd.ExecuteNonQuery(); } catch { /* checkpoint failure isn't fatal — the copy below still produces a usable snapshot in most cases */ }
        }

        Directory.CreateDirectory(dest);
        long bytes = 0;

        // Copy the DB file (post-checkpoint, so it's self-contained).
        if (File.Exists(liveDb))
        {
            var destDb = Path.Combine(dest, AppPaths.DbFileName);
            File.Copy(liveDb, destDb);
            bytes += new FileInfo(destDb).Length;
        }

        // Copy the entire blobs/ tree, preserving the two-level
        // sha-prefix fan-out that BlobStore relies on.
        var liveBlobs = Path.Combine(_liveRoot, AppPaths.BlobsDirName);
        if (Directory.Exists(liveBlobs))
        {
            var destBlobs = Path.Combine(dest, AppPaths.BlobsDirName);
            bytes += CopyDirectoryRecursive(liveBlobs, destBlobs);
        }

        return new FixtureSnapshotResult(name, dest, bytes);
    }

    /// <summary>Enumerate the fixtures directory. Returns each
    /// snapshot's name + total on-disk size (recursive dir walk) so
    /// the CLI's <c>list</c> subcommand can print both columns.
    /// Empty when the fixtures root doesn't exist yet.</summary>
    public IReadOnlyList<FixtureListing> List()
    {
        if (!Directory.Exists(_fixturesRoot)) return Array.Empty<FixtureListing>();
        var results = new List<FixtureListing>();
        foreach (var dir in Directory.EnumerateDirectories(_fixturesRoot))
        {
            var name = Path.GetFileName(dir);
            results.Add(new FixtureListing(name, dir, DirSize(dir)));
        }
        // Alphabetical — stable output, easier to grep.
        results.Sort((a, b) => StringComparer.OrdinalIgnoreCase.Compare(a.Name, b.Name));
        return results;
    }

    /// <summary>Delete a named fixture directory. Throws
    /// <see cref="FixtureNotFoundException"/> if it doesn't exist —
    /// the caller distinguishes typos from race-loss.</summary>
    public void Delete(string name)
    {
        ValidateName(name);
        var path = PathFor(name);
        if (!Directory.Exists(path))
            throw new FixtureNotFoundException($"no fixture named '{name}' (looked in {path})");
        Directory.Delete(path, recursive: true);
    }

    /// <summary>Shell snippet that sets
    /// <see cref="AppPaths.SupportDirEnvVar"/> to the fixture's
    /// path. Two dialects for the two shells a Windows user is
    /// likely to be in: <c>cmd</c> (default) uses <c>set NAME=value</c>;
    /// <c>powershell</c> uses <c>$env:NAME = "value"</c>. Path is
    /// literal — no quoting — because Windows file paths don't
    /// contain a shell-interpretable character that either dialect
    /// would misparse in these forms.</summary>
    public string EnvSnippet(string name, FixtureShell shell)
    {
        ValidateName(name);
        var path = PathFor(name);
        if (!Directory.Exists(path))
            throw new FixtureNotFoundException($"no fixture named '{name}' (looked in {path})");
        return shell switch
        {
            FixtureShell.Cmd        => $"set {AppPaths.SupportDirEnvVar}={path}",
            FixtureShell.PowerShell => $"$env:{AppPaths.SupportDirEnvVar} = \"{path}\"",
            _                       => throw new ArgumentOutOfRangeException(nameof(shell)),
        };
    }

    private static long DirSize(string dir)
    {
        long total = 0;
        try
        {
            foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
            {
                try { total += new FileInfo(f).Length; } catch { /* file vanished mid-walk */ }
            }
        }
        catch { /* dir vanished / permission — best effort */ }
        return total;
    }

    private static long CopyDirectoryRecursive(string source, string dest)
    {
        Directory.CreateDirectory(dest);
        long bytes = 0;
        foreach (var file in Directory.EnumerateFiles(source))
        {
            var name = Path.GetFileName(file);
            var target = Path.Combine(dest, name);
            File.Copy(file, target);
            try { bytes += new FileInfo(target).Length; } catch { }
        }
        foreach (var sub in Directory.EnumerateDirectories(source))
        {
            var name = Path.GetFileName(sub);
            bytes += CopyDirectoryRecursive(sub, Path.Combine(dest, name));
        }
        return bytes;
    }

    /// <summary>Reject names that could escape the fixtures root
    /// (path separators, drive letters, <c>..</c>) or that Windows
    /// wouldn't accept as a directory name (empty, reserved chars,
    /// reserved device names, trailing dot/space). Cheap defense
    /// against a bad CLI arg — a fixture name is user input.</summary>
    public static void ValidateName(string name)
    {
        if (string.IsNullOrWhiteSpace(name))
            throw new ArgumentException("fixture name must not be empty", nameof(name));
        if (name.Contains('/') || name.Contains('\\') || name.Contains(':') || name == "." || name == "..")
            throw new ArgumentException(
                $"fixture name '{name}' contains a path separator or reserved value",
                nameof(name));
        foreach (var ch in name)
        {
            if (Path.GetInvalidFileNameChars().Contains(ch))
                throw new ArgumentException(
                    $"fixture name '{name}' contains character invalid for a Windows path: {ch}",
                    nameof(name));
        }
    }
}

public readonly record struct FixtureSnapshotResult(string Name, string Path, long BytesCopied);
public readonly record struct FixtureListing(string Name, string Path, long Bytes);

public enum FixtureShell
{
    /// <summary><c>set NAME=value</c> — the classic cmd.exe form.</summary>
    Cmd,
    /// <summary><c>$env:NAME = "value"</c> — PowerShell form.</summary>
    PowerShell,
}

public sealed class FixtureExistsException     : Exception { public FixtureExistsException(string message)     : base(message) { } }
public sealed class FixtureNotFoundException   : Exception { public FixtureNotFoundException(string message)   : base(message) { } }
