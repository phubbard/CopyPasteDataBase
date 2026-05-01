using CpdbWin.Core.Analysis;
using Xunit;

namespace CpdbWin.Core.Tests;

public class LinkMetadataParserTests
{
    // ─── Title extraction ────────────────────────────────────────────────

    [Fact]
    public void Parse_OgTitle_PreferredOverTwitterAndTitle()
    {
        const string html = """
            <html><head>
              <meta property="og:title" content="OG Wins">
              <meta name="twitter:title" content="TW Loses">
              <title>tag-loses</title>
            </head></html>
            """;
        var r = LinkMetadataParser.Parse(html);
        Assert.Equal("OG Wins", r.Title);
        Assert.Equal(LinkMetadataParser.TitleSource.OpenGraph, r.Source);
    }

    [Fact]
    public void Parse_TwitterTitle_FallsBackWhenNoOg()
    {
        const string html = """
            <html><head>
              <meta name="twitter:title" content="From Twitter">
              <title>tag-loses</title>
            </head></html>
            """;
        var r = LinkMetadataParser.Parse(html);
        Assert.Equal("From Twitter", r.Title);
        Assert.Equal(LinkMetadataParser.TitleSource.TwitterCard, r.Source);
    }

    [Fact]
    public void Parse_TitleTag_FallsBackWhenNoMetaTags()
    {
        const string html = """
            <html><head><title>just-a-tag</title></head></html>
            """;
        var r = LinkMetadataParser.Parse(html);
        Assert.Equal("just-a-tag", r.Title);
        Assert.Equal(LinkMetadataParser.TitleSource.TitleTag, r.Source);
    }

    [Fact]
    public void Parse_NoSignals_ReturnsNullTitleAndNoneSource()
    {
        const string html = "<html><body>no head</body></html>";
        var r = LinkMetadataParser.Parse(html);
        Assert.Null(r.Title);
        Assert.Equal(LinkMetadataParser.TitleSource.None, r.Source);
    }

    [Fact]
    public void Parse_AttributesInReverseOrder_StillMatch()
    {
        // content="…" first, then property="og:title" — supported by the
        // dual-order regex so we don't lose hits on e.g. WordPress
        // themes that emit attrs in a non-canonical order.
        const string html = """
            <meta content="Reversed Order" property="og:title">
            """;
        var r = LinkMetadataParser.Parse(html);
        Assert.Equal("Reversed Order", r.Title);
    }

    [Fact]
    public void Parse_TitleEntitiesDecoded()
    {
        const string html = """
            <title>Tom &amp; Jerry &#39;rocks&#39;</title>
            """;
        var r = LinkMetadataParser.Parse(html);
        Assert.Equal("Tom & Jerry 'rocks'", r.Title);
    }

    [Fact]
    public void Parse_EmptyTitleContent_FallsThroughToNextSource()
    {
        // Empty content="" should not count as a hit. Twitter title
        // should win.
        const string html = """
            <meta property="og:title" content="">
            <meta name="twitter:title" content="real title">
            """;
        var r = LinkMetadataParser.Parse(html);
        Assert.Equal("real title", r.Title);
        Assert.Equal(LinkMetadataParser.TitleSource.TwitterCard, r.Source);
    }

    // ─── Thumbnail extraction ────────────────────────────────────────────

    [Fact]
    public void Parse_OgImage_PrioritizedOverTwitter()
    {
        const string html = """
            <meta property="og:image" content="https://cdn.example/og.jpg">
            <meta name="twitter:image" content="https://cdn.example/tw.jpg">
            """;
        var r = LinkMetadataParser.Parse(html);
        Assert.Equal(new Uri("https://cdn.example/og.jpg"), r.ThumbnailUrl);
    }

    [Fact]
    public void Parse_OgImageSecureUrl_FallsBackWhenNoBareOgImage()
    {
        const string html = """
            <meta property="og:image:secure_url" content="https://cdn.example/secure.jpg">
            <meta name="twitter:image" content="https://cdn.example/tw.jpg">
            """;
        var r = LinkMetadataParser.Parse(html);
        Assert.Equal(new Uri("https://cdn.example/secure.jpg"), r.ThumbnailUrl);
    }

    [Fact]
    public void Parse_TwitterImageSrc_FallsBackWhenNoOgFamily()
    {
        const string html = """
            <meta name="twitter:image:src" content="https://cdn.example/twsrc.jpg">
            """;
        var r = LinkMetadataParser.Parse(html);
        Assert.Equal(new Uri("https://cdn.example/twsrc.jpg"), r.ThumbnailUrl);
    }

    [Fact]
    public void Parse_NonHttpThumbnailUrl_Skipped()
    {
        // ftp:// or data: URLs aren't useful for our card preview and
        // would crash the downloader. Filter at parse time.
        const string html = """
            <meta property="og:image" content="ftp://files.example/x.jpg">
            """;
        var r = LinkMetadataParser.Parse(html);
        Assert.Null(r.ThumbnailUrl);
    }

    // ─── Favicon resolution ──────────────────────────────────────────────

    [Fact]
    public void ResolveFavicon_AppleTouchIcon_PreferredOverIcon()
    {
        const string html = """
            <link rel="icon" href="/favicon-16.png">
            <link rel="apple-touch-icon" href="/apple-touch-icon.png">
            """;
        var fav = LinkMetadataParser.ResolveFavicon(html, new Uri("https://example.com/page"));
        Assert.Equal(new Uri("https://example.com/apple-touch-icon.png"), fav);
    }

    [Fact]
    public void ResolveFavicon_AppleTouchIconWithSizeSuffix_StillMatched()
    {
        // "apple-touch-icon-precomposed" and "apple-touch-icon-180x180" both
        // start with the prefix — our regex tolerates the extra characters.
        const string html = """
            <link rel="apple-touch-icon-precomposed" href="/precomposed.png">
            """;
        var fav = LinkMetadataParser.ResolveFavicon(html, new Uri("https://example.com"));
        Assert.Equal(new Uri("https://example.com/precomposed.png"), fav);
    }

    [Fact]
    public void ResolveFavicon_ShortcutIcon_AcceptedAsIcon()
    {
        const string html = """<link rel="shortcut icon" href="/icon.ico">""";
        var fav = LinkMetadataParser.ResolveFavicon(html, new Uri("https://example.com"));
        Assert.Equal(new Uri("https://example.com/icon.ico"), fav);
    }

    [Fact]
    public void ResolveFavicon_NoLinkTags_FallsBackToFaviconIco()
    {
        const string html = "<html><body>no head</body></html>";
        var fav = LinkMetadataParser.ResolveFavicon(html, new Uri("https://example.com/some/path"));
        Assert.Equal(new Uri("https://example.com/favicon.ico"), fav);
    }

    [Fact]
    public void ResolveFavicon_AbsoluteHrefPreserved()
    {
        const string html = """
            <link rel="icon" href="https://cdn.example/favicon.png">
            """;
        var fav = LinkMetadataParser.ResolveFavicon(html, new Uri("https://example.com/page"));
        Assert.Equal(new Uri("https://cdn.example/favicon.png"), fav);
    }

    [Fact]
    public void ResolveFavicon_RelativeHrefResolvedAgainstPage()
    {
        const string html = """
            <link rel="icon" href="../static/icon.png">
            """;
        var fav = LinkMetadataParser.ResolveFavicon(html, new Uri("https://example.com/blog/post"));
        Assert.Equal(new Uri("https://example.com/static/icon.png"), fav);
    }

    // ─── Entity decoder ──────────────────────────────────────────────────

    [Theory]
    [InlineData("Tom &amp; Jerry",       "Tom & Jerry")]
    [InlineData("&lt;hi&gt;",            "<hi>")]
    [InlineData("Don&#39;t panic",       "Don't panic")]
    [InlineData("&quot;quoted&quot;",    "\"quoted\"")]
    [InlineData("non-break&nbsp;space",  "non-break space")]
    [InlineData("plain",                 "plain")]
    [InlineData("",                      "")]
    public void DecodeHtmlEntities_HandlesCommonCases(string input, string expected)
    {
        Assert.Equal(expected, LinkMetadataParser.DecodeHtmlEntities(input));
    }

    [Fact]
    public void DecodeHtmlEntities_LeavesUnknownEntitiesUntouched()
    {
        // Numeric entities outside the small lookup pass through literally.
        // Acceptable: link titles overwhelmingly hit the ASCII subset, and
        // a stray "&hellip;" rendering as "&hellip;" is just less pretty,
        // not broken.
        Assert.Equal("a&hellip;b", LinkMetadataParser.DecodeHtmlEntities("a&hellip;b"));
    }
}
