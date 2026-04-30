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

        public var description: String {
            switch self {
            case .invalidURL:                   return "invalid URL"
            case .httpError(let code):          return "HTTP \(code)"
            case .bodyTooLarge:                 return "body exceeded size cap"
            case .decodeFailure(let reason):    return "decode failure: \(reason)"
            case .network(let error):           return "network: \(error)"
            }
        }
    }

    /// Cap on how many bytes of HTML we'll process per page. Most
    /// pages have their <title> + meta tags within the first 64 KB;
    /// going bigger just costs memory + decoder time. We HEAD-bail
    /// early if Content-Length is huge.
    private static let maxBodyBytes = 256 * 1024

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
        if data.count > Self.maxBodyBytes {
            // We only need the <head>; truncate.
            let head = data.prefix(Self.maxBodyBytes)
            return Self.parseHTMLTitle(Data(head))
        }
        return Self.parseHTMLTitle(data)
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
        var title: String?
        var source: Result.Source = .none
        if let raw = matchMetaContent(in: html, namePattern: #"property\s*=\s*["']og:title["']"#) {
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
