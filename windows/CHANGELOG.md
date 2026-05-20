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

- **Blank-image-preview root-cause fix.** The bug that started
  the v1.27.0 → v1.28.0 (frozen UI) → v1.29.0 (hotfix revert) →
  v1.32.0 (overlap fix) chain. The actual cause: `LoadBitmap`
  built a method-local `InMemoryRandomAccessStream`, called
  `BitmapImage.SetSource(stream)`, and returned. `SetSource`
  returns synchronously but the *decode* runs later — and is
  typically deferred until the consuming `Image` element enters
  a visible visual tree. For row-card thumbs that worked fine:
  the `Image` is already in a visible `ListView` item, decode
  runs immediately, stream is still alive. For the preview pane,
  `DetailImageScroll` starts `Collapsed` — decode was deferred
  until we flipped `Visibility = Visible`, by which time the
  local stream had been GC'd and there was nothing to decode
  from. Silently-empty `<Image>`.
  - **Fix:** pin the backing stream to the `BitmapImage`'s
    lifetime via `ConditionalWeakTable<BitmapImage,
    IRandomAccessStream>` — the stream is freed automatically
    when its bitmap is collected (no leak).
  - **Belt-and-braces:** `ShowImagePreview` now flips
    `DetailImageScroll.Visibility = Visible` *before* assigning
    `DetailImage.Source`, so the decode trigger fires immediately.
  - **Diagnostic.** Every preview now subscribes
    `ImageOpened` / `ImageFailed` and logs to
    `%LOCALAPPDATA%\cpdb\image-preview.log` (entry id, decoded
    pixel dimensions, or the WinUI error message). The previous
    three attempts (v1.27 null-check, v1.28 sync-over-async,
    v1.29 revert) burned cycles because we couldn't see what
    was actually happening; now we can. If this still doesn't
    fully fix it, the log says exactly why.

- **Preview pane no longer overlaps state from the previous
  selection.** Reported with a screenshot: selecting a link entry
  after an image entry showed the link title sitting on top of a
  leftover "Show OCR text" button and stray classifier tag chips
  from the previous image. Cause: `MainWindow.ShowDetail` reset
  only `DetailLinkScroll` + `DetailLinkImage.Source` up front; the
  image layout (`DetailImageScroll`, `DetailImage`, `DetailTagsList`,
  `DetailOcrButton`, `DetailOcrPanel`) and the text scroll
  (`DetailTextScroll`) were never collapsed when entering a
  non-image branch, so they rendered through. Fix: comprehensive
  reset at the top of `ShowDetail` — collapse all three layouts +
  clear sources + hide OCR/tags — then each branch only flips its
  own piece on. `ShowDetailEmpty` and `ShowDetailMulti` already
  did this; `ShowDetail` was the only entry point missing the
  call.

- **"Refetch all link titles" maintenance action.** A new
  `MaintenanceCommands.RefetchAllLinks` clears `link_title` +
  `link_fetched_at` + retry state on every live `kind=link` row
  (and the FTS5 shadow's `link_title` column) so the backfill
  loop re-fetches every title under current fetcher rules.
  Surfaced two ways:
  - **Preferences → Library maintenance → "Refetch all link
    titles"** — for already-settled rows that picked up the bare
    short title before v1.30.0's WordPress-aware precedence
    landed.
  - **`cpdb-win backfill-titles --refetch-all`** — symmetric with
    the existing `--retry-empty` flag (which only re-arms blanks);
    covers macOS's `cpdb fetch-link-titles --force`.

  Stronger than "Retry empty titles" — that one only wipes blanks;
  this one wipes successful settlements too. Tombstoned rows are
  skipped; non-link rows untouched.

- **WordPress-aware link-title preference.** Reported with a real
  case: pasting `https://ultracrepidarian.phfactor.net/` settled
  the title as just `"ultracrepidarian"` instead of the rich
  `"ultracrepidarian – ultracrepidarian: a person who criticizes,
  judges, or gives advice outside the area of his or her
  expertise."` that the page's `<title>` tag actually carries.
  Cause: our default precedence is `og:title → twitter:title →
  <title>` (the documented contract, good for most sites), but
  WordPress themes consistently put the bare post slug in
  `og:title` and the rich `"Title – Tagline"` form in `<title>`.
  Fix: detect WordPress via the standard
  `<meta name="generator" content="WordPress…">` tag (matches both
  WordPress.com and self-hosted, both attribute orders, case-
  insensitive) and reverse the order for those pages to
  `<title>` → og:title → twitter:title. Non-WP sites keep the
  default precedence. WP backs ~40-60% of public sites, so the
  payoff is broad. `LinkMetadataParser.LooksLikeWordPress` is
  exposed publicly so future callers can diagnose detection.
  *Existing rows whose link_title was already settled in the old
  short form aren't auto-refreshed — they'd need a "refetch all"
  reset (deferred to a follow-up if you want a Library-maintenance
  button for it); fresh captures pick up the new logic
  immediately.*

- **HOTFIX: unfreeze the UI.** v1.28.0 made `LoadBitmap` call
  `BitmapImage.SetSourceAsync(...).AsTask().GetAwaiter().GetResult()`
  to surface decode failures synchronously — but on the UI thread
  that's a classic sync-over-async deadlock: the WinRT
  `IAsyncAction`'s completion callback is marshalled back to the
  UI thread, which is stuck inside `GetResult()`. Observed
  symptom: clicking any image entry froze the window with a
  permanent mouse spinner; keyboard input was equally dead. v1.29.0
  reverts `LoadBitmap` to the original non-blocking
  `BitmapImage.SetSource` — the UI never blocks. The earlier
  blank-pane bug for some image entries is **deliberately left as
  a separate investigation** rather than risk another bad fix —
  better blank preview pane than a frozen window.

- **Image preview actually shows the image now.** v1.27.0's fix
  for the blank-pane bug was incomplete: `LoadBitmap` used
  `BitmapImage.SetSource(stream)`, which queues an *asynchronous*
  decode and never throws — corrupt / unsupported bytes fire
  `ImageFailed` with nobody listening, and the
  `InMemoryRandomAccessStream` local can be garbage-collected
  before the decode runs even for valid bytes, ending the same
  way. So `LoadBitmap` returned a non-null `BitmapImage`, the
  v1.27.0 null-check passed, and an empty `<Image>` reached the
  UI — including for ordinary, well-formed Chrome JPEG thumbs.
  Now `LoadBitmap` calls `SetSourceAsync(...).AsTask()
  .GetAwaiter().GetResult()` so the decode happens synchronously
  before returning: bad bytes *throw* (caught → returns `null` →
  fallback fires), good bytes are fully populated before
  `Image.Source` is assigned, and the stream is guaranteed alive
  across the call.

- **Image preview falls back to URL/metadata when the thumbnail
  can't be rendered.** Reported: selecting some image entries left
  the right pane completely blank — except for the source-URL +
  HTML-snippet bar at the bottom. Cause: the image branch in
  `MainWindow.ShowDetail` asked `LoadBitmap` to decode
  `previews.thumb_large`, but the call returns `null` for corrupt
  / unsupported bytes (BitmapImage swallows async decode failures),
  and we assigned that `null` straight to `DetailImage.Source` —
  leaving an empty `<Image>` element. Now `ShowDetail` decodes the
  thumb upfront and treats a `null` result the same as "no thumb
  available": fall through to the text-flavor branch (so the
  source URL becomes the main preview), still calling
  `ShowMetadata` for `kind=image` rows so source URL + HTML
  snippet stay anchored at the bottom. Net: an image with a bad
  thumb surfaces the URL prominently instead of a blank pane.
  `ShowImagePreview`'s signature now takes a decoded `BitmapImage`
  (no longer a `byte[]`) so a null bitmap can never reach the UI
  by mistake.

- **Preferences: separate Re-OCR / Re-tag buttons** (so re-running
  one analysis pass doesn't redo the other). The single combined
  "Re-OCR images" was misleading — under the hood the v1.24.0
  service did both OCR and classification, so resetting it actually
  cost both. Now there are two buttons and they really are
  independent:
  - **Re-OCR images** — clears only the OCR pass sentinel; the
    classifier tags on existing rows survive untouched and the
    analyzer re-runs only text recognition.
  - **Re-tag images** — clears only the classifier pass sentinel;
    existing OCR text survives and the analyzer re-runs only the
    image classifier.
- **Schema v10: per-pass image-analysis sentinels.** Adds
  `entries.ocr_at` and `entries.tags_at` (REAL, nullable) so OCR
  and the classifier can be reset independently. Backfilled from
  `analyzed_at` so existing fully-analyzed rows don't look like
  fresh candidates after the upgrade. `analyzed_at` stays as the
  Mac-parity "ever processed" marker; both passes still stamp it
  on settle. Migration is non-destructive (`ALTER TABLE … ADD
  COLUMN` + `UPDATE … SET … = COALESCE(…, analyzed_at)`).
- **`ImageAnalysisService` skips already-done passes.** Each
  candidate now carries `NeedsOcr` / `NeedsTags` flags so the loop
  runs only the pass(es) actually missing. Capture-wake on a fresh
  image still does both; a "Re-OCR" reset only re-OCRs.
- **CLI unchanged:** `cpdb-win analyze-images [--force]` still
  resets and re-runs both passes (the macOS contract).

- **Image tags are interactive in the preview pane.** Under the
  thumbnail, the image-classifier's top-3 labels now render as
  clickable chips. Click any one → search box gets the label, kind
  filter resets to "All", and the main list refilters to show
  every entry whose text / OCR / link title / image tags contains
  that word — image search by content, one click. The list query
  carries `image_tags` directly (short strings, ~30 bytes/row) so
  the chips appear instantly with no per-selection DB hit.

- **Tag storage switched to comma+space separation.** v1.24.0 used
  a single space, but ImageNet has multi-word labels
  ("great white shark"), so a space made the stored string
  ambiguous to split for display. Storage and display now use
  `", "`; FTS5's unicode61 tokenizer splits on both whitespace
  *and* punctuation, so search-by-tag works against both legacy
  v1.24.0 and current data. The display parser
  (`CpdbWin.Core.Analysis.ImageTags.Parse`) auto-detects and
  handles either form.

- **Image classification (tags) — `image_tags` finally populated.**
  The Windows analogue of macOS Vision's `VNClassifyImageRequest`,
  closing the half of the OCR-+-tags parity row Windows was
  missing. Bundled **MobileNetV2** ImageNet-1k ONNX (~13 MB) +
  human-readable 1000-class labels, run through
  Microsoft.ML.OnnxRuntime (ships native libs for both win-x64 and
  win-arm64 — picked up automatically per RID on publish).
  Top-3 labels per image, space-separated, stored in
  `entries.image_tags` and folded into the FTS5 `image_tags`
  column, so a screenshot of a laptop is searchable by `laptop`
  alongside any text the OCR pass found in it.
  - **One pass, one DB write per image.** `ImageAnalysisService`
    now runs OCR and classification sequentially on the same
    decoded bytes, then settles both via the new
    `EntryRepository.SettleImageAnalysis(id, ocrText, imageTags)`
    — one transaction, one FTS5 update. Existing `SettleImageOcr`
    is a back-compat alias so v1.22.x callers/tests stay valid.
  - **Best-effort load.** A missing model file or failed native-
    lib load returns `null` tags; OCR keeps working. Accuracy and
    label vocabulary differ from Apple's classifier — the parity
    claim is "image search by content", not byte-for-byte tag
    equality.

- **OCR is visible in the UI.** Image entries that have been
  OCR'd now show a small **OCR** chip on the list row, and the
  preview pane gets a **Show OCR text** button under the image.
  Click it to expand a scrollable, **selectable** text block —
  mouse-select any subset and Ctrl+C copies just that portion (the
  whole text isn't pushed back into the clipboard, you choose what
  to take). The `EntryRepository` list query carries only a cheap
  `has_ocr` non-empty flag so 100-row lists don't lug full OCR
  strings; the panel fetches the actual text on demand via a new
  `GetOcrText(id)`.

- **On-device OCR for image entries.** The Windows analogue of the
  macOS Vision text pass — screenshots become searchable by their
  contents. `ImageOcr` wraps Windows' built-in
  `Windows.Media.Ocr.OcrEngine` (no model bundle, no network, no
  new dependency — Core already used WinRT imaging).
  `ImageAnalysisService` mirrors the proven `LinkBackfillService`
  loop: capture-wake on every kind=image insert + a 15-min sweep,
  reentry-guarded, `analyzed_at` as the one-shot sentinel (stamped
  even when no text is found, so a blank image isn't re-OCR'd
  forever). Recognised text is written to `entries.ocr_text` and
  folded into the existing FTS5 `ocr_text` column, so it ranks in
  the same search. Surfaces: `cpdb-win analyze-images [--force]`
  (the CLI process does the OCR itself, like macOS); Preferences →
  Library maintenance → **Re-OCR images**; live UI refresh when a
  row settles. **Image classification tags** remain out of scope
  (no built-in Windows equivalent of Vision's
  `VNClassifyImageRequest`; `image_tags` stays NULL — tracked ⏳).

- **Preferences parity with macOS.** The Settings window grew from
  hotkey + import/export to a scrollable pane closing the macOS
  gap (for the sections that actually apply to a standalone
  Windows build):
  - **Startup** — "Launch cpdb-win at login" toggle, wired to
    `AutoLaunch` (was tray-menu-only). Disabled with an explanation
    on a non-installed build (can't hijack the shared Run key).
  - **Library maintenance** — "Re-enrich now" (reclassify URL-text
    → link, then queue title/thumbnail refetch for title-less
    links), plus discrete "Reclassify kinds" / "Retry empty
    titles". Same `CpdbWin.Core.Maintenance` engine as the CLI, run
    on a worker connection; pokes the main window + lets the
    backfill loop pick the candidates up. This is the self-serve
    fix for a stale/restored library.
  - **Storage** — read-only DB path, db/wal/shm + blob sizes, and
    live / pinned / total entry counts (closes the macOS "Storage
    usage diagnostic" parity row).
  - **Updates** — "Check for Updates…" + current version, mirroring
    the tray item into the window.
  - Deliberately *not* mirrored: iCloud sync (Apple-only), Quick
    Look position (no Quick Look on Windows), Image-analysis
    OCR/threshold (engine not implemented yet), Permissions (no
    Windows runtime-permission equivalent).

- **Maintenance CLI ships in the installer.** `cpdb-win.exe`
  (`reclassify-kinds`, `backfill-titles --retry-empty`, `dedupe`,
  `import-urls`, `export`) was only ever a from-source build —
  there was no way for an installed user to trigger re-enrichment
  or other maintenance. `build-installer.ps1` now publishes the
  CLI (self-contained, same RID) into the same folder Velopack
  packs, so it installs alongside the GUI at
  `%LOCALAPPDATA%\CpdbWin\current\cpdb-win.exe` and stays current
  across auto-updates. Example — re-enrich a restored/old library:
  `cpdb-win reclassify-kinds` then `cpdb-win backfill-titles
  --retry-empty`, then relaunch cpdb-win so the backfill loop
  fetches the titles + thumbnails.

- **GUI URL-import now refreshes the main window.** The
  Preferences "Import" path writes via its own worker-thread
  SqliteConnection (so a big import doesn't freeze the UI and
  doesn't touch the capture connection cross-thread). The side
  effect: it never raises `CaptureService.Ingested`, so the main
  window — which only re-queries on a capture / backfill-settle /
  search-box change — kept showing the pre-import list and the
  freshly-imported rows looked missing (they were in the DB the
  whole time). A successful import with new/bumped rows now pokes
  the main window to re-query (new `MainWindow.RequestRefresh()`,
  wired via an `onStoreChanged` callback through `PreferencesWindow`).

- **Main-window interaction: click selects, double-click / Enter
  activates.** Previously a single click *activated* an entry
  (copied it, hid the window, pasted back) — so you couldn't
  browse or multi-select without triggering a paste. Now a single
  click only selects (native Shift/Ctrl range + toggle, preview
  pane updates); **double-click or Enter** copies the entry to the
  clipboard, hides the window, and pastes it back to the app you
  came from. Right-click menu (Pin / Delete) unchanged.

- **Delete keeps your place in the list.** After deleting the
  selected entry the cursor snapped back to the top *and* keyboard
  focus fell back to the search box (the list re-query rebuilds the
  ItemsSource, destroying the focused row), so clearing several
  rows meant re-navigating every single time. Delete now re-selects
  the row that slid into the deleted slot (or the new last row if
  you deleted the tail) **and** restores keyboard focus to that row
  when the delete came from the list — so you can sit there and hit
  Delete repeatedly to walk straight down the list. A delete driven
  from the search box (type-to-filter + arrow nav) deliberately
  keeps focus in the box. The preview pane follows the new
  selection.

- **Autostart can no longer be hijacked by a non-installed build.**
  Autostart is one shared `HKCU\…\Run\CpdbWin` value. A dev / Debug
  / portable run (e.g. a `bin\Debug` build used for testing) called
  `AutoLaunch.SetEnabled(true)` and overwrote it with its own
  throwaway path — so a reboot launched the *stale dev binary*
  instead of the real install (observed: an ancient 1.11 dev build
  auto-starting after the install had updated to 1.16.0). Now
  `AutoLaunch` only writes the Run key when the running process
  lives under the Velopack install root
  (`%LOCALAPPDATA%\CpdbWin\`); a non-installed build leaves both
  the Run key and the one-time `AutoLaunchInitialized` flag
  untouched. Disabling autostart is still allowed from any build so
  a bad entry can always be cleaned up.

## [1.16.0] – 2026-05-19

- **Exports implement the corrected v2.9.6 contract.** The v2.9.0
  exporter dropped enrichment: fetched link/YouTube titles were
  only folded into the headline (no distinct field), OCR was
  truncated to 500 chars, and `image_tags` was missing from HTML.
  macOS v2.9.6 corrected the contract; Windows now matches it
  byte-for-byte:
  - Every enrichment field is surfaced **explicitly labelled** —
    `fetched_title` (YouTube/page titles), the **full** untruncated
    `ocr_text`, and `image_tags`. Markdown gets a per-entry
    enrichment block (`**Fetched title:**` / `**Image tags:**` /
    fenced `**OCR text:**`); HTML gets `.enrich` rows + dark-mode
    styling; **CSV header is now 13 columns** (`fetched_title`
    inserted after `headline`).
  - All embedded captured text is **LF-normalised** (`\r\n`/`\r`
    → `\n`) and the whole document is guaranteed CR-free — captured
    clipboard text routinely carries CRLF, which made editors
    prompt to "fix" the file.

## [1.15.0] – 2026-05-19

- **Persistent tray-icon visibility across updates.** The
  notification-area icon now registers with a fixed `guidItem`
  (`NIF_GUID`). Windows keys the user's "show this icon on the
  taskbar" preference by icon identity; without a GUID that
  identity is the executable path, and Velopack installs each
  version in its own folder — so every auto-update looked like a
  new icon and silently dumped it back into the hidden overflow.
  With a stable GUID the choice survives updates. Includes a
  fallback (release stale GUID binding → retry → drop GUID) for
  the known Velopack path-rebinding edge case so the icon can
  never fail to appear.

## [1.14.0] – 2026-05-19

- **Single-instance guard.** Launching cpdb-win while it's already
  running (e.g. "Launch on login" started it at boot, then the user
  double-clicks the shortcut) used to spin up a second process —
  two capture loops, two global-hotkey registrations fighting, and
  two writers on one SQLite DB. Now a named-mutex guard makes the
  duplicate launch exit immediately and instead surface the
  already-running window. The guard sits after Velopack's
  install/update hooks, so auto-update's restart is unaffected.

- **Visible Settings button.** Preferences (Import / Export,
  hotkey, update check) was only reachable by right-clicking the
  tray icon — undiscoverable. Added a gear button to the main
  window's top bar that opens the same Preferences window; the
  tray menu item stays as a secondary path.

## [1.13.0] – 2026-05-19

- Internal version bump folded forward into v1.14.0 (no separate
  release cut).

## [1.12.0] – 2026-05-18

- **Boot diagnostics + empty-DB circuit breaker.** Hardening
  after an unexplained, unrecoverable history loss. Two parts:
  - *Gc audit log.* `Gc.Run()` returns a `Stats` (tombstoned /
    hard-deleted / orphaned) that was previously discarded — a
    destructive sweep left no trace. It is now written to
    `%LOCALAPPDATA%\cpdb\gc.log` (`liveBefore` → `liveAfter`)
    alongside the other diagnostic logs.
  - *Circuit breaker.* Each clean boot records the live-entry
    count to a `.entrycount` sidecar. If the next boot finds the
    DB went non-empty → zero, cpdb-win skips Gc, refuses to start
    capture (the DB is frozen for inspection), writes a loud
    `DATA-LOSS-WARNING.txt`, and tells the user. One-shot — the
    marker is rewritten so a deliberate "clear history" doesn't
    lock the app out.

## [1.11.0] – 2026-05-11

- **Client-side auto-update (x64 + arm64).** Functional parity
  with the macOS Sparkle contract (`docs/parity.md § Auto-update`).
  Until now the app only *shipped* a Velopack installer + delta
  `.nupkg`s — a running cpdb-win never noticed a new release. New
  `UpdateService` (CpdbWin.App) over Velopack's
  `UpdateManager` + `GithubSource`:
  - Background check 30s after launch, then every 24h, plus an
    on-demand **"Check for Updates…"** tray menu item.
  - **Prompt, not silent**: an available update is downloaded in
    the background, then a Yes/No box offers restart-to-apply.
    cpdb-win never restarts unasked.
  - Skips dev / debug / portable runs (`UpdateManager.IsInstalled`
    is false) — a manual check says so; the background cadence
    stays quiet.
  - Reentry-guarded so startup / daily-timer / manual triggers
    coalesce. All failure swallowed + logged to
    `%LOCALAPPDATA%\cpdb\update.log`; a manual check also surfaces
    up-to-date / error in a message box so the menu item never
    looks dead.
- **Per-architecture Velopack channels.** `build-installer.ps1`
  packs each rid with `--channel win-<arch>`, which makes every
  emitted artifact architecture-qualified
  (`releases.win-x64.json` / `releases.win-arm64.json`,
  `CpdbWin-<ver>-win-<arch>-full.nupkg`,
  `CpdbWin-win-<arch>-Setup.exe`, `RELEASES-win-<arch>`). Both
  arches' installers AND both arches' auto-update feeds now
  coexist on a single GitHub release with zero filename collision
  (verified empirically against Velopack 0.0.1298 — the channel
  is baked into the nupkg name, not just the manifest).
  `release-installer.ps1` uploads both feeds; `UpdateService`
  picks `ExplicitChannel` from
  `RuntimeInformation.ProcessArchitecture`, so an x64 install only
  ever downloads x64 packages and an arm64 install only arm64.
- **Auto-update only sees published releases.** GitHub's
  unauthenticated API hides draft releases, so testers never
  auto-update to an unpublished draft — the desired behavior.
  Publish a release to make it offered.
- **Migration note.** Builds before 1.11.0 were packed on
  Velopack's default `win` channel. The in-app updater on a
  pre-1.11.0 install looks for the old `releases.win.json`, which
  1.11.0+ releases no longer carry (they ship
  `releases.win-x64.json` / `-arm64`). Existing testers should
  **re-install once from the 1.11.0 `Setup.exe`** for their arch;
  from then on auto-update tracks the matching per-arch channel.

## [1.10.0] – 2026-05-11

- **Data portability — URL-list import + history export.** Parity
  with macOS v2.9.0 / v2.9.5 (`docs/parity.md § Data portability`).
  One engine implementation per feature, shared by the CLI and the
  WinUI Preferences pane (not duplicated):
  - `CpdbWin.Core.Portability.UrlImporter` — parse a URL list
    (trim, drop blank + `#`-comment lines, accept only
    `http`/`https`/`file`, reject others with a reason). Each
    accepted line becomes a synthetic `public.url` +
    `public.utf8-plain-text` snapshot ingested via the normal path
    so it lands kind=link and enriches through the backfill loop.
    Attributed to a synthetic "cpdb import" source app
    (`cpdb.import`) so seeded rows are distinguishable.
    `spreadSeconds` backdates `captured_at` (oldest line = oldest)
    so a bulk import doesn't collapse to one timestamp.
  - `CpdbWin.Core.Portability.HistoryExporter` — newest-first by
    `created_at`, metadata + text only (no flavor bytes). Three
    formats: **md** (paragraph per entry), **csv** (RFC-4180,
    exactly 12 columns: `id,kind,pinned,evicted,created_at,
    captured_at,source_app,device,headline,text_preview,ocr_text,
    image_tags`), **html** (self-contained, dark-mode `@media`, no
    external assets). `headline` = link_title › title ›
    text_preview › `(kind)`. Timestamps ISO-8601. `--limit` and
    `--include-evicted` honored.
- **CLI: `cpdb-win import-urls` + `cpdb-win export`.**
  - `cpdb-win import-urls FILE [--dry-run] [--spread-seconds N]`
    — `--dry-run` prints the accept/reject plan without touching
    the store.
  - `cpdb-win export --format md|csv|html [--output FILE]
    [--limit N] [--include-evicted]` — no `--output` streams the
    document to stdout (pipes / redirects), so
    `cpdb-win export --format csv > history.csv` works.
- **Preferences "Import / Export" section.** File-open picker →
  import (1-hour spread); format combo + file-save picker
  (pre-named `cpdb-export-<yyyy-MM-dd>.<ext>`) → export. Both run
  on a worker thread with a private `SqliteConnection` (WAL
  coexists with the live capture connection — never touch the
  shared `_host.Database` cross-thread); a status line reports the
  result. File pickers use `InitializeWithWindow` since the app is
  unpackaged WinUI 3.

Tests: +33 (410 total green; was 377). `UrlImporterTests`:
scheme-filter Theory, comment/blank stripping, importer-app
attribution, dup→bump, empty set, `spreadSeconds` oldest-first
backdating, snapshot flavor shape. `HistoryExporterTests`:
format parsing + extension, newest-first ordering + limit +
tombstone exclusion, headline precedence, CSV 12-column header +
RFC-4180 escaping + ISO-8601 timestamps + pinned/evicted flags,
Markdown shape, HTML self-contained + dark-mode + escaping, "no
flavor bytes" guard.

## [1.9.0] – 2026-05-01

- **Paste-back actually works now.** Picking an entry in the popup
  has, since v1.4.0, hidden the window and synthesized Ctrl+V to
  the previously-foreground app. The hide + foreground transition
  was correct but `SendInput` was silently rejecting every event:
  the managed `INPUT` struct only declared the `KEYBDINPUT` arm of
  the union (24 bytes), so `Marshal.SizeOf<INPUT>()` returned 32
  while the OS expects 40 bytes on x64. With `cbSize` mismatched,
  `SendInput` returned 0 inputs injected and we never noticed
  because we didn't check the return value. Fixed: union now
  spelled out with `MOUSEINPUT` + `KEYBDINPUT` + `HARDWAREINPUT`,
  the return value is logged so a future regression won't be
  silent.
- **Foreground-app capture is now resilient.** Previous version
  only captured `LastForegroundHwnd` inside `BringMainToFront`
  (hotkey / tray-click paths). After a successful paste-back
  cleared the captured HWND, any subsequent way the window came
  back to view (Activated re-fire, click-back, prefs return,
  etc.) didn't have a fresh HWND to paste to — paste-back
  silently no-op'd. Now we install a global
  `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` that updates
  `LastForegroundHwnd` on every foreground change, excluding our
  own window. The captured target reflects the last non-cpdb-win
  app that was foreground, regardless of how cpdb-win was
  summoned.
- **`AttachThreadInput` on the way out.** Hardened the
  `SetForegroundWindow` call after our window hides — the same
  thread-input-fusion trick we use to steal focus on summon now
  also fuses for the foreground hand-back, so the OS reliably
  honors the focus restore even when our process isn't the
  freshly-deactivated one.
- **`ShowWindow(SW_RESTORE)` only when iconic.** Previous version
  unconditionally `SW_RESTORE`'d the previous window before
  pasting, which on a non-minimized window can toggle z-order /
  snap state and visually move it. Now we only un-minimize when
  the previous window is actually minimized (`IsIconic`).
- **Modifier-state drain before SendInput.** If the user is
  still physically holding `Shift` from the `Ctrl+Shift+V` hotkey
  by the time we paste back, our synthetic `Ctrl+V` recombines
  with the held `Shift` into `Ctrl+Shift+V` — which is our own
  hotkey, so we'd pop the window back up instead of pasting. Now
  we send synthetic key-up events for `Shift` / `Alt` / `Win`
  before issuing `Ctrl+V`.
- **`%LOCALAPPDATA%\cpdb\paste-back.log`.** Per-event diagnostic
  log for the paste-back path: which entry was activated, whether
  the clipboard write succeeded, the captured prevHwnd, whether
  `SetForegroundWindow` worked, the foreground class name + first
  40 chars of the clipboard text right before SendInput, and the
  number of inputs SendInput accepted. Self-rotates at 1 MB.

- **README per-platform badges.** Two CI status badges (Tests ·
  macOS+iOS / Tests · Windows) plus a "Supported platforms"
  matrix using shields.io static badges for macOS arm64 / x86_64,
  iOS arm64, Windows x64 / arm64.
- **Velopack `--shortcuts StartMenu,Desktop`.** Explicit in
  `build-installer.ps1` so future installer-driven installs
  always create both shortcuts. Velopack's default left some
  testers without a Start menu entry on first install.
- **`windows/create-start-menu-shortcut.ps1`** — for testers on
  pre-1.9.0 builds (no `--shortcuts` flag) or running directly
  from a Debug build, a one-shot helper that resolves the cpdb-win
  exe and writes Start menu + Desktop `.lnk` files.

## [1.8.0] – 2026-05-01

- **In-place schema migrator.** New `Migrator.EnsureSchema(db)` is
  the single boot entry point: fresh installs run `Schema.Initialize`,
  existing v1.0/v1.1 installs (schema v5) flow through `Migrate`
  which applies v6 (pinned + index), v7 (body_evicted_at), v8
  (link_title + link_fetched_at + FTS5 rebuild + reindex live rows),
  v9 (link_retry_count + link_retry_after) — only the missing
  steps. Idempotent: safe to call on a fully-up-to-date DB and
  picks up where it left off if a previous boot crashed mid-
  migration. Previously the upgrade path was "delete cpdb.db and
  start fresh" — testers lost their history.

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
