using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Ingest;
using Xunit;

namespace CpdbWin.Core.Tests;

public class TitleAndPreviewTests
{
    private static CanonicalHash.Flavor Text(string s) =>
        new("public.utf8-plain-text", Encoding.UTF8.GetBytes(s));

    private static CanonicalHash.Flavor FileUrl(string url) =>
        new("public.file-url", Encoding.UTF8.GetBytes(url));

    [Fact]
    public void Title_FirstNonEmptyLine_Trimmed()
    {
        var (title, preview) = TitleAndPreview.Derive(new[] { Text("\n\n  hello world  \nignored\n") });
        Assert.Equal("hello world", title);
        Assert.Equal("\n\n  hello world  \nignored\n", preview);
    }

    [Fact]
    public void Title_TruncatedTo200Chars()
    {
        var line = new string('x', 250);
        var (title, _) = TitleAndPreview.Derive(new[] { Text(line) });
        Assert.Equal(200, title!.Length);
        Assert.Equal(new string('x', 200), title);
    }

    [Fact]
    public void Title_HandlesCrLfLineEndings()
    {
        var (title, _) = TitleAndPreview.Derive(new[] { Text("first\r\nsecond\r\n") });
        Assert.Equal("first", title);
    }

    [Fact]
    public void Preview_TruncatedTo2048Chars()
    {
        var bigText = new string('a', 3000);
        var (_, preview) = TitleAndPreview.Derive(new[] { Text(bigText) });
        Assert.Equal(2048, preview!.Length);
    }

    [Fact]
    public void Preview_NullWhenNoTextFlavor()
    {
        var (title, preview) = TitleAndPreview.Derive(new[]
        {
            FileUrl("file:///C:/notes/todo.txt"),
        });
        Assert.Equal("todo.txt", title);
        Assert.Null(preview);
    }

    [Fact]
    public void Title_FromFileUrl_WhenNoText()
    {
        var (title, _) = TitleAndPreview.Derive(new[] { FileUrl("file:///C:/Users/me/Pictures/cat.png") });
        Assert.Equal("cat.png", title);
    }

    [Fact]
    public void Title_FromFileUrl_PercentDecoded()
    {
        var (title, _) = TitleAndPreview.Derive(new[]
        {
            FileUrl("file:///C:/Users/me/Pictures/hello%20world.txt"),
        });
        Assert.Equal("hello world.txt", title);
    }

    [Fact]
    public void Title_PrefersTextOverFileUrl()
    {
        var (title, _) = TitleAndPreview.Derive(new[]
        {
            Text("from text\n"),
            FileUrl("file:///C:/whatever.txt"),
        });
        Assert.Equal("from text", title);
    }

    [Fact]
    public void Title_NullWhenAllTextIsWhitespace()
    {
        var (title, preview) = TitleAndPreview.Derive(new[] { Text("   \n\t\n   \n") });
        Assert.Null(title);
        Assert.Equal("   \n\t\n   \n", preview);
    }

    [Fact]
    public void EmptyFlavors_ReturnsNulls()
    {
        var (title, preview) = TitleAndPreview.Derive(Array.Empty<CanonicalHash.Flavor>());
        Assert.Null(title);
        Assert.Null(preview);
    }
}
