# Changelog

Notable changes per release. Signed binaries on the
[GitHub releases page](https://github.com/phubbard/CopyPasteDataBase/releases).

The `[Unreleased]` section accumulates between releases. `make publish-github`
moves it into a new dated `[X.Y.Z]` heading at tag time and resets the
working area to empty. Edit it freely if a commit message wasn't quite
human-readable — what's in `[Unreleased]` is what ships.

## [Unreleased]

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
