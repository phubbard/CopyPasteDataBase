using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Ingest;
using Xunit;

namespace CpdbWin.Core.Tests;

public class KindClassifierTests
{
    private static CanonicalHash.Flavor F(string uti, byte[] data) => new(uti, data);
    private static CanonicalHash.Flavor F(string uti, string text) => new(uti, Encoding.UTF8.GetBytes(text));
    private static CanonicalHash.Flavor F(string uti, int byteCount) => new(uti, new byte[byteCount]);

    [Fact]
    public void Text_OnlyPlainText() =>
        Assert.Equal("text", KindClassifier.Classify(new[] { F("public.utf8-plain-text", "hi") }));

    [Fact]
    public void Link_UrlBeatsText() =>
        Assert.Equal("link", KindClassifier.Classify(new[]
        {
            F("public.utf8-plain-text", "https://example.com"),
            F("public.url", "https://example.com"),
        }));

    [Fact]
    public void Image_BeatsUrl_WhenSubstantive() =>
        // Chrome "Copy image" — the source URL rides along, but the image
        // bytes are the payload.
        Assert.Equal("image", KindClassifier.Classify(new[]
        {
            F("public.url", "https://example.com/cat.png"),
            F("public.png", KindClassifier.MinImageBytes),
        }));

    [Fact]
    public void Image_SubstantivePngCounts() =>
        Assert.Equal("image", KindClassifier.Classify(new[]
        {
            F("public.png", KindClassifier.MinImageBytes),
        }));

    [Fact]
    public void Image_SmallPngDoesNotCount() =>
        // Below the threshold, a "PNG" flavor is treated as breadcrumb
        // metadata rather than the primary content.
        Assert.NotEqual("image", KindClassifier.Classify(new[]
        {
            F("public.png", KindClassifier.MinImageBytes - 1),
            F("public.utf8-plain-text", "fallback"),
        }));

    [Fact]
    public void Image_BeatsFileUrl_WhenSubstantive() =>
        // CleanShot-style: writes both a file-url and inline PNG. The PNG
        // is the payload, the file-url is metadata.
        Assert.Equal("image", KindClassifier.Classify(new[]
        {
            F("public.file-url", "file:///tmp/x.png"),
            F("public.png", KindClassifier.MinImageBytes),
        }));

    [Fact]
    public void File_WhenOnlyFileUrl() =>
        Assert.Equal("file", KindClassifier.Classify(new[]
        {
            F("public.file-url", "file:///tmp/foo.txt"),
        }));

    [Fact]
    public void Color_WhenColorUti() =>
        Assert.Equal("color", KindClassifier.Classify(new[]
        {
            F("public.color", new byte[] { 1, 2, 3 }),
        }));

    [Fact]
    public void Other_WhenNothingMatches() =>
        Assert.Equal("other", KindClassifier.Classify(new[]
        {
            F("public.html", "<b>hi</b>"),
        }));

    [Fact]
    public void Empty_FlavorsClassifyAsOther() =>
        Assert.Equal("other", KindClassifier.Classify(Array.Empty<CanonicalHash.Flavor>()));

    // ─── URL-shaped plain text → link (parity w/ Mac v2.7.11) ────────────

    [Fact]
    public void Link_PlainTextHttpUrl_NoOtherFlavors()
    {
        // Windows clipboard often delivers "Copy address" out of Edge /
        // Chrome as plain text only — no public.url. Without this rule
        // those captures land as kind=text and skip the backfill loop.
        Assert.Equal("link", KindClassifier.Classify(new[]
        {
            F("public.utf8-plain-text", "https://www.youtube.com/watch?v=abc"),
        }));
    }

    [Fact]
    public void Link_PlainTextHttpsUrl_TrimmedWhitespaceOK() =>
        Assert.Equal("link", KindClassifier.Classify(new[]
        {
            F("public.utf8-plain-text", "  https://example.com/article\n"),
        }));

    [Fact]
    public void Text_PlainTextWithUrlInsideProse_StaysText() =>
        // "Look at https://example.com for context" — has whitespace so
        // it's a sentence containing a URL, not a URL itself.
        Assert.Equal("text", KindClassifier.Classify(new[]
        {
            F("public.utf8-plain-text", "Look at https://example.com for context"),
        }));

    [Fact]
    public void Text_PlainTextNonHttpScheme_StaysText() =>
        Assert.Equal("text", KindClassifier.Classify(new[]
        {
            F("public.utf8-plain-text", "ftp://files.example/x"),
        }));

    [Fact]
    public void Text_OversizedUrl_StaysText()
    {
        // 4 KB starts-with-http blob — would mis-classify without the
        // length cap. Cap is MaxUrlLength = 2048.
        var bigBlob = "https://example.com/" + new string('x', 4000);
        Assert.Equal("text", KindClassifier.Classify(new[]
        {
            F("public.utf8-plain-text", bigBlob),
        }));
    }

    [Theory]
    [InlineData("https://example.com",                 true)]
    [InlineData("http://example.com/path?q=1#frag",    true)]
    [InlineData("HTTPS://EXAMPLE.COM",                 true)]   // case-insensitive scheme
    [InlineData("",                                    false)]
    [InlineData("https://",                            false)]  // no host
    [InlineData("not a url at all",                    false)]
    [InlineData("file:///C:/local",                    false)]
    [InlineData("javascript:alert(1)",                 false)]
    public void LooksLikeUrl_MatchesContract(string s, bool expected) =>
        Assert.Equal(expected, KindClassifier.LooksLikeUrl(s));
}
