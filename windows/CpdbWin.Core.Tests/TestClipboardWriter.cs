using CpdbWin.Core.Capture;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Thin test-side wrapper over <see cref="ClipboardWriter"/>. Existed
/// before ClipboardWriter did; kept now as a friendlier name for tests
/// that just want "put this string on the clipboard".
/// </summary>
internal static class TestClipboardWriter
{
    public static void SetUnicodeText(string text) => ClipboardWriter.WriteText(text);

    public static void Empty()
    {
        // Tolerant of "another process holds the clipboard" so test teardown
        // never explodes.
        try { ClipboardWriter.Write(Array.Empty<(string Uti, byte[] Data)>()); }
        catch { }
    }
}
