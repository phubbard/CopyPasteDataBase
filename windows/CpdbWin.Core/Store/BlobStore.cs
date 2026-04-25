using System.Security.Cryptography;

namespace CpdbWin.Core.Store;

/// <summary>
/// Content-addressed file store for flavor bytes that exceed the 256 KB
/// inline threshold. Layout per docs/schema.md §Blob store:
/// <c>&lt;root&gt;/&lt;hex[0:2]&gt;/&lt;hex[2:4]&gt;/&lt;hex&gt;</c> where the hex
/// is the lowercase SHA-256 of the bytes. Two-level fan-out keeps any
/// directory below ~64K entries in practice.
///
/// Writes are atomic via temp-file + rename. If two callers race to write
/// the same key, the loser sees the file already exists post-rename and
/// silently uses the winner's copy — both wrote identical bytes.
/// </summary>
public sealed class BlobStore
{
    public string Root { get; }

    public BlobStore(string root)
    {
        Root = root;
        Directory.CreateDirectory(root);
    }

    /// <summary>Hex SHA-256 of the input. Matches the on-disk filename.</summary>
    public static string ComputeKey(ReadOnlySpan<byte> bytes)
    {
        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(bytes, hash);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    public string PathFor(string key)
    {
        if (key.Length < 4) throw new ArgumentException("key too short", nameof(key));
        return Path.Combine(Root, key[..2], key.Substring(2, 2), key);
    }

    public bool Has(string key) => File.Exists(PathFor(key));

    public byte[] Get(string key) => File.ReadAllBytes(PathFor(key));

    public void Delete(string key)
    {
        var p = PathFor(key);
        if (File.Exists(p)) File.Delete(p);
    }

    /// <summary>Writes bytes (if not already present) and returns the key.</summary>
    public string Put(ReadOnlySpan<byte> bytes)
    {
        var key = ComputeKey(bytes);
        var path = PathFor(key);
        if (File.Exists(path)) return key;

        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp." + Guid.NewGuid().ToString("N");
        try
        {
            using (var fs = new FileStream(temp, FileMode.CreateNew, FileAccess.Write))
            {
                fs.Write(bytes);
            }
            try
            {
                File.Move(temp, path);
            }
            catch (IOException) when (File.Exists(path))
            {
                // Lost a race; another writer landed the same content first.
                File.Delete(temp);
            }
        }
        catch
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { }
            throw;
        }
        return key;
    }
}
