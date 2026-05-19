# Changelog

Notable changes per release. Signed binaries on the
[GitHub releases page](https://github.com/phubbard/CopyPasteDataBase/releases).

The `[Unreleased]` section accumulates between releases. `make publish-github`
moves it into a new dated `[X.Y.Z]` heading at tag time and resets the
working area to empty. Edit it freely if a commit message wasn't quite
human-readable — what's in `[Unreleased]` is what ships.

## [Unreleased]

- **Import no longer aborts after the first URL.** Reported: GUI
  "Import URLs…" on an 11-line file only imported the first entry.
  Root cause — `Configuration()` set no SQLite busy timeout, so the
  Preferences import's `Store.open()` (a second connection in the
  *same* menu-bar-app process as the running capture daemon) hit an
  immediate `SQLITE_BUSY` on the contended write lock by iteration
  2; the `try` propagated and aborted the whole loop after one
  insert. (The CLI is a separate process and usually won the race,
  which is why it looked fine in testing — a classic
  works-on-my-machine.) Two fixes:
    - `Store` now sets `busyMode = .timeout(5.0)` — contended
      writers wait (up to 5 s, far longer than any cpdb write txn)
      instead of failing instantly. Benefits every consumer (CLI
      racing the app, the GUI, the syncer).
    - `UrlImporter.run` isolates each line in its own do/catch:
      one ingest throwing now counts as `failed` and the batch
      continues, instead of losing every remaining URL. CLI `done:`
      line and the GUI status both surface the `failed` count.
  Verified: a 10-URL file imports `inserted=10 … failed=0` against
  the live DB with the daemon running.

## [2.9.6] – 2026-05-18

- **Export now carries every enrichment field + is LF-clean.** Two
  bugs in the v2.9.0 exporter:
    - It dropped/buried the metadata cpdb *derives* — fetched
      link/YouTube titles were only folded into the headline (no
      distinct field), OCR text was truncated to 500 chars, and
      `image_tags` were absent from HTML entirely. Now all three
      are explicit, labelled fields in every format, and **OCR is
      no longer truncated** (the searchable text is the whole point
      of an export). CSV gains a dedicated `fetched_title` column
      (13 cols now: …`headline,fetched_title,text_preview,ocr_text,
      image_tags`); Markdown gets a per-entry enrichment block;
      HTML gets `.enrich` rows.
    - Mixed line endings — captured clipboard text routinely
      carries CRLF (Windows source apps) or lone CR, while the
      exporter's own separators are LF, so editors (Nova, etc.)
      prompted to "fix" the file. All embedded captured text is now
      LF-normalised; verified zero CR bytes across md/csv/html.

## [2.9.5] – 2026-05-18

- **Import / Export in Preferences (GUI).** The v2.9.0 import/export
  was CLI-only; most users never open a terminal. New
  "Import / Export" section in the Preferences window:
    - **Import URLs…** — NSOpenPanel for a text file; ingests via
      the shared `UrlImporter` with a 1-hour `captured_at` spread.
      Status line reports inserted / bumped / skipped / rejected.
    - **Export…** — format picker (Markdown / CSV / HTML) +
      NSSavePanel pre-filled with `cpdb-export-<date>.<ext>`.
      Renders via the shared `HistoryExporter`.
  Both run off the main thread so a big library doesn't beachball
  the window. The import/export *logic* was factored out of the
  CLI commands into `UrlImporter` (CpdbCore) and `HistoryExporter`
  (CpdbShared) so the CLI and GUI are one implementation —
  verified byte-identical output across both paths.

## [2.9.4] – 2026-05-18

- **Accessibility (and all TCC grants) survive updates — stable
  Designated Requirement.** Bug caught by the auto-update test: a
  running build showed Accessibility as not-granted even though the
  System Settings toggle was on. Root cause — codesign's *default*
  Designated Requirement pins the exact signing leaf certificate,
  and macOS TCC records that DR when you grant a permission. An
  Apple-Development-signed dev build, a Developer-ID-signed release,
  and any post-cert-rotation build each get a *different* DR, so
  every signing-identity change silently revokes Accessibility /
  Local Network / etc. Fix: every outer codesign now passes an
  explicit `--requirements` pinning the Team ID
  (`certificate leaf[subject.OU] = NSR65JVW9F`, stable across cert
  kind and rotation) instead of the leaf cert. All builds cpdb will
  ever ship now share one DR, so a grant persists across dev
  deploys, Developer-ID releases, Sparkle updates, and cert
  renewals. **One-time action:** because the DR itself changed, you
  must re-grant Accessibility once after installing 2.9.4+ (System
  Settings → Privacy & Security → Accessibility — remove the stale
  cpdb entry, re-add); from then on it sticks forever.

## [2.9.3] – 2026-05-18

- **Auto-update robustness verification + honest documentation.**
  The v2.9.1 e2e test (2.9.1→2.9.2) surfaced that the app's
  long-standing `installSPMBundleShims()` (root-level symlinks for
  SPM's hardcoded `Bundle.module` path) breaks
  `codesign --verify --strict` / `spctl` *on a launched app*. Audited
  it: it does NOT affect fresh installs (notarized DMG ships the
  clean bundle; Gatekeeper passes at first launch and never
  re-assesses) or Sparkle updates (validates the clean downloaded
  DMG + the host Designated Requirement, which a structural symlink
  doesn't change). The shim is load-bearing — KeyboardShortcuts'
  `Bundle.module` `fatalError`s without it, and codesign forbids
  the bundle at the .app root regardless — so it stays, but the
  misleading "this is safe" comment is replaced with an honest
  accounting. This release is the consecutive-hop proof: a running,
  already-self-symlinked 2.9.2 updating itself to 2.9.3.

## [2.9.2] – 2026-05-18

- **Auto-update end-to-end verification.** Trivial release cut
  solely to prove the v2.9.1 Sparkle pipeline works in the wild:
  a running 2.9.1 install detecting, downloading, EdDSA-verifying,
  and installing this 2.9.2 from the live GitHub appcast. No
  functional change.

## [2.9.1] – 2026-05-18

- **In-app auto-update via Sparkle 2.** The direct-download Mac
  build now checks for updates on its own. A new "Check for
  Updates…" item in the menu-bar menu triggers an on-demand check;
  a background check also runs once a day (`SUScheduledCheckInterval
  = 86400`). Updates are EdDSA-signed (`SUPublicEDKey` in
  Info.plist, private key offline) and verified before install.
  `SUAutomaticallyUpdate = false` — cpdb *prompts* rather than
  silently swapping, which is right for a menu-bar app you rarely
  quit (a silent install-on-quit could sit pending for weeks).
    - Feed is the stable `releases/latest/download/appcast.xml`
      GitHub URL, so every release just uploads its own appcast.
    - `make appcast` generates + EdDSA-signs the appcast from the
      notarized DMG; wired into `make publish` and the
      `publish-github` asset upload.
    - `Sparkle.framework` is embedded into `Contents/Frameworks/`
      and signed inside-out (`scripts/sign-nested.sh`) — `codesign
      --deep` mis-signs Sparkle's XPC helpers and fails notary, so
      both the dev-sign and Developer-ID re-sign paths now do
      explicit inside-out signing instead of `--deep`.
    - Sparkle linked only by the GUI app; the headless CLI +
      libraries stay dependency-free.

## [2.9.0] – 2026-05-18

- **`cpdb import-urls <file>`.** Bulk-seed the database from a text
  file of one http(s):// or file:// URL per line. Each line is
  ingested through the normal capture path — so kind=link rows
  enter the link-metadata backfill queue and get titles +
  thumbnails enriched in the background just like a real copy.
  Entries are attributed to a synthetic "cpdb import" source app
  (new `FrontmostAppInfo.importer`) so seeded data is
  distinguishable from real captures. Blank lines and `#`-comments
  skipped; non-http(s)/file schemes rejected with a reason.
  `--dry-run` previews; `--spread-seconds N` spreads `captured_at`
  backwards over N seconds (oldest line = oldest) so an import
  doesn't collapse into a single timestamp. Use cases: seeding a
  fresh install from a bookmarks export, migrating a read-later
  list, scripted ingestion.
- **`cpdb export --format {md,csv,html}`.** Dump live history to a
  portable document. Markdown is a paragraph per entry (headline +
  source/device/timestamp badges + full text in a code block +
  OCR/tags). CSV is RFC-4180 with 12 columns. HTML is a
  self-contained styled page with dark-mode support, no external
  assets. Newest-first by `created_at`, mirrors the popup. `--output`
  writes to a file (else stdout), `--limit N` caps, evicted-body
  entries included by default (metadata still present).

## [2.8.6] – 2026-05-01

- **Reject CAPTCHA / bot-check pages as transient failures.** Reddit
  (and a growing list of Cloudflare-protected sites) serves an
  interstitial "Please wait for verification" / "Just a moment…"
  page to non-browser User-Agents. The HTTP layer reports 200 OK,
  so we used to extract `<title>Reddit - Please wait for
  verification</title>` and stamp *that* as the canonical title.
  New `looksLikeBotCheck()` heuristic detects the common
  interstitial titles ("verification", "just a moment", "attention
  required", "are you human", "captcha", etc.) and throws a new
  `FetchError.botCheckDetected` — classified as transient, so the
  row stays a candidate for retry instead of being permanently
  marked with the wrong title.
- **Reddit-specific JSON API path.** Comment URLs of the shape
  `/r/<sub>/comments/<id>/…` now route through Reddit's public
  `<...>.json` endpoint, which bypasses the CAPTCHA gate entirely
  and returns clean post metadata (title + thumbnail). Falls
  through to the generic HTML scrape on any failure so a malformed
  URL doesn't dead-end. Subreddit pages and user profiles are not
  in scope — their JSON shape is different.
- **2 new tests** cover Reddit comments-URL detection and the bot-
  check title-pattern matcher.

- **iOS list rows render link titles + thumbnails.** The Mac shipped
  link enrichment in v2.7.x but iOS only exposed the title +
  thumbnail in the *detail* view. Now the SearchView list also
  honours them:
    - `EntryRow`'s leading icon shows the preview thumbnail (44×44
      rounded square) for `kind=link` entries that have one in
      the `previews` table — same code path image entries already
      use, just extended to cover links.
    - `EntryRow`'s snippet text prefers `entry.linkTitle` when
      present, falling back through the existing chain (title →
      textPreview → linkURL → kind label) when the backfill hasn't
      run or the page had no extractable title.
    - `SearchView`'s row-build query now SELECTs `thumb_small` for
      both image AND link kinds (previously only images).
  iOS doesn't fetch link metadata — it's read-only — so this just
  lights up the data the Mac is already syncing down via CloudKit.

## [2.8.4] – 2026-04-30

- **Unified "Permissions" section in Preferences.** Accessibility
  and Local Network now share a single section with consistent
  iconography: green ✓ when granted, orange ! when denied, neutral
  hourglass while a probe is in flight. Each row shows the same
  three-element layout (status + label, deny-state help blurb,
  "Open System Settings…" / "Re-check" buttons).
- **Live permission status detection.** Local Network grant state
  used to be invisible (no public API). New `LocalNetwork.probe()`
  spawns a one-shot `NWBrowser` against `_bonjour._tcp` with peer-
  to-peer enabled — `.ready` ⇒ granted, `.failed` ⇒ denied, 1.5s
  timeout ⇒ unknown. The Preferences window starts a 5-second
  poller while it's open: every tick re-checks Accessibility
  (synchronous, instant) and re-runs the Local Network probe (only
  when the last result wasn't already granted). When you flip the
  toggle in System Settings, the green checkmark appears within
  ~5s without any clicks back in cpdb. Poller stops automatically
  on window dismiss.

## [2.8.3] – 2026-04-30

- **Push-batch recordID dedup.** Fixes `CKError 12 "You can't save
  the same record twice"` that started showing up after running
  `cpdb dedupe --links-all-time`. Two local entries can map to the
  same content-addressed CloudKit recordID (`entry-<sha256>`) when
  one is live and one is tombstoned-by-dedupe — both end up in the
  push queue, both serialize to the same recordID in one
  `modifyRecords` call, CloudKit rejects the entire batch. The
  push-build loop now collapses duplicates by recordID at queue-
  drain time: if one is live and one is tombstoned, prefer the
  live row (it's the canonical state for that recordID); the
  loser's queue row is removed in the same write so future batches
  don't keep crashing on it.

## [2.8.2] – 2026-04-30

- **Exponential-backoff link retry + connectivity gate.** Pre-v9
  the link backfill retried transient-failure rows on *every*
  cycle (~96×/day, forever). Now:
    - **Schema v9** adds `link_retry_count` and `link_retry_after`
      to `entries`.
    - On a transient failure (HTTP 403/429/5xx, network blip), the
      row's count increments and `link_retry_after = now + 60 ·
      min(60, 2^count)` seconds — schedule is 1, 2, 4, 8, 16, 32,
      then capped at 60 minutes.
    - `linksNeedingMetadata` honours both `link_retry_after` and a
      max-attempts cap of `EntryRepository.linkBackfillMaxRetries`
      (6) — beyond that the row drops out of the queue. "Retry
      empties" + `cpdb fetch-link-titles --retry-empty` and the
      "Refetch all" button reset the retry state cleanly so a
      user-driven retry starts fresh.
    - Successful fetches and permanent failures clear the retry
      state, so a row that finally succeeded doesn't carry stale
      backoff into a future re-fetch.
- **Reachability monitor.** New `Reachability` actor wraps
  `NWPathMonitor` and exposes `isOnline` plus a
  `cpdbReachabilityChanged` notification. The link backfill
  short-circuits to a no-op when the OS reports no internet —
  rows aren't penalized for being offline. AppDelegate observes
  the offline→online edge and fires an immediate catch-up batch,
  so a Mac coming back from sleep / airplane mode / Wi-Fi
  reconnect resumes work without waiting for the 15-minute timer.
- **6 new tests** cover the backoff math (1·2^count minutes,
  60-minute cap), success-clears-state, and the
  retry_after / max_retries gates in `linksNeedingMetadata`.

## [2.8.1] – 2026-04-30

- **Quieter CloudKit push logs.** Multi-Mac install means three
  devices race to push the same content-addressed flavor records
  (`flavor-<sha256>-<…>`) in tandem. The race-loser's per-record
  save returns CloudKit's `.batchRequestFailed` ("Atomic failure")
  even though the data is already on the server from the winner's
  push, so this is benign concurrency noise — *not* data loss —
  but the log was screaming. Same applies to
  `.serverRecordChanged` (etag conflict) and `.unknownItem`
  (parent entry tombstoned mid-push). All three now aggregate
  into one info-level summary line per cycle:
  `N flavor record(s) lost a concurrent multi-device push race
  (data already on server)`. Real failures still surface as
  errors as before.

## [2.8.0] – 2026-04-30

Marker release consolidating the 2.7.x series. No new functionality
beyond v2.7.14 — bumped to 2.8.0 to mark "link metadata enrichment"
as a finished feature theme. Highlights from the underlying point
releases:

- **Background-fetched link titles + thumbnails.** Captured URLs
  grow a human-readable title and a preview image in the
  background. YouTube uses oEmbed; everything else uses HTML
  scrape (og:title / twitter:title / `<title>`,
  og:image / twitter:image). Wikipedia REST API + favicon
  discovery serve as additional thumbnail-fallback paths so the
  long tail of "no OpenGraph" sites still gets *something*.
  Indexed in FTS5 — search for "santa cruz vala" and the YouTube
  URL you copied surfaces by video title.
- **Live popup updates.** Cards refresh in place when the
  background fills them in. GRDB ValueObservation tracks the
  link-fetched-at sum and previews row count, so a fresh title or
  thumbnail morphs the card from "URL only" → "title + thumbnail"
  without dismiss + re-summon. Capture-wake link backfill makes
  freshly-copied URLs enrich within ~1–3 seconds.
- **Hover tooltips on every card.** Type, source app, originating
  device (your Mac or another via CloudKit sync), and absolute
  capture timestamp.
- **Pasteboard-classification fixes.** URL-shaped plain text (the
  `pbcopy` / paste-into-input-field shape) classifies as
  `kind=link` so the backfill picks it up. Bumped duplicates
  reclassify if the kind heuristic has changed since first
  capture. New `cpdb reclassify-kinds` migration cleans up the
  historical pile in one command.
- **Multi-Mac dupe prevention.** `com.apple.loginwindow` joins the
  always-ignore list — previously every screen-unlock event on
  every Mac generated a phantom duplicate that propagated through
  CloudKit. New `cpdb dedupe --links-all-time` collapses URL
  duplicates regardless of capture-time gap, salvaging
  link_titles from siblings before tombstoning.
- **Reliability.** Backfill is decoupled from the periodic sync
  loop (a wedged URL fetch can no longer stall CloudKit pull/push).
  Transient errors (HTTP 403/429/5xx, network timeouts) leave
  rows un-stamped so they retry on the next cycle. New "Retry
  empties" button in Preferences targets only the failed/empty
  subset, no more YouTube rate-limit hammering. Single-instance
  guard at app launch stops the menu-bar-icon pileup. Local
  Network preferences row + `NSLocalNetworkUsageDescription` for
  the privacy prompt.
- **Popup polish.** Standard close button on the panel.

Underlying versions: 2.7.0 through 2.7.14. See those entries
below for per-bug detail.

## [2.7.14] – 2026-04-30

- **Bump-time kind reclassification.** When a duplicate capture
  bumps an existing row, the Ingestor now compares the new
  snapshot's kind against the stored kind and updates if they
  differ. Catches the case where v2.7.11's "URL-shaped plain text
  → kind=link" rule shipped *after* a row was first captured as
  text — re-copying the same URL would just bump created_at,
  leaving the row stuck as kind=text and never enriching it.
  When the transition is text→link, `link_fetched_at` is also
  cleared so the next backfill cycle picks the row up.
- **`cpdb reclassify-kinds` migration.** One-shot CLI to retrofit
  the same fix across history without needing to re-copy each
  URL by hand. Scans every `kind=text` row whose `text_preview`
  is a single http(s):// URL (same heuristic as the runtime
  classifier) and switches it to `kind=link`, clearing
  `link_fetched_at`. Idempotent. Pushes the kind change through
  CloudKit so other devices update too. Use `--dry-run` to
  preview.

## [2.7.13] – 2026-04-30

- **Two new thumbnail-fallback paths.** When a page's HTML head
  doesn't ship `og:image` / `twitter:image`, the link backfill
  now tries:
    1. **Wikipedia REST API** (`*.wikipedia.org` only). Hits
       `/api/rest_v1/page/summary/<title>` and uses the response's
       `thumbnail.source` (or `originalimage.source` as a backup).
       Many Wikipedia articles ship a lead image in the API
       response that isn't reflected in the page's og: meta tags
       — this fallback surfaces it.
    2. **Favicon discovery.** Looks for `<link rel="apple-touch-
       icon">` first (typically 180×180 PNG, decent at card size),
       then `<link rel="icon">` / `rel="shortcut icon"`, finally
       falls through to the conventional `<scheme>://<host>/
       favicon.ico`. Resolves relative hrefs against the page URL.
       The `fetchThumbnailBytes` step still gates on Content-Type
       starts-with-`image/` so 404 HTML pages don't sneak through.
  Net effect: significantly fewer "URL only" cards in the popup
  for sites that have *some* visual identity but missed the
  OpenGraph standard. 6 new fetcher tests cover the favicon
  precedence rules and Wikipedia host detection.

## [2.7.12] – 2026-04-30

- **Hover tooltips on every popup card.** Hovering an entry card
  now shows a multi-line tooltip with the entry's kind, source
  app + bundle id, originating device (your Mac name or another
  Mac that synced the entry via CloudKit), and the absolute
  capture timestamp. When `created_at` and `captured_at` differ
  by more than a second (CloudKit-pulled entries preserve the
  source device's capture time but get a new local ingest time),
  the tooltip surfaces both. `EntryRow` gained a `deviceName`
  field via a JOIN against the `devices` table — used by the
  tooltip today, available for any future surface that wants per-
  device attribution (browse window filters, sync diagnostics).

## [2.7.11] – 2026-04-30

- **URL-shaped plain text now classifies as `kind=link`.** Pasteboard
  writes that omit the `public.url` UTI (terminal `pbcopy`, paste-
  into-input flows, some apps' "Copy" buttons) used to land as
  `kind=text` even when the payload was a single http(s):// URL.
  They now classify as link, so the link-title backfill picks them
  up and the popup renders them with the link card layout.
  Conservative heuristic: payload must be a single whitespace-
  trimmed token starting with http(s)://, ≤2048 chars, with a
  parseable host.
- **Capture-wake gates on kind=link.** The ingestion notification
  now carries the entry's kind in userInfo; AppDelegate's wake
  observer skips non-link captures. Stops the wasteful pattern
  where every text/image/file capture re-fired a 5-row link
  backfill batch (which always hit the same rate-limited rows at
  the top of the queue).

## [2.7.10] – 2026-04-30

- **Live updates: cards refresh in place when the background
  fills them in.** The popup already used GRDB ValueObservation
  while open, but the watched projection was just `(count,
  maxCreatedAt)` — which doesn't change when an existing row gets
  a new `link_title` or a fresh thumbnail. The projection now
  also tracks `SUM(link_fetched_at)` and the previews row count,
  so a link backfill or a thumbnail download fires the
  observation and the card morphs from "URL only" → "title +
  thumbnail" without dismiss + re-summon. With debounce already
  at 120 ms, a burst of CloudKit-pulled rows still only triggers
  one refresh.
- **Capture-wake link backfill.** The 15-minute periodic loop is
  too lazy for "I just copied this URL → open the popup → see
  the title." Now every local capture also fires a 5-row backfill
  immediately (gated by the existing BackfillGate so it doesn't
  pile on top of an in-flight periodic batch). Combined with the
  ValueObservation fix above, a fresh YouTube copy renders as a
  URL card → title + thumbnail card within ~1–3 seconds.

## [2.7.9] – 2026-04-30

- **Ignore `com.apple.loginwindow` for capture.** When the screen
  unlocks, macOS sometimes re-emits the pasteboard with a slightly
  different flavor set (an extra `public.text` UTI on top of
  `public.utf8-plain-text` we'd already captured). Same data, but
  the content_hash differs because it's computed across the full
  flavor set — so it slips past dedup as a "new" entry. With
  multiple Macs all running cpdb + CloudKit sync, every Mac's
  unlock event creates its own phantom dupe and the dupes propagate
  to every device. Now `loginwindow` joins Passwords and Keychain
  Access in the always-ignore list at the source.
- **`cpdb dedupe --links-all-time`.** The existing `cpdb dedupe`
  uses a 5-second window — useful for the Xcode-debug-console
  near-dupe pattern but useless for loginwindow phantoms that
  appear hours or days apart on different Macs. New flag drops the
  time bucket for `kind=link` rows: same trimmed text_preview
  anywhere in history collapses to one entry. Other kinds still
  respect the window. Also salvages `link_title` from siblings
  before tombstoning so the dedup doesn't lose backfill work.

## [2.7.8] – 2026-04-30

- **"Retry empties" — targeted link refetch.** Until now, the
  Preferences "Refetch all" button and `cpdb fetch-link-titles
  --force` cleared `link_fetched_at` on every link, which on a
  3000-row library means hammering YouTube oEmbed (and tripping
  its rate limit, which is the bug 2.7.7 worked around). New
  surface lets you target only the failed/empty subset:
    - Preferences → "Retry empties" button (alongside "Fetch link
      titles" and "Refetch all"), with help-tag explanations of
      when to use each.
    - `cpdb fetch-link-titles --retry-empty` — clears
      `link_fetched_at` only on rows whose `link_title` is
      null/empty, then runs a normal batch. Reports how many were
      cleared up front.
    - New `EntryRepository.resetLinkFetchedAtForEmptyTitles()`
      helper backs both UI surfaces.

## [2.7.7] – 2026-04-29

- **Transient errors no longer mark a link "fetched".** YouTube's
  oEmbed endpoint returns HTTP 403 once you trip its rate limit
  (which a 1000-entry bulk backfill does easily), then recovers an
  hour later. Previously any fetch error stamped `link_fetched_at`
  with no title, so the row never got retried — leading to "why is
  this YouTube link missing a title?" days later. Now `FetchError`
  has an `isTransient` property: HTTP 403/408/425/429/5xx and
  generic network errors are transient and leave the row un-stamped
  for the next cycle to retry. Decode errors and invalid URLs are
  permanent and still stamp normally.
- After upgrading, hit Preferences → "Refetch link titles" once to
  retry the entries that v2.7.0–2.7.6 marked permanently empty due
  to this bug.

## [2.7.6] – 2026-04-29

- **Backfill actually runs again.** Root cause of v2.7.0–2.7.5
  silence: the `linksNeedingMetadata(limit: 1)` probe used by the
  daemon was returning the most recent unfetched row, but if that
  row was a `mailto:` URL or other non-http(s) string captured as
  `kind=link`, the swift post-filter dropped it. The probe saw an
  empty array and bailed with "no candidates, idle", every cycle —
  even though thousands of valid http(s) URLs sat behind it. Worse:
  the same offending rows never got `link_fetched_at` stamped, so
  they stayed at the top of `created_at DESC` forever, crowding out
  real candidates. Two fixes:
    - **SQL-side URL prefix filter.** `linksNeedingMetadata` now
      includes `AND text_preview LIKE 'http%'` directly in the
      query. Mailto/empty/garbage rows are skipped at query time;
      they stay in the DB unfetched (no harm) but no longer block
      the queue.
    - **No more probe.** The daemon's backfill now goes straight to
      `runOnce` (which returns an empty Report on idle ticks). The
      probe was a micro-optimization that masked the bug above.

## [2.7.5] – 2026-04-29

- **More backfill diagnostic logs.** v2.7.4 showed the periodic loop
  is healthy — every tick completes, and the detached backfill task
  is being spawned. But no `link-title backfill: …` lines appeared,
  meaning the task itself bails out silently. v2.7.5 logs at every
  branch (gate acquire, probe query, candidate count) so we can see
  exactly which guard is firing. Diagnostic-only.

## [2.7.4] – 2026-04-29

- **Periodic-tick observability.** Every step of the periodic sync
  loop now emits a paired begin/end log line (pull begin/end, push
  begin/end, evict-if-due begin/end, backfill spawn, tick complete)
  with a monotonic tick counter. Diagnostic-only — no behavior
  change. Lets us pinpoint exactly where the loop stalls when
  cloudkit pull/push hangs (which is what we hit in v2.7.3 even
  after decoupling the link backfill).

## [2.7.3] – 2026-04-29

- **Backfill no longer wedges the periodic loop.** v2.7.2's wall-clock
  timeout couldn't actually unstick a hung URLSession because
  `withThrowingTaskGroup` implicitly awaits all child tasks before
  returning, even after `cancelAll()` — and macOS in Local Network
  limbo ignores cancellation. So a single parked URL would hang the
  whole CloudKit periodic loop too. Now the periodic loop fires the
  backfill in a *detached* task and moves on; an actor-based reentry
  guard skips the next tick if the previous batch is still in flight.
  CloudKit pull/push and the link backfill are no longer coupled.
- **Backfill always logs.** Previously the daemon only logged on
  `attempted > 0`, which made it impossible to tell from logs alone
  whether the loop had wedged or just had nothing to do. Every batch
  now logs a `starting batch (limit=N)` line and an outcome line.

## [2.7.2] – 2026-04-29

- **Single-instance guard.** A botched relaunch (e.g. `open -a cpdb`
  on top of a still-running copy) used to leave multiple cpdb glyphs
  in the menu bar with no way to tell them apart. The app now
  terminates any other process sharing its bundle id at launch
  (polite quit, then force after 0.6 s) before installing its status
  item. The `DaemonLock` still arbitrates the writer role, but the
  GUI shell is now strictly single-instance.
- **Local Network preferences row.** New section in the Preferences
  window explains why cpdb sometimes needs Local Network permission
  (URLs on a corporate VPN / intranet resolve to private IPs) and
  links to the Privacy & Security pane. macOS doesn't expose an API
  to query the grant state, so we don't auto-detect — just provide
  the deep link. `NSLocalNetworkUsageDescription` is set so the
  prompt itself uses friendly copy.
- **Popup window has a close button.** `NSPanel`'s `.closable` style
  flag added — useful when your hand's already on the trackpad. ⌘W
  and Escape still work too.
- **Backfiller can't wedge on a hung URL.** Each `LinkMetadataFetcher`
  call is now wrapped in a 20 s wall-clock race, so a single URL
  parked indefinitely (most often macOS holding it pending the
  Local Network prompt) no longer stalls the periodic-sync loop.
  Timeouts count as failures and stamp `link_fetched_at` like any
  other failure.

## [2.7.1] – 2026-04-29

- **Link preview thumbnails (phase 2 of v2.7).** The metadata fetcher
  now also pulls a preview image — YouTube oEmbed `thumbnail_url`,
  HTML `og:image` / `og:image:secure_url` / `twitter:image` /
  `twitter:image:src` (in priority order). Image bytes go through
  the existing `Thumbnailer` (256 / 640 px JPEGs) and land in the
  same `previews` table image-kind entries already use, so:
    - Mac LinkCard renders the thumbnail at the top of the card,
      bounded to 120 pt so the title still has room.
    - iOS EntryDetailView shows the thumbnail above the link title.
    - CloudKit sync of thumbnails is free — the existing
      `thumbSmall` / `thumbLarge` CKAsset fields on the Entry record
      already cover this.
- Image download discipline: 10 s timeout, 4 MB body cap, content-
  type sanity check (must start with `image/`). Failures are
  silent, no per-entry sentinel — the user can hit "Refetch all"
  in Preferences to retry.
- 6 new fetcher tests exercise the og:image priority chain,
  twitter:image fallback, mixed-attribute pages, and rejection of
  non-http(s) image URLs (data:, javascript:).

## [2.7.0] – 2026-04-29

- **Background-fetched link titles.** Captured URLs now grow a
  searchable human-readable title in the background. YouTube URLs
  hit the public oEmbed endpoint (clean JSON, no API key). Other
  pages get an HTML scrape with priority `og:title` →
  `twitter:title` → `<title>`. Titles land in the new
  `entries.link_title` column and the FTS5 index, so a search for
  "santa cruz vala" surfaces a copied YouTube URL by its video
  title even if you don't remember the URL itself.
- Real-world result on a 3.3k-link library: ~73% of links got a
  title, ~5% returned no extractable title (graceful no-op),
  remainder failed (mostly internal corp URLs). Failures are
  marked fetched-but-empty so we don't retry forever; the
  Preferences "Refetch all" button clears the sentinels for users
  who want to retry after going back online.
- Mac LinkCard now leads with the fetched title (semibold) and
  shows the URL in a secondary monospaced row beneath. iOS
  EntryDetailView mirrors the layout. Cards without a title fall
  back to the original URL-on-top layout.
- Daemon runs a small backfill batch (50 entries) every periodic
  cycle, so a fresh installation doesn't hammer the network all
  at once.
- New `cpdb fetch-link-titles [--limit N] [--force] [--dry-run]`
  CLI for manual sweeps and scripted runs. CloudKit round-trips
  `link_title` + `link_fetched_at` so once any device fetches, the
  title syncs to the rest of the fleet for free.
- Schema migration v8: `entries.link_title` (TEXT?) +
  `entries.link_fetched_at` (REAL?) and a v2-style FTS5 rebuild
  that adds `link_title` to the indexed column set.

## [2.6.4] – 2026-04-27

- **Cross-platform parity contracts.** `docs/schema.md` extended with
  explicit semantic sections for v6 pinning + v7 eviction —
  describes the *behaviour* a port must implement (sort order, skip
  rules, sync round-trip, pull-side cooperation), not just the SQL
  shape. New `docs/parity.md` is the scoreboard: what's shipping
  on macOS / iOS / Windows with version stamps and links to the
  contract section. Read both when picking up a port-side feature
  in a fresh Claude session.

## [2.6.3] – 2026-04-27

- **Test-fixture scaffolding.** New `cpdb fixture …` subcommand
  family lets you snapshot the live data directory, run any cpdb
  command against the snapshot, and delete it when done — no risk
  to the real DB or blobs. `Paths.supportDirectory` honours a new
  `CPDB_SUPPORT_DIR` environment variable that the fixture command
  generates with `cpdb fixture env <name>` for shell `eval`. Snapshot
  uses `/usr/bin/ditto` so SQLite WAL files + xattrs survive intact.
  Useful for testing eviction policies on real-shaped data without
  destruction.
- Subcommands: `snapshot`, `list`, `env`, `path`, `delete`.

## [2.6.2] – 2026-04-27

- **Time-window eviction policy.** Optional, off by default.
  Preferences → Storage → "Discard flavor bodies older than N days"
  (default 90, range 7–3650). Daemon runs the policy once per
  24h; users can also force a sweep with the new "Discard now"
  button or the `cpdb evict --before-days N` CLI command.
- Eviction discards flavor body bytes (entry_flavors rows + on-disk
  blobs under `blobs/`) and sets `entries.body_evicted_at`.
  Metadata + thumbnails stay forever — pinned entries skip eviction
  entirely. Search history is preserved at full fidelity; only the
  paste-back content is gone.
- CloudKit sync of the new `body_evicted_at` field — siblings learn
  about evicted entries and don't re-hydrate them on pull. (No
  evict→pull→re-evict loop.)
- New `RestoreError.bodyEvicted` distinguishes "body was deliberately
  discarded" from "entry never existed" so the UI can offer the
  right next step.
- Schema migration v7 adds `entries.body_evicted_at` (REAL?).
- Storage diagnostic now surfaces the count of body-evicted entries
  alongside the live + pinned counts.

## [2.6.1] – 2026-04-27

- **Storage usage diagnostic.** New `cpdb storage` command and a new
  Storage section in Preferences break the library down by tier:
  metadata (always kept, ~MB), thumbnails (always kept, ~tens of MB),
  flavor bodies (evictable, often hundreds of MB to GB). Surfaces
  the pinned-entry count too. Driven by a new
  `StorageInspector.report` API in CpdbShared — a couple of cheap
  SUM queries plus a directory walk over `blobs/`. No eviction yet;
  this just lets you see what's eating space before the next two
  releases land time-window and size-budget policies.

## [2.6.0] – 2026-04-27

- **Pinning.** New per-entry pin state — pinned entries float to the
  top of the popup and skip eviction policies (when the eviction
  policies land in the next two releases). Mac: right-click → Pin /
  Unpin. iOS: swipe right on a row. Pin glyph in the top-left of the
  card / inline with the row text marks pinned entries at a glance.
  CloudKit syncs the state across devices. Schema migration v6 adds
  `entries.pinned`; pre-v2.6 clients ignore the field.

## [2.5.10] – 2026-04-27

- **Intel-Mac launch fix, take two.** v2.5.9 stripped the dev
  provisioning profile (UDID allow-list) but didn't replace it.
  Restricted entitlements (iCloud, APNs, application-identifier)
  need a profile to authorise them at launch — `codesign --verify`
  passes statically, but AMFI rejects with `Code Signature Invalid`
  on any Mac. We now embed a separate `cpdb-developer-id.provisionprofile`
  for redistribution (Developer ID-typed, no UDIDs, authorises the
  iCloud container + APNs). The dev profile keeps being used for
  in-house `make install-app`.
- DMG staging uses `ditto` instead of `cp -R`. Apple's blessed
  primitive for preserving codesign integrity across copies; the
  difference is rare in practice but worth a belt for free.

## [2.5.9] – 2026-04-27

- **Intel-Mac launch fix.** `make sign-release` now strips
  `Contents/embedded.provisionprofile` before re-signing with
  Developer ID. The dev profile is a UDID allow-list — leaving it
  embedded caused AMFI on any unregistered Mac to refuse to open the
  bundle ("the application cpdb.app cannot be opened"), even though
  the binary was correctly Developer-ID-signed and notarized.
- Pin CloudKit environment to `Production` in
  `cpdb-release.entitlements` via
  `com.apple.developer.icloud-container-environment` — Developer ID
  apps default to Development, where requests silently fail.
- README hook: now allows a push if any commit in `<upstream>..HEAD`
  touches README.md (used to require a touch in the most recent commit
  on top of the last README-touching commit, which incorrectly blocked
  chained `git commit && git push`).
- Auto-generated `CHANGELOG.md` wired into `make publish-github` via
  the `[Unreleased]` mechanism.

## [2.5.8] – 2026-04-27

- Compiler-warning cleanup: `EntryRepository.tombstone` drops an unused
  `Void`-typed binding; `CloudKitSyncer.pushPendingChanges` returns a
  Sendable `EntryWriteOutcome` struct instead of mutating outer
  captured `var`s; `PopupController.installMonitors` no longer carries
  NSEvent across the `MainActor.assumeIsolated` boundary;
  `PreviewCoordinator` drops a no-op `@preconcurrency` annotation.
- New `make bump VERSION_NEW=X.Y.Z` rewrites the version everywhere it
  lives (`Version.swift`, `Info.plist`, iOS pbxproj) in one step.
- New `make publish-github` does the GitHub side of a release: pushes
  main + `vX.Y.Z` tag, regenerates SHA256SUMS, drafts notes from
  `git log <prev-tag>..`, uploads/replaces the release assets via `gh`.
  Idempotent. Combined with `make publish`, a full release is now
  three commands.

## [2.5.7] – 2026-04-27

- **Windows port (cpdb-win) initial implementation.** WinUI 3 app on
  .NET 8 with the same SQLite + FTS5 schema (`docs/schema.md` is the
  contract). Capture layer translates Windows clipboard formats
  (CF_DIB/CF_DIBV5/CF_HDROP/CF_HTML/CF_UNICODETEXT) to UTI flavors;
  ingest path writes entries + flavors with content-hash dedup; FTS5
  search; tray icon with global hotkey; auto-launch on login;
  thumbnail previews; multi-select delete; password-manager
  blocklist; Velopack-based installer; GitHub-driven release script;
  Windows tests CI workflow.
- **Universal arm64 + x86_64 release artefacts.** `make release` now
  forces `UNIVERSAL=1` and asserts both slices via `lipo -archs` before
  publish. CI gate (tests.yml) does the same on every PR. Intel-Mac
  beta tester unblocked.
- Universal Clipboard echo marker (`com.apple.is-remote-clipboard`)
  stripped at capture time before the canonical hash is computed —
  stops a single logical capture from creating two rows when one Mac
  in the fleet is running pre-fix code.
- `org.chromium.source-url` now treated as equivalent to `public.url`
  in the plain-text fallback chain. Image copies from Brave / Chrome /
  Edge / Arc surface their source URL in the entry preview, which
  drives the new domain badge and feeds FTS5.
- iOS Info.plist pinned via `INFOPLIST_KEY_CFBundleDisplayName =
  CopyPaste` so Xcode's General tab doesn't keep clearing it.
- Canonical-hash test vectors (`HashVectors.swift`) for the Windows
  port to assert byte parity.
- README refresh: iOS companion section reflects shipped state;
  Windows track called out alongside the Apple track.
- `docs/schema.md`: canonical reference for the SQLite schema, kind
  classification, content_hash algorithm, blob spillover rule, FTS5
  tokenizer chain, and Windows-clipboard-format → UTI translation.

## [2.5.6] – 2026-04-23

- iOS push path: tombstones from swipe-delete (and any future iOS-side
  capture) now drain to CloudKit. `AppContainer.pushNow` runs every
  pull cycle plus immediately after a delete. Before this, deletes on
  iOS sat in the local PushQueue forever.

## [2.5.5] – 2026-04-23

- Single-entry delete. iOS: swipe left on a row. Mac: right-click on a
  popup card → context menu with Quick Look, Share…, Delete.
- `EntryRepository.tombstone(id:)` is the shared helper — sets
  `deleted_at`, removes the FTS shadow, enqueues for CloudKit push.
- Mac Share uses `NSSharingServicePicker` anchored to the popup; image
  entries stage their primary flavor to a temp file so receivers see a
  proper image preview.

## [2.5.4] – 2026-04-23

- Configurable safety-net pull interval. Preferences → iCloud sync →
  *Safety-net pull every*. 5 min – 24 h, default 15 min, adaptive step.
- Quieter logs: empty no-change pull pages stop printing.
- Re-launching cpdb.app while it's already running pops the search UI
  (`applicationShouldHandleReopen`) instead of silently no-oping.

## [2.5.3] – 2026-04-23

- Stop polluting `text_preview` with `file://` URLs. The v2.5.0
  plain-text fallback to `public.file-url` was overwriting screenshot
  titles with 200-char file paths. Fallback now only matches
  `public.url` and `public.url-name`; file-URL handling stays in
  `Ingestor.deriveTitle` which extracts a sensible filename.
- New `cpdb backfill-titles` rewrites historical rows that got
  contaminated, then enqueues for CloudKit push so iOS / sibling Macs
  pick up the cleaned values.

## [2.5.2] – 2026-04-23

- **Event-driven push on the Mac.** `Ingestor` posts a
  `.cpdbLocalEntryIngested` notification on every insert/bump; the
  daemon runs `pushPendingChanges` immediately. New captures reach
  CloudKit in ~1–3 s instead of waiting up to 5 min for the periodic
  safety-net tick.
- **Cross-device pull dedup.** Three Macs with Universal Clipboard
  used to each capture the same content with byte-different flavor
  bytes, yielding three rows per device. The pull path now collapses
  incoming records with matching trimmed text onto an existing row
  within ±2 s.
- iOS live updates while foregrounded: 30 s foreground poll +
  scene-phase pull + GRDB `ValueObservation` → `dbChangeToken` so
  SearchView refreshes as soon as the DB changes from any source.
- Pull-side upsert no longer crashes with `UNIQUE constraint failed:
  entries.uuid` after `cpdb dedupe` — tombstoned rows now block
  re-insert instead of falling through to INSERT.
- iOS sync progress moved inline next to the filter button; the list
  no longer shifts when a pull starts/ends.
- v2.5.1 (folded into 2.5.2): Ingestor within-window dedup, `cpdb
  dedupe` cleanup command, iOS scene-phase + BGAppRefreshTask pulls,
  About-window text wrap, link badges in EntryRow.

## [2.0.0] – 2026-04-23

- **CloudKit sync across Macs.** Private Database custom zone,
  silent-push subscriptions, content-addressed CKRecord IDs (v2.1
  wire format), full-fidelity flavor `CKAsset` sync, iCloud-mirrored
  OCR + image tags + thumbnails. Install on a second Mac signed into
  the same iCloud account → full history appears.
- About window with live sync progress + library stats.
- Preferences iCloud pane: pause, reset change token, re-push
  everything.
- Multi-Mac deploy script (`deploy.sh`).
- git-sha build IDs (`CFBundleVersion` = marketing + short-sha).
- App icon generated from SF Symbols.
- Bundle id rename `local.cpdb` → `net.phfactor.cpdb` with one-time
  data-directory migration.
- Refactor: split `CpdbCore` into `CpdbCore` (macOS-only) +
  `CpdbShared` (cross-platform) so iOS can consume the shared layer
  later.

## [1.3.2] – 2026-04-21

- Live-search prefix matching (`tgncha` finds `tgnchat`) and a
  results counter in the popup header.

## [1.3.1] – 2026-04-20

- Fix Quick Look focus loss; gear icon to open Preferences from the
  popup; doc refresh.

## [1.3.0] – 2026-04-20

- **Quick Look for entries.** ⌘Y or Space (when search field is
  empty) pops Apple's full QL panel for the selected entry. Single-
  window Finder-like model — opening QL dismisses the popup, dismissing
  QL returns focus to the prior app. Optional "Remember position when
  opening Quick Look" preserves search + selection across QL round-
  trips.

## [1.2.2] – 2026-04-19

- Defeat the Passwords-app frontmost-race: track 5 seconds of
  frontmost-app activations so a Passwords copy that dismisses its
  sheet within ~50 ms still gets dropped. Apple-Strong-Password shape
  heuristic added as a final safety net.

## [1.2.1] – 2026-04-17

- Source-app blocklist: drop captures from `com.apple.Passwords` /
  `com.apple.keychainaccess`.

## [1.2.0] – 2026-04-17

- **On-device OCR + image classifier** for image entries
  (`VNRecognizeTextRequest.accurate` + `VNClassifyImageRequest`).
  Extracted text and tags fold into the same FTS5 index as plain
  text — search finds screenshots by their contents.
- Per-column scope toggles in the popup header (`text` · `OCR` ·
  `tags`). Match-source badge tells you which column hit.
- Configurable OCR languages in Preferences.

## [1.1.1] – 2026-04-17

- Prefer image classification when image bytes are present (kind=file
  entries with embedded image data get reclassified).
- `cpdb regenerate-thumbnails` backfill helper for older entries.

## [1.1.0] – 2026-04-17

- Image thumbnails generated at capture (256/640 px JPEG into the
  `previews` table).
- Popup auto-scrolls to newest entry on summon.
- Version shown in popup header.
- Full-width popup; per-kind rendering for text / link / image / file
  / colour cards.

## [1.0.0] – 2026-04-17

Initial release. Headless capture daemon + menu-bar app + global
hotkey + non-activating popup + paste-into-previous-app + Paste.db
importer (`com.wiheads.paste`) + CLI peer.
