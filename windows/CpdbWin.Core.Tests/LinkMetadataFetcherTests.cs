using System.Net;
using System.Text;
using CpdbWin.Core.Analysis;
using Xunit;

namespace CpdbWin.Core.Tests;

public class LinkMetadataFetcherTests
{
    // ─── URL normalization ───────────────────────────────────────────────

    [Theory]
    [InlineData("https://example.com",                  true)]
    [InlineData("http://example.com",                   true)]
    [InlineData("  https://example.com/path  ",         true)] // trim
    [InlineData("",                                     false)]
    [InlineData("not-a-url",                            false)]
    [InlineData("ftp://files.example",                  false)]
    [InlineData("file:///C:/local",                     false)]
    [InlineData("javascript:alert(1)",                  false)]
    public void TryNormalize_AcceptsHttpHttpsOnly(string input, bool expected)
    {
        Assert.Equal(expected, LinkMetadataFetcher.TryNormalize(input, out _));
    }

    // ─── Content-Type guard (IsHtmlLike) ─────────────────────────────────

    [Theory]
    [InlineData("text/html",                  true)]
    [InlineData("TEXT/HTML",                  true)]   // case-insensitive
    [InlineData("application/xhtml+xml",      true)]
    [InlineData("text/plain",                 true)]   // legacy / misconfigured
    [InlineData("text/xml",                   true)]   // text/* family
    [InlineData("",                           true)]   // unspecified → assume html
    // Non-HTML — WordPress.com ActivityPub + similar should be rejected so the
    // HTML parser doesn't grep 5 KB of JSON looking for <title>.
    [InlineData("application/activity+json",  false)]
    [InlineData("application/ld+json",        false)]
    [InlineData("application/json",           false)]
    [InlineData("image/png",                  false)]
    [InlineData("video/mp4",                  false)]
    [InlineData("application/pdf",            false)]
    public void IsHtmlLike_AcceptsMarkupRejectsEverythingElse(string contentType, bool expected)
    {
        Assert.Equal(expected, LinkMetadataFetcher.IsHtmlLike(contentType));
    }

    // ─── YouTube host detection ──────────────────────────────────────────

    [Theory]
    [InlineData("https://www.youtube.com/watch?v=abc",  true)]
    [InlineData("https://youtube.com/watch?v=abc",      true)]
    [InlineData("https://m.youtube.com/watch?v=abc",    true)]
    [InlineData("https://youtu.be/abc",                 true)]
    [InlineData("https://music.youtube.com/watch?v=x",  false)] // subdomains we don't oEmbed
    [InlineData("https://example.com/video",            false)]
    public void IsYouTubeHost_MatchesCanonicalShapes(string url, bool expected)
    {
        Assert.Equal(expected, LinkMetadataFetcher.IsYouTubeHost(new Uri(url)));
    }

    // ─── Reddit comments URL detection ───────────────────────────────────

    [Theory]
    [InlineData("https://www.reddit.com/r/AskReddit/comments/abc123/why_do_cats/",      true,  "AskReddit", "abc123")]
    [InlineData("https://old.reddit.com/r/programming/comments/xyz",                     true,  "programming", "xyz")]
    [InlineData("https://new.reddit.com/r/technology/comments/foo/bar",                  true,  "technology", "foo")]
    [InlineData("https://m.reddit.com/r/aww/comments/baz/",                              true,  "aww", "baz")]
    [InlineData("https://np.reddit.com/r/sub/comments/id/title/",                        true,  "sub", "id")]
    [InlineData("https://reddit.com/r/sub/comments/id",                                  true,  "sub", "id")]
    // Non-comment Reddit URLs fall through to the HTML scrape.
    [InlineData("https://www.reddit.com/r/programming/",                                 false, null, null)]
    [InlineData("https://www.reddit.com/user/spez",                                      false, null, null)]
    [InlineData("https://reddit.com/",                                                   false, null, null)]
    // Reddit-shaped paths on non-Reddit hosts must NOT match.
    [InlineData("https://example.com/r/sub/comments/id",                                 false, null, null)]
    public void TryParseRedditCommentsUrl_HitsRealRedditPosts(
        string url, bool expected, string? expectedSub, string? expectedId)
    {
        var ok = LinkMetadataFetcher.TryParseRedditCommentsUrl(new Uri(url), out var sub, out var id);
        Assert.Equal(expected, ok);
        if (expected)
        {
            Assert.Equal(expectedSub, sub);
            Assert.Equal(expectedId,  id);
        }
        else
        {
            Assert.Null(sub);
            Assert.Null(id);
        }
    }

    [Fact]
    public async Task FetchAsync_RedditCommentsUrl_HitsJsonEndpointAndParses()
    {
        var hits = new List<Uri>();
        var handler = new FakeHandler
        {
            OnSend = req =>
            {
                hits.Add(req.RequestUri!);
                if (req.RequestUri!.AbsoluteUri.EndsWith(".json", StringComparison.Ordinal))
                {
                    return Json(req, """
                        [
                          { "kind": "Listing",
                            "data": { "children": [
                              { "kind": "t3",
                                "data": {
                                  "title": "Why do cats knead?",
                                  "thumbnail": "https://b.thumbs.redditmedia.com/abc.jpg"
                                }
                              }
                            ]}
                          },
                          { "kind": "Listing",
                            "data": { "children": [] } }
                        ]
                        """);
                }
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var outcome = await fetcher.FetchAsync(
            "https://www.reddit.com/r/AskReddit/comments/abc123/why_do_cats_knead/");
        var success = Assert.IsType<FetchOutcome.Success>(outcome);
        Assert.Equal("Why do cats knead?", success.Title);
        Assert.Equal(new Uri("https://b.thumbs.redditmedia.com/abc.jpg"), success.ThumbnailUrl);
        // Confirms we hit the .json endpoint and not the comments page.
        Assert.Single(hits);
        Assert.EndsWith(".json", hits[0].AbsoluteUri);
    }

    [Theory]
    [InlineData("self")]
    [InlineData("default")]
    [InlineData("spoiler")]
    [InlineData("nsfw")]
    [InlineData("")]
    public async Task FetchAsync_RedditSentinelThumbnail_RejectedAsNotAnImage(string sentinel)
    {
        // Build the JSON without raw-string interpolation — the
        // double-brace escape ($$""" ... """) plays poorly with the
        // single-brace pairs in the body, and concat is unambiguous.
        var body = "[{\"data\":{\"children\":[{\"data\":"
                 + "{\"title\":\"text post\",\"thumbnail\":\""
                 + sentinel
                 + "\"}}]}}]";
        var handler = new FakeHandler
        {
            OnSend = req =>
            {
                if (req.RequestUri!.AbsoluteUri.EndsWith(".json", StringComparison.Ordinal))
                {
                    return Json(req, body);
                }
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var outcome = await fetcher.FetchAsync(
            "https://www.reddit.com/r/test/comments/abc/text_post/");
        var success = Assert.IsType<FetchOutcome.Success>(outcome);
        Assert.Equal("text post", success.Title);
        // Sentinel rejected — no thumbnail surfaced.
        Assert.Null(success.ThumbnailUrl);
    }

    [Fact]
    public async Task FetchAsync_RedditMissingPostBody_FallsThroughToHtmlScrape()
    {
        // Empty children array → Reddit JSON gives us nothing useful;
        // contract says we fall through to step 3.
        var hits = new List<Uri>();
        var handler = new FakeHandler
        {
            OnSend = req =>
            {
                hits.Add(req.RequestUri!);
                if (req.RequestUri!.AbsoluteUri.EndsWith(".json", StringComparison.Ordinal))
                {
                    return Json(req, """[{"data":{"children":[]}}]""");
                }
                return Html(req, req.RequestUri!.AbsoluteUri,
                    "<html><head><title>HTML Fallback Title</title></head></html>");
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var outcome = await fetcher.FetchAsync(
            "https://www.reddit.com/r/test/comments/xyz/post/");
        var success = Assert.IsType<FetchOutcome.Success>(outcome);
        Assert.Equal("HTML Fallback Title", success.Title);
        // Both endpoints hit — JSON first, then HTML fallback.
        Assert.Equal(2, hits.Count);
        Assert.EndsWith(".json", hits[0].AbsoluteUri);
    }

    // ─── Bot-check rejection ─────────────────────────────────────────────

    [Theory]
    [InlineData("Just a moment...",                        true)]
    [InlineData("Just a moment",                           true)]
    [InlineData("Please wait for verification",            true)]
    [InlineData("Are you human?",                          true)]
    [InlineData("Checking your browser before accessing",  true)]
    [InlineData("Attention Required! | Cloudflare",        true)]
    [InlineData("ACCESS DENIED",                           true)]   // case-insensitive
    [InlineData("Verify you are a human",                  true)]
    [InlineData("Please verify you are human",             true)]
    [InlineData("Human verification required",             true)]
    [InlineData("Please complete the captcha",             true)]
    [InlineData("This is a real article title",            false)]
    [InlineData("",                                        false)]
    public void LooksLikeBotCheck_MatchesContractList(string title, bool expected) =>
        Assert.Equal(expected, LinkMetadataFetcher.LooksLikeBotCheck(title));

    [Fact]
    public void BotCheckPatterns_HasExactlyTenEntries() =>
        // Schema contract names ten substrings — any change must round-trip
        // through docs/schema.md § Fetcher resolution chain step 4.
        Assert.Equal(10, LinkMetadataFetcher.BotCheckPatterns.Length);

    [Fact]
    public async Task FetchAsync_BotCheckTitle_ReturnsTransient()
    {
        // Cloudflare-style 200 OK page with a bot-check title — the row
        // must stay a candidate for retry (Transient), not get settled
        // with a junk title.
        var handler = new FakeHandler
        {
            OnSend = req => Html(req, "https://blocked.example/",
                "<html><head><title>Just a moment...</title></head></html>")
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        Assert.IsType<FetchOutcome.Transient>(
            await fetcher.FetchAsync("https://blocked.example/"));
    }

    [Fact]
    public async Task FetchAsync_BotCheckOgTitle_AlsoReturnsTransient()
    {
        // Also exercise the og:title path — bot-check pages sometimes
        // populate that too.
        const string body =
            "<html><head>" +
            "<meta property=\"og:title\" content=\"Attention Required! | Cloudflare\">" +
            "</head></html>";
        var handler = new FakeHandler
        {
            OnSend = req => Html(req, "https://og-blocked.example/", body)
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        Assert.IsType<FetchOutcome.Transient>(
            await fetcher.FetchAsync("https://og-blocked.example/"));
    }

    // ─── Wikipedia host detection ────────────────────────────────────────

    [Theory]
    [InlineData("https://en.wikipedia.org/wiki/Foo",    true)]
    [InlineData("https://de.wikipedia.org/wiki/Foo",    true)]
    [InlineData("https://wikipedia.org/wiki/Foo",       true)]
    [InlineData("https://example.com/wiki/Foo",         false)]
    public void IsWikipediaHost_MatchesAllLanguages(string url, bool expected)
    {
        Assert.Equal(expected, LinkMetadataFetcher.IsWikipediaHost(new Uri(url)));
    }

    // ─── HTTP failure classification (pure) ─────────────────────────────

    [Theory]
    [InlineData(403, true)]   // YouTube oEmbed rate-limit signal
    [InlineData(408, true)]
    [InlineData(425, true)]
    [InlineData(429, true)]
    [InlineData(500, true)]
    [InlineData(502, true)]
    [InlineData(503, true)]
    [InlineData(504, true)]
    [InlineData(599, true)]
    [InlineData(404, false)]
    [InlineData(401, false)]
    [InlineData(400, false)]
    [InlineData(410, false)] // Gone — settle, don't retry
    public void ClassifyHttpFailure_MatchesContractTransientSet(int code, bool transient)
    {
        var outcome = LinkMetadataFetcher.ClassifyHttpFailure(code, "test");
        if (transient)
        {
            Assert.IsType<FetchOutcome.Transient>(outcome);
        }
        else
        {
            Assert.IsType<FetchOutcome.Permanent>(outcome);
        }
    }

    // ─── Fetcher integration with mock handler ──────────────────────────

    [Fact]
    public async Task FetchAsync_InvalidUrl_ReturnsPermanent()
    {
        using var fetcher = new LinkMetadataFetcher(new HttpClient(new FakeHandler()), ownsClient: true);
        var outcome = await fetcher.FetchAsync("not-a-url");
        Assert.IsType<FetchOutcome.Permanent>(outcome);
    }

    [Fact]
    public async Task FetchAsync_GenericHtml_ParsesOgTitle()
    {
        var handler = new FakeHandler
        {
            OnSend = req => Html(req, "https://example.com/article",
                """<html><head><meta property="og:title" content="Hello World"></head></html>""")
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var outcome = await fetcher.FetchAsync("https://example.com/article");
        var success = Assert.IsType<FetchOutcome.Success>(outcome);
        Assert.Equal("Hello World", success.Title);
        Assert.Equal(LinkMetadataParser.TitleSource.OpenGraph, success.Source);
    }

    [Fact]
    public async Task FetchAsync_GenericHtml_NoTitleSignals_ReturnsSuccessNullTitle()
    {
        // 200 OK but page has nothing parseable → Success(null, …). The
        // backfiller settles with null, stamps fetched_at, stops retrying.
        var handler = new FakeHandler
        {
            OnSend = req => Html(req, "https://example.com",
                "<html><body>no title here</body></html>")
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var outcome = await fetcher.FetchAsync("https://example.com/");
        var success = Assert.IsType<FetchOutcome.Success>(outcome);
        Assert.Null(success.Title);
    }

    [Fact]
    public async Task FetchAsync_Generic404_ReturnsPermanent()
    {
        var handler = new FakeHandler
        {
            OnSend = _ => new HttpResponseMessage(HttpStatusCode.NotFound)
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var outcome = await fetcher.FetchAsync("https://gone.example/");
        Assert.IsType<FetchOutcome.Permanent>(outcome);
    }

    [Fact]
    public async Task FetchAsync_Generic429_ReturnsTransient()
    {
        var handler = new FakeHandler
        {
            OnSend = _ => new HttpResponseMessage((HttpStatusCode)429)
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var outcome = await fetcher.FetchAsync("https://rate-limited.example/");
        Assert.IsType<FetchOutcome.Transient>(outcome);
    }

    [Fact]
    public async Task FetchAsync_Generic500_ReturnsTransient()
    {
        var handler = new FakeHandler
        {
            OnSend = _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        Assert.IsType<FetchOutcome.Transient>(
            await fetcher.FetchAsync("https://broken.example/"));
    }

    [Fact]
    public async Task FetchAsync_NetworkException_ReturnsTransient()
    {
        var handler = new FakeHandler
        {
            OnSend = _ => throw new HttpRequestException("simulated DNS failure")
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        Assert.IsType<FetchOutcome.Transient>(
            await fetcher.FetchAsync("https://unreachable.example/"));
    }

    [Fact]
    public async Task FetchAsync_YouTube_HitsOEmbedEndpointAndParses()
    {
        var hits = new List<Uri>();
        var handler = new FakeHandler
        {
            OnSend = req =>
            {
                hits.Add(req.RequestUri!);
                return Json(req, """{"title":"My Video","thumbnail_url":"https://i.ytimg.com/vi/abc/hq.jpg"}""");
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);

        var outcome = await fetcher.FetchAsync("https://www.youtube.com/watch?v=abc");

        var success = Assert.IsType<FetchOutcome.Success>(outcome);
        Assert.Equal("My Video", success.Title);
        Assert.Equal(new Uri("https://i.ytimg.com/vi/abc/hq.jpg"), success.ThumbnailUrl);
        // Caller must have hit the oEmbed endpoint, not the watch page itself.
        Assert.Single(hits);
        Assert.StartsWith("https://www.youtube.com/oembed", hits[0].ToString());
    }

    [Fact]
    public async Task FetchAsync_YouTube_403_ReturnsTransient()
    {
        var handler = new FakeHandler
        {
            OnSend = _ => new HttpResponseMessage(HttpStatusCode.Forbidden)
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        // YouTube uses 403 as an effective rate limit, so it must be transient.
        Assert.IsType<FetchOutcome.Transient>(
            await fetcher.FetchAsync("https://www.youtube.com/watch?v=x"));
    }

    [Fact]
    public async Task FetchAsync_Wikipedia_NoOgImage_FallsBackToRestApiThumbnail()
    {
        // Page returns an article with no og:image — fetcher should hit
        // the REST summary endpoint and surface the thumbnail.source.
        var handler = new FakeHandler
        {
            OnSend = req =>
            {
                var u = req.RequestUri!.AbsoluteUri;
                if (u.StartsWith("https://en.wikipedia.org/wiki/", StringComparison.Ordinal))
                {
                    return Html(req, u, "<html><head><title>Clipboard</title></head></html>");
                }
                if (u.StartsWith("https://en.wikipedia.org/api/rest_v1/page/summary/", StringComparison.Ordinal))
                {
                    return Json(req, """
                        {
                          "thumbnail":     {"source":"https://upload.wikimedia.org/clipboard.jpg"},
                          "originalimage": {"source":"https://upload.wikimedia.org/clipboard-orig.jpg"}
                        }
                        """);
                }
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);

        var outcome = await fetcher.FetchAsync("https://en.wikipedia.org/wiki/Clipboard_(computing)");

        var success = Assert.IsType<FetchOutcome.Success>(outcome);
        Assert.Equal("Clipboard", success.Title);
        Assert.Equal(new Uri("https://upload.wikimedia.org/clipboard.jpg"), success.ThumbnailUrl);
    }

    [Fact]
    public async Task FetchAsync_NoOgImage_FallsBackToFavicon()
    {
        // No og:image, no apple-touch-icon, no <link rel="icon"> → the
        // conventional /favicon.ico is the Stage B output. Stage C
        // (downloader) will discover whether it exists.
        var handler = new FakeHandler
        {
            OnSend = req => Html(req, "https://example.com/article",
                "<html><head><title>Story</title></head></html>")
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var outcome = await fetcher.FetchAsync("https://example.com/article");
        var success = Assert.IsType<FetchOutcome.Success>(outcome);
        Assert.Equal(new Uri("https://example.com/favicon.ico"), success.ThumbnailUrl);
    }

    [Fact]
    public async Task FetchAsync_RespectsBodyByteCap()
    {
        // Page slams us with a 5 MB body. Fetcher caps at 256 KB so it
        // doesn't pin a worker. Title still parses because the header
        // happens early.
        var html = "<html><head><title>Cap Test</title></head><body>"
                 + new string('x', 5 * 1024 * 1024) + "</body></html>";
        var handler = new FakeHandler
        {
            OnSend = req => Html(req, "https://big.example/", html)
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var outcome = await fetcher.FetchAsync("https://big.example/");
        var success = Assert.IsType<FetchOutcome.Success>(outcome);
        Assert.Equal("Cap Test", success.Title);
    }

    [Fact]
    public async Task FetchThumbnailBytesAsync_NonImageContentType_ReturnsNull()
    {
        var handler = new FakeHandler
        {
            OnSend = req =>
            {
                var resp = new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new ByteArrayContent(new byte[] { 1, 2, 3 })
                };
                resp.Content.Headers.ContentType =
                    new System.Net.Http.Headers.MediaTypeHeaderValue("text/html");
                return resp;
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var bytes = await fetcher.FetchThumbnailBytesAsync(new Uri("https://example.com/x.jpg"));
        Assert.Null(bytes);
    }

    [Fact]
    public async Task FetchThumbnailBytesAsync_ImageContentType_ReturnsBytes()
    {
        var payload = new byte[] { 0xFF, 0xD8, 0xFF, 0xE0 }; // tiny JPEG header
        var handler = new FakeHandler
        {
            OnSend = req =>
            {
                var resp = new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new ByteArrayContent(payload)
                };
                resp.Content.Headers.ContentType =
                    new System.Net.Http.Headers.MediaTypeHeaderValue("image/jpeg");
                return resp;
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var bytes = await fetcher.FetchThumbnailBytesAsync(new Uri("https://example.com/x.jpg"));
        Assert.Equal(payload, bytes);
    }

    [Fact]
    public async Task FetchThumbnailBytesAsync_OversizedBody_ReturnsNull()
    {
        var payload = new byte[5 * 1024 * 1024]; // 5 MB > 4 MB cap
        var handler = new FakeHandler
        {
            OnSend = req =>
            {
                var resp = new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new ByteArrayContent(payload)
                };
                resp.Content.Headers.ContentType =
                    new System.Net.Http.Headers.MediaTypeHeaderValue("image/png");
                resp.Content.Headers.ContentLength = payload.Length;
                return resp;
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        Assert.Null(await fetcher.FetchThumbnailBytesAsync(new Uri("https://huge.example/big.png")));
    }

    // ─── Test helpers ───────────────────────────────────────────────────

    /// <summary>
    /// Build a 200-OK text/html response. The request URI is included as
    /// breadcrumb so the test can assert the right URL was hit.
    /// </summary>
    private static HttpResponseMessage Html(HttpRequestMessage req, string urlForLog, string html)
    {
        _ = urlForLog; // currently unused, kept for future logging
        var resp = new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(html, Encoding.UTF8, "text/html"),
            RequestMessage = req,
        };
        return resp;
    }

    private static HttpResponseMessage Json(HttpRequestMessage req, string json)
    {
        var resp = new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
            RequestMessage = req,
        };
        return resp;
    }

    /// <summary>
    /// Synchronous in-memory <see cref="HttpMessageHandler"/>. Tests set
    /// <see cref="OnSend"/> to script the response.
    /// </summary>
    internal sealed class FakeHandler : HttpMessageHandler
    {
        public Func<HttpRequestMessage, HttpResponseMessage> OnSend { get; set; } =
            _ => new HttpResponseMessage(HttpStatusCode.NotFound);

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            try
            {
                return Task.FromResult(OnSend(request));
            }
            catch (Exception ex)
            {
                return Task.FromException<HttpResponseMessage>(ex);
            }
        }
    }
}
