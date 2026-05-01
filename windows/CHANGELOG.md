# cpdb-win Changelog

Per-version notes for the Windows port. The Mac side lives in
[../CHANGELOG.md](../CHANGELOG.md). Windows ships independently
(1.x.x line) and is feature-gated against
[`docs/parity.md`](../docs/parity.md) — every entry below
should also flip a row in that scoreboard.

The `[Unreleased]` section accumulates between cuts. When we tag a
release via `windows/release-installer.ps1`, move it under a
dated `[1.X.Y]` heading and reset `[Unreleased]` to empty.

## [Unreleased]

- **`cpdb-win` maintenance CLI.** New console executable
  (`CpdbWin.Cli` project, output `cpdb-win.exe`) ships alongside
  the GUI app. Three subcommands implemented in v1:
  - `cpdb-win reclassify-kinds` — re-applies the current
    `KindClassifier` to every live row; updates kind on drift,
    resets link backfill state on text→link drift.
  - `cpdb-win backfill-titles --retry-empty` — clears
    `link_fetched_at` + retry counters for kind=link rows that
    settled with null/empty title.
  - `cpdb-win dedupe --links-all-time` — collapses live link
    rows that share a `text_preview` URL; salvages `link_title`
    from a sibling before tombstoning so the survivor inherits
    a populated title.

  Implementation lives in `CpdbWin.Core.Maintenance.MaintenanceCommands`
  so the same helpers can be invoked from the GUI later (e.g. a
  Preferences "Run maintenance" button). All operations are
  idempotent and safe to run while the GUI is up — WAL mode
  serializes the writes.
- **Hover tooltips on row cards.** Each entry in the popup list
  now shows a `ToolTipService.ToolTip` with the entry kind, the
  source app's display name (or bundle id when not resolved),
  and the absolute capture timestamp. Skips the originating-
  device line — Windows is standalone in v1 (no sync substrate
  yet). Mirrors macOS v2.7.12.
- **Reddit JSON API path.** URLs matching `/r/<sub>/comments/<id>/…`
  now route through `https://www.reddit.com/r/<sub>/comments/<id>.json`
  for clean title + thumbnail JSON without scraping the comment
  page (which Reddit gates with a CAPTCHA for non-logged-in users).
  Sentinel `thumbnail` values (`self`, `default`, `spoiler`, `nsfw`,
  empty string) are rejected. Falls through to the generic HTML
  scrape on any error so a malformed Reddit URL doesn't dead-end.
- **Bot-check / CAPTCHA rejection.** Cloudflare, DataDome, and
  Akamai bot-mitigation interstitials serve a 200 OK page with a
  giveaway title — "Just a moment…", "Attention Required!", "Please
  verify you are human", etc. After title extraction we now match
  the title against ten such substrings (case-insensitive) and
  classify as transient on a hit, so the row stays a backfill
  candidate and the backoff window gives the rate-limiter time to
  forget us.

## [1.5.0] – 2026-04-30

- **Link entries get thumbnails.** When the metadata fetcher
  resolves an og:image / twitter:image / Wikipedia REST API
  thumbnail / favicon URL, the bytes are downloaded (≤ 4 MB),
  handed to `Thumbnailer`, and written to the `previews` table.
  The card's left thumbnail slot now renders for kind=link rows
  in addition to kind=image. Best-effort: 4xx / oversized /
  non-image / decode failures leave the row settled-without-
  thumbnail rather than tearing down the cycle.
- **Dedicated detail-pane layout for kind=link.** Selecting a
  link entry now shows a stacked layout — fetched title (16pt,
  semi-bold) on top, og:image thumbnail centered (capped 320px
  tall), URL HyperlinkButton at the bottom. Replaces the
  previous fall-through where link rows used the same TextBlock
  as plain-text entries.

## [1.4.0] – 2026-04-30

- **URL-shaped plain text → kind=link.** Edge / Chrome's "Copy
  address" command writes only `public.utf8-plain-text` (no
  `public.url`); the new heuristic in `KindClassifier.LooksLikeUrl`
  classifies these as kind=link so the metadata backfill loop
  picks them up. Conservative: ≤ 2 KB, no embedded whitespace,
  scheme `http`/`https`, non-null host.
- **Reclassify-on-bump.** When a content-hash dedup bumps an
  existing row, `Ingestor.Ingest` now compares the new
  classification against the stored kind. On a `text → link`
  drift, the row's kind is updated AND its
  `link_title` / `link_fetched_at` / `link_retry_count` /
  `link_retry_after` are reset so the next backfill cycle picks
  it up. Mirrors macOS v2.7.14.
- **Live UI refresh as titles fetch.** `MainWindow` subscribes
  to `LinkBackfillService.RowSettled` and dispatches `Refresh()`
  so freshly-fetched titles appear in the list within a few
  seconds of the capture.
- **First-run autostart on by default + paste-back.** New
  installs enable the `HKCU\…\Run` autostart entry once on first
  launch (idempotent — disabling it from the tray menu sticks).
  The paste-back path captures the foreground HWND when the
  window is summoned, then on Enter restores it and synthesizes
  Ctrl+V via `SendInput` so the just-copied flavor pastes into
  the originating app in a single gesture.
- **Browser-shaped User-Agent.** Bumped from
  `… cpdb-link-fetcher/1.0` to a plain Chromium-on-Windows UA so
  NYT / CNN / Cloudflare-fronted publishers stop 403'ing us. We
  pull `og:title` honestly; the UA is the cheapest route past
  the most common bot blocks (separate from the post-extraction
  bot-check matcher in [Unreleased]).
- **WinAppSDK 1.5 → 1.8.** Matches the runtime that ships with
  recent Windows 11 builds. Removed the custom `Program.cs` /
  `DISABLE_XAML_GENERATED_MAIN` shim that was breaking on 1.8;
  Velopack's install/update args are now intercepted at the top
  of `App.OnLaunched`.

## [1.3.0] – 2026-04-30

- **Link-metadata backfill loop.** New
  `CpdbWin.Core.Analysis.LinkBackfillService` drives the
  fetcher: a 15-minute periodic timer, a capture-wake hook that
  fires a 5-row batch on every kind=link insert, an
  `IConnectivityProbe` gate (default
  `NetworkInterface.GetIsNetworkAvailable`), an offline→online
  catch-up via `NetworkChange.NetworkAvailabilityChanged`, and
  a `SemaphoreSlim` reentry guard so concurrent triggers
  coalesce. Outcome dispatch matches the schema contract:
  Success → SettleLink; Permanent → SettleLink(null);
  Transient → BumpLinkRetry.
- **`LinkMetadataFetcher`.** YouTube oEmbed →
  generic HTML scrape (`og:title` → `twitter:title` → `<title>`)
  → Wikipedia REST API thumbnail fallback for
  `*.wikipedia.org` → favicon last-resort. HTTP body capped at
  256 KB, thumbnail bytes capped at 4 MB. HTTP 403 / 408 / 425 /
  429 / 5xx + network exceptions → Transient; 4xx / decode /
  malformed URL → Permanent.

## [1.2.0] – 2026-04-30

- **Schema v8 + v9.** `entries` gains `link_title`,
  `link_fetched_at` (v8), `link_retry_count`, `link_retry_after`
  (v9). FTS5 dropped + rebuilt with `link_title` as the 6th
  indexed column; every live row reindexed in the same migration.
  `body_evicted_at` (v7) reserved as a no-op column so the union
  DDL stays bit-compatible with macOS v9 schemas.
- **EntryRepository link backfill plumbing.**
  `NextLinkBackfillCandidates(limit, now)` (gates on
  `kind='link' AND deleted_at IS NULL AND link_fetched_at IS
  NULL AND text_preview LIKE 'http%' AND link_retry_count <
  MAX_RETRIES AND (link_retry_after IS NULL OR <= now)` and
  orders by `created_at DESC`); `SettleLink(id, title?)` for
  success and permanent give-up; `BumpLinkRetry(id, now?)` with
  `60·min(60, 2^count)` backoff (cap = 60 min after 6 attempts).

## [1.1.0] – 2026-04-28

- **Pinning.** `entries.pinned` schema column + `idx_entries_pinned`
  partial index + sort-order semantics (`ORDER BY pinned DESC,
  created_at DESC`). Right-click → Pin / Unpin in the row
  context menu; multi-selection toggles every selected row to
  the same target state.

## [1.0.0] – 2026-04-25

- Initial cpdb-win release. WinUI 3 desktop app + tray icon,
  hotkey (Ctrl+Shift+V) to summon the search popup, full
  capture pipeline (clipboard listener → flavor classification
  → SQLite), FTS5 search, kind-filter chips, Velopack installer.
