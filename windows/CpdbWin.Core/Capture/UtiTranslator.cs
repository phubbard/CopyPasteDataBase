using System.Text;

namespace CpdbWin.Core.Capture;

/// <summary>
/// Translates one Windows clipboard format + raw bytes into a (uti, bytes)
/// pair for canonical hashing and storage. The mapping comes from
/// docs/schema.md §entry_flavors. v1 supports the formats below; CF_TEXT,
/// CF_HDROP, CF_DIB*, and CF_HTML defer until we have an image-encode
/// pipeline / file-list parser / CF_HTML header parser respectively.
/// </summary>
public static class UtiTranslator
{
    public const uint CF_TEXT        = 1;
    public const uint CF_BITMAP      = 2;
    public const uint CF_DIB         = 8;
    public const uint CF_UNICODETEXT = 13;
    public const uint CF_HDROP       = 15;
    public const uint CF_DIBV5       = 17;

    public readonly record struct Translation(string Uti, byte[] Data);

    /// <summary>
    /// Returns null when the format is intentionally unsupported in v1, so
    /// the caller drops it. The (formatId, formatName) split exists because
    /// standard CF_* IDs are well-known constants while registered formats
    /// (PNG, JFIF, …) get session-local IDs in the 0xC000–0xFFFF range and
    /// must be matched by name via GetClipboardFormatName.
    /// </summary>
    public static Translation? Translate(uint formatId, string? formatName, ReadOnlySpan<byte> raw)
    {
        if (formatId == CF_UNICODETEXT)
            return new Translation("public.utf8-plain-text", DecodeUtf16LeWithNullTerm(raw));

        if (formatName is null) return null;

        return formatName switch
        {
            "PNG"                     => new Translation("public.png",  raw.ToArray()),
            "JFIF" or "JPEG"          => new Translation("public.jpeg", raw.ToArray()),
            "UniformResourceLocatorW" => new Translation("public.url",  DecodeUtf16LeWithNullTerm(raw)),
            "HTML Format"             => CfHtmlParser.ExtractFragment(raw) is { } html
                                         ? new Translation("public.html", html)
                                         : null,
            _                         => null,
        };
    }

    /// <summary>
    /// Multi-flavor entry point used by the capture pipeline. Currently only
    /// CF_HDROP can produce more than one translation per source format
    /// (one <c>public.file-url</c> per path); everything else falls through
    /// to the single-shot <see cref="Translate"/>.
    /// </summary>
    public static IReadOnlyList<Translation> TranslateMulti(uint formatId, string? formatName, ReadOnlySpan<byte> raw)
    {
        if (formatId == CF_HDROP)
        {
            var paths = HdropParser.ParsePaths(raw);
            if (paths.Count == 0) return Array.Empty<Translation>();
            var result = new List<Translation>(paths.Count);
            foreach (var path in paths)
            {
                var url = HdropParser.ToFileUrl(path);
                if (url is null) continue;
                result.Add(new Translation("public.file-url",
                    System.Text.Encoding.UTF8.GetBytes(url)));
            }
            return result;
        }

        var single = Translate(formatId, formatName, raw);
        return single is null ? Array.Empty<Translation>() : new[] { single.Value };
    }

    /// CF_UNICODETEXT and UniformResourceLocatorW are UTF-16 LE with one or
    /// more trailing 00 00 code units. Strip the terminator(s) and round
    /// through UTF-8 so the canonical-hash bytes match what macOS stores
    /// for public.utf8-plain-text / public.url.
    private static byte[] DecodeUtf16LeWithNullTerm(ReadOnlySpan<byte> raw)
    {
        int len = raw.Length;
        while (len >= 2 && raw[len - 1] == 0 && raw[len - 2] == 0)
            len -= 2;
        len &= ~1;
        return Encoding.UTF8.GetBytes(Encoding.Unicode.GetString(raw[..len]));
    }
}
