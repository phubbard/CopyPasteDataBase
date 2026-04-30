import Testing
import Foundation
@testable import CpdbShared

@Suite("Link metadata fetcher — HTML parsing")
struct LinkMetadataFetcherTests {

    private func data(_ html: String) -> Data {
        html.data(using: .utf8)!
    }

    @Test("og:title beats <title>")
    func ogTitleWins() {
        let html = """
        <html><head>
        <title>Default page title</title>
        <meta property="og:title" content="The Better Title">
        </head><body></body></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.title == "The Better Title")
        #expect(result.source == .htmlOpenGraph)
    }

    @Test("twitter:title used when og:title absent")
    func twitterTitleFallback() {
        let html = """
        <html><head>
        <title>Default page title</title>
        <meta name="twitter:title" content="Twitter Card Title">
        </head><body></body></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.title == "Twitter Card Title")
        #expect(result.source == .htmlTwitterCard)
    }

    @Test("<title> tag used when no meta tags")
    func plainTitleTag() {
        let html = """
        <!DOCTYPE html>
        <html><head><title>Just a Title</title></head>
        <body></body></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.title == "Just a Title")
        #expect(result.source == .htmlTitleTag)
    }

    @Test("nil title when page has no title at all")
    func noTitleSourcePresent() {
        let html = "<html><head></head><body>no title here</body></html>"
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.title == nil)
        #expect(result.source == .none)
    }

    @Test("attribute order: content first, name second")
    func attributesReversedOrder() {
        let html = """
        <html><head>
        <meta content="Reversed Order Title" property="og:title">
        </head><body></body></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.title == "Reversed Order Title")
        #expect(result.source == .htmlOpenGraph)
    }

    @Test("HTML entities are decoded in titles")
    func htmlEntitiesDecoded() {
        let html = """
        <html><head>
        <title>Bob &amp; Alice&#39;s &quot;Adventure&quot;</title>
        </head></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.title == "Bob & Alice's \"Adventure\"")
    }

    @Test("Multi-line <title> still parses (typical newsroom HTML)")
    func multilineTitle() {
        let html = """
        <html><head><title>
        Big News:
        Something Happened
        </title></head></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.title?.contains("Big News") == true)
        #expect(result.title?.contains("Something Happened") == true)
    }

    @Test("YouTube URL detection")
    func youtubeDetection() {
        // www.youtube.com
        #expect(LinkMetadataFetcher.isYouTubeURL(URL(string: "https://www.youtube.com/watch?v=abc")!))
        // youtu.be shortlink
        #expect(LinkMetadataFetcher.isYouTubeURL(URL(string: "https://youtu.be/abc")!))
        // m.youtube.com (mobile)
        #expect(LinkMetadataFetcher.isYouTubeURL(URL(string: "https://m.youtube.com/watch?v=abc")!))
        // youtube.com without www
        #expect(LinkMetadataFetcher.isYouTubeURL(URL(string: "https://youtube.com/shorts/abc")!))
        // Not YouTube
        #expect(!LinkMetadataFetcher.isYouTubeURL(URL(string: "https://vimeo.com/12345")!))
        #expect(!LinkMetadataFetcher.isYouTubeURL(URL(string: "https://example.com")!))
        // not-quite-youtube domain
        #expect(!LinkMetadataFetcher.isYouTubeURL(URL(string: "https://notyoutube.com")!))
    }

    @Test("og:image is extracted alongside og:title")
    func ogImageExtracted() {
        let html = """
        <html><head>
        <meta property="og:title" content="Article Title">
        <meta property="og:image" content="https://cdn.example.com/hero.jpg">
        </head></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.title == "Article Title")
        #expect(result.thumbnailURL?.absoluteString == "https://cdn.example.com/hero.jpg")
    }

    @Test("og:image:secure_url is accepted as og:image fallback")
    func ogImageSecureUrl() {
        let html = """
        <html><head>
        <meta property="og:title" content="Article">
        <meta property="og:image:secure_url" content="https://cdn.example.com/hero.png">
        </head></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.thumbnailURL?.absoluteString == "https://cdn.example.com/hero.png")
    }

    @Test("twitter:image used when no og:image")
    func twitterImageFallback() {
        let html = """
        <html><head>
        <title>Plain Title</title>
        <meta name="twitter:image" content="https://cdn.example.com/twitter.jpg">
        </head></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.thumbnailURL?.absoluteString == "https://cdn.example.com/twitter.jpg")
    }

    @Test("page with title but no image: thumbnailURL nil")
    func titleNoImage() {
        let html = """
        <html><head><title>Just a title</title></head></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.title == "Just a title")
        #expect(result.thumbnailURL == nil)
    }

    @Test("page with image but no title: thumbnailURL set, title nil")
    func imageNoTitle() {
        let html = """
        <html><head>
        <meta property="og:image" content="https://cdn.example.com/x.jpg">
        </head></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.title == nil)
        #expect(result.thumbnailURL?.absoluteString == "https://cdn.example.com/x.jpg")
    }

    @Test("non-http(s) image URLs (data:, javascript:) are rejected")
    func rejectNonHttpImages() {
        let html = """
        <html><head>
        <title>x</title>
        <meta property="og:image" content="data:image/svg+xml;base64,PHN2Zw==">
        </head></html>
        """
        let result = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(result.thumbnailURL == nil)
    }

    @Test("HTML entity decoder: common entities")
    func entityDecoder() {
        let cases: [(String, String)] = [
            ("plain", "plain"),
            ("&amp;", "&"),
            ("&lt;hr&gt;", "<hr>"),
            ("&quot;hi&quot;", "\"hi\""),
            ("it&#39;s", "it's"),
            ("a&nbsp;b", "a b"),
            ("&amp;&amp;", "&&"),
        ]
        for (input, expected) in cases {
            #expect(LinkMetadataFetcher.decodeHTMLEntities(input) == expected, "\(input) → \(expected)")
        }
    }
}
