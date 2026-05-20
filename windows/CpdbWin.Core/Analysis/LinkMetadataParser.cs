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
    /// <para>
    /// Default title resolution: <c>og:title</c> → <c>twitter:title</c>
    /// → <c>&lt;title&gt;</c>. The og:title-first order matches the
    /// macOS contract and produces clean social-card-friendly titles
    /// for most sites.
    /// </para>
    /// <para>
    /// <b>WordPress exception:</b> WP themes consistently put the rich
    /// <c>"Post Title – Site Tagline"</c> form in <c>&lt;title&gt;</c>
    /// while <c>og:title</c> is the bare post slug — picking og:title
    /// first there loses the tagline. Since WordPress backs ~40-60%
    /// of public sites, the parser detects the
    /// <c>&lt;meta name="generator" content="WordPress…"&gt;</c>
    /// fingerprint (covers both WordPress.com and self-hosted) and
    /// reverses the order to <c>&lt;title&gt;</c> → <c>og:title</c> →
    /// <c>twitter:title</c>.
    /// </para>
    /// <para>
    /// Thumbnail resolution is unchanged: <c>og:image</c> →
    /// <c>og:image:secure_url</c> → <c>og:image:url</c> →
    /// <c>twitter:image</c> → <c>twitter:image:src</c>.
    /// </para>
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

        // WordPress-aware ordering: themes consistently put the rich
        // "Title – Tagline" form in <title> while og:title is the bare
        // slug. Detect via the standard generator meta tag and reverse
        // the preference list.
        bool isWordPress = LooksLikeWordPress(html);

        if (isWordPress && MatchTitleTag(html) is { } wpTag &&
            !string.IsNullOrWhiteSpace(wpTag))
        {
            title = DecodeHtmlEntities(wpTag);
            source = TitleSource.TitleTag;
        }
        else if (MatchMetaContent(html, OgTitlePattern) is { } og)
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

    // Matches `<meta name="generator" content="WordPress…">` in either
    // attribute order — both WordPress.com (content="WordPress.com")
    // and self-hosted WP (content="WordPress 6.x.x") emit this. A WP
    // theme can in theory strip the tag, but the vast majority leave
    // it in place and that's good enough — when absent, the parser
    // simply falls through to the default og:title-first order.
    private static readonly Regex WordPressGeneratorRegex = new(
        """<meta[^>]+(?:name\s*=\s*["']generator["'][^>]+content\s*=\s*["']\s*WordPress|content\s*=\s*["']\s*WordPress[^"']*["'][^>]+name\s*=\s*["']generator["'])""",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// <summary>
    /// True when <paramref name="html"/> looks like a WordPress page
    /// via its standard generator meta tag — covers both
    /// WordPress.com (<c>content="WordPress.com"</c>) and self-hosted
    /// installs (<c>content="WordPress &lt;version&gt;"</c>) in either
    /// attribute order. Used by <see cref="Parse(string)"/> to flip the
    /// title-source preference (rich <c>&lt;title&gt;</c> over short
    /// <c>og:title</c>); exposed publicly so the link fetcher / CLI
    /// can diagnose WP detection without re-parsing.
    /// </summary>
    public static bool LooksLikeWordPress(string html) =>
        WordPressGeneratorRegex.IsMatch(html);
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
        // Common numeric entities for typographic punctuation that
        // WordPress + Markdown-flavoured sites emit literally in
        // <title>. Without these the title shows as e.g.
        // "ultracrepidarian &#8211; ultracrepidarian: …".
        ("&#8211;", "–"),  // en dash –
        ("&#8212;", "—"),  // em dash —
        ("&#8216;", "‘"),  // left single quote ‘
        ("&#8217;", "’"),  // right single quote ’
        ("&#8220;", "“"),  // left double quote “
        ("&#8221;", "”"),  // right double quote ”
        ("&#8230;", "…"),  // ellipsis …
        ("&ndash;", "–"),
        ("&mdash;", "—"),
        ("&lsquo;", "‘"),
        ("&rsquo;", "’"),
        ("&ldquo;", "“"),
        ("&rdquo;", "”"),
        ("&hellip;", "…"),
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
