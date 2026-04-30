# Changelog

Notable changes per release. Signed binaries on the
[GitHub releases page](https://github.com/phubbard/CopyPasteDataBase/releases).

The `[Unreleased]` section accumulates between releases. `make publish-github`
moves it into a new dated `[X.Y.Z]` heading at tag time and resets the
working area to empty. Edit it freely if a commit message wasn't quite
human-readable — what's in `[Unreleased]` is what ships.

## [Unreleased]

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
