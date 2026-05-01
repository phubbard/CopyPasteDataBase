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
