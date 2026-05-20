# Hand-off: WordPress-aware link-title precedence (macOS port)

> **Origin:** Windows v1.30.0 ([PR #36](https://github.com/phubbard/CopyPasteDataBase/pull/36),
> merged 2026-05-20). The Mac side has the same bug; this doc briefs
> the macOS Claude session so it can port the fix and close the
> parity deviation that `docs/parity.md` currently records.

## TL;DR

The link-metadata title precedence (`og:title → twitter:title →
<title>`) is correct for most sites and matches macOS Vision's
social-card-friendly assumptions. **WordPress themes systematically
invert the convention**: they put the bare post slug in `og:title`
and the rich `"Title – Tagline"` form in `<title>`. So our default
precedence picks the short bare slug and stops, losing the tagline
on roughly **40-60% of the public web**.

Fix on macOS:

1. Detect WordPress via `<meta name="generator" content="WordPress…">`
   (covers WordPress.com and self-hosted, both attribute orders,
   case-insensitive).
2. For detected WP pages, reverse the precedence to
   `<title>` → `og:title` → `twitter:title`.
3. Non-WP pages keep the default order.

## The bug — real case

Pasting `https://ultracrepidarian.phfactor.net/` settled
`link_title` as just `"ultracrepidarian"`. The page actually carries:

| tag                  | value                                                                                                                          |
|----------------------|--------------------------------------------------------------------------------------------------------------------------------|
| `<meta name="generator" content="WordPress.com">` | (the WP fingerprint we want to match)                                                |
| `<meta property="og:title" content="…">`           | `ultracrepidarian` *(bare slug)*                                                     |
| `<title>…</title>`                                  | `ultracrepidarian – ultracrepidarian: a person who criticizes, judges, or gives advice outside the area of his or her expertise.` |

`og:title`-first picks the short one. With WP detection, we'd take
the rich `<title>` instead.

## Where the code lives on macOS

- **File:** `Sources/CpdbShared/Analysis/LinkMetadataFetcher.swift`
- **Function:** `parseHTMLTitle(_ data: Data) -> Result` (around line 521)
- **Helpers nearby:** `matchMetaContent`, `matchTitleTag`,
  `decodeHTMLEntities` — keep using them; no new infrastructure
  needed.

## Suggested implementation (Swift)

Add near the other matcher helpers (case-insensitive regex; matches
both attribute orders):

```swift
/// True when `html` looks like a WordPress page via its standard
/// generator meta tag — covers both WordPress.com
/// (`content="WordPress.com"`) and self-hosted
/// (`content="WordPress <version>"`) in either attribute order.
/// Used by `parseHTMLTitle` to flip the title-source preference
/// (rich `<title>` over short `og:title`).
static func looksLikeWordPress(_ html: String) -> Bool {
    let pattern = #"<meta[^>]+(?:name\s*=\s*["']generator["'][^>]+content\s*=\s*["']\s*WordPress|content\s*=\s*["']\s*WordPress[^"']*["'][^>]+name\s*=\s*["']generator["'])"#
    return html.range(
        of: pattern,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}
```

Then in `parseHTMLTitle`, before the existing `og:title` check:

```swift
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
```

Note the fallthrough: a WP page **without** a `<title>` still
yields `og:title` via the existing path, so the WP branch never
makes things worse than today.

Thumbnail resolution stays unchanged.

## Tests to mirror (XCTest)

Five cases on the Windows side; port directly. File on Windows:
`windows/CpdbWin.Core.Tests/LinkMetadataParserTests.cs`. On macOS
the equivalent is `Tests/CpdbCoreTests/LinkMetadataFetcherTests.swift`
(or wherever `parseHTMLTitle` is currently tested).

1. **`Parse_WordPress_PrefersRichTitleTagOverShortOgTitle`** — exact
   `ultracrepidarian` shape (generator=WordPress.com, og:title
   "ultracrepidarian", `<title>` "ultracrepidarian – …"). Assert
   the rich `<title>` value wins and `source == .htmlTitleTag`.

2. **`Parse_SelfHostedWordPress_AlsoTriggersTitlePrecedence`** —
   `generator="WordPress 6.4.2"` (not the literal `.com` string).
   Same expectations.

3. **`Parse_WordPress_FallsBackToOgWhenTitleTagMissing`** — WP page
   with no `<title>` tag still yields `og:title` via the existing
   fall-through.

4. **`Parse_NonWordPress_KeepsOgTitleFirst`** — control: page with
   no generator tag must still pick `og:title` first.

5. **`LooksLikeWordPress_TruthTable`** — table-driven:

   | input                                                              | expected |
   |--------------------------------------------------------------------|----------|
   | `<meta name="generator" content="WordPress.com">`                  | true     |
   | `<meta name="generator" content="WordPress 6.4.2">`                | true     |
   | `<meta name="generator" content="wordpress">`                       | true     |
   | `<meta content="WordPress 5.9" name="generator">`                   | true     |
   | `<meta name="generator" content="Hugo 0.120.0">`                    | false    |
   | `<meta name="generator" content="Jekyll">`                          | false    |
   | `<meta name="author" content="WordPress fan">`                      | false    |
   | `""`                                                                | false    |

## Parity doc update

`docs/parity.md` currently reads (Windows-side fix landed in
v1.30.0; macOS still owes the port):

> Generic HTML title scrape (og:title → twitter:title → `<title>`)
> | ✅ v2.7.0 | — | ✅ v1.3.0 / WP-aware v1.30.0 | … **Windows v1.30.0
> deviation:** WordPress sites … reverse the order to `<title>` →
> og:title → twitter:title … macOS could adopt the same; not yet
> ported

When the Mac port lands, edit that row:

- Bump the macOS column from `✅ v2.7.0` to `✅ v2.7.0 / WP-aware
  v<your-version>`.
- Drop the "macOS could adopt the same; not yet ported" sentence.
- The Windows deviation language can stay or be removed —
  whichever reads cleaner once both sides match.

## Existing rows on Mac

Already-settled link titles in the bare-slug form aren't auto-
refreshed by this change; the row's `link_fetched_at` is non-null
so the backfill loop skips it. Two ways to recover for existing
rows:

1. **Per-row:** delete and re-paste the URL — fresh capture, new
   logic, rich title.
2. **Library-wide:** a "Refetch all link titles" maintenance
   action (clears `link_fetched_at` + `link_title` on every live
   `kind=link` row). macOS Preferences already has a "Refetch all"
   button in the link-metadata section — no new work needed.

Mention this in the macOS CHANGELOG entry so users know.

## Cross-platform impact

The deviation is currently in Windows' favour for WP pages. If the
two ports diverge for a long time, FTS5 indexed titles on a synced
library will differ between Mac and Windows for the same URL — not
a *bug* (the title is whatever the platform happened to settle),
but worth noting in the macOS commit message so reviewers don't
flag it as a contract violation. Once Mac lands the same logic
they converge again.

## Files touched on the Windows side (for reference)

- `windows/CpdbWin.Core/Analysis/LinkMetadataParser.cs` — added
  `LooksLikeWordPress` + WP branch in `Parse`.
- `windows/CpdbWin.Core.Tests/LinkMetadataParserTests.cs` — +5
  cases.
- `docs/parity.md` — row updated with the deviation note.
- `windows/CHANGELOG.md` — `[Unreleased]` entry under v1.30.0.
- `windows/Directory.Build.props` — version bump.
