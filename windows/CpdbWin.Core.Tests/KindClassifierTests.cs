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
}
