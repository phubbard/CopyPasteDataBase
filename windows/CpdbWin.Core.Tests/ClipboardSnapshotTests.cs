using System.Text;
using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

public class ClipboardSnapshotTests : IDisposable
{
    public void Dispose() => TestClipboardWriter.Empty();

    [Fact]
    public void Capture_ReadsUnicodeTextWeJustWrote()
    {
        var unique = $"cpdb-snapshot-{Guid.NewGuid()}";
        TestClipboardWriter.SetUnicodeText(unique);

        var snap = ClipboardSnapshot.Capture();

        var text = snap.Flavors.Single(f => f.Uti == "public.utf8-plain-text");
        Assert.Equal(Encoding.UTF8.GetBytes(unique), text.Data.ToArray());
    }

    [Fact]
    public void Capture_DropsAutoSynthesizedAnsiAndLocaleFormats()
    {
        // When we set only CF_UNICODETEXT, Windows synthesizes CF_TEXT,
        // CF_OEMTEXT, and CF_LOCALE on read. The translator drops all three
        // (we don't trust round-tripping through codepages), so the snapshot
        // should contain exactly one flavor — the original UTF-16 we wrote.
        TestClipboardWriter.SetUnicodeText("hello");
        var snap = ClipboardSnapshot.Capture();

        Assert.Single(snap.Flavors);
        Assert.Equal("public.utf8-plain-text", snap.Flavors[0].Uti);
    }

    [Fact]
    public void ContentHash_IsStableAcrossRepeatedCaptures()
    {
        TestClipboardWriter.SetUnicodeText("stable-content-hash");

        var a = ClipboardSnapshot.Capture().ContentHash();
        var b = ClipboardSnapshot.Capture().ContentHash();

        Assert.Equal(a, b);
    }

    [Fact]
    public void ContentHash_MatchesPinnedHelloVector()
    {
        // End-to-end check: clipboard → snapshot → canonical hash. With
        // exactly the "hello" UTF-8 plain-text flavor on the clipboard,
        // we should recover the pinned vector from docs/schema.md.
        TestClipboardWriter.SetUnicodeText("hello");
        var snap = ClipboardSnapshot.Capture();

        Assert.Equal(
            "b22187611777c1e9c84c3fdd054ed311a47d12f33cba6d1e7761bd3a7314073a",
            CanonicalHash.ToHex(snap.ContentHash()));
    }
}
