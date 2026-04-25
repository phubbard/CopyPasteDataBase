namespace CpdbWin.Core.Capture;

/// <summary>
/// Extracts the HTML payload from a Windows <c>CF_HTML</c> clipboard
/// blob. The format wraps the actual HTML in an ASCII header block of
/// the form
/// <code>
/// Version:0.9
/// StartHTML:00000180
/// EndHTML:00001234
/// StartFragment:00000200
/// EndFragment:00001220
/// SourceURL:https://example.com/
/// &lt;html&gt;…
/// </code>
/// where the offset values point into the CF_HTML byte stream itself
/// (not into the HTML alone). Browsers populate <c>StartFragment</c> /
/// <c>EndFragment</c> with the user-selected slice — that's the chunk
/// users mean when they "copy from a webpage", so we prefer that over
/// the wider <c>StartHTML</c>/<c>EndHTML</c> range.
/// </summary>
public static class CfHtmlParser
{
    /// <summary>
    /// Returns the HTML fragment bytes, or null if the headers are
    /// unparseable / point outside the buffer. Headers are scanned up to
    /// 4 KB; real CF_HTML headers are well under 500 bytes.
    /// </summary>
    public static byte[]? ExtractFragment(ReadOnlySpan<byte> raw)
    {
        int? startFragment = null, endFragment = null;
        int? startHtml = null, endHtml = null;

        int headerScanLimit = Math.Min(raw.Length, 4096);
        int p = 0;
        while (p < headerScanLimit)
        {
            // The first '<' character at line start marks the end of the
            // ASCII header block (the HTML body begins).
            if (raw[p] == '<') break;

            int lineEnd = p;
            while (lineEnd < headerScanLimit && raw[lineEnd] != '\n') lineEnd++;
            var line = raw[p..lineEnd];
            if (line.Length > 0 && line[^1] == '\r') line = line[..^1];

            if (TryParseHeader(line, "StartFragment:"u8, out var sf)) startFragment = sf;
            else if (TryParseHeader(line, "EndFragment:"u8,   out var ef)) endFragment   = ef;
            else if (TryParseHeader(line, "StartHTML:"u8,     out var sh)) startHtml     = sh;
            else if (TryParseHeader(line, "EndHTML:"u8,       out var eh)) endHtml       = eh;

            p = lineEnd + 1;
        }

        // Prefer the user-selected fragment; fall back to the full HTML range.
        int? sliceStart = startFragment ?? startHtml;
        int? sliceEnd   = endFragment   ?? endHtml;
        if (sliceStart is null || sliceEnd is null) return null;
        if (sliceStart < 0 || sliceEnd <= sliceStart || sliceEnd > raw.Length) return null;

        return raw[sliceStart.Value..sliceEnd.Value].ToArray();
    }

    private static bool TryParseHeader(ReadOnlySpan<byte> line, ReadOnlySpan<byte> prefix, out int value)
    {
        value = 0;
        if (!line.StartsWith(prefix)) return false;

        var rest = line[prefix.Length..];
        int v = 0;
        bool sawDigit = false;
        foreach (var b in rest)
        {
            if (b == ' ' || b == '\t') { if (sawDigit) break; else continue; }
            if (b < '0' || b > '9') return false;
            v = v * 10 + (b - '0');
            sawDigit = true;
        }
        if (!sawDigit) return false;
        value = v;
        return true;
    }
}
