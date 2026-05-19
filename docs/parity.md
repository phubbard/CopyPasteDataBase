# Cross-platform parity scoreboard

Single source of truth for what's implemented where. Update this
file in the same commit as the feature lands, on whichever platform.

`docs/schema.md` is the authoritative behavior contract for every
feature in this table — the per-platform implementation is judged
against the contract there, not against another platform's source.

Legend:

- ✅ implemented and shipping
- ⏳ planned / next-up for that platform
- — not applicable on that platform (architectural decision, not a
  TODO)

## Capture & ingest

| Feature | macOS | iOS | Windows | Contract / notes |
|---|---|---|---|---|
| Capture daemon | ✅ v1.0 | — | ✅ v1.0 | iOS doesn't capture (privacy decision) |
| FTS5 search index | ✅ v1.0 | ✅ v2.5 | ✅ v1.0 | tokenizer chain in `docs/schema.md` § FTS5 |
| Canonical content_hash | ✅ v1.0 | ✅ v2.5 | ✅ v1.0 | byte-exact algorithm in `docs/schema.md` § Canonical hash; pinned vectors in `Tests/CpdbCoreTests/HashVectors.swift` |
| Inline / blob spillover (256 KB) | ✅ v1.0 | ✅ v2.5 | ✅ v1.0 | rule in `docs/schema.md` § Blob store |
| Kind classification | ✅ v1.0 | ✅ v2.5 | ✅ v1.0 | rules + Windows-clipboard-format → UTI table in `docs/schema.md` § Kind classification |
| OCR + image tags | ✅ v1.2 (Vision) | ✅ v2.5 | ⏳ | Windows: `Windows.Media.Ocr` is the planned engine; image classifier still TBD (no built-in equivalent of Vision's `VNClassifyImageRequest`) |
| Password-manager blocklist | ✅ v1.2.1 | — | ✅ | block by source-app identifier; Apple-Strong-Password shape heuristic (Apple-only) |
| `nspasteboard.org` transient markers | ✅ v1.0 | — | — | Apple-only convention |

## Search & UI

| Feature | macOS | iOS | Windows | Contract / notes |
|---|---|---|---|---|
| Per-column scope toggles (text / OCR / tags) | ✅ v1.2 | ✅ v2.5 | ⏳ | scope is a Set passed into `EntryRepository.search`; matches at the FTS5 column-filter level |
| Kind-filter chips | ✅ v2.5 (popup) | ✅ v2.5 | ✅ v2.5.7 | filter persists in user preferences |
| Quick Look / preview | ✅ v1.3 (QLPreviewPanel) | ✅ v2.5 (sheet) | ⏳ | Windows: image viewer + inline text panel per `cpdb v2.0` plan |
| Match-source badges | ✅ v1.2 | — | ⏳ | small chip on cards when hit comes from non-text column |
| Domain badge on browser-image entries | ✅ v2.5.7 | — | ✅ | inline `🌐 host.tld` overlay; data driven by `text_preview` parsed as URL |

## Sync

| Feature | macOS | iOS | Windows | Contract / notes |
|---|---|---|---|---|
| CloudKit Private Database sync | ✅ v2.0 | ✅ v2.5 | — | Apple-only substrate; Windows v1 is standalone |
| Content-addressed CKRecord IDs | ✅ v2.0 | ✅ v2.5 | — | wire-format v2.1; recordName = `entry-<sha256-hex>` |
| Cross-device dedup (Universal Clipboard echo) | ✅ v2.5.2 | — | — | Apple-specific marker; strip in `PasteboardSnapshot` before hashing |
| Push-to-device (`ActionRequest`) | ✅ v2.5 (consume) | ✅ v2.5 (send) | — | iOS → Mac paste flow |
| Cross-platform sync substrate | ⏳ planned | ⏳ planned | ⏳ planned | brainstorm in earlier session — Cloudflare Worker + HMAC; not yet started |

## Link metadata enrichment (v2.7 → v2.8 series)

| Feature | macOS | iOS | Windows | Contract / notes |
|---|---|---|---|---|
| `entries.link_title` + `link_fetched_at` columns | ✅ v2.7.0 | ✅ v2.7.0 | ✅ v1.2.0 | schema v8; FTS5 also gains a `link_title` indexed column |
| `entries.link_retry_count` + `link_retry_after` columns | ✅ v2.8.2 | ✅ v2.8.2 | ✅ v1.2.0 | schema v9; semantics in `docs/schema.md` § Link metadata retry |
| YouTube oEmbed title fetch | ✅ v2.7.0 | — | ✅ v1.3.0 | iOS reads via CloudKit; doesn't fetch. Windows: hits `https://www.youtube.com/oembed?url=…&format=json`. Standalone in v1, no sync |
| Generic HTML title scrape (og:title → twitter:title → `<title>`) | ✅ v2.7.0 | — | ✅ v1.3.0 | regex-based, see `windows/CpdbWin.Core/Analysis/LinkMetadataParser.cs` |
| Preview thumbnails: og:image / twitter:image | ✅ v2.7.1 | ✅ v2.7.1 (read) | ✅ v1.5.0 | `LinkBackfillService.TryAttachThumbnailAsync` downloads bytes, hands to `Thumbnailer`, writes to `previews` table. Best-effort: 404s / decode failures leave the entry without a preview rather than failing the settle. |
| Wikipedia REST API thumbnail fallback | ✅ v2.7.13 | — | ✅ v1.3.0 | hits `/api/rest_v1/page/summary/<title>` for `*.wikipedia.org` URLs lacking og:image |
| Favicon thumbnail fallback (apple-touch-icon → icon → `/favicon.ico`) | ✅ v2.7.13 | — | ✅ v1.3.0 | last-resort thumb when nothing else works |
| URL-shaped plain text → kind=link classification | ✅ v2.7.11 | ✅ v2.7.11 | ✅ v1.4.0 | covers Edge / Chrome "Copy address" writes that omit `public.url`. Heuristic in `KindClassifier.LooksLikeUrl` |
| Reclassify-on-bump (kind drift after heuristic update) | ✅ v2.7.14 | — | ✅ v1.4.0 | when content_hash dedup bumps an existing row, compare new vs stored kind, update + reset link backfill state on text→link drift |
| `cpdb reclassify-kinds` migration | ✅ v2.7.14 | — | ✅ v1.7.0 | one-shot retroactive cleanup. Windows: `cpdb-win reclassify-kinds` |
| Capture-wake immediate enrichment | ✅ v2.7.10 | — | ✅ v1.3.0 | fire 5-row backfill on every link capture. Windows: AppHost subscribes to `CaptureService.Ingested` and routes kind=link inserts/bumps to `LinkBackfillService.WakeForCapture` |
| Live popup card updates while backfill runs | ✅ v2.7.10 | ✅ v2.5 (live updates) | ✅ v1.4.0 | MainWindow subscribes to `LinkBackfillService.RowSettled` and re-renders via dispatcher |
| Capture-wake gates on kind=link | ✅ v2.7.11 | — | ✅ v1.3.0 | text/image/file captures don't pointlessly fire link backfill |
| Transient error classification | ✅ v2.7.7 | — | ✅ v1.3.0 | HTTP 403/408/425/429/5xx + network errors are transient; don't stamp `link_fetched_at` |
| Exponential backoff (1·2^count min, cap 60 min) | ✅ v2.8.2 | — | ✅ v1.2.0 | contract: `docs/schema.md` § Link metadata retry. 6-attempt cap |
| Reachability gate before fetches | ✅ v2.8.2 | — | ✅ v1.3.0 | mac: `NWPathMonitor`. Windows: `IConnectivityProbe` (default `NetworkInterface.GetIsNetworkAvailable`) |
| Online-edge catch-up wake | ✅ v2.8.2 | — | ✅ v1.3.0 | network transitions offline→online → fire backfill batch via `NetworkChange.NetworkAvailabilityChanged` |
| "Retry empties" targeted refetch | ✅ v2.7.8 | — | ✅ v1.7.0 | only clears sentinels for rows whose `link_title` is null/empty. Windows: `cpdb-win backfill-titles --retry-empty` |
| Hover tooltips on cards (source app, device, timestamp) | ✅ v2.7.12 | — | ✅ v1.7.0 | uses WinUI `ToolTipService.ToolTip`; surfaces type / source app / capture timestamp. Skips device line (Windows is standalone in v1) |
| Bot-check / CAPTCHA detection (transient classification) | ✅ v2.8.6 | — | ✅ v1.6.0 | reject titles like "Please wait for verification", "Just a moment…", "Attention Required!", "Are you human?", etc. as transient (don't stamp link_fetched_at). Pattern list in `LinkMetadataFetcher.LooksLikeBotCheck` (10 substrings, case-insensitive) |
| Reddit `.json` API path | ✅ v2.8.6 | — | ✅ v1.6.0 | URLs matching `/r/<sub>/comments/<id>/…` route through `https://www.reddit.com/r/<sub>/comments/<id>.json` (bypasses CAPTCHA gate). Sentinel `thumbnail` values ("self"/"default"/"spoiler"/"nsfw"/"") rejected. Falls through to generic HTML scrape on any error |
| Multi-mac dupe prevention (loginwindow blocklist) | ✅ v2.7.9 | — | — | Apple-specific source-app phantom |
| `cpdb dedupe --links-all-time` (cross-time link collapse) | ✅ v2.7.9 | — | ✅ v1.7.0 | salvages `link_title` from siblings before tombstoning. Windows: `cpdb-win dedupe --links-all-time` |
| Permissions UI (Accessibility + Local Network status) | ✅ v2.8.4 | — | — | Windows uses MSIX capability manifest, no runtime equivalent |
| CloudKit push-batch recordID dedup | ✅ v2.8.3 | — | — | sync-only fix; Windows v1 is standalone |
| Quieter CloudKit push logs (concurrency-race noise filter) | ✅ v2.8.1 | — | — | sync-only |

## Storage management (v2.6 series)

| Feature | macOS | iOS | Windows | Contract / notes |
|---|---|---|---|---|
| Pinning (`entries.pinned`) | ✅ v2.6.0 | ✅ v2.6.0 | ✅ v1.1.0 | contract: `docs/schema.md` § Pinning. Schema column already exists; sort order + eviction-skip semantics are mandatory; UI is per-platform |
| Storage usage diagnostic | ✅ v2.6.1 | — | ✅ v1.21.0 | Windows: Preferences → Storage shows DB path, db/wal/shm + blob sizes, and live/pinned/total entry counts (read-only). iOS storage is small + caches itself; doesn't need the diagnostic |
| Time-window eviction | ✅ v2.6.2 | — | ⏳ | contract: `docs/schema.md` § Eviction. `body_evicted_at` column + sync round-trip + pull-side cooperation are mandatory |
| Test-fixture scaffolding | ✅ v2.6.3 | — | ⏳ | contract: env-var-overridable data dir; ditto-equivalent snapshot |
| Size-budget eviction (LRU + size-weighted) | ⏳ planned | — | ⏳ | not yet implemented anywhere |
| Per-kind quotas | ⏳ planned | — | ⏳ | optional advanced feature |
| iOS hydrate-on-demand | — | ⏳ planned | — | iOS-specific: pull metadata + thumbnail eagerly, fetch flavor body on detail-view open |
| Gc audit log + empty-DB circuit breaker | — | — | ✅ v1.12.0 | Windows-specific hardening after an unexplained history loss: Gc `Stats` written to `gc.log`; a non-empty→empty boot skips Gc, refuses to start capture, and warns. No Mac/iOS equivalent required |

## Data portability — import / export (v2.9 series)

Both a CLI surface (above) and a GUI surface (Preferences →
"Import / Export"). The logic is factored into reusable types so
CLI and GUI are one implementation — Windows should mirror that
(one engine helper, called by both `cpdb-win.exe` and the WinUI
Preferences pane) rather than duplicating.

| Feature | macOS | iOS | Windows | Contract / notes |
|---|---|---|---|---|
| URL-list import | ✅ v2.9.0 / 2.9.7 | — | ✅ v1.10.0 / verify v2.9.7 | `UrlImporter` (CpdbCore / `CpdbWin.Core.Portability`). Parse: trim, drop blank + `#`-comment lines, accept only `http`/`https`/`file` schemes (reject others with a reason). Each accepted line → synthetic clipboard snapshot with `public.url` + `public.utf8-plain-text` flavors → normal ingest path → kind=link → background enrichment. Source app = synthetic "cpdb import" identity so seeded rows are distinguishable. `spreadSeconds` backdates `captured_at` (oldest line = oldest) so the import doesn't collapse to one timestamp. **v2.9.7 contract (verify Windows has both):** (1) the per-line ingest MUST be isolated — one row throwing counts as `failed` and the loop continues, never aborts the batch; (2) the SQLite connection MUST set a busy timeout (mac: GRDB `busyMode=.timeout(5)`; Windows: `Microsoft.Data.Sqlite` `Default Timeout`/`BusyTimeout`) or a second connection contending with the live capture writer drops all rows after the first |
| History export | ✅ v2.9.0 / 2.9.6 | — | ✅ v1.10.0 / ✅ v1.16.0 (v2.9.6 delta) | `HistoryExporter` (CpdbShared / `CpdbWin.Core.Portability`). Newest-first by `created_at`, metadata + text only (no flavor bytes — an archive is for reading/search, not restore). **v2.9.6 corrected the contract — Windows v1.16.0 implements the corrected shape:** (a) **carry every enrichment field** — `fetched_title` (YouTube/page titles), full `ocr_text` (NOT truncated), `image_tags` (segment labels) — explicitly labelled, not just folded into the headline; (b) **LF-normalise all embedded captured text** (`\r\n`/`\r` → `\n`) so the file has uniform line endings (captured clipboard content frequently carries CRLF and editors otherwise prompt). Formats: **md** = `#` header + paragraph-per-entry (headline · source · device · ts; text_preview fenced; enrichment block with `**Fetched title:**` / `**Image tags:**` / fenced `**OCR text:**`); **csv** = RFC-4180, exactly these 13 columns in order: `id,kind,pinned,evicted,created_at,captured_at,source_app,device,headline,fetched_title,text_preview,ocr_text,image_tags`; **html** = self-contained styled page, dark-mode `@media`, `.enrich` rows for the gleaned fields, no external assets. `headline` = link_title › title › text_preview › `(kind)`. Timestamps ISO-8601 |
| Import/Export GUI (Preferences) | ✅ v2.9.5 | — | ✅ v1.10.0 | Windows: WinUI Preferences pane — file-open dialog → import engine helper (1-hour spread); format combo + file-save dialog (pre-named `cpdb-export-<date>.<ext>`) → export engine helper. Run off the UI thread (private SqliteConnection on the worker; WAL coexists with the live capture connection); status line for the result |

## CLI surface

The Mac CLI has accumulated subcommands as the data layer grew. The
Windows port shipped a maintenance CLI (`cpdb-win.exe`) in v1.7.0 —
console-only, no WinUI dependency, dispatches to the same engine
helpers in `CpdbWin.Core.Maintenance`. Read / display subcommands
(`list`, `search`, `show`, `copy`, `stats`) are out of scope for v1
since the GUI covers them. As of **v1.20.0 the CLI is bundled in
the Velopack installer** — it publishes into the same folder as the
GUI and lands at `%LOCALAPPDATA%\CpdbWin\current\cpdb-win.exe`
(stable across auto-updates), so users get the documented
maintenance surface without a separate download.

| Command | macOS | Windows | Notes |
|---|---|---|---|
| `cpdb list` | ✅ | — | GUI covers this |
| `cpdb search` | ✅ | — | GUI covers this |
| `cpdb show <id>` | ✅ | — | GUI covers this |
| `cpdb copy <id>` | ✅ | — | GUI covers this |
| `cpdb stats` | ✅ | — | GUI covers this |
| `cpdb storage` | ✅ v2.6.1 | ⏳ | tier-by-tier breakdown |
| `cpdb evict --before-days N` | ✅ v2.6.2 | ⏳ | manual eviction trigger |
| `cpdb fixture {snapshot, list, env, path, delete}` | ✅ v2.6.3 | ⏳ | test-data scaffolding |
| `cpdb dedupe --links-all-time` | ✅ v2.7.9 | ✅ v1.7.0 | Windows: `cpdb-win dedupe --links-all-time`. Mac v2.5.2 also had a Universal-Clipboard-echo dedup; that variant is Apple-specific |
| `cpdb backfill-titles --retry-empty` | ✅ v2.7.8 | ✅ v1.7.0 | Windows: `cpdb-win backfill-titles --retry-empty` |
| `cpdb reclassify-kinds` | ✅ v2.7.14 | ✅ v1.7.0 | Windows: `cpdb-win reclassify-kinds` |
| `cpdb fetch-link-titles [--limit][--force][--retry-empty][--dry-run]` | ✅ v2.7.0 / 2.7.8 | ✅ v1.7.0 | Windows: `cpdb-win backfill-titles` family covers this |
| `cpdb import-urls FILE [--dry-run][--spread-seconds N]` | ✅ v2.9.0 | ✅ v1.10.0 | one URL per line, http(s)/file only, `#`-comments + blanks skipped; ingest as synthetic clipboard captures attributed to a "cpdb import" source app so links enrich via the normal backfill. Logic in `UrlImporter` (shared by CLI + GUI). Windows: `cpdb-win import-urls FILE [--dry-run] [--spread-seconds N]` |
| `cpdb export --format md\|csv\|html [--output][--limit][--include-evicted]` | ✅ v2.9.0 | ✅ v1.10.0 | metadata + text only (no flavor bytes); newest-first. Logic in `HistoryExporter` (shared by CLI + GUI). CSV is RFC-4180 12-col; HTML self-contained w/ dark mode; MD = paragraph-per-entry. Windows: `cpdb-win export --format md\|csv\|html [--output FILE] [--limit N] [--include-evicted]` (no `--output` → stdout) |
| `cpdb sync {push-once, pull-once}` | ✅ v2.0 | — | CloudKit, Apple-only |

## Build / packaging

| Concern | macOS | iOS | Windows | Notes |
|---|---|---|---|---|
| Universal arm64 + x86_64 release | ✅ v2.5.7 | — | ✅ x64 | iOS is arm64-only by hardware |
| Code signing for distribution | ✅ Developer ID | ✅ App Store team | ✅ Authenticode (planned) | Mac: notarized DMG via `make publish`; Windows: Velopack-signed MSIX |
| Stable identity across updates | ✅ v2.9.4 | — | n/a | Mac: codesign `--requirements` pins the Team ID (`subject.OU`) not the leaf cert, so macOS TCC grants (Accessibility/Local Network) survive cert rotation + Apple-Dev↔Developer-ID swaps. Windows has no TCC-equivalent that's identity-keyed; not applicable |
| Auto-update | ✅ Sparkle 2 (v2.9.1) | — | ✅ v1.11.0 | Mac: EdDSA-signed appcast at `releases/latest/download/appcast.xml`, daily background check + "Check for Updates…" menu item, prompt-not-silent. Windows: `UpdateService` over Velopack `GithubSource`, check 30s after launch + every 24h + on-demand tray item, download-then-prompt-then-restart (never silent), skips dev/portable builds. **Multi-arch**: `build-installer.ps1` packs each rid with `--channel win-<arch>` so every artifact (manifest, nupkg, Setup.exe, RELEASES) is architecture-qualified; `release-installer.ps1` publishes both feeds on one GitHub release with zero collision; `UpdateService` selects `ExplicitChannel` from `RuntimeInformation.ProcessArchitecture` so x64 and arm64 each update against their own packages. Functionally at parity — different framework per platform |
| GitHub Releases publication | ✅ via `make publish-github` | — | ✅ via `windows/release-installer.ps1` | both write to the same repo's releases page |

## How to use this table when picking up a thread

1. Read the row whose feature you're implementing.
2. Read the linked contract section in `docs/schema.md`.
3. Implement against the contract — the existing-platform code is
   *one* implementation, not the spec.
4. Open a PR titled `<platform>: <feature> (parity with <other> vX.Y.Z)`.
5. Update this table in the same commit. Move ⏳ → ✅ vX.Y.Z.

A well-formed handoff prompt to a fresh Claude session is short:

> Implement Windows feature parity with `<feature>` per the contract
> in `docs/schema.md` § `<section>`. The macOS implementation
> shipped in v`<version>`; cross-reference for ideas, but the
> contract section is the spec. Update `docs/parity.md` in your
> PR.
