using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace CpdbWin.Core.Capture;

/// <summary>
/// Order-independent SHA-256 over a sequence of pasteboard items. Survives
/// from v1 as the <b>fallback-rung emission</b> of canonical-hash v2
/// (semantic identity — see <see cref="ContentIdentity"/>): the v2 rung
/// chain only reaches this code when no image / file / url / text / color
/// flavor keyed identity, which is rare. The output is also the historical
/// <c>entries.content_hash</c> for <c>hash_version = 1</c> rows on disk
/// and the contract the Mac+Python references mirror byte-for-byte.
///
/// Canonical form (per docs/canonical-hash-v2.md §2.3 fallback rung +
/// <c>Tools/gen_hash_vectors.py</c> <c>v1_emission</c>):
/// <code>
/// for each item in items:                # items in original order
///     for each flavor in SORTED(item.flavors, by: BYTE-WISE UTF-8 of uti):
///         emit uti.utf8
///         emit 0x00
///         emit uint64_be(flavor.data.count)
///         emit flavor.data
///     emit 0x01                          # item separator
/// </code>
///
/// <para>
/// <b>Sort contract.</b> Sort is byte-wise over the UTF-8 encoding of the
/// UTI — NOT Swift's <c>String &lt;</c> (Unicode-scalar collation) and NOT
/// <see cref="StringComparer.Ordinal"/> (UTF-16 code-unit collation). For
/// ASCII UTIs (the universe today) all three coincide, so existing v1
/// hashes on disk are unchanged by this fix. For a non-ASCII UTI spanning
/// the BMP / supplementary-plane boundary the three differ: UTF-16
/// surrogate pairs have a code-unit value of <c>0xD800..0xDBFF</c> which
/// compares as <i>less than</i> any 3-byte UTF-8 BMP codepoint in
/// <c>U+E000..U+FFFF</c>, while in UTF-8 the 4-byte supplementary sequence
/// (leading byte <c>0xF0..0xF4</c>) compares <i>greater than</i> the
/// 3-byte BMP sequence (leading byte <c>0xE0..0xEF</c>). The v2 reference
/// vectors include a non-ASCII pair that pins this; the JSON theory will
/// catch any regression.
/// </para>
/// </summary>
public static class CanonicalHash
{
    public readonly record struct Flavor(string Uti, ReadOnlyMemory<byte> Data);

    /// <summary>SHA-256 of <see cref="EmitV1"/>. The historical v1
    /// <c>entries.content_hash</c> and the v2 fallback rung's outer-hash
    /// input differ by one SHA-256 call, so the raw emission is exposed
    /// separately via <see cref="EmitV1"/>; this method preserves the v1
    /// API surface for any caller still asking for the hashed form.</summary>
    public static byte[] Compute(IReadOnlyList<IReadOnlyList<Flavor>> items)
    {
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hasher.AppendData(EmitV1(items));
        return hasher.GetHashAndReset();
    }

    /// <summary>The raw canonical emission bytes — the SHA-256 input that
    /// <see cref="Compute"/> hashes. Exposed because the v2 fallback rung
    /// inside <see cref="ContentIdentity"/> wraps these bytes with one
    /// outer SHA-256 over <c>"fallback" || 0x00 || EmitV1(...)</c>; if it
    /// asked for <see cref="Compute"/> here it would be hashing twice.
    /// Mirrors <c>v1_emission()</c> in <c>Tools/gen_hash_vectors.py</c>
    /// byte-for-byte.</summary>
    public static byte[] EmitV1(IReadOnlyList<IReadOnlyList<Flavor>> items)
    {
        using var ms = new MemoryStream();
        Span<byte> lenBuf = stackalloc byte[8];

        foreach (var item in items)
        {
            // Byte-wise UTF-8 sort. See class doc on why Ordinal is wrong.
            var sorted = item.OrderBy(f => Encoding.UTF8.GetBytes(f.Uti), Utf8ByteComparer.Instance);
            foreach (var flavor in sorted)
            {
                var utiBytes = Encoding.UTF8.GetBytes(flavor.Uti);
                ms.Write(utiBytes, 0, utiBytes.Length);
                ms.WriteByte(0x00);
                BinaryPrimitives.WriteUInt64BigEndian(lenBuf, (ulong)flavor.Data.Length);
                ms.Write(lenBuf);
                ms.Write(flavor.Data.Span);
            }
            ms.WriteByte(0x01);
        }

        return ms.ToArray();
    }

    public static string ToHex(ReadOnlySpan<byte> bytes)
        => Convert.ToHexString(bytes).ToLowerInvariant();

    /// <summary>
    /// Lexicographic byte-array comparer. Same ordering Python's
    /// <c>sorted(..., key=lambda s: s.encode("utf-8"))</c> produces and
    /// Swift's <c>Array(s.utf8).lexicographicallyPrecedes(...)</c>.
    /// </summary>
    private sealed class Utf8ByteComparer : IComparer<byte[]>
    {
        public static readonly Utf8ByteComparer Instance = new();
        public int Compare(byte[]? x, byte[]? y)
        {
            if (ReferenceEquals(x, y)) return 0;
            if (x is null) return -1;
            if (y is null) return  1;
            int n = Math.Min(x.Length, y.Length);
            for (int i = 0; i < n; i++)
            {
                int d = x[i] - y[i];
                if (d != 0) return d;
            }
            return x.Length - y.Length;
        }
    }
}
