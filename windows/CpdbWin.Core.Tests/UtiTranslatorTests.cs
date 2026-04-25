using System.Text;
using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

public class UtiTranslatorTests
{
    [Fact]
    public void UnicodeText_StripsNullTerminator_AndReEncodesAsUtf8()
    {
        var raw = Encoding.Unicode.GetBytes("hello\0");
        var t = UtiTranslator.Translate(UtiTranslator.CF_UNICODETEXT, null, raw);

        Assert.NotNull(t);
        Assert.Equal("public.utf8-plain-text", t!.Value.Uti);
        Assert.Equal(Encoding.UTF8.GetBytes("hello"), t.Value.Data);
    }

    [Fact]
    public void UnicodeText_HandlesNonAsciiAndCjk()
    {
        var raw = Encoding.Unicode.GetBytes("héllo 世界\0");
        var t = UtiTranslator.Translate(UtiTranslator.CF_UNICODETEXT, null, raw);

        Assert.Equal(Encoding.UTF8.GetBytes("héllo 世界"), t!.Value.Data);
    }

    [Fact]
    public void UnicodeText_ToleratesMissingTerminator()
    {
        var raw = Encoding.Unicode.GetBytes("abc");
        var t = UtiTranslator.Translate(UtiTranslator.CF_UNICODETEXT, null, raw);

        Assert.Equal(Encoding.UTF8.GetBytes("abc"), t!.Value.Data);
    }

    [Fact]
    public void UnicodeText_ToleratesMultipleTerminators()
    {
        var raw = Encoding.Unicode.GetBytes("abc\0\0\0");
        var t = UtiTranslator.Translate(UtiTranslator.CF_UNICODETEXT, null, raw);

        Assert.Equal(Encoding.UTF8.GetBytes("abc"), t!.Value.Data);
    }

    [Fact]
    public void Png_PassesBytesThrough()
    {
        var raw = new byte[] { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00 };
        var t = UtiTranslator.Translate(0xC123, "PNG", raw);

        Assert.Equal("public.png", t!.Value.Uti);
        Assert.Equal(raw, t.Value.Data);
    }

    [Fact]
    public void JfifAndJpegBothMapToPublicJpeg()
    {
        var raw = new byte[] { 0xff, 0xd8, 0xff };
        var jfif = UtiTranslator.Translate(0xC456, "JFIF", raw);
        var jpeg = UtiTranslator.Translate(0xC457, "JPEG", raw);

        Assert.Equal("public.jpeg", jfif!.Value.Uti);
        Assert.Equal("public.jpeg", jpeg!.Value.Uti);
        Assert.Equal(raw, jfif.Value.Data);
    }

    [Fact]
    public void UrlW_StripsTerminator_AndDecodes()
    {
        var raw = Encoding.Unicode.GetBytes("https://example.com/\0");
        var t = UtiTranslator.Translate(0xC789, "UniformResourceLocatorW", raw);

        Assert.Equal("public.url", t!.Value.Uti);
        Assert.Equal(Encoding.UTF8.GetBytes("https://example.com/"), t.Value.Data);
    }

    [Fact]
    public void UnsupportedFormatsReturnNull()
    {
        Assert.Null(UtiTranslator.Translate(UtiTranslator.CF_TEXT,  null, new byte[] { 0 }));
        Assert.Null(UtiTranslator.Translate(UtiTranslator.CF_HDROP, null, new byte[] { 0 }));
        Assert.Null(UtiTranslator.Translate(UtiTranslator.CF_DIB,   null, new byte[] { 0 }));
        Assert.Null(UtiTranslator.Translate(UtiTranslator.CF_DIBV5, null, new byte[] { 0 }));
        Assert.Null(UtiTranslator.Translate(UtiTranslator.CF_BITMAP, null, new byte[] { 0 }));
        Assert.Null(UtiTranslator.Translate(0xC999, "HTML Format", new byte[] { 0 }));
        Assert.Null(UtiTranslator.Translate(0xC999, "Some other thing", new byte[] { 0 }));
        Assert.Null(UtiTranslator.Translate(0xC999, null, new byte[] { 0 }));
    }
}
