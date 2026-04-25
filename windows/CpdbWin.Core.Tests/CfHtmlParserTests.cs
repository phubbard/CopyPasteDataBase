using System.Text;
using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

public class CfHtmlParserTests
{
    /// <summary>
    /// Build a synthetic CF_HTML payload whose header offsets point at the
    /// fragment delimiters in the body. Header length is constant because
    /// {N:D8} always expands to 8 chars, so we can compute offsets in one
    /// pass.
    /// </summary>
    private static byte[] BuildCfHtml(string preamble, string fragment, string suffix)
    {
        const string headerFormat =
            "Version:0.9\r\n" +
            "StartHTML:{0:D8}\r\n" +
            "EndHTML:{1:D8}\r\n" +
            "StartFragment:{2:D8}\r\n" +
            "EndFragment:{3:D8}\r\n";

        var html = preamble + "<!--StartFragment-->" + fragment + "<!--EndFragment-->" + suffix;
        int headerLen = string.Format(headerFormat, 0, 0, 0, 0).Length;

        int htmlStart = headerLen;
        int htmlEnd   = htmlStart + html.Length;
        int fragStart = htmlStart + (preamble + "<!--StartFragment-->").Length;
        int fragEnd   = fragStart + fragment.Length;

        var header = string.Format(headerFormat, htmlStart, htmlEnd, fragStart, fragEnd);
        return Encoding.ASCII.GetBytes(header + html);
    }

    [Fact]
    public void ExtractFragment_ReturnsExactlyTheFragmentBytes()
    {
        var raw = BuildCfHtml("<html><body>", "<b>hello</b>", "</body></html>");
        var html = CfHtmlParser.ExtractFragment(raw);
        Assert.Equal("<b>hello</b>", Encoding.UTF8.GetString(html!));
    }

    [Fact]
    public void ExtractFragment_HandlesMultilineHtml()
    {
        var raw = BuildCfHtml(
            "<html>\n<body>\n",
            "<p>line one</p>\n<p>line two</p>",
            "\n</body>\n</html>");
        var html = CfHtmlParser.ExtractFragment(raw);
        Assert.Equal("<p>line one</p>\n<p>line two</p>", Encoding.UTF8.GetString(html!));
    }

    [Fact]
    public void ExtractFragment_FallsBackToStartHtmlEndHtml_WhenFragmentMissing()
    {
        var html = "<html><body><b>hi</b></body></html>";
        const string headerFormat =
            "Version:0.9\r\n" +
            "StartHTML:{0:D8}\r\n" +
            "EndHTML:{1:D8}\r\n";
        int headerLen = string.Format(headerFormat, 0, 0).Length;
        int sH = headerLen;
        int eH = sH + html.Length;
        var header = string.Format(headerFormat, sH, eH);
        var raw = Encoding.ASCII.GetBytes(header + html);

        var slice = CfHtmlParser.ExtractFragment(raw);
        Assert.Equal(html, Encoding.UTF8.GetString(slice!));
    }

    [Fact]
    public void ExtractFragment_ReturnsNull_WhenAllOffsetsMissing()
    {
        var raw = Encoding.ASCII.GetBytes("Version:0.9\r\nSomething:else\r\n<html></html>");
        Assert.Null(CfHtmlParser.ExtractFragment(raw));
    }

    [Fact]
    public void ExtractFragment_ReturnsNull_WhenOffsetsOutOfRange()
    {
        var raw = Encoding.ASCII.GetBytes(
            "Version:0.9\r\nStartFragment:00000050\r\nEndFragment:00009999\r\n<html></html>");
        Assert.Null(CfHtmlParser.ExtractFragment(raw));
    }

    [Fact]
    public void ExtractFragment_ReturnsNull_WhenEndBeforeStart()
    {
        var raw = Encoding.ASCII.GetBytes(
            "Version:0.9\r\nStartFragment:00000050\r\nEndFragment:00000040\r\n<html></html>");
        Assert.Null(CfHtmlParser.ExtractFragment(raw));
    }

    [Fact]
    public void ExtractFragment_ToleratesLfOnlyLineEndings()
    {
        // Some sources emit LF instead of CRLF — the parser should still
        // recognise the headers.
        var html = "<b>x</b>";
        const string fmt = "Version:0.9\nStartFragment:{0:D8}\nEndFragment:{1:D8}\n";
        int hdrLen = string.Format(fmt, 0, 0).Length;
        int sf = hdrLen;
        int ef = sf + html.Length;
        var raw = Encoding.ASCII.GetBytes(string.Format(fmt, sf, ef) + html);
        Assert.Equal(html, Encoding.UTF8.GetString(CfHtmlParser.ExtractFragment(raw)!));
    }
}
