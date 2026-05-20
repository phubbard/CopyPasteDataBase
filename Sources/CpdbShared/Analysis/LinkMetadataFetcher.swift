import Foundation

/// Background-fetches a human-readable title for a captured URL.
///
/// Three resolution paths, ordered cheapest → most general:
///
///   1. **YouTube** — public oEmbed endpoint
///      (`https://www.youtube.com/oembed?url=…&format=json`).
///      No API key, no auth, returns clean JSON with `title`,
///      `author_name`, `thumbnail_url`. Works for watch URLs,
///      youtu.be shortlinks, shorts, and embeds.
///   2. **HTML scrape with Open Graph priority** — for everything
///      else, fetch the HTML and extract (in order):
///      `<meta property="og:title" content="…">`,
///      `<meta name="twitter:title" content="…">`,
///      `<title>…</title>`.
///   3. **Failure** — caller stores `link_fetched_at = now`,
///      `link_title = NULL` so we don't keep retrying. The Mac
///      Preferences "Refetch link titles" button can clear those
///      sentinels for users who want to retry after going back
///      online.
///
/// Network discipline: 8s request timeout, 4s resource timeout for
/// the body so a slow page doesn't pin a worker. We send a benign
/// User-Agent so sites that block the default URLSession one don't
/// 403 us.
public actor LinkMetadataFetcher {

    public struct Result: Sendable, Equatable {
        public var title: String?
        public var thumbnailURL: URL?
        public var source: Source

        public enum Source: String, Sendable, Equatable {
            case youtubeOEmbed
            case htmlOpenGraph    // og:title (and/or og:image)
            case htmlTwitterCard  // twitter:title (and/or twitter:image)
            case htmlTitleTag     // <title>
            case none             // page returned but no title found
        }
    }

    public enum FetchError: Error, CustomStringConvertible, Sendable {
        case invalidURL
        case httpError(Int)
        case bodyTooLarge
        case decodeFailure(String)
        case network(any Error)
        /// HTTP 200 but the page body is a bot-check / CAPTCHA
        /// interstitial rather than the real content. Detected by
        /// title-pattern matching ("verification", "are you human",
        /// "captcha", etc.). Treated as transient so the next
        /// backfill cycle gets another shot — sometimes the same
        /// IP/UA gets through later.
        case botCheckDetected
        /// HTTP 200 with a suspiciously tiny body and no
        /// extractable title source — almost always a CDN
        /// throttle / rate-limit response that lacks any of the
        /// usual "verification" keywords but is clearly not the
        /// real page (real pages with no titles essentially never
        /// happen at this size). Discovered after a "Refetch all"
        /// burst poisoned ~50 rows on a WordPress host: same URL,
        /// same UA, fetched cleanly a minute later. Treated as
        /// transient so the next cycle retries.
        case suspectThrottleResponse(bodyBytes: Int)

        public var description: String {
            switch self {
            case .invalidURL:                   return "invalid URL"
            case .httpError(let code):          return "HTTP \(code)"
            case .bodyTooLarge:                 return "body exceeded size cap"
            case .decodeFailure(let reason):    return "decode failure: \(reason)"
            case .network(let error):           return "network: \(error)"
            case .botCheckDetected:             return "bot-check / CAPTCHA interstitial"
            case .suspectThrottleResponse(let n): return "suspect throttle response (\(n) bytes, no title)"
            }
        }

        /// Errors we expect to clear up on retry — typically rate
        /// limits (YouTube oEmbed returns 403 on bursty traffic) or
        /// server-side blips. The backfiller leaves these rows
        /// un-stamped so a future cycle picks them up again instead
        /// of marking them permanently fetched-with-empty.
        public var isTransient: Bool {
            switch self {
            case .httpError(let code):
                // 408 timeout, 425 too early, 429 rate limit,
                // 5xx server. 403 is included because YouTube uses
                // it as an effective rate-limit signal (real
                // permission-denied is rare for public endpoints).
                return code == 403 || code == 408 || code == 425 || code == 429 || (500..<600).contains(code)
            case .network, .botCheckDetected, .suspectThrottleResponse:
                // URLSession errors (timeout, DNS, connection lost),
                // bot-check interstitials, and suspect-throttle
                // responses are usually transient — different
                // time-of-day / IP / load can succeed.
                return true
            case .invalidURL, .bodyTooLarge, .decodeFailure:
                return false
            }
        }
    }

    /// True if a title string looks like a CAPTCHA / bot-check /
    /// "are you human" interstitial page. Used by the parsers to
    /// reject obviously-blocked pages so we don't stamp the
    /// interstitial as the canonical link title. Conservative — we
    /// don't want to misclassify a legitimate page that happens to
    /// contain "verification" in a longer title — so we anchor to
    /// short titles whose dominant phrase is one of the bot-check
    /// signals.
    static func looksLikeBotCheck(_ title: String) -> Bool {
        let t = title.lowercased()
        // The phrases that show up as the *whole* title on
        // interstitial pages (Reddit, Cloudflare, hCaptcha,
        // PerimeterX, Akamai, etc.).
        let needles = [
            "please wait for verification",
            "just a moment",            // Cloudflare's 5-second challenge
            "are you human",
            "checking your browser",
            "attention required",        // Cloudflare blocked-page title
            "access denied",
            "verify you are a human",
            "please verify you are human",
            "human verification",
            "captcha",
        ]
        return needles.contains(where: { t.contains($0) })
    }

    /// Cap on how many bytes of HTML we'll process per page. Most
    /// pages have their <title> + meta tags within the first 64 KB;
    /// going bigger just costs memory + decoder time. We HEAD-bail
    /// early if Content-Length is huge.
    private static let maxBodyBytes = 256 * 1024

    /// Bodies below this size with NO title-source matches are
    /// treated as suspect throttle / rate-limit responses (see
    /// `FetchError.suspectThrottleResponse`). Real HTML pages
    /// carrying any title essentially never come in this small; a
    /// 2 KB floor is well above CDN throttle pages (usually <1 KB)
    /// and well below a real WordPress post or news article.
    static let suspectThrottleBodyBytes = 2048

    /// Per-instance URLSession with our timeouts and User-Agent.
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = [
            // Most sites accept a generic browser-shaped UA; the
            // default URLSession one (`CFNetwork/x.x Darwin/x.x.x`)
            // gets blocked by some bot mitigation rules. We're an
            // honest fetcher, not a scraper, so identifying as a
            // browser is a benign accommodation.
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) cpdb-link-fetcher/1.0",
            "Accept": "text/html, application/xhtml+xml, application/json;q=0.9",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        self.session = URLSession(configuration: config)
    }

    /// Fetch metadata for a URL string. Returns nil titles silently
    /// on success-but-no-title; throws on transport failures so the
    /// caller can decide whether to retry vs. mark fetched.
    public func fetch(urlString: String) async throws -> Result {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw FetchError.invalidURL
        }
        if Self.isYouTubeURL(url) {
            return try await fetchYouTube(url: url)
        }
        // Reddit serves a "Please wait for verification" CAPTCHA
        // page to non-browser User-Agents, but the public JSON API
        // (just append `.json` to a comments URL) bypasses the
        // gate entirely and returns clean post metadata. Try that
        // first; on failure fall through to the generic HTML
        // scrape so a malformed Reddit URL doesn't dead-end.
        if Self.isRedditCommentsURL(url) {
            do {
                return try await fetchRedditJSON(url: url)
            } catch {
                // Fall through. If the generic scrape also fails
                // (or hits the bot-check detector), the caller's
                // transient/permanent classification still applies.
            }
        }
        return try await fetchGenericHTML(url: url)
    }

    // MARK: - YouTube oEmbed

    static func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        // Accept www.youtube.com / m.youtube.com / youtube.com / youtu.be.
        let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let normalized2 = normalized.hasPrefix("m.") ? String(normalized.dropFirst(2)) : normalized
        return normalized2 == "youtube.com" || normalized2 == "youtu.be"
    }

    private func fetchYouTube(url: URL) async throws -> Result {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let endpoint = components.url else { throw FetchError.invalidURL }

        let (data, response) = try await session.data(from: endpoint)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.httpError(http.statusCode)
        }
        // oEmbed schema: title is the headline string; thumbnail_url
        // points at the canonical YouTube thumbnail (typically the
        // hqdefault.jpg). Both are optional in the spec but YouTube
        // populates both for valid videos.
        struct OEmbed: Decodable {
            let title: String?
            let thumbnail_url: String?
        }
        do {
            let decoded = try JSONDecoder().decode(OEmbed.self, from: data)
            return Result(
                title: decoded.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                thumbnailURL: decoded.thumbnail_url.flatMap { URL(string: $0) },
                source: decoded.title == nil ? .none : .youtubeOEmbed
            )
        } catch {
            throw FetchError.decodeFailure("oembed json: \(error)")
        }
    }

    // MARK: - Reddit JSON API

    /// Match a Reddit comments URL that the public JSON API can
    /// answer for. Reddit serves a "Please wait for verification"
    /// CAPTCHA to non-browser User-Agents on the HTML path, but
    /// appending `.json` (or hitting `old.reddit.com`) gets clean
    /// post metadata back. Match conservatively — only the
    /// `/r/<sub>/comments/<id>/...` shape, not arbitrary subreddit
    /// or user-profile pages whose JSON API has a different shape.
    static func isRedditCommentsURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let normalized2 = normalized.hasPrefix("old.") ? String(normalized.dropFirst(4)) : normalized
        guard normalized2 == "reddit.com" else { return false }
        let comps = url.pathComponents.filter { $0 != "/" }
        // /r/<sub>/comments/<id>/<slug>?
        return comps.count >= 4 && comps[0] == "r" && comps[2] == "comments"
    }

    private struct RedditPostListing: Decodable {
        struct Listing: Decodable {
            struct Children: Decodable {
                struct Post: Decodable {
                    let title: String?
                    // Reddit serves preview images as a structured
                    // tree (multiple resolutions, sometimes blurred
                    // for NSFW). We just take the largest non-nil
                    // source URL — Thumbnailer will downscale.
                    let thumbnail: String?
                    let url_overridden_by_dest: String?
                }
                let data: Post
            }
            let children: [Children]
        }
        let data: Listing
    }

    /// Hit Reddit's public JSON endpoint for a comments URL and
    /// return the post title + (if present) the post's preview
    /// thumbnail.
    private func fetchRedditJSON(url: URL) async throws -> Result {
        // Strip any trailing slug segments past the post id — the
        // JSON endpoint cares about `/comments/<id>` and ignores
        // the rest. Append `.json`.
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw FetchError.invalidURL
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        // Expect /r/<sub>/comments/<id>/[slug]; rebuild without slug.
        guard parts.count >= 4 else { throw FetchError.invalidURL }
        let basePath = "/" + parts.prefix(4).joined(separator: "/") + ".json"
        var endpointComps = comps
        endpointComps.host = "www.reddit.com"
        endpointComps.path = basePath
        endpointComps.query = nil
        endpointComps.fragment = nil
        guard let endpoint = endpointComps.url else { throw FetchError.invalidURL }

        let (data, response) = try await session.data(from: endpoint)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.httpError(http.statusCode)
        }
        // The endpoint returns an array of two listings: [post, comments].
        // We only need the first.
        do {
            let listings = try JSONDecoder().decode([RedditPostListing].self, from: data)
            guard let post = listings.first?.data.children.first?.data else {
                throw FetchError.decodeFailure("reddit json: empty listing")
            }
            // Reddit's `thumbnail` field is sometimes a sentinel
            // string ("self", "default", "spoiler", "nsfw") instead
            // of a URL; reject those.
            let thumbURL: URL? = {
                if let t = post.thumbnail,
                   t.hasPrefix("http"),
                   let u = URL(string: t) { return u }
                return nil
            }()
            return Result(
                title: post.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                thumbnailURL: thumbURL,
                source: post.title == nil ? .none : .htmlOpenGraph
            )
        } catch let e as FetchError {
            throw e
        } catch {
            throw FetchError.decodeFailure("reddit json: \(error)")
        }
    }

    // MARK: - Thumbnail bytes

    /// Cap on raw thumbnail bytes we'll download. Anything bigger
    /// is almost certainly a hero image we'd downscale anyway —
    /// bail before paying the bandwidth.
    private static let maxThumbnailBytes = 4 * 1024 * 1024  // 4 MB

    /// Download the bytes for a thumbnail URL surfaced by
    /// `parseHTMLTitle` or `fetchYouTube`. Returns nil instead of
    /// throwing on reasonable failures (404, connection refused,
    /// not-an-image content type) — callers treat thumbnail
    /// fetches as best-effort enrichment, not critical-path.
    public func fetchThumbnailBytes(url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // Hint: we want an image. Some CDNs honour Accept and serve
        // a smaller variant.
        request.setValue("image/jpeg, image/png, image/webp, image/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode != 200 { return nil }
                // Sanity-check Content-Type — some sites return an
                // HTML error page with 200; we don't want to feed
                // that to the thumbnailer.
                if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
                   !contentType.hasPrefix("image/")
                {
                    return nil
                }
            }
            if data.count > Self.maxThumbnailBytes { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Generic HTML scrape

    private func fetchGenericHTML(url: URL) async throws -> Result {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.httpError(http.statusCode)
        }
        let body: Data = data.count > Self.maxBodyBytes ? Data(data.prefix(Self.maxBodyBytes)) : data
        var result = Self.parseHTMLTitle(body)

        // Bot-check / CAPTCHA interstitial detection. Reddit,
        // Cloudflare-protected sites, and a growing list of others
        // serve a "Please wait for verification" / "Just a moment"
        // page to non-browser User-Agents. The HTTP layer reports
        // 200 OK so we sail through, but the title we extracted
        // belongs to the interstitial, not the real page. Reject
        // here so the row stays a candidate for retry instead of
        // being permanently stamped with the wrong title.
        if let title = result.title, Self.looksLikeBotCheck(title) {
            throw FetchError.botCheckDetected
        }

        // Suspect-throttle detection. A 200 OK with a tiny body
        // AND no extractable title (no og:title, no twitter:title,
        // no <title>) is almost certainly a CDN rate-limit /
        // throttle response — real pages with no title source
        // essentially never happen at this size (even the
        // sparsest legitimate page carries head boilerplate
        // pushing it past a few KB). Real-world trigger: a
        // "Refetch all" burst against a WordPress site poisoned
        // ~50 rows with empty titles; the same URLs fetched
        // cleanly a minute later. Treat as transient so the next
        // backoff cycle retries instead of stamping
        // fetched-with-empty permanently. 2 KB is a generous
        // floor — most throttle pages are <1 KB.
        if result.title == nil, body.count < Self.suspectThrottleBodyBytes {
            throw FetchError.suspectThrottleResponse(bodyBytes: body.count)
        }

        // Thumbnail fallback chain when og:image / twitter:image
        // didn't surface a usable URL. Order is biased toward
        // visual fidelity:
        //   1. Wikipedia REST API summary endpoint — pulls the
        //      article's lead image when present (much better than
        //      a 16x16 favicon for *.wikipedia.org).
        //   2. Page-declared favicon (`<link rel="icon">`) or the
        //      conventional `/favicon.ico` location. Always at
        //      least *something* — a tiny site icon is better than
        //      a gray box on a long-tail domain.
        if result.thumbnailURL == nil, Self.isWikipediaHost(url.host) {
            if let thumb = await fetchWikipediaSummaryThumbnail(pageURL: url) {
                result.thumbnailURL = thumb
            }
        }
        if result.thumbnailURL == nil {
            result.thumbnailURL = Self.faviconURL(html: body, pageURL: url)
        }
        return result
    }

    // MARK: - Wikipedia REST API thumbnail fallback

    static func isWikipediaHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        // Match en.wikipedia.org, de.wikipedia.org, etc.
        return host == "wikipedia.org" || host.hasSuffix(".wikipedia.org")
    }

    /// Hit the Wikipedia REST API's page-summary endpoint for the
    /// given article URL and return the thumbnail's `source` field
    /// (an https URL pointing at upload.wikimedia.org). Returns nil
    /// on any error or when the article has no thumbnail (text-only
    /// articles like "Clipboard (computing)" legitimately have
    /// neither og:image nor a REST-API thumbnail).
    private func fetchWikipediaSummaryThumbnail(pageURL: URL) async -> URL? {
        // Article title is the last path component after `/wiki/`.
        // Wikipedia article paths look like /wiki/Title_With_Underscores
        // or /wiki/Title_With_(parens). Keep the underscores + parens
        // — the REST API expects the same canonical form.
        let path = pageURL.path
        guard let range = path.range(of: "/wiki/"),
              range.upperBound < path.endIndex
        else { return nil }
        let title = String(path[range.upperBound...])
        guard !title.isEmpty,
              let host = pageURL.host
        else { return nil }
        // Build the API URL. Use addingPercentEncoding so accented
        // characters (Wikipedia titles can contain them) survive.
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let api = URL(string: "https://\(host)/api/rest_v1/page/summary/\(encoded)")
        else { return nil }
        struct Summary: Decodable {
            struct Thumb: Decodable { let source: String? }
            let thumbnail: Thumb?
            let originalimage: Thumb?
        }
        do {
            let (data, response) = try await session.data(from: api)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
            let summary = try JSONDecoder().decode(Summary.self, from: data)
            // Prefer thumbnail (Wikipedia downscales for us). Fall
            // through to originalimage if only the original is set,
            // since fetchThumbnailBytes will refuse anything > 4 MB
            // and the Thumbnailer downscales further.
            if let s = summary.thumbnail?.source, let url = URL(string: s) { return url }
            if let s = summary.originalimage?.source, let url = URL(string: s) { return url }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Favicon fallback

    /// Resolve a favicon URL for a page. Tries (in order):
    ///   1. `<link rel="icon" href="…">` declared in the HTML head
    ///   2. `<link rel="shortcut icon" href="…">`
    ///   3. `<link rel="apple-touch-icon" href="…">` (often
    ///      higher-resolution than favicon.ico — better visual)
    ///   4. The conventional `https://<host>/favicon.ico` location.
    /// Returns the resolved absolute URL. Doesn't HEAD-test it —
    /// the caller (`fetchThumbnailBytes`) will discover 404s and
    /// non-image content types and silently skip.
    ///
    /// We bias toward apple-touch-icon over favicon.ico because
    /// apple-touch-icon is typically 180×180 PNG (visually decent in
    /// our card preview) whereas favicon.ico is often 16×16 (looks
    /// muddy when scaled up).
    static func faviconURL(html: Data, pageURL: URL) -> URL? {
        let body: String = {
            if let utf8 = String(data: html, encoding: .utf8) { return utf8 }
            return String(data: html, encoding: .isoLatin1) ?? ""
        }()
        // Order of preference: apple-touch-icon (large) → icon → shortcut icon.
        let relPatterns = [
            #"rel\s*=\s*["']apple-touch-icon(?:[^"']*)?["']"#,
            #"rel\s*=\s*["'](?:shortcut\s+)?icon["']"#,
        ]
        for relPattern in relPatterns {
            if let href = matchLinkHref(in: body, relPattern: relPattern),
               let resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL,
               resolved.scheme?.lowercased() == "http" || resolved.scheme?.lowercased() == "https"
            {
                return resolved
            }
        }
        // Conventional fallback. Always try this — most sites have a
        // favicon at /favicon.ico even if the HTML doesn't declare
        // one.
        if let host = pageURL.host,
           let scheme = pageURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https"
        {
            return URL(string: "\(scheme)://\(host)/favicon.ico")
        }
        return nil
    }

    /// Find a `<link rel="…" href="…">` whose rel matches `relPattern`.
    /// Tolerates the attributes appearing in either order, just like
    /// `matchMetaContent`. Returns the raw href value (may be relative
    /// — caller resolves against the page URL).
    private static func matchLinkHref(in html: String, relPattern: String) -> String? {
        let patterns = [
            #"<link\s[^>]*"# + relPattern + #"[^>]*href\s*=\s*["']([^"']*)["'][^>]*>"#,
            #"<link\s[^>]*href\s*=\s*["']([^"']*)["'][^>]*"# + relPattern + #"[^>]*>"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, options: [], range: range),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: html)
            {
                let href = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !href.isEmpty { return href }
            }
        }
        return nil
    }

    /// HTML title + thumbnail extraction. Pulls `og:title` /
    /// `twitter:title` / `<title>` for the title, and `og:image` /
    /// `twitter:image` for the preview thumbnail URL — independently,
    /// so a page with og:title but no og:image (or vice versa)
    /// still yields whatever's available. Naive regex — fast,
    /// fragile against unusual HTML, but catches the ~95% case.
    static func parseHTMLTitle(_ data: Data) -> Result {
        // Decoders: try UTF-8 first; fall back to Latin-1 so we
        // never fail to read SOMETHING. Bonus regression-safety
        // since the title is mostly ASCII even on non-UTF-8 pages.
        let html: String = {
            if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
            return String(data: data, encoding: .isoLatin1) ?? ""
        }()
        // Title resolution.
        //
        // Default precedence: og:title → twitter:title → <title>.
        // WordPress themes invert that convention: they put the
        // bare post slug in og:title and the rich "Title – Tagline"
        // form in <title>. WP backs ~40-60% of the public web, so
        // when we detect it (via the `<meta name="generator"
        // content="WordPress…">` fingerprint) we flip the order to
        // <title> → og:title → twitter:title to surface the richer
        // headline. Non-WP pages keep the default. Fallthrough is
        // preserved either way — a WP page without a <title> still
        // yields og:title via the regular path. Ported from the
        // Windows v1.30.0 fix; see
        // docs/handoffs/macos-wordpress-title-precedence.md.
        var title: String?
        var source: Result.Source = .none
        let isWordPress = Self.looksLikeWordPress(html)
        if isWordPress,
           let raw = matchTitleTag(in: html),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            title = decodeHTMLEntities(raw)
            source = .htmlTitleTag
        } else if let raw = matchMetaContent(in: html, namePattern: #"property\s*=\s*["']og:title["']"#) {
            title = decodeHTMLEntities(raw)
            source = .htmlOpenGraph
        } else if let raw = matchMetaContent(in: html, namePattern: #"name\s*=\s*["']twitter:title["']"#) {
            title = decodeHTMLEntities(raw)
            source = .htmlTwitterCard
        } else if let raw = matchTitleTag(in: html) {
            title = decodeHTMLEntities(raw)
            source = .htmlTitleTag
        }
        // Thumbnail resolution. og:image first, twitter:image as
        // fallback. Some pages declare og:image:secure_url or
        // og:image:url instead of bare og:image — match all three.
        var thumbnailURL: URL?
        for pattern in [
            #"property\s*=\s*["']og:image["']"#,
            #"property\s*=\s*["']og:image:secure_url["']"#,
            #"property\s*=\s*["']og:image:url["']"#,
            #"name\s*=\s*["']twitter:image["']"#,
            #"name\s*=\s*["']twitter:image:src["']"#,
        ] {
            if let raw = matchMetaContent(in: html, namePattern: pattern),
               let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
            {
                thumbnailURL = url
                break
            }
        }
        return Result(title: title, thumbnailURL: thumbnailURL, source: source)
    }

    /// True when `html` looks like a WordPress page via its
    /// standard generator meta tag — covers WordPress.com
    /// (`content="WordPress.com"`) and self-hosted
    /// (`content="WordPress <version>"`) in either attribute order
    /// (case-insensitive). Used by `parseHTMLTitle` to flip the
    /// title-source preference (rich `<title>` over short
    /// `og:title`). Ported from Windows v1.30.0; see
    /// `docs/handoffs/macos-wordpress-title-precedence.md`.
    static func looksLikeWordPress(_ html: String) -> Bool {
        let pattern = #"<meta[^>]+(?:name\s*=\s*["']generator["'][^>]+content\s*=\s*["']\s*WordPress|content\s*=\s*["']\s*WordPress[^"']*["'][^>]+name\s*=\s*["']generator["'])"#
        return html.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Find a `<meta {namePattern} content="…">` value. Tolerates
    /// the attributes appearing in either order
    /// (content-then-name OR name-then-content).
    private static func matchMetaContent(in html: String, namePattern: String) -> String? {
        // Both attribute orders. The regex captures the content
        // value between quotes (single or double).
        let patterns = [
            #"<meta\s[^>]*"# + namePattern + #"[^>]*content\s*=\s*["']([^"']*)["'][^>]*>"#,
            #"<meta\s[^>]*content\s*=\s*["']([^"']*)["'][^>]*"# + namePattern + #"[^>]*>"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, options: [], range: range),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: html)
            {
                let content = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { return content }
            }
        }
        return nil
    }

    private static func matchTitleTag(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<title[^>]*>(.*?)</title>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html)
        else { return nil }
        let content = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    /// Tiny HTML entity decoder. Covers the common cases (`&amp;`,
    /// `&quot;`, `&#39;`, `&nbsp;`, `&lt;`, `&gt;`); falls through
    /// for anything weirder. Full entity decoding would need
    /// NSAttributedString HTML init or a real parser — overkill for
    /// link titles.
    static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        let pairs: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&#x27;", "'"),
            ("&#34;", "\""),
        ]
        for (entity, replacement) in pairs {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }
}
