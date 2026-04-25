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

    public static string DefaultRoot() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            AppDirName);

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
