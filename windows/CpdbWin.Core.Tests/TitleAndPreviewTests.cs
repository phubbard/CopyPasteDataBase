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

    private static CanonicalHash.Flavor Url(string url) =>
        new("public.url", Encoding.UTF8.GetBytes(url));

    private static CanonicalHash.Flavor ChromiumSourceUrl(string url) =>
        new("org.chromium.source-url", Encoding.UTF8.GetBytes(url));

    private static CanonicalHash.Flavor UrlName(string name) =>
        new("public.url-name", Encoding.UTF8.GetBytes(name));

    // URL-only fallback per docs/schema.md § Link metadata enrichment: when
    // the source app ships only public.url (no plain-text shadow), the URL
    // string itself becomes text_preview so the backfill candidate query
    // (`text_preview LIKE 'http%'`) finds the row.

    [Fact]
    public void Preview_FallsBackToPublicUrl_WhenNoText()
    {
        var (title, preview) = TitleAndPreview.Derive(new[]
        {
            Url("https://example.com/a/b"),
        });
        Assert.Equal("https://example.com/a/b", title);
        Assert.Equal("https://example.com/a/b", preview);
    }

    [Fact]
    public void Preview_FallsBackToChromiumSourceUrl_WhenNoTextOrPublicUrl()
    {
        // Chromium-family browsers (Chrome / Brave / Edge / Arc) ship image
        // copies with org.chromium.source-url instead of public.url.
        var (title, preview) = TitleAndPreview.Derive(new[]
        {
            ChromiumSourceUrl("https://news.example/articles/42"),
        });
        Assert.Equal("https://news.example/articles/42", title);
        Assert.Equal("https://news.example/articles/42", preview);
    }

    [Fact]
    public void Preview_FallsBackToUrlName_WhenOnlyHumanReadableTitlePresent()
    {
        var (title, preview) = TitleAndPreview.Derive(new[]
        {
            UrlName("Example article title"),
        });
        Assert.Equal("Example article title", title);
        Assert.Equal("Example article title", preview);
    }

    [Fact]
    public void Preview_PrefersPlainTextOverPublicUrl_WhenBothPresent()
    {
        var (title, preview) = TitleAndPreview.Derive(new[]
        {
            Text("explicit text"),
            Url("https://example.com"),
        });
        Assert.Equal("explicit text", title);
        Assert.Equal("explicit text", preview);
    }

    [Fact]
    public void Preview_PrefersPublicUrlOverChromiumSourceUrl()
    {
        // public.url is the cross-app convention; Chromium's source-url is a
        // browser-specific shape. When both happen to be present, the
        // standard wins.
        var (title, preview) = TitleAndPreview.Derive(new[]
        {
            ChromiumSourceUrl("https://chromium.example/x"),
            Url("https://canonical.example/y"),
        });
        Assert.Equal("https://canonical.example/y", title);
        Assert.Equal("https://canonical.example/y", preview);
    }

    [Fact]
    public void Preview_EmptyUrlBytes_FallsThrough()
    {
        // An empty (zero-byte) public.url must not surface as text_preview;
        // otherwise the candidate query's `LIKE 'http%'` filter would still
        // skip it but we'd be writing junk.
        var (title, preview) = TitleAndPreview.Derive(new[]
        {
            Url(""),
            UrlName("Real Name"),
        });
        Assert.Equal("Real Name", title);
        Assert.Equal("Real Name", preview);
    }
}
