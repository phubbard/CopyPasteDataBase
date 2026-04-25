using CpdbWin.Core.Store;
using Xunit;

namespace CpdbWin.Core.Tests;

public class BlobStoreTests : IDisposable
{
    private readonly string _root;
    private readonly BlobStore _store;

    public BlobStoreTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "cpdb-blob-tests-" + Guid.NewGuid().ToString("N"));
        _store = new BlobStore(_root);
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    [Fact]
    public void Put_RoundTripsBytes()
    {
        var bytes = "hello world"u8.ToArray();
        var key = _store.Put(bytes);

        Assert.True(_store.Has(key));
        Assert.Equal(bytes, _store.Get(key));
    }

    [Fact]
    public void Put_IsIdempotentForSameContent()
    {
        var bytes = new byte[] { 1, 2, 3, 4 };
        var k1 = _store.Put(bytes);
        var k2 = _store.Put(bytes);
        Assert.Equal(k1, k2);
    }

    [Fact]
    public void Put_KeyMatchesSha256OfBytes()
    {
        var bytes = "hello"u8.ToArray();
        var key = _store.Put(bytes);
        // sha256("hello")
        Assert.Equal("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", key);
    }

    [Fact]
    public void PathFor_UsesTwoLevelHexFanout()
    {
        var key = "abcdef0123456789".PadRight(64, '0');
        var path = _store.PathFor(key);
        var expected = Path.Combine(_root, "ab", "cd", key);
        Assert.Equal(expected, path);
    }

    [Fact]
    public void Delete_RemovesFile()
    {
        var key = _store.Put(new byte[] { 0x42 });
        Assert.True(_store.Has(key));
        _store.Delete(key);
        Assert.False(_store.Has(key));
    }

    [Fact]
    public void Delete_OnMissingKeyIsNoOp()
    {
        _store.Delete(new string('0', 64));  // no throw
    }

    [Fact]
    public void Put_LeavesNoTempFiles()
    {
        _store.Put(new byte[] { 1, 2, 3 });
        var temps = Directory.EnumerateFiles(_root, "*.tmp.*", SearchOption.AllDirectories);
        Assert.Empty(temps);
    }
}
