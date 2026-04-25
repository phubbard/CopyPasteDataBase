using System.Text;
using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

public class ClipboardWriterTests : IDisposable
{
    public void Dispose()
    {
        TestClipboardWriter.Empty();
        ProductionDbCleanup.TombstoneTestEntries();
    }

    [Fact]
    public void WriteText_RoundTripsThroughCapture()
    {
        var unique = $"{ProductionDbCleanup.TestPrefix}writer-{Guid.NewGuid()}";
        ClipboardWriter.WriteText(unique);

        var snap = ClipboardSnapshot.Capture();
        var text = snap.Flavors.Single(f => f.Uti == "public.utf8-plain-text");
        Assert.Equal(Encoding.UTF8.GetBytes(unique), text.Data.ToArray());
    }

    [Fact]
    public void Write_PngFlavor_IsCapturable()
    {
        // 16-byte synthetic "PNG" — content doesn't have to be a real PNG
        // because we only check the round-trip through the registered
        // PNG clipboard format.
        var fake = new byte[] { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4, 5, 6, 7, 8 };
        ClipboardWriter.Write(new[] { ("public.png", fake) });

        var snap = ClipboardSnapshot.Capture();
        var png = snap.Flavors.Single(f => f.Uti == "public.png");
        Assert.Equal(fake, png.Data.ToArray());
    }

    [Fact]
    public void Write_UnknownUti_IsSilentlySkipped()
    {
        // public.color isn't in v1's writeable set; should empty the clipboard
        // (the EmptyClipboard at the start of Write) and produce no flavors.
        ClipboardWriter.Write(new[] { ("public.color", new byte[] { 1, 2, 3 }) });
        var snap = ClipboardSnapshot.Capture();
        Assert.Empty(snap.Flavors);
    }

    [Fact]
    public void Write_EmptyEnumerable_ClearsClipboard()
    {
        ClipboardWriter.WriteText("seed");
        ClipboardWriter.Write(Array.Empty<(string, byte[])>());

        var snap = ClipboardSnapshot.Capture();
        Assert.Empty(snap.Flavors);
    }
}
