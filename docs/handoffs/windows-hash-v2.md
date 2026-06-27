# Hand-off: canonical-hash v2 — semantic content identity (Windows port)

> **Origin:** macOS/iOS, shipped in **cpdb 3.0.0** (and the `modified_at`
> piece in 3.1.0). Full design + rationale: [`docs/canonical-hash-v2.md`](../canonical-hash-v2.md).
> This doc briefs the Windows Claude session so it can port the new
> entry-identity algorithm + the schema columns and close the parity
> deviation `docs/parity.md` now records.
>
> **Not urgent.** cpdb-win is standalone (no cross-device sync), so
> nothing is broken today — Windows keeps working on its v1 hash. Do
> this to (a) keep the cross-platform content-hash contract aligned for
> any future sync, and (b) get the same dedup-quality win the Mac got
> (the jitter problem below affects the Windows clipboard too).

## TL;DR

Entry identity changed from a SHA-256 over the **full** clipboard
flavor/format set to a SHA-256 over the **primary content only**, chosen
by a deterministic rung chain:

```
image (≥1 KB) → file-url → url → normalized text → color → full-set fallback
```

Why: volatile sidecar formats (Chromium session tokens, Universal
Clipboard re-publication noise, link-preview metadata, encoding
variants) jitter byte-for-byte between otherwise-identical copies, so
the old full-set hash forked one logical clip into many rows. An audit
of a real library found 86% of duplicate pairs were this. Hashing only
the primary content makes "the same thing copied twice" converge to one
entry — on every platform.

Three things the Windows port needs:

1. **`ContentIdentity`** — port the rung chain (the algorithm is
   language-neutral and pinned by a shared test-vector file).
2. **Four new `entries` columns** + a one-shot **rehash migration** of
   the existing library.
3. **A byte-wise UTF-8 sort fix** in the existing `CanonicalHash` (it
   currently sorts with `StringComparer.Ordinal` — a latent bug, same
   one macOS had).

## The bug — real case

Copy the same caddy config snippet from Chrome twice, ~19 s apart.
Chrome re-emits the clipboard with a tweaked internal session token in
`org.chromium.source-url` (Mac) / its Windows clipboard-format analogue;
the user-visible text and HTML are byte-identical, only the volatile
metadata moves a byte. The full-set hash differs → two rows for one
clip. Likewise a URL copied on an iPhone arrives on an idle Mac via
Universal Clipboard as a bare `public.url`, forking from a normal copy
of the same URL. Semantic identity hashes only the URL/text, so all of
these collapse to one entry.

## The algorithm — authoritative sources

**Do not re-derive the hexes by hand.** Two artifacts are the contract:

- **`Tests/Fixtures/hash-vectors-v2.json`** — 26 pinned vectors:
  `{ name, items: [[{uti, base64}]], expect_tag, expect_hex, equals? }`.
  This file is **authoritative** over any prose. Your C# `ContentIdentity`
  must reproduce every `expect_hex` and `expect_tag`, and honour every
  `equals` relation. Port `CanonicalHashTests.cs` to a JSON-driven xUnit
  `[Theory]` reading this exact file (it's in the repo both platforms
  share).
- **`Tools/gen_hash_vectors.py`** — the reference implementation. When
  the prose in `docs/canonical-hash-v2.md` §2 and this Python disagree,
  the Python (and the JSON it emits) wins. Read `identity(flat)` and the
  primitives (`best_text`, `normalize_text`, `trim_url_set`,
  `strip_one_trailing_slash`, `looks_like_url_portable`, `percent_decode`,
  `v1_emission`) and mirror them exactly.

The payload is `SHA256( tag_utf8 || 0x00 || value_bytes )` where `tag` ∈
{`image`,`file`,`url`,`text`,`color`,`fallback`}. Output stays 32 bytes.
Pinned constants (all in §2.3): `URL_TRIM_SET` = {U+0020, U+0009, U+000A,
U+000D, U+00A0}; image threshold 1024 bytes; `VOLATILE_DENYLIST` (fallback
rung only); BOM-less UTF-16 = **little-endian** everywhere; strict
decode-or-skip (never substitute U+FFFD); the fallback flavor sort is
**byte-wise comparison of the UTF-8 encodings** of the UTIs.

## Windows-specific mapping (clipboard formats ↔ UTIs)

cpdb-win already translates Windows clipboard formats → UTIs in
`Capture/UtiTranslator.cs`. Identity runs on those UTIs, so most of the
rung chain is automatic. The contract notes that must hold:

- **`CF_UNICODETEXT` → `public.utf8-plain-text`**, decoded to UTF-8, then
  `normalize_text` applies **CRLF→LF** (load-bearing on CRLF-native
  Windows — a Mac LF copy and a Windows CRLF copy of the same text must
  produce the same `text` identity).
- **`CF_HDROP` (file list) → `public.file-url`**: flattening is
  first-occurrence-wins, so the **first path keys identity**; apply the
  same percent-decode + one-trailing-slash strip. There is no
  shared-pasteboard / Universal-Clipboard clause on Windows.
- **URL formats → `public.url`**: the url rung + the text→url promotion
  (a bare `http(s)://…` text copy) converge with Mac/iOS by construction.
  `UrlImporter.cs` inherits this automatically.
- **Images are explicitly platform-local.** `DIB`/`CF_DIBV5` → PNG
  encoding is **not byte-deterministic across encoders**, so a Windows
  image and a Mac image of the "same" screenshot will NOT share an
  identity. Document it; don't try to converge it. (v1 had the same
  property — image identity was always raw-bytes.)
- **HTML-as-text is platform-local too.** Mac hashes raw `public.html`
  bytes in the rung-4 ladder's last resort; Windows would hash its
  `CfHtmlParser.ExtractFragment` slice — guaranteed different for the
  same copy. State it honestly rather than papering over it. (This only
  affects the rare html-only-no-text clip.)

So **text, url, and file identities converge cross-platform; image and
html-only identities are platform-local.** That's acceptable — when
cross-platform sync eventually lands, those are the documented seams.

## The `VOLATILE_DENYLIST` ↔ `UtiTranslator` allowlist invariant

The fallback rung excludes a denylist of volatile UTIs. On Windows the
**`UtiTranslator` allowlist is the real enforcement mechanism**: if the
translator never emits a volatile format as a UTI, it can't reach the
hash. Add a **disjointness test** (`UtiTranslatorTests.cs` /
`CanonicalHashTests.cs`): assert no UTI the translator emits appears in
`VOLATILE_DENYLIST`. This keeps the fallback rung dormant-by-construction
as the translator grows. The Windows never-store analogues of the
nspasteboard transient/concealed markers are
`ExcludeClipboardContentFromMonitorProcessing` and
`CanIncludeInClipboardHistory` — honour them at capture (a whole-clip
skip), same as the Mac's `TransientGuard`.

## Schema changes (the four columns + the rehash)

Mac added these to `entries`:

| Column | Type | Meaning |
|---|---|---|
| `hash_version` | INTEGER, default 1 | 1 = legacy full-set hash; 2 = semantic identity |
| `prev_content_hash` | BLOB, nullable | the v1 hash retained after rehash (forensics + the importer's dual-era dedup probe) |
| `identity_tag` | TEXT, nullable | the rung that produced a v2 hash (image/file/url/text/color/fallback) |
| `modified_at` | REAL, NOT NULL | unix seconds of the last user mutation (pin/delete/restore) — see the undo section below |

**A one-shot rehash migration** then converts the existing library:
recompute every row's identity, set `prev_content_hash = content_hash`,
`content_hash = <v2>`, `hash_version = 2`, `identity_tag = <tag>`; rows
with no usable content (body-evicted, no flavor bytes) keep their v1 hash
and `hash_version = 1`. After rehashing, **collision-merge** rows that
now share a v2 hash (semantic identity is more aggressive, so genuine
dups collapse): keep the earliest, salvage pin/enrichment onto it,
tombstone the losers. This is far simpler than the Mac's cutover — **no
CloudKit, no zone, no resumable-cutover machinery** (cpdb-win is
standalone). It's just a local migration step. The Mac's
`Sources/CpdbShared/Store/IdentityCutover.swift` (`mergeCollisions`,
`EntryCoalesce`) is the reference for the merge logic.

> **Hard requirement:** `ContentIdentity` + the rehash migration ship in
> the **same Windows release**. The importer (`UrlImporter.cs`) and the
> capture `Ingestor.cs` both dedup by `content_hash`; if the algorithm
> changes but the existing rows aren't rehashed, every re-import /
> re-capture duplicates the whole library.

### ⚠️ Migration-identifier collision (resolve deliberately)

The migrator identifiers **diverged at v10**:

- macOS: `v1`…`v9` (shared), then **`v10_semantic_identity`**, **`v11_modified_at`**.
- Windows: `v1`…`v9` (shared), then **`v10_image_per_pass_timestamps`** (a
  Windows-only OCR split that macOS doesn't have).

Same number, different migrations. **Add the new Windows migrations under
fresh identifiers after Windows's v10** — e.g. `v11_semantic_identity`
(+ the rehash) and `v12_modified_at` — **do not** reuse `v10`. This is
fine: migration identifiers are **local bookkeeping** (each platform
tracks its own applied set in its migrations table); they do **not**
travel with synced data, and no DB crosses platforms today. The contract
that must hold is **column-set compatibility + the same `content_hash`
algorithm**, not identifier-string equality. Update `docs/schema.md` to
say migration identifiers are aligned through v9 and per-platform from
v10 onward, with the resulting schema kept compatible.

## `modified_at` + last-writer-wins (undo foundation)

`modified_at` is the timestamp of the last user mutation (pin / delete /
restore). On the Mac it drives **last-writer-wins** resolution on sync
pull so an undone delete propagates instead of staying deleted on a
sibling, and concurrent pin/unpin races converge. Windows has no sync
today, so it needs the **column** (for schema parity + future sync) but
not the pull-side LWW yet. Set it on insert (= `created_at`) and bump it
on pin/delete/restore. If/when Windows joins sync, port the LWW rule from
`Sources/CpdbShared/Sync/CloudKitSyncer.swift` (the `remoteMutationWins =
d.modifiedAt >= existing.modifiedAt` block). The undo **UI** itself
(Mac ⌘Z, iOS snackbar/shake) is per-platform and not a data contract —
build whatever fits WinUI; the reversible primitives are `restore()`
(un-tombstone + re-index FTS) and a pin toggle, both already trivial.

## Target code pointers (Windows)

- **`Capture/CanonicalHash.cs`** — (a) **fix the sort**: line ~38 uses
  `OrderBy(f => f.Uti, StringComparer.Ordinal)`. Ordinal compares UTF-16
  code units; the contract wants **byte-wise UTF-8** (`OrderBy(... )`
  comparing `Encoding.UTF8.GetBytes(uti)` lexicographically, e.g. a
  custom `IComparer<byte[]>`). No-op for ASCII UTIs, so existing v1
  vectors are unchanged; it's the correctness fix the fallback rung
  needs. (b) **Retain** `CanonicalHash` as the **fallback-rung emission**
  helper. Fix the stale "Swift `<` compares Unicode scalars" header claim
  if present.
- **`Capture/ContentIdentity.cs`** (new) — the rung chain. Mirror
  `Sources/CpdbShared/Capture/ContentIdentity.swift` /
  `Tools/gen_hash_vectors.py`.
- **`Capture/UtiTranslator.cs`** — the allowlist; add the disjointness
  invariant.
- **`Capture/Ingestor.cs`** — switch the capture dedup to compute v2
  identity + stamp `hash_version`/`identity_tag`/`modified_at`.
- **`Portability/UrlImporter.cs`** — inherits url-rung convergence; just
  ensure it dedups on the v2 hash + stamps the columns.
- **`Store/Schema.cs` + `Store/Migrator.cs`** — the four columns + the
  `v11_semantic_identity` (rehash + merge) and `v12_modified_at`
  migrations.

## Tests to mirror

- **JSON vectors**: `CanonicalHashTests.cs` → a `[Theory]` over
  `Tests/Fixtures/hash-vectors-v2.json` asserting `expect_tag` +
  `expect_hex` + `equals`. Include the non-ASCII-UTI sort-collation
  vector (it fails a wrong comparer on both platforms).
- **Disjointness**: no translator UTI ∈ `VOLATILE_DENYLIST`.
- **Rung-chain table tests**: image-beats-sidecars, sub-threshold-png →
  fallback, url-promotion + its negative, CRLF normalization, empty→fallback.
- **Migration test** (`MigratorTests.cs`): a v1-hash fixture DB rehashes
  to v2, collisions merge, columns populate, idempotent re-run.

## Wrap-up checklist (Windows side)

- [ ] `docs/parity.md` — flip the Windows cells for the hash-v2 /
      modified_at rows from ⏳ to ✅ with the Windows version stamp.
- [ ] `windows/CHANGELOG.md` entry.
- [ ] `windows/Directory.Build.props` `<Version>` bump (currently 1.37.0).
- [ ] Update `docs/schema.md` §Content identity + the migration-identifier
      note.

## What is NOT in scope for Windows

No CloudKit, no `cpdb-v3` zone, no resumable cutover, no pull-side
conflict resolution, no iOS-style read/write capture. cpdb-win is
standalone; this is purely: the identity algorithm, the four schema
columns, and the one-shot local rehash+merge migration.
