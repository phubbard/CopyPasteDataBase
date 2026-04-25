using CpdbWin.Core.Store;
using Xunit;

namespace CpdbWin.Core.Tests;

public class AppPathsTests
{
    [Fact]
    public void DefaultRoot_LivesUnderLocalApplicationData()
    {
        var root = AppPaths.DefaultRoot();
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        Assert.Equal(Path.Combine(local, "cpdb"), root);
    }

    [Fact]
    public void DatabaseFile_AndBlobsDir_AreUnderRoot()
    {
        Assert.Equal(@"C:\foo\cpdb.db", AppPaths.DatabaseFile(@"C:\foo"));
        Assert.Equal(@"C:\foo\blobs",   AppPaths.BlobsDir(@"C:\foo"));
    }

    [Fact]
    public void Initialize_CreatesRootAndBlobsDir()
    {
        var root = Path.Combine(Path.GetTempPath(), "cpdb-apppaths-" + Guid.NewGuid().ToString("N"));
        try
        {
            var resolved = AppPaths.Initialize(root);
            Assert.True(Directory.Exists(resolved.Root));
            Assert.True(Directory.Exists(resolved.Blobs));
            Assert.Equal(Path.Combine(root, "cpdb.db"), resolved.Database);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    [Fact]
    public void Initialize_IsIdempotent()
    {
        var root = Path.Combine(Path.GetTempPath(), "cpdb-apppaths-" + Guid.NewGuid().ToString("N"));
        try
        {
            AppPaths.Initialize(root);
            // Second call must not throw and must leave the dirs in place.
            var second = AppPaths.Initialize(root);
            Assert.True(Directory.Exists(second.Root));
            Assert.True(Directory.Exists(second.Blobs));
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }
}
