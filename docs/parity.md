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

## Storage management (v2.6 series)

| Feature | macOS | iOS | Windows | Contract / notes |
|---|---|---|---|---|
| Pinning (`entries.pinned`) | ✅ v2.6.0 | ✅ v2.6.0 | ✅ v1.1.0 | contract: `docs/schema.md` § Pinning. Schema column already exists; sort order + eviction-skip semantics are mandatory; UI is per-platform |
| Storage usage diagnostic | ✅ v2.6.1 | — | ⏳ | iOS storage is small + caches itself; doesn't need the diagnostic |
| Time-window eviction | ✅ v2.6.2 | — | ⏳ | contract: `docs/schema.md` § Eviction. `body_evicted_at` column + sync round-trip + pull-side cooperation are mandatory |
| Test-fixture scaffolding | ✅ v2.6.3 | — | ⏳ | contract: env-var-overridable data dir; ditto-equivalent snapshot |
| Size-budget eviction (LRU + size-weighted) | ⏳ planned | — | ⏳ | not yet implemented anywhere |
| Per-kind quotas | ⏳ planned | — | ⏳ | optional advanced feature |
| iOS hydrate-on-demand | — | ⏳ planned | — | iOS-specific: pull metadata + thumbnail eagerly, fetch flavor body on detail-view open |

## CLI surface

The Mac CLI has accumulated subcommands as the data layer grew. The
Windows port is mostly UI; if it ships a CLI later, this table is
the punch list:

| Command | macOS | Windows | Notes |
|---|---|---|---|
| `cpdb list` | ✅ | — | |
| `cpdb search` | ✅ | — | |
| `cpdb show <id>` | ✅ | — | |
| `cpdb copy <id>` | ✅ | — | |
| `cpdb stats` | ✅ | — | |
| `cpdb storage` | ✅ v2.6.1 | ⏳ | tier-by-tier breakdown |
| `cpdb evict --before-days N` | ✅ v2.6.2 | ⏳ | manual eviction trigger |
| `cpdb fixture {snapshot, list, env, path, delete}` | ✅ v2.6.3 | ⏳ | test-data scaffolding |
| `cpdb dedupe` | ✅ v2.5.2 | — | Apple-specific (UC echo) |
| `cpdb backfill-titles` | ✅ v2.5.3 | — | one-off cleanup of historical regression |
| `cpdb sync {push-once, pull-once}` | ✅ v2.0 | — | CloudKit, Apple-only |

## Build / packaging

| Concern | macOS | iOS | Windows | Notes |
|---|---|---|---|---|
| Universal arm64 + x86_64 release | ✅ v2.5.7 | — | ✅ x64 | iOS is arm64-only by hardware |
| Code signing for distribution | ✅ Developer ID | ✅ App Store team | ✅ Authenticode (planned) | Mac: notarized DMG via `make publish`; Windows: Velopack-signed MSIX |
| Auto-update | ⏳ planned | — | ✅ Velopack | Mac path TBD (Sparkle?) |
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
