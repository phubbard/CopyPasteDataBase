using System.Text;
using System.Text.RegularExpressions;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// Pure HTML parsing helpers for the link-metadata fetcher. Lives in its
/// own type so the regex-heavy work is testable without HTTP plumbing.
///
/// Mirrors <c>Sources/CpdbShared/Analysis/LinkMetadataFetcher.swift</c>'s
/// <c>parseHTMLTitle</c> / <c>faviconURL</c> / <c>decodeHTMLEntities</c>
/// — naive regex by design. Real DOM parsing would catch malformed HTML
/// edge cases, but the cost is a parser dependency we'd rather avoid for
/// what's effectively a 95%-case heuristic. The bytes we don't catch
/// fall through to the favicon fallback or to <c>SettleLink(.., null)</c>
/// after retries, neither of which is the end of the world.
/// </summary>
public static class LinkMetadataParser
{
    /// <summary>Where the title came from. Useful for diagnostics + for
    /// the UI's match-source badge feature (Stage D).</summary>
    public enum TitleSource
    {
        None,
        OpenGraph,
        TwitterCard,
        TitleTag,
    }

    public readonly record struct ParseResult(
        string? Title,
        TitleSource Source,
        Uri? ThumbnailUrl);

    /// <summary>
    /// Parse a page's title and thumbnail URL from raw HTML bytes. Always
    /// returns a value — fields are nullable when nothing useful was
    /// found.
    ///
    /// Title resolution: <c>og:title</c> → <c>twitter:title</c> →
    /// <c>&lt;title&gt;</c>. Thumbnail resolution: <c>og:image</c> →
    /// <c>og:image:secure_url</c> → <c>og:image:url</c> →
    /// <c>twitter:image</c> → <c>twitter:image:src</c>.
    /// </summary>
    public static ParseResult Parse(ReadOnlySpan<byte> html)
    {
        var body = Decode(html);
        return Parse(body);
    }

    /// <summary>String overload for tests — skips the encoding-detection
    /// step.</summary>
    public static ParseResult Parse(string html)
    {
        string? title = null;
        var source = TitleSource.None;

        if (MatchMetaContent(html, OgTitlePattern) is { } og)
        {
            title = DecodeHtmlEntities(og);
            source = TitleSource.OpenGraph;
        }
        else if (MatchMetaContent(html, TwitterTitlePattern) is { } tw)
        {
            title = DecodeHtmlEntities(tw);
            source = TitleSource.TwitterCard;
        }
        else if (MatchTitleTag(html) is { } tag)
        {
            title = DecodeHtmlEntities(tag);
            source = TitleSource.TitleTag;
        }

        Uri? thumb = null;
        foreach (var pattern in ThumbnailPatterns)
        {
            if (MatchMetaContent(html, pattern) is { } raw &&
                Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var u) &&
                IsHttpScheme(u))
            {
                thumb = u;
                break;
            }
        }

        return new ParseResult(title, source, thumb);
    }

    /// <summary>
    /// Resolve a favicon URL for <paramref name="pageUrl"/> by inspecting
    /// the HTML for <c>&lt;link rel="…" href="…"&gt;</c> declarations.
    /// Order: <c>apple-touch-icon</c> (often 180×180 PNG, decent in our
    /// card preview) → <c>icon</c> / <c>shortcut icon</c> → conventional
    /// <c>/favicon.ico</c>. Returns null only if the page URL itself
    /// can't host a favicon (no host, non-http scheme).
    /// </summary>
    public static Uri? ResolveFavicon(ReadOnlySpan<byte> html, Uri pageUrl)
        => ResolveFavicon(Decode(html), pageUrl);

    /// <summary>String overload for tests.</summary>
    public static Uri? ResolveFavicon(string html, Uri pageUrl)
    {
        // Apple-touch-icon first. Its `apple-touch-icon-precomposed` and
        // size-suffixed variants (`apple-touch-icon-180x180.png`) all
        // start with "apple-touch-icon", so the prefix match is enough.
        var preferences = new[]
        {
            @"rel\s*=\s*[""']apple-touch-icon(?:[^""']*)?[""']",
            @"rel\s*=\s*[""'](?:shortcut\s+)?icon[""']",
        };
        foreach (var relPattern in preferences)
        {
            if (MatchLinkHref(html, relPattern) is { } href &&
                Uri.TryCreate(pageUrl, href, out var resolved) &&
                IsHttpScheme(resolved))
            {
                return resolved;
            }
        }

        // Conventional /favicon.ico fallback. Most sites have one even
        // when the HTML doesn't declare anything.
        if (pageUrl.Scheme is "http" or "https" && !string.IsNullOrEmpty(pageUrl.Host))
        {
            return new Uri($"{pageUrl.Scheme}://{pageUrl.Host}/favicon.ico");
        }
        return null;
    }

    /// <summary>
    /// Tiny entity decoder for the common cases we hit in &lt;title&gt;
    /// content (<c>&amp;amp;</c>, <c>&amp;quot;</c>, etc.). Anything
    /// weirder falls through unchanged. Full decoding would need
    /// HtmlAgilityPack or AngleSharp — overkill for link titles.
    /// </summary>
    public static string DecodeHtmlEntities(string s)
    {
        if (string.IsNullOrEmpty(s)) return s;
        var b = new StringBuilder(s.Length);
        b.Append(s);
        foreach (var (entity, replacement) in Entities)
        {
            b.Replace(entity, replacement);
        }
        return b.ToString();
    }

    // ─── Patterns ─────────────────────────────────────────────────────────

    private const string OgTitlePattern      = @"property\s*=\s*[""']og:title[""']";
    private const string TwitterTitlePattern = @"name\s*=\s*[""']twitter:title[""']";
    private static readonly string[] ThumbnailPatterns =
    {
        @"property\s*=\s*[""']og:image[""']",
        @"property\s*=\s*[""']og:image:secure_url[""']",
        @"property\s*=\s*[""']og:image:url[""']",
        @"name\s*=\s*[""']twitter:image[""']",
        @"name\s*=\s*[""']twitter:image:src[""']",
    };

    private static readonly (string Entity, string Replacement)[] Entities =
    {
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&nbsp;", " "),
        ("&#x27;", "'"),
        ("&#34;", "\""),
    };

    // ─── Regex helpers ────────────────────────────────────────────────────

    /// <summary>
    /// Match <c>&lt;meta {namePattern} content="…"&gt;</c>, tolerating the
    /// attributes appearing in either order.
    /// </summary>
    private static string? MatchMetaContent(string html, string namePattern)
    {
        // Run both attribute orders; first non-empty match wins.
        var orderA = $@"<meta\s[^>]*{namePattern}[^>]*content\s*=\s*[""']([^""']*)[""'][^>]*>";
        var orderB = $@"<meta\s[^>]*content\s*=\s*[""']([^""']*)[""'][^>]*{namePattern}[^>]*>";
        foreach (var pattern in new[] { orderA, orderB })
        {
            try
            {
                var m = Regex.Match(html, pattern,
                    RegexOptions.IgnoreCase | RegexOptions.Singleline,
                    TimeSpan.FromSeconds(1));
                if (m.Success && m.Groups.Count >= 2)
                {
                    var content = m.Groups[1].Value.Trim();
                    if (content.Length > 0) return content;
                }
            }
            catch (RegexMatchTimeoutException)
            {
                // Pathologically large or malicious HTML. Bail this
                // pattern; the next one or the outer caller can decide.
            }
        }
        return null;
    }

    private static string? MatchTitleTag(string html)
    {
        try
        {
            var m = Regex.Match(html, "<title[^>]*>(.*?)</title>",
                RegexOptions.IgnoreCase | RegexOptions.Singleline,
                TimeSpan.FromSeconds(1));
            if (m.Success && m.Groups.Count >= 2)
            {
                var content = m.Groups[1].Value.Trim();
                return content.Length > 0 ? content : null;
            }
        }
        catch (RegexMatchTimeoutException) { /* fall through */ }
        return null;
    }

    /// <summary>
    /// Match <c>&lt;link {relPattern} href="…"&gt;</c>. Same attribute-
    /// order tolerance as <see cref="MatchMetaContent"/>.
    /// </summary>
    private static string? MatchLinkHref(string html, string relPattern)
    {
        var orderA = $@"<link\s[^>]*{relPattern}[^>]*href\s*=\s*[""']([^""']*)[""'][^>]*>";
        var orderB = $@"<link\s[^>]*href\s*=\s*[""']([^""']*)[""'][^>]*{relPattern}[^>]*>";
        foreach (var pattern in new[] { orderA, orderB })
        {
            try
            {
                var m = Regex.Match(html, pattern,
                    RegexOptions.IgnoreCase | RegexOptions.Singleline,
                    TimeSpan.FromSeconds(1));
                if (m.Success && m.Groups.Count >= 2)
                {
                    var href = m.Groups[1].Value.Trim();
                    if (href.Length > 0) return href;
                }
            }
            catch (RegexMatchTimeoutException) { /* fall through */ }
        }
        return null;
    }

    // ─── Encoding / utility ──────────────────────────────────────────────

    /// <summary>
    /// Decode HTML bytes to a string. UTF-8 first; if that fails (mojibake
    /// or invalid sequences), Latin-1 — never fails, every byte is a
    /// valid code point. Picks up enough of the markup that the regex
    /// patterns still hit, since meta tags + titles are typically ASCII.
    /// </summary>
    private static string Decode(ReadOnlySpan<byte> bytes)
    {
        try
        {
            return Encoding.UTF8.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return Encoding.Latin1.GetString(bytes);
        }
    }

    private static bool IsHttpScheme(Uri u) =>
        u.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase) ||
        u.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase);
}
