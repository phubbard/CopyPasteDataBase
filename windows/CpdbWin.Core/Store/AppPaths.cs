namespace CpdbWin.Core.Store;

/// <summary>
/// Resolves on-disk locations for cpdb-win. The default root is
/// <c>%LOCALAPPDATA%\cpdb</c>, per docs/schema.md §Database file location.
/// Tests pass an explicit root so they don't pollute the real install.
/// </summary>
public static class AppPaths
{
    public const string AppDirName = "cpdb";
    public const string DbFileName = "cpdb.db";
    public const string BlobsDirName = "blobs";

    /// <summary>
    /// Environment-variable override for the support directory.
    /// Named to match Mac's <c>CPDB_SUPPORT_DIR</c> so muscle memory
    /// carries across platforms — <c>cpdb-win fixture env NAME</c>
    /// (v1.53) prints a shell snippet setting this var so a user
    /// can point the app / CLI at a fixture snapshot for the
    /// current shell session.
    /// </summary>
    public const string SupportDirEnvVar = "CPDB_SUPPORT_DIR";

    /// <summary>
    /// Sibling of <see cref="AppDirName"/> used as the fixtures root
    /// (<c>%LOCALAPPDATA%\cpdb-fixtures\&lt;name&gt;\</c>). Sibling
    /// rather than child so a `fixture delete` (or an accidental
    /// nuke of the fixtures tree) can never touch the live DB.
    /// Mirrors Mac's <c>{bundleId}-fixtures</c> layout.
    /// </summary>
    public const string FixturesDirName = "cpdb-fixtures";

    /// <summary>
    /// Resolve the support-directory root. Env-var override wins
    /// over the default so <c>cpdb-win fixture env NAME</c> +
    /// <c>set CPDB_SUPPORT_DIR=…</c> can retarget the whole app /
    /// CLI at a fixture snapshot for the current shell session.
    /// Empty / whitespace values are ignored (matches Mac's null-
    /// coalesce behaviour).
    /// </summary>
    public static string DefaultRoot()
    {
        var envRoot = Environment.GetEnvironmentVariable(SupportDirEnvVar);
        if (!string.IsNullOrWhiteSpace(envRoot)) return envRoot;
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            AppDirName);
    }

    /// <summary>Absolute path to the fixtures directory (containing
    /// per-name subdirectories). Not created — callers materialise
    /// it as needed. Sibling of the default support root by design;
    /// respects the LocalAppData env override for a portable-mode
    /// install without inheriting <see cref="SupportDirEnvVar"/>
    /// (fixtures are always keyed to the machine, not the current
    /// shell's overridden support dir).</summary>
    public static string FixturesRoot() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            FixturesDirName);

    public static string DatabaseFile(string root) => Path.Combine(root, DbFileName);
    public static string BlobsDir(string root) => Path.Combine(root, BlobsDirName);

    public readonly record struct Resolved(string Root, string Database, string Blobs);

    /// <summary>
    /// Ensure the root and blobs directory exist; return the absolute paths.
    /// Idempotent — safe to call on every app launch.
    /// </summary>
    public static Resolved Initialize(string? root = null)
    {
        var r = root ?? DefaultRoot();
        Directory.CreateDirectory(r);
        var blobs = BlobsDir(r);
        Directory.CreateDirectory(blobs);
        return new Resolved(r, DatabaseFile(r), blobs);
    }
}
