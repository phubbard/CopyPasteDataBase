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

    @Test("Reddit comments URL detection")
    func redditCommentsDetection() {
        #expect(LinkMetadataFetcher.isRedditCommentsURL(URL(string: "https://www.reddit.com/r/MLV/comments/1sy973g/title/")!))
        #expect(LinkMetadataFetcher.isRedditCommentsURL(URL(string: "https://reddit.com/r/MLV/comments/1sy973g/")!))
        #expect(LinkMetadataFetcher.isRedditCommentsURL(URL(string: "https://old.reddit.com/r/MLV/comments/1sy973g/title/")!))
        // Non-comments Reddit pages should miss
        #expect(!LinkMetadataFetcher.isRedditCommentsURL(URL(string: "https://www.reddit.com/r/MLV/")!))
        #expect(!LinkMetadataFetcher.isRedditCommentsURL(URL(string: "https://www.reddit.com/user/foo")!))
        // Other hosts
        #expect(!LinkMetadataFetcher.isRedditCommentsURL(URL(string: "https://example.com/r/MLV/comments/x/")!))
    }

    @Test("Bot-check title patterns")
    func botCheckDetection() {
        // Real Reddit interstitial title we hit in production
        #expect(LinkMetadataFetcher.looksLikeBotCheck("Reddit - Please wait for verification"))
        // Cloudflare's two flavours
        #expect(LinkMetadataFetcher.looksLikeBotCheck("Just a moment..."))
        #expect(LinkMetadataFetcher.looksLikeBotCheck("Attention Required! | Cloudflare"))
        // Generic captcha gates
        #expect(LinkMetadataFetcher.looksLikeBotCheck("Are you human?"))
        #expect(LinkMetadataFetcher.looksLikeBotCheck("Please verify you are human"))
        // Real titles must NOT match
        #expect(!LinkMetadataFetcher.looksLikeBotCheck("Santa Cruz Vala — first ride review"))
        #expect(!LinkMetadataFetcher.looksLikeBotCheck("Linux — Wikipedia"))
        #expect(!LinkMetadataFetcher.looksLikeBotCheck(""))
    }

    @Test("Wikipedia host detection")
    func wikipediaHostDetection() {
        #expect(LinkMetadataFetcher.isWikipediaHost("en.wikipedia.org"))
        #expect(LinkMetadataFetcher.isWikipediaHost("de.wikipedia.org"))
        #expect(LinkMetadataFetcher.isWikipediaHost("WIKIPEDIA.ORG"))
        #expect(LinkMetadataFetcher.isWikipediaHost("wikipedia.org"))
        // Not Wikipedia
        #expect(!LinkMetadataFetcher.isWikipediaHost("notwikipedia.org"))
        #expect(!LinkMetadataFetcher.isWikipediaHost("wikipedia.org.evil.example"))
        #expect(!LinkMetadataFetcher.isWikipediaHost(nil))
    }

    @Test("Favicon: apple-touch-icon preferred over plain icon")
    func faviconAppleTouchPreferred() {
        let html = """
        <html><head>
        <link rel="icon" href="/favicon.ico">
        <link rel="apple-touch-icon" href="/touch-icon-180.png">
        </head></html>
        """
        let url = LinkMetadataFetcher.faviconURL(
            html: html.data(using: .utf8)!,
            pageURL: URL(string: "https://example.com/page")!
        )
        #expect(url?.absoluteString == "https://example.com/touch-icon-180.png")
    }

    @Test("Favicon: <link rel='icon'> resolved against page URL")
    func faviconLinkRelResolved() {
        let html = """
        <html><head><link rel="icon" href="/static/icon.png"></head></html>
        """
        let url = LinkMetadataFetcher.faviconURL(
            html: html.data(using: .utf8)!,
            pageURL: URL(string: "https://example.com/some/page")!
        )
        #expect(url?.absoluteString == "https://example.com/static/icon.png")
    }

    @Test("Favicon: falls back to /favicon.ico when no <link> declared")
    func faviconConventionalFallback() {
        let html = "<html><head></head><body></body></html>"
        let url = LinkMetadataFetcher.faviconURL(
            html: html.data(using: .utf8)!,
            pageURL: URL(string: "https://example.com/long/path/here")!
        )
        #expect(url?.absoluteString == "https://example.com/favicon.ico")
    }

    @Test("Favicon: 'shortcut icon' rel value also recognised")
    func faviconShortcutIconRel() {
        let html = """
        <html><head><link rel="shortcut icon" href="/favicon.png"></head></html>
        """
        let url = LinkMetadataFetcher.faviconURL(
            html: html.data(using: .utf8)!,
            pageURL: URL(string: "https://example.com/")!
        )
        #expect(url?.absoluteString == "https://example.com/favicon.png")
    }

    @Test("Favicon: absolute URL in href used directly")
    func faviconAbsoluteHref() {
        let html = """
        <html><head><link rel="apple-touch-icon" href="https://cdn.example.net/icon.png"></head></html>
        """
        let url = LinkMetadataFetcher.faviconURL(
            html: html.data(using: .utf8)!,
            pageURL: URL(string: "https://example.com/")!
        )
        #expect(url?.absoluteString == "https://cdn.example.net/icon.png")
    }

    // MARK: - WordPress-aware title precedence (ported from Windows v1.30.0)
    // Contract: docs/handoffs/macos-wordpress-title-precedence.md.
    // WP themes put the bare slug in og:title and "Title – Tagline" in
    // <title>, so on detected WP pages parseHTMLTitle flips to
    // <title> → og:title → twitter:title. Non-WP unaffected.

    @Test("WordPress: rich <title> beats short og:title")
    func wordpressPrefersRichTitleTagOverShortOgTitle() {
        let html = """
        <html><head>
        <meta name="generator" content="WordPress.com">
        <meta property="og:title" content="ultracrepidarian">
        <title>ultracrepidarian – ultracrepidarian: a person who criticizes outside their expertise.</title>
        </head></html>
        """
        let r = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(r.title?.hasPrefix("ultracrepidarian – ") == true)
        #expect(r.source == .htmlTitleTag)
    }

    @Test("WordPress: self-hosted generator string also triggers precedence flip")
    func selfHostedWordPressAlsoTriggers() {
        let html = """
        <html><head>
        <meta name="generator" content="WordPress 6.4.2">
        <meta property="og:title" content="short slug">
        <title>Rich Title – With Tagline</title>
        </head></html>
        """
        let r = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(r.title == "Rich Title – With Tagline")
        #expect(r.source == .htmlTitleTag)
    }

    @Test("WordPress: falls back to og:title when <title> missing")
    func wordpressFallsBackToOgWhenTitleTagMissing() {
        let html = """
        <html><head>
        <meta name="generator" content="WordPress.com">
        <meta property="og:title" content="only og has it">
        </head></html>
        """
        let r = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(r.title == "only og has it")
        #expect(r.source == .htmlOpenGraph)
    }

    @Test("Non-WordPress: keeps og:title first")
    func nonWordPressKeepsOgFirst() {
        let html = """
        <html><head>
        <meta property="og:title" content="og wins">
        <title>title loses</title>
        </head></html>
        """
        let r = LinkMetadataFetcher.parseHTMLTitle(data(html))
        #expect(r.title == "og wins")
        #expect(r.source == .htmlOpenGraph)
    }

    @Test("looksLikeWordPress: truth table")
    func looksLikeWordPressTruthTable() {
        let cases: [(html: String, expected: Bool, label: String)] = [
            (#"<meta name="generator" content="WordPress.com">"#,           true,  "WP.com"),
            (#"<meta name="generator" content="WordPress 6.4.2">"#,         true,  "self-hosted versioned"),
            (#"<meta name="generator" content="wordpress">"#,               true,  "lowercase"),
            (#"<meta content="WordPress 5.9" name="generator">"#,           true,  "attr order reversed"),
            (#"<meta name="generator" content="Hugo 0.120.0">"#,            false, "Hugo"),
            (#"<meta name="generator" content="Jekyll">"#,                  false, "Jekyll"),
            (#"<meta name="author" content="WordPress fan">"#,              false, "WP in author, not generator"),
            ("",                                                            false, "empty"),
        ]
        for c in cases {
            #expect(
                LinkMetadataFetcher.looksLikeWordPress(c.html) == c.expected,
                "\(c.label) → expected \(c.expected)"
            )
        }
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
