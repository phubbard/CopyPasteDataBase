using System.Text;
using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

public class CanonicalHashTests
{
    // Vectors derived by re-implementing the canonical byte stream
    //   uti.utf8 || 0x00 || u64_be(len) || data ; then 0x01 item separator
    // exactly as Sources/CpdbShared/Capture/CanonicalHash.swift does, then
    // piping the bytes through sha256sum. They MUST match what the macOS
    // hasher produces — the Swift reference is the contract.

    [Fact]
    public void HelloPlainText_MatchesPinnedVector()
    {
        var items = new List<IReadOnlyList<CanonicalHash.Flavor>>
        {
            new List<CanonicalHash.Flavor>
            {
                new("public.utf8-plain-text", Encoding.UTF8.GetBytes("hello")),
            },
        };

        var hash = CanonicalHash.Compute(items);

        Assert.Equal(
            "b22187611777c1e9c84c3fdd054ed311a47d12f33cba6d1e7761bd3a7314073a",
            CanonicalHash.ToHex(hash));
    }

    [Fact]
    public void HelloPlainTextAndHtml_MatchesPinnedVector()
    {
        var items = new List<IReadOnlyList<CanonicalHash.Flavor>>
        {
            new List<CanonicalHash.Flavor>
            {
                new("public.utf8-plain-text", Encoding.UTF8.GetBytes("hello")),
                new("public.html", Encoding.UTF8.GetBytes("<b>hello</b>")),
            },
        };

        var hash = CanonicalHash.Compute(items);

        // public.html sorts before public.utf8-plain-text (ordinal).
        Assert.Equal(
            "17a95cac0686665cfe5342a3a041d7afedfa4c14a59d6d3c6b7b53a4bf0ad85a",
            CanonicalHash.ToHex(hash));
    }

    [Fact]
    public void OrderIndependentWithinItem()
    {
        var a = new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes("hello"));
        var b = new CanonicalHash.Flavor("public.html", Encoding.UTF8.GetBytes("<b>hello</b>"));

        var ab = CanonicalHash.Compute(new List<IReadOnlyList<CanonicalHash.Flavor>>
            { new List<CanonicalHash.Flavor> { a, b } });
        var ba = CanonicalHash.Compute(new List<IReadOnlyList<CanonicalHash.Flavor>>
            { new List<CanonicalHash.Flavor> { b, a } });

        Assert.Equal(ab, ba);
    }

    [Fact]
    public void ItemSeparatorMatters()
    {
        // [{a,b}] must hash differently from [{a},{b}] — the 0x01 separator
        // is the only thing distinguishing them, so a missing separator is a
        // silent collision bug.
        var a = new CanonicalHash.Flavor("public.a", new byte[] { 1 });
        var b = new CanonicalHash.Flavor("public.b", new byte[] { 2 });

        var oneItem = CanonicalHash.Compute(new List<IReadOnlyList<CanonicalHash.Flavor>>
            { new List<CanonicalHash.Flavor> { a, b } });
        var twoItems = CanonicalHash.Compute(new List<IReadOnlyList<CanonicalHash.Flavor>>
            { new List<CanonicalHash.Flavor> { a }, new List<CanonicalHash.Flavor> { b } });

        Assert.NotEqual(oneItem, twoItems);
    }

    [Fact]
    public void EmptyDataFlavorIsHashed()
    {
        // A zero-byte flavor still emits its uti + 0x00 + u64_be(0).
        var items = new List<IReadOnlyList<CanonicalHash.Flavor>>
        {
            new List<CanonicalHash.Flavor>
            {
                new("public.utf8-plain-text", Array.Empty<byte>()),
            },
        };

        var hash = CanonicalHash.Compute(items);
        Assert.Equal(32, hash.Length);
    }
}
