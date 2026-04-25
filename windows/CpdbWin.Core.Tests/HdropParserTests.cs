using System.Text;
using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

public class HdropParserTests
{
    private static byte[] BuildDropfiles(IEnumerable<string> paths, bool fWide = true)
    {
        using var ms = new MemoryStream();
        var w = new BinaryWriter(ms);

        // DROPFILES: pFiles, POINT pt (8 bytes), fNC, fWide
        w.Write((int)20);   // pFiles
        w.Write((int)0);    // pt.x
        w.Write((int)0);    // pt.y
        w.Write((int)0);    // fNC
        w.Write(fWide ? 1 : 0);

        foreach (var p in paths)
        {
            w.Write(Encoding.Unicode.GetBytes(p));
            w.Write((short)0);   // wide null terminator
        }
        w.Write((short)0);       // list-end null

        return ms.ToArray();
    }

    [Fact]
    public void ParsePaths_SinglePath()
    {
        var raw = BuildDropfiles(new[] { @"C:\foo.txt" });
        var paths = HdropParser.ParsePaths(raw);
        Assert.Single(paths);
        Assert.Equal(@"C:\foo.txt", paths[0]);
    }

    [Fact]
    public void ParsePaths_MultiplePaths_PreservesOrder()
    {
        var input = new[] { @"C:\a.txt", @"D:\dir\b with space.png", @"\\server\share\c.zip" };
        var raw = BuildDropfiles(input);
        var paths = HdropParser.ParsePaths(raw);
        Assert.Equal(input, paths);
    }

    [Fact]
    public void ParsePaths_AnsiHdrop_NotSupported()
    {
        var raw = BuildDropfiles(new[] { @"C:\foo.txt" }, fWide: false);
        Assert.Empty(HdropParser.ParsePaths(raw));
    }

    [Fact]
    public void ParsePaths_BufferTooSmall_ReturnsEmpty()
    {
        Assert.Empty(HdropParser.ParsePaths(new byte[10]));
    }

    [Fact]
    public void ParsePaths_pFilesOutOfRange_ReturnsEmpty()
    {
        var raw = BuildDropfiles(new[] { @"C:\foo.txt" });
        // Smash pFiles to point past the buffer.
        var corrupt = (byte[])raw.Clone();
        BitConverter.GetBytes(99999).CopyTo(corrupt.AsSpan(0));
        Assert.Empty(HdropParser.ParsePaths(corrupt));
    }

    [Fact]
    public void ToFileUrl_LocalPath_UsesFileScheme()
    {
        Assert.Equal("file:///C:/foo.txt", HdropParser.ToFileUrl(@"C:\foo.txt"));
    }

    [Fact]
    public void ToFileUrl_PathWithSpaces_PercentEncoded()
    {
        var url = HdropParser.ToFileUrl(@"C:\Users\me\hello world.txt");
        Assert.Equal("file:///C:/Users/me/hello%20world.txt", url);
    }

    [Fact]
    public void ToFileUrl_UncPath_KeepsServerInAuthority()
    {
        var url = HdropParser.ToFileUrl(@"\\server\share\file.txt");
        Assert.Equal("file://server/share/file.txt", url);
    }
}
