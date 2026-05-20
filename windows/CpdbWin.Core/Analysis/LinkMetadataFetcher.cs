using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;
using CpdbWin.Core.Store;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// Background-fetches a human-readable title (and best-effort thumbnail
/// URL) for a captured URL. Mirrors
/// <c>Sources/CpdbShared/Analysis/LinkMetadataFetcher.swift</c>:
///
/// <list type="number">
/// <item><b>YouTube oEmbed</b> for <c>*.youtube.com</c> / <c>youtu.be</c>:
///       hits <c>https://www.youtube.com/oembed?url=…&amp;format=json</c>.
///       Public endpoint, no auth, returns clean JSON with title +
///       thumbnail URL.</item>
/// <item><b>Generic HTML scrape</b> for everything else: GET the page,
///       cap at 256 KB, parse <c>og:title</c> → <c>twitter:title</c> →
///       <c>&lt;title&gt;</c>; same priority for thumbnail meta tags.
///       Extra fallbacks for thumbnail: Wikipedia REST API summary
///       endpoint for <c>*.wikipedia.org</c> URLs lacking og:image, then
///       the page's favicon (apple-touch-icon → icon → /favicon.ico).</item>
/// </list>
///
/// The returned <see cref="FetchOutcome"/> is the dispatch shape the
/// backfill loop (Stage C) consumes: <see cref="FetchOutcome.Success"/>
/// → <see cref="EntryRepository.SettleLink"/> with the title (or null if
/// the page had none); <see cref="FetchOutcome.Permanent"/> → SettleLink
/// with null; <see cref="FetchOutcome.Transient"/> →
/// <see cref="EntryRepository.BumpLinkRetry"/>.
/// </summary>
public sealed class LinkMetadataFetcher : IDisposable
{
    /// <summary>
    /// Cap on raw HTML bytes we'll process per page. Most pages have
    /// their <c>&lt;title&gt;</c> + meta tags within the first 64 KB;
    /// going bigger just costs memory + decoder time.
    /// </summary>
    public const int MaxBodyBytes = 256 * 1024;

    /// <summary>Cap on raw thumbnail bytes we'll download.</summary>
    public const int MaxThumbnailBytes = 4 * 1024 * 1024;

    /// <summary>
    /// User-Agent string. Sites with bot-mitigation (NYT, CNN, Cloudflare-
    /// fronted publishers) 403 anything that doesn't look like a real
    /// browser — including UAs that contain telltale tokens like our
    /// product name. Send a plain Chromium-on-Windows UA. We're an honest
    /// fetcher pulling og:title / &lt;title&gt;; the UA is the cheapest
    /// way to get past the most common blocks.
    /// </summary>
    public const string DefaultUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/130.0.0.0 Safari/537.36";

    private readonly HttpClient _http;
    private readonly bool _ownsHttp;

    /// <summary>Default constructor wires a fresh <see cref="HttpClient"/>
    /// with our timeouts and User-Agent.</summary>
    public LinkMetadataFetcher() : this(CreateDefaultClient(), ownsClient: true) { }

    /// <summary>Test seam: inject a custom <see cref="HttpClient"/> (e.g.
    /// one configured with a fake <see cref="HttpMessageHandler"/>).
    /// Caller decides ownership — we won't dispose if
    /// <paramref name="ownsClient"/> is false.</summary>
    public LinkMetadataFetcher(HttpClient client, bool ownsClient = false)
    {
        _http = client;
        _ownsHttp = ownsClient;
    }

    public void Dispose()
    {
        if (_ownsHttp) _http.Dispose();
    }

    private static HttpClient CreateDefaultClient()
    {
        var handler = new HttpClientHandler
        {
            AllowAutoRedirect = true,
            MaxAutomaticRedirections = 5,
            // Cookie containers are stateful; we want clean stateless
            // requests so a captured URL never accidentally surfaces a
            // logged-in user's content.
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
        };
        var client = new HttpClient(handler)
        {
            // 8s for the full request including read. Caps a slow
            // server's ability to pin a worker thread; transient
            // timeouts are par for the course on flaky networks.
            Timeout = TimeSpan.FromSeconds(8),
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd(DefaultUserAgent);
        // HTML-only Accept by default. Previously included
        // application/json;q=0.9, which made ActivityPub-aware CDNs
        // (WordPress.com's nginx fronting Federated-WordPress sites)
        // willing to serve the federated-actor JSON for the page URL
        // instead of the HTML version — and worse, cache the JSON
        // variant against the same URL key for subsequent requests.
        // Result: WP pages settled with NULL title because the parser
        // got 5 KB of ActivityPub JSON to grep for `<title>` in.
        // YouTube oEmbed and Reddit `.json` endpoints return JSON
        // regardless of Accept, so dropping it here doesn't affect
        // either special-case path.
        client.DefaultRequestHeaders.Accept.ParseAdd(
            "text/html, application/xhtml+xml");
        client.DefaultRequestHeaders.AcceptLanguage.ParseAdd("en-US,en;q=0.9");
        return client;
    }

    // ─── Public API ───────────────────────────────────────────────────────

    /// <summary>
    /// Fetch metadata for <paramref name="urlString"/>. Always returns —
    /// transient/permanent failures are reified as
    /// <see cref="FetchOutcome.Transient"/> /
    /// <see cref="FetchOutcome.Permanent"/> rather than thrown so the
    /// backfill loop can dispatch without a try/catch.
    /// </summary>
    public async Task<FetchOutcome> FetchAsync(string urlString, CancellationToken ct = default)
    {
        if (!TryNormalize(urlString, out var url))
        {
            return new FetchOutcome.Permanent("invalid URL");
        }
        if (IsYouTubeHost(url))
        {
            return await FetchYouTubeAsync(url, ct).ConfigureAwait(false);
        }
        if (TryParseRedditCommentsUrl(url, out var sub, out var id))
        {
            // Step 2 of the resolution chain. Reddit's JSON API returns
            // a clean post title + thumbnail URL with no scraping. Fall
            // through to the generic HTML scrape on any error so a
            // malformed Reddit URL doesn't dead-end.
            var redditOutcome = await FetchRedditAsync(url, sub!, id!, ct).ConfigureAwait(false);
            if (redditOutcome is FetchOutcome.Success { Title.Length: > 0 } success)
            {
                return success;
            }
            // Either Reddit gave us no title (deleted post, NSFW gate, etc.)
            // or the call failed transient/permanent. Try the HTML path
            // before giving up — Reddit serves a real <title> in HTML too.
        }
        return await FetchGenericHtmlAsync(url, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Download the bytes for a thumbnail URL. Best-effort: returns null
    /// for any non-2xx status, non-image content type, oversized payload,
    /// or transport error. Callers (Stage D) hand the bytes to
    /// <c>Thumbnailer</c> and write them to the <c>previews</c> table.
    /// </summary>
    public async Task<byte[]?> FetchThumbnailBytesAsync(Uri url, CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Accept.Clear();
            req.Headers.Accept.ParseAdd("image/jpeg, image/png, image/webp, image/*;q=0.8");
            using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct)
                .ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return null;
            var contentType = resp.Content.Headers.ContentType?.MediaType?.ToLowerInvariant();
            if (contentType is not null && !contentType.StartsWith("image/", StringComparison.Ordinal))
                return null;
            // Length-cap: many CDNs include Content-Length, so we can
            // bail before reading. If absent, we read up to MaxThumbnailBytes
            // + 1 and reject if we hit the cap.
            if (resp.Content.Headers.ContentLength is long len && len > MaxThumbnailBytes)
                return null;
            var bytes = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            if (bytes.Length > MaxThumbnailBytes) return null;
            return bytes;
        }
        catch
        {
            return null;
        }
    }

    // ─── YouTube oEmbed ───────────────────────────────────────────────────

    /// <summary>
    /// Hosts that map to the YouTube oEmbed endpoint. Public so tests
    /// can exercise the boundary directly.
    /// </summary>
    public static bool IsYouTubeHost(Uri url)
    {
        var host = url.Host.ToLowerInvariant();
        if (host.StartsWith("www.", StringComparison.Ordinal)) host = host[4..];
        if (host.StartsWith("m.",   StringComparison.Ordinal)) host = host[2..];
        return host == "youtube.com" || host == "youtu.be";
    }

    private async Task<FetchOutcome> FetchYouTubeAsync(Uri url, CancellationToken ct)
    {
        var endpoint = new Uri(
            $"https://www.youtube.com/oembed?url={Uri.EscapeDataString(url.AbsoluteUri)}&format=json");
        try
        {
            using var resp = await _http.GetAsync(endpoint, HttpCompletionOption.ResponseContentRead, ct)
                .ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                return ClassifyHttpFailure((int)resp.StatusCode, "youtube oembed");
            }
            var json = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            try
            {
                var oembed = JsonSerializer.Deserialize<OEmbedDto>(json, OEmbedJsonOpts);
                var title = oembed?.Title?.Trim();
                Uri? thumb = null;
                if (oembed?.ThumbnailUrl is { Length: > 0 } t &&
                    Uri.TryCreate(t, UriKind.Absolute, out var u))
                {
                    thumb = u;
                }
                return new FetchOutcome.Success(
                    Title: string.IsNullOrEmpty(title) ? null : title,
                    ThumbnailUrl: thumb,
                    Source: LinkMetadataParser.TitleSource.None /* sourced from oEmbed; reuse None to mean "non-HTML" */);
            }
            catch (JsonException ex)
            {
                // Malformed JSON from YouTube is functionally permanent —
                // retrying won't fix it.
                return new FetchOutcome.Permanent($"youtube oembed json: {ex.Message}");
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return new FetchOutcome.Transient("youtube oembed timeout");
        }
        catch (HttpRequestException ex)
        {
            return new FetchOutcome.Transient($"youtube oembed network: {ex.Message}");
        }
    }

    private sealed class OEmbedDto
    {
        [JsonPropertyName("title")]
        public string? Title { get; set; }
        [JsonPropertyName("thumbnail_url")]
        public string? ThumbnailUrl { get; set; }
    }

    private static readonly JsonSerializerOptions OEmbedJsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    // ─── Reddit JSON ──────────────────────────────────────────────────────

    /// <summary>
    /// Detect a Reddit comments URL and extract its <c>(subreddit, postId)</c>.
    /// Host must be <c>reddit.com</c> or one of <c>www.|old.|new.|m.|np.</c>;
    /// path must be <c>/r/&lt;sub&gt;/comments/&lt;id&gt;[/...]</c>. Public so
    /// the unit tests can exercise the matcher without HTTP. Mirrors the
    /// per-URL contract in <c>docs/schema.md § Fetcher resolution chain</c>.
    /// </summary>
    public static bool TryParseRedditCommentsUrl(Uri url, out string? subreddit, out string? postId)
    {
        subreddit = null;
        postId = null;
        var host = url.Host.ToLowerInvariant();
        // Strip the few subdomain prefixes Reddit ships under. The schema
        // contract names www. / old. ; we also accept m. / new. / np. /
        // i.redd.it variants since they're real-world common.
        foreach (var prefix in new[] { "www.", "old.", "new.", "m.", "np." })
        {
            if (host.StartsWith(prefix, StringComparison.Ordinal))
            {
                host = host[prefix.Length..];
                break;
            }
        }
        if (host != "reddit.com") return false;

        // /r/<sub>/comments/<id>[/...]
        var segments = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length < 4) return false;
        if (!segments[0].Equals("r", StringComparison.OrdinalIgnoreCase)) return false;
        if (!segments[2].Equals("comments", StringComparison.OrdinalIgnoreCase)) return false;
        var sub = segments[1];
        var id = segments[3];
        if (string.IsNullOrEmpty(sub) || string.IsNullOrEmpty(id)) return false;

        subreddit = sub;
        postId = id;
        return true;
    }

    /// <summary>
    /// Sentinel <c>thumbnail</c> values Reddit serves for posts that have
    /// no real image. Schema contract: reject these and fall through to
    /// the HTML / favicon path.
    /// </summary>
    private static readonly HashSet<string> RedditThumbnailSentinels = new(StringComparer.OrdinalIgnoreCase)
    {
        "self", "default", "spoiler", "nsfw", "image", ""
    };

    private async Task<FetchOutcome> FetchRedditAsync(
        Uri originalUrl, string subreddit, string postId, CancellationToken ct)
    {
        var endpoint = new Uri(
            $"https://www.reddit.com/r/{Uri.EscapeDataString(subreddit)}/comments/{Uri.EscapeDataString(postId)}.json");
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, endpoint);
            // Reddit serves cleaner JSON (sometimes with full post body)
            // when we explicitly ask for it. The default Accept (which
            // includes text/html) sometimes routes us to the HTML page.
            req.Headers.Accept.Clear();
            req.Headers.Accept.ParseAdd("application/json");
            using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct)
                .ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                return ClassifyHttpFailure((int)resp.StatusCode, "reddit json");
            }
            var json = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            try
            {
                using var doc = JsonDocument.Parse(json);
                // Shape: [ { "kind":"Listing", "data":{ "children":[
                //   { "kind":"t3", "data":{ "title":"...", "thumbnail":"..." } }, ... ] } }, ... ]
                var root = doc.RootElement;
                if (root.ValueKind != JsonValueKind.Array || root.GetArrayLength() < 1)
                {
                    return new FetchOutcome.Permanent("reddit json: unexpected shape");
                }
                var firstListing = root[0];
                if (!firstListing.TryGetProperty("data", out var listingData)) goto fallback;
                if (!listingData.TryGetProperty("children", out var children)
                    || children.ValueKind != JsonValueKind.Array
                    || children.GetArrayLength() < 1) goto fallback;
                var post = children[0];
                if (!post.TryGetProperty("data", out var postData)) goto fallback;

                string? title = null;
                if (postData.TryGetProperty("title", out var titleEl)
                    && titleEl.ValueKind == JsonValueKind.String)
                {
                    title = titleEl.GetString()?.Trim();
                    if (string.IsNullOrEmpty(title)) title = null;
                }
                Uri? thumb = null;
                if (postData.TryGetProperty("thumbnail", out var thumbEl)
                    && thumbEl.ValueKind == JsonValueKind.String)
                {
                    var raw = thumbEl.GetString();
                    if (raw is not null
                        && !RedditThumbnailSentinels.Contains(raw)
                        && (raw.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                            || raw.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                        && Uri.TryCreate(raw, UriKind.Absolute, out var u))
                    {
                        thumb = u;
                    }
                }

                return new FetchOutcome.Success(title, thumb, LinkMetadataParser.TitleSource.None);

            fallback:
                return new FetchOutcome.Permanent("reddit json: missing post body");
            }
            catch (JsonException ex)
            {
                return new FetchOutcome.Permanent($"reddit json parse: {ex.Message}");
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return new FetchOutcome.Transient("reddit json timeout");
        }
        catch (HttpRequestException ex)
        {
            return new FetchOutcome.Transient($"reddit json network: {ex.Message}");
        }
    }

    // ─── Generic HTML scrape ──────────────────────────────────────────────

    private async Task<FetchOutcome> FetchGenericHtmlAsync(Uri url, CancellationToken ct)
    {
        byte[] body;
        try
        {
            using var resp = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct)
                .ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                return ClassifyHttpFailure((int)resp.StatusCode, "html");
            }
            // Guard against non-HTML responses. WordPress.com's
            // ActivityPub support returns `application/activity+json`
            // for the page URL when the client signals JSON is
            // acceptable — and CDN-caches it under a key our previous
            // Accept header overlapped with. Even with the corrected
            // Accept (HTML-only) above, the stale cache may still
            // serve JSON for a while. Treating non-HTML as transient
            // lets the row keep trying and stops the parser from
            // grepping 5 KB of JSON for an HTML title (which silently
            // settles with NULL). text/html, application/xhtml+xml,
            // and a permissive "looks like markup" fallback all pass.
            var contentType = resp.Content.Headers.ContentType?.MediaType?.ToLowerInvariant();
            if (contentType is not null && !IsHtmlLike(contentType))
            {
                return new FetchOutcome.Transient(
                    $"non-html content-type: {contentType}");
            }
            // Cap body read at MaxBodyBytes — most pages have their head
            // section well within the first 64 KB, and an unbounded read
            // is a DoS vector for the daemon's worker queue.
            using var stream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            using var ms = new MemoryStream();
            var buf = new byte[8192];
            int total = 0;
            while (total < MaxBodyBytes)
            {
                var n = await stream.ReadAsync(buf.AsMemory(0, Math.Min(buf.Length, MaxBodyBytes - total)), ct)
                    .ConfigureAwait(false);
                if (n <= 0) break;
                ms.Write(buf, 0, n);
                total += n;
            }
            body = ms.ToArray();
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return new FetchOutcome.Transient("html timeout");
        }
        catch (HttpRequestException ex)
        {
            return new FetchOutcome.Transient($"html network: {ex.Message}");
        }

        var parsed = LinkMetadataParser.Parse(body);

        // Step 4 of the resolution chain: bot-check rejection. Cloudflare
        // / DataDome / Akamai bot mitigation often serves a 200 OK page
        // whose title is "Just a moment…" or "Attention Required!" — the
        // raw HTTP status looks fine but there's nothing useful in the
        // body. Treat as transient so the row stays a candidate; the
        // backoff window gives the rate-limiter time to forget us. Per
        // schema.md § Fetcher resolution chain step 4.
        if (parsed.Title is { } extractedTitle && LooksLikeBotCheck(extractedTitle))
        {
            return new FetchOutcome.Transient(
                $"bot-check rejection: \"{Trunc(extractedTitle, 60)}\"");
        }

        var thumb = parsed.ThumbnailUrl;

        // Wikipedia REST API thumbnail fallback — articles like
        // "Clipboard (computing)" have no og:image, but the REST summary
        // endpoint exposes whatever lead image they do have. Skip if
        // og:image already gave us a thumbnail.
        if (thumb is null && IsWikipediaHost(url))
        {
            thumb = await FetchWikipediaSummaryThumbnailAsync(url, ct).ConfigureAwait(false);
        }

        // Last-resort favicon. Always at least *something* so the card
        // doesn't render bare. fetchThumbnailBytesAsync handles 404s
        // (e.g., favicon.ico simply not existing) by returning null.
        thumb ??= LinkMetadataParser.ResolveFavicon(body, url);

        return new FetchOutcome.Success(parsed.Title, thumb, parsed.Source);
    }

    /// <summary>
    /// Bot-check pattern list per <c>docs/schema.md § Fetcher resolution
    /// chain step 4</c>. Case-insensitive substring match; if any matches
    /// the post-extraction title, the page is treated as a bot challenge
    /// (Cloudflare "Just a moment…", Akamai "Access Denied", etc.) and
    /// the fetch is reported as transient. Public so unit tests can
    /// exercise the matcher directly.
    /// </summary>
    public static bool LooksLikeBotCheck(string title)
    {
        if (string.IsNullOrEmpty(title)) return false;
        foreach (var pattern in BotCheckPatterns)
        {
            if (title.Contains(pattern, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    /// <summary>
    /// Ten substrings that have shown up in real bot-mitigation interstitial
    /// pages. Order doesn't matter — first match wins. Match the schema
    /// contract verbatim; do not edit without updating
    /// <c>docs/schema.md § Fetcher resolution chain step 4</c>.
    /// </summary>
    public static readonly string[] BotCheckPatterns =
    {
        "please wait for verification",
        "just a moment",
        "are you human",
        "checking your browser",
        "attention required",
        "access denied",
        "verify you are a human",
        "please verify you are human",
        "human verification",
        "captcha",
    };

    private static string Trunc(string s, int max) =>
        s.Length <= max ? s : s.Substring(0, max) + "…";

    // ─── Wikipedia REST API ───────────────────────────────────────────────

    public static bool IsWikipediaHost(Uri url)
    {
        var host = url.Host.ToLowerInvariant();
        return host == "wikipedia.org" || host.EndsWith(".wikipedia.org", StringComparison.Ordinal);
    }

    /// <summary>
    /// For a Wikipedia article URL like
    /// <c>https://en.wikipedia.org/wiki/Clipboard_(computing)</c>, hit
    /// <c>https://en.wikipedia.org/api/rest_v1/page/summary/Clipboard_(computing)</c>
    /// and return the <c>thumbnail.source</c> URL (or
    /// <c>originalimage.source</c> as a last resort). Returns null on any
    /// error or for text-only articles that genuinely have no image.
    /// </summary>
    private async Task<Uri?> FetchWikipediaSummaryThumbnailAsync(Uri pageUrl, CancellationToken ct)
    {
        const string marker = "/wiki/";
        var path = pageUrl.AbsolutePath;
        var idx = path.IndexOf(marker, StringComparison.Ordinal);
        if (idx < 0) return null;
        var titleSegment = path[(idx + marker.Length)..];
        if (string.IsNullOrEmpty(titleSegment)) return null;

        var apiUrl = new Uri(
            $"{pageUrl.Scheme}://{pageUrl.Host}/api/rest_v1/page/summary/{titleSegment}");
        try
        {
            using var resp = await _http.GetAsync(apiUrl, HttpCompletionOption.ResponseContentRead, ct)
                .ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return null;
            var json = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            var summary = JsonSerializer.Deserialize<WikipediaSummaryDto>(json, OEmbedJsonOpts);
            if (summary?.Thumbnail?.Source is { Length: > 0 } t1 &&
                Uri.TryCreate(t1, UriKind.Absolute, out var u1))
            {
                return u1;
            }
            if (summary?.Originalimage?.Source is { Length: > 0 } t2 &&
                Uri.TryCreate(t2, UriKind.Absolute, out var u2))
            {
                return u2;
            }
            return null;
        }
        catch
        {
            return null;
        }
    }

    private sealed class WikipediaSummaryDto
    {
        [JsonPropertyName("thumbnail")]
        public WikipediaImageDto? Thumbnail { get; set; }
        [JsonPropertyName("originalimage")]
        public WikipediaImageDto? Originalimage { get; set; }
    }

    private sealed class WikipediaImageDto
    {
        [JsonPropertyName("source")]
        public string? Source { get; set; }
    }

    /// <summary>
    /// True when <paramref name="contentType"/> looks like a markup
    /// document the HTML parser can usefully grep. Matches
    /// <c>text/html</c>, <c>application/xhtml+xml</c>, the generic
    /// <c>text/*</c> family (some misconfigured servers send
    /// <c>text/plain</c> with HTML in the body), and bare ASCII
    /// <c>"text"</c> for legacy responses with no subtype. Returns
    /// false for <c>application/activity+json</c>,
    /// <c>application/ld+json</c>, generic <c>application/json</c>,
    /// images, video, etc. Public for unit tests.
    /// </summary>
    public static bool IsHtmlLike(string contentType)
    {
        if (string.IsNullOrEmpty(contentType)) return true;  // unspecified → assume html
        return contentType.Equals("text/html",            StringComparison.OrdinalIgnoreCase)
            || contentType.Equals("application/xhtml+xml", StringComparison.OrdinalIgnoreCase)
            || contentType.StartsWith("text/",             StringComparison.OrdinalIgnoreCase);
    }

    // ─── HTTP failure classification ──────────────────────────────────────

    /// <summary>
    /// Map an HTTP status code to a transient or permanent outcome. The
    /// transient set matches the Mac contract:
    /// 403 (often a YouTube-style rate limit), 408 timeout, 425 too early,
    /// 429 too many requests, 5xx server errors. Everything else is
    /// permanent — the row settles with a null title.
    /// </summary>
    public static FetchOutcome ClassifyHttpFailure(int statusCode, string context)
    {
        bool transient = statusCode == 403
                      || statusCode == 408
                      || statusCode == 425
                      || statusCode == 429
                      || (statusCode >= 500 && statusCode < 600);
        var msg = $"{context} HTTP {statusCode}";
        return transient
            ? new FetchOutcome.Transient(msg)
            : new FetchOutcome.Permanent(msg);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// <summary>
    /// Trim, parse, and require an http(s) scheme. Public for the
    /// backfiller's pre-flight check (Stage C) — the candidate query
    /// already filters on <c>text_preview LIKE 'http%'</c>, but a
    /// secondary <see cref="Uri"/> validation is cheap insurance against
    /// junk like <c>http://[</c>.
    /// </summary>
    public static bool TryNormalize(string urlString, out Uri url)
    {
        url = null!;
        if (string.IsNullOrWhiteSpace(urlString)) return false;
        var trimmed = urlString.Trim();
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var u)) return false;
        if (!u.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase)
            && !u.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase))
            return false;
        url = u;
        return true;
    }
}

/// <summary>
/// Result of a single <see cref="LinkMetadataFetcher.FetchAsync"/> call.
/// The three subtypes drive backfiller dispatch:
/// <list type="bullet">
/// <item><see cref="Success"/> — settle with the title (which may be
///       null when the page returned 200 but had nothing parseable).</item>
/// <item><see cref="Permanent"/> — a permanent failure (4xx besides
///       transients, malformed URL, unparseable JSON). Settle with a
///       null title so the row stops appearing as a candidate.</item>
/// <item><see cref="Transient"/> — a transient failure (rate limit,
///       network blip, 5xx). The backfiller bumps the retry counter
///       and parks the row behind the backoff window.</item>
/// </list>
/// </summary>
public abstract record FetchOutcome
{
    public sealed record Success(
        string? Title,
        Uri? ThumbnailUrl,
        LinkMetadataParser.TitleSource Source) : FetchOutcome;

    public sealed record Permanent(string Reason) : FetchOutcome;

    public sealed record Transient(string Reason) : FetchOutcome;
}
