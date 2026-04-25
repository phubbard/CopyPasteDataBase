using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace CpdbWin.Core.Capture;

/// <summary>
/// Order-independent SHA-256 over a sequence of pasteboard items. The output
/// is the dedup key in <c>entries.content_hash</c> and must be byte-for-byte
/// identical to the Swift reference in
/// <c>Sources/CpdbShared/Capture/CanonicalHash.swift</c>.
///
/// Canonical form (per docs/schema.md §Canonical hash):
/// <code>
/// for each item in items:                # items in original order
///     for each flavor in SORTED(item.flavors, by: uti):
///         emit uti.utf8
///         emit 0x00
///         emit uint64_be(flavor.data.count)
///         emit flavor.data
///     emit 0x01                          # item separator
/// </code>
/// </summary>
public static class CanonicalHash
{
    public readonly record struct Flavor(string Uti, ReadOnlyMemory<byte> Data);

    public static byte[] Compute(IReadOnlyList<IReadOnlyList<Flavor>> items)
    {
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Span<byte> lenBuf = stackalloc byte[8];
        Span<byte> oneByte = stackalloc byte[1];

        foreach (var item in items)
        {
            // Ordinal sort so ASCII UTI strings collate identically to
            // Swift's `<` operator on String (which compares Unicode scalars).
            var sorted = item.OrderBy(f => f.Uti, StringComparer.Ordinal);
            foreach (var flavor in sorted)
            {
                hasher.AppendData(Encoding.UTF8.GetBytes(flavor.Uti));
                oneByte[0] = 0x00;
                hasher.AppendData(oneByte);
                BinaryPrimitives.WriteUInt64BigEndian(lenBuf, (ulong)flavor.Data.Length);
                hasher.AppendData(lenBuf);
                hasher.AppendData(flavor.Data.Span);
            }
            oneByte[0] = 0x01;
            hasher.AppendData(oneByte);
        }

        return hasher.GetHashAndReset();
    }

    public static string ToHex(ReadOnlySpan<byte> bytes)
        => Convert.ToHexString(bytes).ToLowerInvariant();
}
