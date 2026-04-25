using System.Text;
using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

public class UtiTranslatorMultiTests
{
    private static byte[] BuildDropfiles(params string[] paths)
    {
        using var ms = new MemoryStream();
        var w = new BinaryWriter(ms);
        w.Write((int)20);
        w.Write((int)0); w.Write((int)0);
        w.Write((int)0);
        w.Write((int)1); // fWide
        foreach (var p in paths)
        {
            w.Write(Encoding.Unicode.GetBytes(p));
            w.Write((short)0);
        }
        w.Write((short)0);
        return ms.ToArray();
    }

    [Fact]
    public void TranslateMulti_Hdrop_EmitsOneFileUrlPerPath()
    {
        var raw = BuildDropfiles(@"C:\a.txt", @"C:\b.txt");
        var translations = UtiTranslator.TranslateMulti(UtiTranslator.CF_HDROP, null, raw);

        Assert.Equal(2, translations.Count);
        Assert.All(translations, t => Assert.Equal("public.file-url", t.Uti));
        Assert.Equal("file:///C:/a.txt", Encoding.UTF8.GetString(translations[0].Data));
        Assert.Equal("file:///C:/b.txt", Encoding.UTF8.GetString(translations[1].Data));
    }

    [Fact]
    public void TranslateMulti_Hdrop_EmptyRaw_ReturnsEmpty()
    {
        var translations = UtiTranslator.TranslateMulti(UtiTranslator.CF_HDROP, null, new byte[0]);
        Assert.Empty(translations);
    }

    [Fact]
    public void TranslateMulti_NonHdrop_DelegatesToSingleTranslate()
    {
        var raw = Encoding.Unicode.GetBytes("hello\0");
        var translations = UtiTranslator.TranslateMulti(UtiTranslator.CF_UNICODETEXT, null, raw);
        Assert.Single(translations);
        Assert.Equal("public.utf8-plain-text", translations[0].Uti);
    }

    [Fact]
    public void TranslateMulti_UnknownFormat_ReturnsEmpty()
    {
        Assert.Empty(UtiTranslator.TranslateMulti(0xC999, "Unknown", new byte[] { 1 }));
    }

    [Fact]
    public void Translate_HtmlFormat_ExtractsFragment()
    {
        // Build a minimal CF_HTML byte stream and check it round-trips
        // through Translate as public.html with the fragment payload.
        const string headerFormat =
            "Version:0.9\r\n" +
            "StartFragment:{0:D8}\r\n" +
            "EndFragment:{1:D8}\r\n";
        const string fragment = "<b>hi</b>";
        int headerLen = string.Format(headerFormat, 0, 0).Length;
        int sf = headerLen;
        int ef = sf + fragment.Length;
        var raw = Encoding.ASCII.GetBytes(string.Format(headerFormat, sf, ef) + fragment);

        var t = UtiTranslator.Translate(0xC123, "HTML Format", raw);
        Assert.NotNull(t);
        Assert.Equal("public.html", t!.Value.Uti);
        Assert.Equal(fragment, Encoding.UTF8.GetString(t.Value.Data));
    }

    [Fact]
    public void Translate_HtmlFormat_MalformedReturnsNull()
    {
        var raw = Encoding.ASCII.GetBytes("Version:0.9\r\nNo fragments here\r\n<html/>");
        Assert.Null(UtiTranslator.Translate(0xC123, "HTML Format", raw));
    }
}
