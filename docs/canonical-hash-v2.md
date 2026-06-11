# Canonical hash v2 — content identity

**Status:** final design, ready to implement. Supersedes `docs/schema.md` §Canonical hash (v1).
**Identity revision constant:** `idv2-r1` (logged with every computed hash; never a hash input).
**Philosophy:** entry identity = SHA-256 of the *primary* content only (image bytes > file-url > url > normalized text > color > full-set fallback). Identity matches user-perceived content; storage keeps full capture fidelity. Validated by simulation as **V4_semantic** plus three sim-gated refinements (URL trailing-slash strip, URL-context trim, html-as-text rescue).

---

## 1. Motivation (measured)

v1 hashes the full flavor set, so any volatile sidecar forks identity. The audit of the production snapshot (`/tmp/cpdb-audit.db`, 9,630 live entries) found the forks are systemic, not incidental: among same-text/different-hash pairs, `public.file-url` differed in **32/33 pairs**, raw `public.utf8-plain-text` bytes in 14 (whitespace/line-ending jitter), `org.chromium.source-url` in 7, `public.utf16-external-plain-text` (BOM/encoding) in 7, `com.apple.linkpresentation.metadata` in 6, `public.html` in 5, `public.rtf` in 3, `com.apple.WebKit.custom-pasteboard-data` in 3. The UTI population also includes 650+ `dyn.*` rows and `com.apple.iWork.pasteboardState.documentId-<n>` (volatile ID embedded in the UTI *name*) — a denylist can never stay ahead of this.

The simulation (`/tmp/identity_sim.py` over the audit DB, 9,624 rehashable live entries) measured four candidate identity functions:

| candidate | clusters merged | excess rows eliminated | v1-distinct pairs merged | false merges (flavor-verified) |
|---|---|---|---|---|
| V2 (UTI denylist) | 24 | 26 | 28 | 0 |
| V3 (UTI allowlist) | 46 | 50 | 57 | 0 |
| **V4 (semantic)** | **441** | **502 (5.2% of live corpus)** | **574** | **0** |
| V5 (semantic + trim) | 502 | 569 | 677 | 0, but 25 rtf/html-variant collapses and a 4.3-year whitespace mega-cluster |

V4 has **20× the dedup power of UTI filtering** (502 vs 26/50 rows) because UTI filtering still hashes raw text and file-url bytes — the two dominant jitter sources. 344/441 clusters (78%) have <30s spread: exactly the same-copy jitter the 30s Ingestor window papers over locally but CloudKit pulls bypass. Every flagged cluster was inspected at the raw-flavor level; all merges are legitimate (e.g. ids 3165/5938 byte-identical `public.url`; ids 4572/9398 byte-identical text 262 days apart, rtf differing only by `cocoartf` writer version).

V5's general outer-whitespace trim is **rejected**: +67 rows (+12%) at the cost of tripled >1-day text merges (59 vs 29), 5× formatting-variant collapses (25 vs 5), and the whitespace mega-cluster. Two narrow V5-adjacent rules survive because they are bounded and corpus-validated: trimming in *URL contexts only*, and special-casing empty content.

Why now: iOS is about to become a read/write peer. Coordination-free multi-writer convergence requires that two devices capturing the same content compute the same identity with no shared state — v1 structurally cannot deliver that.

---

## 2. Identity definition

### 2.1 Payload

```
content_hash_v2 = SHA256( tag_utf8 || 0x00 || value_bytes )
```

Tags (domain separators, none contains 0x00): `"image"`, `"file"`, `"url"`, `"text"`, `"color"`, `"fallback"`. Output stays 32 raw bytes — every `hex.count == 64` parser (`FlavorRecordMapper.swift:126-139`, `CloudKitSyncer.contentHashFromRecordName:1299`) keeps its length assumption, and record names stay `entry-<64hex>`.

### 2.2 Flattening rule (multi-item snapshots)

Item grouping is not persisted (`entry_flavors` PK is `(entry_id, uti)`, flattened with `onConflict: .ignore` at `Ingestor.swift:221`), so v1's capture-time hash was never reproducible from the DB for multi-item captures. v2 defines identity over the **flattened flavor map**, computed identically at capture and rehash time:

```
flatten(items) -> map<uti, bytes>:
  for item in items (original order):
    for flavor in item.flavors:
      if flavor.uti not in map: map[uti] = bytes   # first occurrence wins
```

This exactly mirrors insert semantics, so `flatten(capture) == flatten(stored rows)` by construction. The v1 `0x01` item separator survives only inside the fallback emission (2.3 rung 6).

### 2.3 The rung chain

Lives in a new `Sources/CpdbShared/Capture/ContentIdentity.swift`, shared by macOS and iOS, ported to `windows/CpdbWin.Core/Capture/ContentIdentity.cs`. Evaluated top-to-bottom over the flattened map; first matching rung wins.

```
SHARED_PASTEBOARD_MARKER = "group.com.apple.coreservices.useractivityd/shared-pasteboard/"
URL_TRIM_SET  = { U+0020, U+0009, U+000A, U+000D, U+00A0 }     # pinned, exhaustive
IMAGE_UTIS    = ["public.png","public.jpeg","public.tiff","public.heic","public.heif","public.image"]
IMAGE_MIN     = 1024  # bytes

func identity(flat: map<uti, bytes>) -> (tag, value):

  # Rung 1 — IMAGE (mirrors hasSubstantiveImageFlavor, PasteboardSnapshot.swift:198-216)
  for uti in IMAGE_UTIS:
    if flat[uti] exists and len(flat[uti]) >= IMAGE_MIN:
      return ("image", flat[uti])                      # raw bytes, highest-priority flavor

  # Rung 2 — FILE
  if flat["public.file-url"] exists:
    s = strict_utf8(flat["public.file-url"])           # decode failure -> skip rung
    if s != nil and not s.contains(SHARED_PASTEBOARD_MARKER):   # UC echo: never keys identity
      s = percent_decode(s)
      s = strip_one_trailing_slash(s)                  # see 2.4
      return ("file", utf8_bytes(s))

  # Rung 3 — URL
  if flat["public.url"] exists:
    s = strict_utf8(flat["public.url"]); if s == nil: skip rung
    s = trim(s, URL_TRIM_SET)
    s = strip_one_trailing_slash(s)
    if s nonempty: return ("url", utf8_bytes(s))

  # Rung 4 — TEXT, with URL-shaped-text promotion
  t = best_text(flat)                                  # decode ladder, see below
  if t exists:
    t = normalize_text(t)                              # BOM strip, CRLF/CR -> LF; NO trim, NO NFC
    if t is empty: goto Rung 6                         # empty-content guard (sim wart)
    p = trim(t, URL_TRIM_SET)
    if looks_like_url_portable(p):
      return ("url", utf8_bytes(strip_one_trailing_slash(p)))   # TRIMMED value — converges pbcopy '\n'
    return ("text", utf8_bytes(t))                     # untrimmed — V4, not V5

  # Rung 5 — COLOR
  for uti in ["com.apple.cocoa.pasteboard.color","public.color"]:
    if flat[uti] exists: return ("color", flat[uti])

  # Rung 6 — FALLBACK
  kept = { (uti,bytes) in flat where uti not volatile }   # VOLATILE_DENYLIST, 2.4
  if kept is empty: kept = flat
  return ("fallback", v1_emission(kept))               # uti||0x00||u64be(len)||bytes per flavor,
                                                       # UTF-8 BYTE-wise sorted, then trailing 0x01
```

**Rung index** (carried on the wire for conflict resolution, §5.2): image=1, file=2, url=3, text=4, color=5, fallback=6. Lower index = computed from more-authoritative input.

**best_text ladder** (decode policy pinned — adversarial finding on Foundation/.NET divergence):

1. `public.utf8-plain-text` — strict UTF-8 validation; invalid → skip source.
2. `public.plain-text` — attempted as strict UTF-8; invalid → skip (MacRoman-era producers fall through).
3. `public.utf16-external-plain-text` — BOM present → use its endianness and strip it; **BOM-less → little-endian on every platform** (matches modern Mac host order and C# `Encoding.Unicode`); strict decode, unpaired surrogate → skip.
4. `public.utf16-plain-text` — same rules.
5. `public.html` raw bytes, strict UTF-8 — last resort; rescues ~10 of the 19 simulated fallback entries (Chromium copies with html but no text flavor). html-sourced text identity is **platform-local** (§6, Windows hashes the CF_HTML fragment slice — documented, not converged).

All sources fail → proceed to rung 5/6. A skipped source never substitutes U+FFFD.

**normalize_text** (byte-level, after strict validation): strip one leading `EF BB BF`; `0D 0A` → `0A`; remaining `0D` → `0A`. No outer trim (V5 rejected), no Unicode NFC. CRLF→LF is a no-op on the Mac corpus (zero CRLF jitter found) but is load-bearing for Windows convergence.

**strip_one_trailing_slash(s)**: if `s` ends with `"/"` and does not end with `"://"`, remove exactly one trailing `/`. `"https://x.com//"` → `"https://x.com/"`; `"https://"` untouched. Applied in rungs 2, 3, and the promotion — this closes the corpus-observed trailing-slash fork (ids 3165/5938) *and* the cross-route fork between `public.url "https://example.com/"` and text `"https://example.com"`. **Sim-gated** (§9 step 0): the rule ships only after `/tmp/identity_sim.py` re-runs with it and flavor-level inspection of the marginal clusters shows no false merges; the vectors below are generated with the rule in.

**looks_like_url_portable(p)** (p already trimmed): `len(p) <= 2048`; starts with literal `http://` or `https://` (lowercase exact match); contains no code point from URL_TRIM_SET; the substring between `://` and the first of `/ ? #` (or end) is non-empty. Replaces Foundation `looksLikeURL` for identity; deliberately converges browser link copies, pbcopy/terminal URL copies, and `UrlImporter`-synthesized entries (`UrlImporter.swift:102-112`, `UrlImporter.cs:136-137`).

**VOLATILE_DENYLIST** (fallback rung only): `public.text`, `com.apple.is-remote-clipboard`, `com.apple.traditional-mac-plain-text`, `org.chromium.source-url`, `org.chromium.internal.source-rfh-token`, `com.apple.WebKit.custom-pasteboard-data`, `com.apple.linkpresentation.metadata`, `com.apple.icns`, `com.raycast.RestoredType`, `com.apple.security.sandbox-extension-dict`, prefix `com.apple.iWork.pasteboardState.`, prefix `dyn.`, `public.utf16-plain-text`, `public.utf16-external-plain-text`. Under semantic identity this list only shapes kind=other junk (~22 rows); the primary rungs make it irrelevant everywhere else — that inversion is the future-proofing core: **a new volatile UTI in 2027 has zero identity impact and requires zero code change.**

**Fallback sort** is pinned as literal **byte-wise comparison of UTF-8 encodings**: Swift `Array(uti.utf8).lexicographicallyPrecedes(...)`, C# comparison of the UTF-8-encoded byte arrays. Neither Swift `String <` (canonically-equivalent collation) nor `StringComparer.Ordinal` (UTF-16 code-unit order) satisfies this off the ASCII plane; both implementations change, and the stale equivalence comment in `CanonicalHash.cs:36-38` is corrected. One vectors case uses a non-ASCII UTI spanning the U+E000/U+10000 boundary so a wrong comparer fails CI on both platforms.

### 2.4 Edge cases

- **Multi-file copies**: flattening keeps the first `public.file-url`; identity = first file. Pre-existing storage lossiness (PK collapse) already made multi-file fidelity impossible; v2 makes identity consistent with what is stored.
- **File-reference URLs**: capture resolves `/.file/id=` file-reference URLs to path URLs **before storage** (new step in `PasteboardSnapshot`), so the recompute-from-storage invariant holds for file entries and reference-vs-path copies of the same file converge. Historic rows hash as stored.
- **Universal Clipboard echoes**: the shared-pasteboard `public.file-url` flavor is **stored but never keys identity** (rung 2 skip above). Image echoes key via rung 1, text echoes via rung 4 — this preserves iPhone-origin copies, for which the Mac watcher's echo is the *only* record anywhere (316 such entries in the audit DB, 282 live, 243 with substantive image bytes). The snapshot is skipped entirely **only** when the shared-pasteboard file-url is the sole substantive flavor (no image ≥1024B, no non-empty text source, no `public.url`, no color) — the file-only Mac-to-Mac mirrors (audit ids 442/3315). Residual accepted: a Mac-to-Mac *Finder file* copy still forks (origin keys `file` on the real path, echo keys `image`/`text`) — low-frequency, handled by the §4.6 sweep for history and tolerated go-forward.
- **Evicted bodies** (`body_evicted_at` set, flavors deleted by `EntryEvictor.swift:140-144`): cannot be rehashed anywhere. They keep their v1 hash forever, `hash_version = 1`. Eviction is sticky and synced, so all devices keep the same v1 hash → record names still converge; they **do** get wire presence in the new zone under that v1 hash (§4.5).
- **Missing or unreadable blob file** at rehash time: keep v1 hash, `hash_version = 1`, logged; included in the reseed like evicted rows (it still has a row and inline flavors worth syncing).
- **Empty text after normalization**: routed to rung 6 so `sha256("text\x00")` never becomes the 4.3-year mega-entry the simulation found. Additionally the **Ingestor skips capture** of snapshots whose every flavor is zero-length (belt over the suspender).
- **Zero-flavor live rows** (pull-inserted before flavors arrived): keep v1 hash, excluded from the reseed; the origin re-delivers them under v2 via the uuid merge (§5.3), with the zombie sweep (§4.4) and `--reap-stragglers` (§9) covering the cases where the origin never does.

### 2.5 Worked examples (from the audit DB)

1. **ids 3165/5938** (`wcl.phfactor.net`): both carry byte-identical `public.url` = `https://wcl.phfactor.net/`; utf8 text differs by trailing slash; one has `linkpresentation.metadata`. v1: two hashes. v2: rung 3 fires on both → trim no-op → slash strip → `("url","https://wcl.phfactor.net")` → `cdccba6413de076dc24f67461b68dd114bbbbbe623c743f4f916c0c8066ef53e`. One entry.
2. **ids 4572/9398** (CWA address, 262 days apart): byte-identical `public.utf8-plain-text`; `public.rtf` differs only by `cocoartf2822` vs `cocoartf2869`. v2: rung 4, not URL-shaped → `("text", <address bytes>)`. One entry; both rtf variants retained via bump-union (§3).
3. **pbcopy vs browser**: terminal `echo https://x.com | pbcopy` yields `{utf8: "https://x.com\n"}` → rung 4 → trim → promotion → `("url","https://x.com")` = `b92e3072845a49f4cdde20685b46eb6debd6815e2384d25a14425bb7eea80213`; Safari link copy `{public.url:"https://x.com/", utf8:"https://x.com"}` → rung 3 → same value. Converged — the promotion's stated purpose, now actually delivered (the untrimmed-bytes bug that produced `798f1c3d…` is fixed by hashing the trimmed promotion value).
4. **Safari image copy** `{public.url, public.png (50 KB), public.html}`: kind=link (kind checks url first) but **identity = rung 1 image**. The kind heuristic and the rung chain deliberately disagree; identity never consults `kind`.

### 2.6 Pinned vectors

Generated by `Tools/gen_hash_vectors.py` (the reference implementation; CI artifact `Tests/Fixtures/hash-vectors-v2.json` is authoritative — schema.md and this table cite it, never the reverse). Verified hexes:

| # | Input (flattened) | tag | content_hash (hex) |
|---|---|---|---|
| 1 | `{utf8-plain-text:"hello"}` | text | `306f89347195cc05509ddca47462e259aac6fd01943d2557004ea6f26370cd58` |
| 2 | `{utf8-plain-text:"hello", org.chromium.source-url:"https://x.y", public.text:"hello"}` | text | **equals: #1** (sidecars excluded by construction) |
| 3 | `{utf8-plain-text:"a\r\nb"}` | text | `4930252210319b32b80fc460afbf2d8bd33efa58de16f861fc6cff5a4f402c20` (CRLF→LF) |
| 4 | `{public.url:"https://example.com/", utf8-plain-text:"https://example.com"}` | url | `7ce6868d0d70a4cad25be46c38e61a0ac80edd2c1d10c370317a07c18eae900c` (slash stripped) |
| 5 | `{utf8-plain-text:"https://example.com/"}` | url | **equals: #4** (promotion + slash strip) |
| 6 | `{utf8-plain-text:"https://x.com\n"}` | url | `b92e3072845a49f4cdde20685b46eb6debd6815e2384d25a14425bb7eea80213`, **equals** `{public.url:"https://x.com"}` |
| 7 | `{utf8-plain-text:" https://x.com "}` | url | **equals: #6** (pinned trim set incl. U+00A0) |
| 8 | `{utf8-plain-text:"see https://x.com now"}` | text | `252ecc3e56b61551328b769484199146e18d3d26a04f66afe29383f681bae1c1` (promotion negative) |
| 9 | `{public.file-url:"file:///Users/pfh/report.pdf"}` | file | `87dea9dc8abdfa1c71e030532c89a97163275d69a61518704b131fcb49066ba2` |
| 10 | `{utf16-external-plain-text: FF FE 68 00 65 00 6C 00 6C 00 6F 00}` | text | **equals: #1** (BOM-LE decode) |
| 11 | `{public.png: <PNG magic padded to ≥1024 B, fixture base64>}` | image | fixture-defined in JSON |
| 12 | `{public.png: 89 50 4E 47 0D 0A 1A 0A}` (8 B, sub-threshold) | fallback | `342ef223de740961d8fa39ffe431e793fde18708e6282440074f79e85d47804d` (pins the sub-threshold→non-image branch; the draft design's `ebe43636…` was computed under a stale emission and is superseded) |
| 13 | `{com.example.custom:"xyz"}` | fallback | `81536d9fe2abf3cac9bd19786938f3cca883a9f40e71999ea223d9f08c3ce309` |
| 14 | `{utf8-plain-text:""}` | fallback | `4d648625bd151b778f4a9a5c38fc2beaf4eceeab4c6b8665b40f2338c1b1f33f` (empty-after-normalization; pins migration behavior for historic empties) |

The JSON additionally carries: multi-item flattening (duplicate UTI across items, first wins); denylist-empties-to-full-set; malformed inputs (lone `0x80` in utf8 → source skipped; unpaired surrogate in utf16 → skipped; BOM-less LE and BE utf16 fixtures); a non-ASCII-UTI fallback sort case; the kind=link-text-only promotion case; `equals:<name>` as a first-class assertion form. Re-derivation snippet for schema.md: `printf 'text\x00hello' | shasum -a 256`.

---

## 3. What is stored vs what is identity (fidelity policy)

**Identity narrows; storage does not.** Capture fidelity is a core product value.

- **Stored, exactly as published**: every flavor — `org.chromium.source-url` (provenance), `linkpresentation.metadata`, `public.html`/`public.rtf`, `dyn.*`, utf16 variants, **and now `com.apple.is-remote-clipboard`** (previously stripped at capture; under v2 sidecars are hash-invisible, so it becomes free Universal-Clipboard provenance — `metadataOnlyUTIs` is deleted and the model unifies to "store everything, hash the primary"). v2 *removes* the pressure v1 created to strip provenance before storage: under v1, fixing jitter meant extending a strip list; under v2 we store more and hash less.
- **Capture-time changes** (the only ones): (a) nspasteboard.org transient/concealed markers move from the macOS-only `TransientFilter.swift` watcher into **CpdbShared, enforced at the Ingestor entry point** (whole-snapshot rejection), so iOS and any future capture path inherit them — under v2 a leaked concealed capture would otherwise *bump an existing visible entry* fleet-wide instead of forking deletably; (b) file-reference URL resolution (2.4); (c) shared-pasteboard sole-substantive-flavor skip (2.4); (d) all-empty-snapshot skip (2.4).
- **Bump semantics — union-preserving** (resolves the assembled design's internal contradiction in favor of the judge grafts, against base §2's replace-on-bump): on a hash hit, `INSERT OR IGNORE` the new snapshot's flavors into the stored row; **never delete UTIs the new snapshot lacks; never overwrite same-UTI bytes** in this release. Update `created_at`, reclassify kind as today, re-enqueue push. Rationale: replace-on-bump + iOS's string-only `UIPasteboard` copy (`EntryDetailView.swift:506-537`) + the Universal Clipboard echo would have stripped RTF/HTML from rich entries fleet-wide every time the user tapped Copy on the iPhone — a blocking adversarial finding. Union is strictly additive over today's behavior (today a hit keeps the first capture's flavors and updates nothing), requires **no flavor-deletion pull-path parser** (descoped entirely), and never touches a flavor row, so the EntryEvictor blob-refcount machinery stays the codebase's only flavor-deletion site. Cost, accepted: stored same-UTI rich bytes remain the *first* capture's (e.g. first copy's RTF wins) — same as today. A future "refresh same-UTI bytes on local non-echo re-copy" can layer on later via the shared refcount helper; it is out of scope here.
- **App attribution on bump**: unchanged (first capture's app/device kept). Honest loss: a merged entry represents N copy events with one provenance row and one (latest) `created_at`. The 29 >1-day V4 merges (tracking numbers re-copied days apart) are legitimate identity but lossy history — accepted per the bump precedent.
- **Other consciously accepted tradeoffs** (carried from the winning design): formatting fidelity collapses across sources by design (quantified: 5 of 441 clusters, all formatting-engine noise); identity is interpretive (1024-byte threshold, text ladder, URL heuristic — pinned constants the contract carries forever); images under-merge (raw-byte identity; re-encodes never converge — v1 had the same property); the fallback rung is best-effort for ~22 junk rows.

---

## 4. Local migration

### 4.1 Architecture: thin GRDB migration + resumable cutover routine

The 2.6 GB problem is real: 860 spilled flavor rows (684 distinct blobs, 2,606,183,367 bytes) must be read and hashed; a single GRDB migration transaction would hang iOS's main-actor `Store.open()` at first launch and crash-loop under the watchdog with full rollback. Therefore:

- **`v10_semantic_identity` (GRDB migration, milliseconds, append-only per Schema.swift convention)** does schema only:
  ```sql
  ALTER TABLE entries ADD COLUMN hash_version INTEGER NOT NULL DEFAULT 1;
  ALTER TABLE entries ADD COLUMN prev_content_hash BLOB;      -- v1 lineage: forensics, importer dual-probe, old-zone GC
  ALTER TABLE entries ADD COLUMN identity_tag TEXT;           -- rung tag, NULL for v1 rows
  CREATE INDEX idx_entries_prev_content_hash ON entries(prev_content_hash);
  CREATE TABLE orphan_flavors (content_hash BLOB, uti TEXT, data BLOB, blob_key TEXT,
                               received_at REAL, PRIMARY KEY (content_hash, uti));
  -- plus a cutover_state row marking 'cutover_pending'
  ```
- **The cutover routine** runs after `Store.open()`, off the main actor, foreground launches only (background BGTask/silent-push launches complete immediately without opening the migrator-gated store — prevents the 0x8badf00d loop). Sync is fully disabled (push returns empty, pull no-ops) while `cutover_pending` is set. On iOS it runs behind a one-time progress UI before sync enables, mirroring the bootstrap pull's per-page progress pattern.

### 4.2 Binary-skew fence

GRDB 6.29.3 silently ignores unknown migrations (`DatabaseMigrator.swift:296-297, 382-401`), so a pre-v10 binary (stale CLI, ~20 `Store.open()` sites; or a mid-choreography Mac) would open a migrated DB without error, insert v1 rows, replay tokens against the wrong zone, and poison pulls. Two layers:

1. **Path rename fence**: the new build moves `cpdb.db`(+`-wal`,`-shm`) to **`cpdb-v3.db`** before opening (precedent: `Paths.migrateFromLegacySupportDirectoryIfNeeded`). Pre-v10 binaries see no database and cannot touch the migrated one (a stale CLI would create a fresh empty `cpdb.db` — stranded but harmless). Runbook: upgrade app and CLI in lockstep on each Mac.
2. **Launch reconcile sweep** (every foreground launch, post-cutover, normally a no-op): rehash-and-merge any live row with `hash_version = 1`, flavors present, `body_evicted_at IS NULL`, and a rung input available — same code path as the migration chunks. Heals any skew-era rows on re-upgrade, since the v10 identifier never re-runs.

### 4.3 Cutover routine, step by step (idempotent; each step records completion in `cutover_state`)

**Step 0 — final old-zone drain (enforced quiesce).** If `cloudkit_push_queue` is non-empty, push it to **cpdb-v2** first (rows still carry v1 hashes pre-rehash; the legacy zone name is kept as a constant for exactly this step). Offline → the routine waits and retries next launch; cutover does not proceed past step 0 with a non-empty queue. This structurally closes the stranded-mutations gap instead of trusting the runbook.

**Step 1 — snapshot.** `VACUUM INTO 'cpdb-v3.db.pre-v10'` on the open connection (WAL-consistent, single file, no `-wal` sidecar — a naive `FileManager` copy would silently drop up to 1000 WAL pages), executed only if the file does not already exist (a retry loop must not overwrite a good snapshot). **Restore procedure** (documented in the runbook): quit all cpdb processes → replace `cpdb-v3.db` with the snapshot → relaunch; v10 re-runs cleanly (identifier absent from the restored `grdb_migrations`) and re-wipes sync state. Delete the snapshot after fleet convergence.

**Step 2 — chunked rehash.** In batches of ~200 rows, each its own short write transaction (crash-resumable: the next run picks up at `hash_version = 1` rows), over **live AND tombstoned** entries:

1. Skip (keep v1) iff: `body_evicted_at IS NOT NULL`; or zero `entry_flavors` rows; or blob file missing/unreadable (logged); or **no rung input exists at all** (no image/file/url/text/color UTI and an empty post-denylist fallback set is impossible by construction, so this is: literally no flavor usable by any rung — **7 rows** in the audit DB). The guard is keyed on **rung input, never on `kind`**: the judge-grafted kind-feeder guard is rejected — `kind` is not a predictor of the rung input (1,567 live kind=link rows have no `public.url`; 1,563 of them rehash perfectly via the rung-4 promotion and *must* re-key, or 16% of the corpus — the most-recopied links — would be stranded out of cpdb-v3 on every device). Partial-flavor wrong-rung rehashes on pull-populated devices are not prevented here; they are *converged* deterministically by the rung-priority rule on the pull path (§5.3), which is strictly more robust than any local guard.
2. Read flavors (spilled via `BlobStore` — content-addressed by single-flavor sha256, independent of entry identity, safe to read); compute `(tag, value)` per §2.3 over the stored flat set; set `prev_content_hash = content_hash`, `content_hash = v2`, `identity_tag = tag`, `hash_version = 2`.
3. Migration-time assertion (logged): count of kept-v1 live rows that *do* have flavors and a body must equal the no-rung-input count (expected 7 on this corpus). Any excess is a bug.

**Step 3 — collision merge** (one short transaction; mandatory — the audit guarantees ~441 live clusters and `idx_entries_live_content_hash` would fire on the first pair). Group **live** rows by new hash; per group with n>1:

- **Survivor**: earliest `created_at`, tie-break smallest `uuid` (both synced → all devices pick the same survivor; keeps wire records stable).
- **Coalesce onto survivor**: `pinned = OR(group)`; `created_at = MAX(group)` (bump-recency semantics); `link_title`/`link_fetched_at`, `ocr_text`/`image_tags` salvaged from losers when survivor NULL (reuse `Dedupe.swift:102-132`, factored into a **shared coalesce helper** also used by the pull path, §5.3); `previews` — keep survivor's, else re-point one loser's; `pinboard_entries` re-pointed with `INSERT OR IGNORE`.
- **Flavors**: survivor keeps its set; adopt loser flavors for UTIs the survivor lacks (`INSERT OR IGNORE`). Same-UTI conflicts: survivor wins (quantified cost: 5 of 441 clusters, all formatting-engine noise).
- **FTS**: after the salvage UPDATEs, call `FtsIndex.indexEntry(...)` for the survivor with post-salvage values (the FTS table has no triggers — `FtsIndex.swift:14-16` — so without this, merged-in OCR text/link titles would be unsearchable, indefinitely on the first device to migrate).
- **Losers**: tombstone (`deleted_at = now`), `FtsIndex.removeEntry`, do **NOT** enqueue. **Losers keep their v1 `content_hash` and `hash_version = 1`** — they are *not* re-keyed to the survivor's v2 hash. Re-keying would create multiple local rows per v2 hash and arm the pull-lookup shadowing bug (inbound updates landing on corpses, deletions never propagating). v1-hash tombstones can never be addressed by anything in cpdb-v3, so they are inert; the tombstone-wins rationale for rehashing applies only to **standalone tombstones** (user-deleted entries, no live collision partner), which *are* rehashed in step 2 and reseeded (§4.5) so deletion state has first-class wire presence.
- Write order is index-safe by construction: losers are tombstoned (and never re-keyed), survivors already hold the v2 hash from step 2 — the partial unique index covers live rows only.

**Step 4 — zombie sweep.** Tombstone (locally, no push) any **zero-flavor `hash_version = 1` live row** whose `TRIM(text_preview)` (or title when previewless) matches another live row — body-less by definition, so nothing is lost, and it pre-empts the permanent iPhone ghosts created when the row's origin uuid lost a collision merge (losers are never pushed, so "the origin re-delivers" would never fire for them). Genuinely unique zero-flavor stragglers stay live, logged.

**Step 5 — sync-state cutover** (one transaction; verbatim v5 playbook `Schema.swift:250-278`, with the corrected reseed taxonomy):

```sql
DELETE FROM cloudkit_state;        -- token key now namespaced: 'zoneChangeToken.cpdb-v3'
DELETE FROM cloudkit_push_queue;
INSERT INTO cloudkit_push_queue (entry_id, ...)
  SELECT id FROM entries
  WHERE (deleted_at IS NULL
           AND NOT (hash_version = 1 AND body_evicted_at IS NULL
                    AND id IN (SELECT entry_id-less zero-flavor set)))   -- exclude ONLY zero-flavor v1 stragglers
     OR (deleted_at >= :now - 90*86400 AND hash_version = 2);            -- recent standalone tombstones: wire presence
-- then: INSERT cutover_state pull-before-push latch; clear 'cutover_pending'
```

Spelled out, the reseed **includes**: all live v2 rows; live kept-v1 rows *with content* — evicted rows and missing-blob rows push under their v1 hash with `hashVersion = 1` (per-row, never a constant — §5.2), preserving wire completeness; standalone tombstones ≤90 days old (rehashed to v2 in step 2). It **excludes**: zero-flavor live v1 stragglers (origin re-delivers; sweep + reaper back-stop) and merge losers (v1-hash tombstones, inert by design).

### 4.4 Idempotency and crash safety

Every step short-circuits on its `cutover_state` marker; step 2 is resumable mid-way via `hash_version`; step 3 is a no-op when no live hash has n>1; rehash of a v2 row recomputes the same hash (rung input = stored flavors, unchanged by migration). A crash anywhere yields a clean resume; the snapshot guards against the only unrecoverable class (a rung-chain bug discovered post-merge).

### 4.5 Verification

`cpdb storage --verify-hashes [--sample N]` (default 200): recompute v2 for N random live flavored `hash_version = 2` rows, assert match, report. Run on each device after its cutover completes (part of the §5.4 choreography). The migration also logs: rehashed/kept-v1-by-reason counts, cluster count and sizes, zombie-sweep count — compare against the simulation's expectations (≈441 clusters on the primary Mac with the final ruleset; record the actual number at the §9 step-0 gate).

### 4.6 Post-migration sweep

One final run of `cpdb dedupe --post-migration` (preview-window based, hash-independent) collapses the historical residue v2 can't: shared-pasteboard file-only mirror rows vs their origins, and pre-v2 cross-device pairs whose flavor bytes are gone. Two hardenings (both required — the unguarded sweep run on two Macs concurrently would tombstone *both* siblings of a pair fleet-wide, since survivor selection was local-id-based and losers are pushed):
1. `--post-migration` **refuses to run** if `cloudkit_push_queue` is non-empty or the last successful pull is older than a freshness threshold; runbook: run on exactly one Mac, after fleet convergence.
2. `Dedupe.swift` survivor selection becomes device-deterministic regardless: earliest `created_at`, tie-break smallest `uuid` (mirroring step 3), so even a concurrent double-run collapses to a harmless double-tombstone of the same loser.

After this, `Dedupe.swift` enters maintenance-only status.

---

## 5. CloudKit migration — Strategy A: new zone `cpdb-v3`

### 5.1 Why a new zone

A not-yet-upgraded device keeps operating against cpdb-v2: fully functional, fully partitioned, zero cross-contamination possible — the decisive advantage over every same-zone strategy. Record names stay `entry-<64hex>` (same length, same parsers) precisely because the new zone guarantees no old-era record can ever arrive.

### 5.2 Code changes

- `CKSchema.swift:24` zone → `"cpdb-v3"`; `CloudKitSyncer.swift:65` subscription → `"cpdb-v3-zone-subscription"`; the legacy zone constant is retained for the §4.3 step-0 drain and the gated GC command. `ensureZoneIfNeeded`/`ensureSubscription` create both with zero new code. Change-token key namespaced per zone (`zoneChangeToken.cpdb-v3`), fixing the un-qualified key at `PushQueue.swift:135` for all future migrations.
- **Entry record gains `hashVersion: Int` and `identityTag: String`** — both written **from the row** (`entries.hash_version`, `entries.identity_tag`), *never* a constant: evicted/missing-blob rows reseeded under their v1 hash must ship `hashVersion = 1`, or the uuid-merge upgrade predicate is corrupted (a mislabeled `2` would permanently block the origin's real v2 record from adopting on peers, orphaning its flavors). `EntryRecordMapper.decode` defaults absent → `(1, nil)`.
- **`hash_version`/`identity_tag` stamped on every insert path**: `Ingestor` (2, tag from `ContentIdentity`), `PasteDbImporter`, `UrlImporter` (via Ingestor), and pull-insert (copied from the decoded record). Without this, every post-migration row would take `DEFAULT 1` and all version-keyed bookkeeping (reseed, verify, reconcile sweep, any future v11) breaks.
- **Pull lookups prefer live rows**: the content-hash lookup at `CloudKitSyncer.swift:1118-1126` becomes `ORDER BY (deleted_at IS NULL) DESC, created_at DESC LIMIT 1` (or two-step: probe live via the partial index, fall back to tombstoned). Even with merge losers kept at v1 (§4.3), delete-then-recopy legitimately produces same-hash live/tombstone siblings today; without ordering, SQLite returns the lowest rowid and the `:1124` tombstone-wins guard silently eats live updates and misroutes inbound deletions. Same ordering on the uuid lookup.
- **Self-healing pull errors**: catch `CKError.changeTokenExpired` / `.zoneNotFound` / `.userDeletedZone` in `pullRemoteChanges` → `resetChangeToken()` + clear the in-actor `zoneEnsured` cache + retry. Removes the only manual-intervention failure class on iOS (no token-reset UI) for this and all future migrations.
- **Pull-before-push latch**: the cutover writes a `cloudkit_state` row (after the wipe, same transaction) that makes `pushPendingChanges()` return empty until one successful full post-migration pull completes (cleared after the final page). This converts the cutover into pull-merge-push on every device. Without it, the iPhone — last in the choreography, `pullNow()` begins with `await pushNow()` which drains to zero (`AppContainer.swift:113`) — would clobber every cutover-day pin/title/tombstone fleet-wide with day-stale values under `.allKeys`, and resurrect server-side tombstones permanently. ~15 lines in the syncer.
- **Orphan-flavor stash**: `upsertFlavor`'s parent-miss branch (`CloudKitSyncer.swift:1028-1037`) writes the flavor into `orphan_flavors` (7-day TTL) instead of dropping it; after every entry upsert/re-key, matching stash rows drain into `entry_flavors`. Closes the cross-page ordering hole (flavors arriving before their entry record, or before a uuid-merge re-key) that previously orphaned bytes forever because the per-page token advance never re-delivers them. ~30 lines; hardens all future out-of-order delivery.
- **Insert hardening (belt-and-suspenders)**: `entry.insert` at `:1245` is wrapped in a `SQLITE_CONSTRAINT`(uuid) catch that logs a dedicated counter and returns `.unchanged` — no single record can ever wedge the change token again, for this or any future migration.

### 5.3 uuid-conflict resolution (full specification — the pull path's new logic)

Runs on every pull-side **content-hash miss** before insert: look up by `uuid` (live-preferred ordering). If a row exists (hashes necessarily differ — a hash match would have hit the primary lookup):

1. **`remote.hashVersion > local.hash_version`** (v1-straggler upgrade — the origin's v2 record arriving at a device that kept v1): adopt remote `content_hash`/`hash_version`/`identity_tag`. If another **live** local row already holds the remote hash → run the **shared coalesce helper** from §4.3 step 3 (pins OR'd, pinboard memberships re-pointed, previews/link/ocr salvaged, missing-UTI flavors adopted) merging the uuid-row into the hash-row, then tombstone the uuid-row (no push). The bare "tombstone and bump" from the draft is rejected — it silently destroyed pins, pinboard memberships, and previews that the migration path carefully preserves. After any adoption: drain the orphan-flavor stash for the new hash; run the same-preview zombie sweep for sibling stragglers. Entries apply before flavors within a page, so the row re-keys in time for same-page v2-addressed flavors; the stash covers cross-page arrivals.
2. **`remote.hashVersion < local.hash_version`**: keep local, return `.unchanged` (never downgrade). Covers the eviction race: the evictor pulls the rehasher's v2 record and upgrades via rule 1; the rehasher drops the evictor's v1-labeled record here; the fleet converges on v2. An equal-hash record never mutates `hash_version` (it can't reach this path; stated for the contract).
3. **Equal version, different hash** — *must never fall through to insert* (the Strategy-B poison page reborn): resolve deterministically by **rung priority** using the wire `identityTag`. The lower rung index (§2.3) wins, because missing flavors can only demote identity *down* the chain — the higher-rung hash was provably computed from a superset (this is exactly the partial-flavor fork: peer rehashed `{public.url, html}` as `url` while the origin, holding the in-flight ≥1 KB png, keyed `image`; audit rows 3039/3118 carry this flavor shape). Remote wins → adopt as in rule 1 (with collision-coalesce). Local wins → return `.unchanged`; the peer resolves symmetrically when it pulls our record. **Tie (same rung)** → lexicographically smaller hash bytes win — covers the ~22 fallback-rung rows and the truncated-blob corruption case with a deterministic, convergent rule instead of the dead `>`-only backstop. The losing side re-keys (flavors unchanged), re-enqueues its row, increments a dedicated fork counter (the forensics the revision-constant graft wants), and enqueues its old recordName into a small `cloudkit_record_deletions` queue drained via `modifyRecords(deleting:)` with the next push, so the lower-rung record doesn't linger for fresh bootstraps. (If the deletions queue is descoped, orphan records are tolerable: every re-encounter resolves identically.)
4. No row by hash or uuid → plain insert (stamped from the record), inside the hardened catch.

Tests required (CloudKitSyncerTests): v1-straggler upgrade; upgrade-with-collision onto a pinned, pinboard-member uuid-row asserting the coalesced fields; eviction race both directions; equal-version image-vs-url fork (both orders); equal-version fallback tie; live/tombstone same-hash sibling — inbound live update hits the survivor, inbound tombstone kills the survivor; uuid-constraint catch never wedges the token; orphan-stash drain across pages.

### 5.4 Device choreography (3 Macs + iPhone, same-day cutover)

1. **Quiesce** — let local, axiom, thor, iPhone each complete a sync cycle on the old build so every DB holds the full union. Enforced in code regardless: §4.3 step 0 drains any pending pushes to cpdb-v2 before a device cuts over, so deletions/pins made during the gap reach cpdb-v2; tombstone reseeding (§4.3 step 5) then carries deletion state into cpdb-v3 when each device migrates. Captures made on a not-yet-upgraded device after the first device migrates remain stranded in cpdb-v2 until that device upgrades — minutes-to-hours of exposure, accepted.
2. **Upgrade the primary Mac (local) first** — app + CLI in lockstep. Migration runs (drain → snapshot → rehash → merge → reseed); its full push seeds cpdb-v3 (the latch is trivially satisfied: first pull of an empty zone). Run `cpdb storage --verify-hashes`.
3. **Upgrade axiom, then thor** — each drains to v2, migrates, **pulls first** (latch), pushes; push-batch recordID dedup (`:274-312`) collapses identical recordNames; `.allKeys` last-writer-wins converges scalar drift. Verify-hashes on each.
4. **Upgrade iOS (TestFlight)** — last. First foreground launch shows the migration progress UI, then latch-gated pull, then push. Background launches before the first foreground launch are no-ops by design.
5. **Post-cutover (same week)**: run `cpdb dedupe --post-migration` on exactly one Mac after fleet convergence (§4.6); run `cpdb storage --reap-stragglers` after N days (tombstones never-upgraded zero-flavor v1 ghosts, logged, no push needed — they have no wire presence).
6. **Old zone**: cpdb-v2 is abandoned in place. Optional GC weeks later via `cpdb sync gc-zone cpdb-v2`, which **refuses to run unless every known device row (devices table, synced through cpdb-v3) has written into the new zone** — per-record targeted deletes against cpdb-v2 are *prohibited* while any reader could remain (a laggard pulling them as `deletedRecordIDs` would tombstone its entire live library locally via `tombstone(contentHash:)`, unrecoverably, since the later migration excludes tombstones from the reseed). Whole-zone deletion is the only sanctioned mechanism: its worst case is a temporarily wedged old binary that self-heals on upgrade (the migration wipes sync state). `prev_content_hash` remains for forensics, not for targeted GC.

### 5.5 Stale devices and ActionRequests

- An old iOS build writes ActionRequests into cpdb-v2; upgraded Macs no longer pull them — requests silently expire unexecuted (benign; user retries after upgrading). Post-cutover requests carry v2 hashes; the graceful-drop path (`CloudKitSyncer.swift:971-984` + server-side delete) covers residual mismatches. No `ActionRequestMapper` change beyond riding the new hashes.
- iOS read/write lands cleanly on top: `ContentIdentity` and the transient-marker set live in CpdbShared, so iOS share-sheet captures compute identical identity and identical safety filtering from day one. Two devices capturing the same content independently compute the same hash with no coordination, push the same recordName, and converge at the server instead of forking.
- **Re-import safety**: `PasteDbImporter` (`:150-157`) probes by computed hash only; post-cutover it must probe **both eras**: `WHERE deleted_at IS NULL AND (content_hash = :v2 OR content_hash = :v1 OR prev_content_hash = :v1)`, computing legacy `CanonicalHash` alongside `ContentIdentity` for the probe only (CanonicalHash.swift survives as the fallback emission anyway), using the new `prev_content_hash` index. Otherwise every row the migration kept at v1 (evicted — which targets old imported content precisely, zero-flavor, missing-blob) re-imports as a duplicate and pushes fleet-wide. Drop the dual probe once the fleet has zero `hash_version = 1` flavored rows (R2 cleanup, §9).

---

## 6. Cross-platform contract changes (exact artifact list)

All in the same PR series as the implementation; parity.md's meta-rule ("update in the same commit as the feature") applies.

1. **`docs/schema.md`** — rewrite §Canonical hash as **§Content identity v2**: payload + tag table, flattening rule, full rung chain with rung indices, pinned constants (URL_TRIM_SET as explicit codepoints, slash-strip rule with edge cases `//`→`/` and bare `https://`, 1024-byte image threshold, `looks_like_url_portable`, best_text decode policy incl. **BOM-less UTF-16 = little-endian** and **strict-decode-or-skip**, VOLATILE_DENYLIST), fallback sort pinned as *byte-wise comparison of UTF-8 encodings* (closing v1's collation gap), `IdentityRevision` constant semantics. New **§Hash-excluded volatile flavors**: the two-column Mac-UTI ↔ Windows-format table from the contract map (`Chromium internal source URL`, `Chromium internal source RFH token`, `CF_LOCALE`, `Shell IDList Array`/CF_HDROP companions, OLE link machinery, `CF_TEXT`/`CF_OEMTEXT` encoding variants, handle-only image formats, session-local private formats ↔ `dyn.*`), plus the nspasteboard transient/concealed markers with their Windows analogues (`ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory`) in a **never-store** sub-table, and the rule that Windows's `UtiTranslator` *allowlist is the enforcement mechanism* — future allowlist expansion must check this section first. §Eviction gains: "body-evicted entries retain their v1 hash permanently (`hash_version=1`); identity v2 is never computed without flavor bytes." Pinned-vector table per §2.6 (v1 table kept under a "v1, historical" label); re-derivation snippet; **`Tests/Fixtures/hash-vectors-v2.json` cited as authoritative over the prose table**. Windows-port checklist item updated to "implement ContentIdentity, pass hash-vectors-v2.json".
2. **`Tests/Fixtures/hash-vectors-v2.json` + `Tools/gen_hash_vectors.py`** (new) — `{name, items:[{uti, base64}], expected_tag, expected_hex | equals:<name>}`; cases per §2.6 including every rung, every normalization branch, malformed inputs, flattening, denylist-to-full-set, sort-collation, promotion negative. Single source — ends the three-way hand-duplication of hex literals.
3. **`Tests/CpdbCoreTests/HashVectors.swift`** — rewritten as a JSON-driven loop (XCTest).
4. **`windows/CpdbWin.Core.Tests/CanonicalHashTests.cs`** — JSON-driven xUnit theory over the same file; plus the **disjointness test**: assert no `UtiTranslator`-emitted UTI appears in VOLATILE_DENYLIST (keeps the fallback rung dormant-by-construction as the translator grows); plus rung-chain table-driven tests. Fix the stale "Swift `<` compares Unicode scalars" header claim while porting.
5. **`docs/parity.md`** — rows: **Canonical content_hash** → "identity v2, semantic rung chain; vectors in Tests/Fixtures/hash-vectors-v2.json" (mac/iOS ✅ vNext, Win ⏳ until handoff lands); **Cross-device dedup (Universal Clipboard echo)** subsumed into new row **Semantic identity / volatile-flavor exclusion**; **Content-addressed CKRecord IDs** → "wire-format v3, zone cpdb-v3" (Apple-only); new rows: shared-pasteboard echo handling (Apple-only), transient/concealed markers → "ingest-time, CpdbShared" (mac+iOS), secondary dedup window → "retired (log-only vNext, deleted vNext+1)" — finally giving it the contract row it never had; `is-remote-clipboard` row updated from "strip before hashing" to "stored; hash-invisible by construction".
6. **`docs/handoffs/windows-hash-v2.md`** (new, house template per `macos-wordpress-title-precedence.md`): Origin PR → TL;DR → the jitter bug with the Warp/loginwindow pair as the real case → target code pointers (`ContentIdentity.cs` to create; `CanonicalHash.cs` retained as fallback emission with byte-wise sort fix; `UtiTranslator.cs`; `Ingestor.cs:43,144,247` switching entry points; `UrlImporter.cs`; `Schema.cs` gaining `hash_version`/`prev_content_hash`/`identity_tag` + its own rehash/merge migration) → **hard requirement: `ContentIdentity.cs` and the `Schema.cs` rehash migration ship in the same Windows release** (else every re-import duplicates wholesale) → tests to mirror (JSON vectors + disjointness + rung tables) → parity.md before/after rows → `windows/CHANGELOG.md` + `Directory.Build.props` bump. Mapping notes the contract must state: CF_UNICODETEXT decodes to UTF-8 and identity then applies CRLF→LF (load-bearing on CRLF-native Windows); CF_HDROP → first path keys identity (flattening first-wins), same percent-decode + slash rule, no shared-pasteboard clause; **DIB→PNG encoding is not byte-deterministic across encoders → cross-platform *image* identity is explicitly out of scope**; **html-as-text identity is likewise platform-local** (Mac hashes raw `public.html` bytes; Windows hashes the `CfHtmlParser.ExtractFragment` slice — guaranteed different for the same copy; documented honestly rather than papered over). `UrlImporter.cs` inherits url-rung convergence automatically.
7. **`docs/relay-protocol.md`** (parked, contract-bearing) — version note at lines 105/138: `envelope_id = HMAC(content_hash, …)` inherits identity v2; text/url/file identities converge cross-platform by construction (CRLF rule, byte-wise sort, portable URL rule); **image and html-sourced-text identities are platform-local**.
8. **`PasteDbImporter.swift:148` / `TransformablePasteboardDecoder.swift:150`** — switch to `ContentIdentity` + the dual-era probe (§5.5). The "safe to re-run" invariant holds because `Store.open` runs the migrator + cutover before any importer touches a post-v10 DB.
9. **Migration runbook** (`docs/migrations/idv2-cutover.md`, new) — choreography, restore procedure, verify commands, GC policy, lockstep CLI note.

---

## 7. Interaction with the 30s secondary dedup window

Both of its reasons to exist die under v2: same-copy volatile jitter (its named purpose, `Ingestor.swift:150-156`) is fixed by construction, and the Xcode RTF-append pattern becomes a plain hash hit handled by primary dedup + union bump. But the cutover release is the largest blast radius in the project's history, so retirement follows the **instrument-then-delete** discipline — with both nets *defanged*, because keeping them as live mutation paths during the seeding storm is actively destructive:

- **Capture-side 30s window** (`Ingestor.swift:131-182`): converted to **log-only** in the cutover release — increment a fire counter, never merge. The live window has no kind filter and matches on 2048-char-truncated `TRIM(text_preview)`; under v2, every hash-miss-plus-window-hit is by definition a *different* identity, so each remaining fire it acted on would be a false merge (Chromium image entry swallowing a URL copy via the source-url preview; `hello` vs `hello\n` re-creating the rejected V5 semantics; >2048-char prefix collisions). Expected telemetry: zero legitimate fires. Delete window + `secondaryDedupWindowSeconds` next release; `IngestorDedupTests` cases convert into rung-chain hash-hit assertions.
- **Pull-side ±2s rescue** (`CloudKitSyncer.swift:1176-1224`): gated on **`record.hashVersion < 2`** — structurally dead from the first cpdb-v3 pull (every record in the new zone is v2), so it cannot swallow the seeding storm's legitimately-distinct same-preview records (shared-pasteboard mirror pairs, partial-flavor forks) the way a time-gated version would — silently, permanently, while masking the forks from telemetry. Keep the counter on the v1 branch (will read zero; v1 records can't arrive in the new zone); delete next release.

---

## 8. Adversarial findings and their resolutions

Every blocking and serious finding is fixed in this design; minors are fixed or consciously accepted as noted.

| # | Finding (severity) | Resolution | Where |
|---|---|---|---|
| 1 | Kind-keyed partial-feeder guard strands 1,563 live link entries out of cpdb-v3 (blocking) | **Fixed.** Guard re-keyed to rung input: skip only when no rung feeder exists (7 rows, asserted at migration time). Reseed taxonomy spelled out: evicted/missing-blob v1 rows included (push under v1 hash), only zero-flavor stragglers excluded. Vector added: kind=link, text-only → tag=url. | §4.3 step 2/5 |
| 2 | Pull `fetchOne` has no live-row preference; tombstoned siblings shadow survivors (blocking) | **Fixed.** `ORDER BY (deleted_at IS NULL) DESC, created_at DESC` on hash and uuid lookups; test with live + lower-id tombstoned sibling. | §5.2 |
| 3 | Equal-hashVersion uuid collision falls through to `entry.insert` — poison page reborn (blocking) | **Fixed.** Full uuid-conflict spec: every collision intercepted; equal-version resolved by rung priority via wire `identityTag` (higher rung wins — superset argument), tie → smaller hash; per-row `hashVersion` (never constant 2); `SQLITE_CONSTRAINT` catch returns `.unchanged` so no record wedges the token. | §5.3 |
| 4 | Kind-feeder guard + unspecified equal-version conflict recreate the wedge (kind ranks url above image; rungs invert) (blocking) | **Fixed** by the same pair: rung-input guard (no kind consultation) + deterministic rung-priority convergence, which heals wrong-rung partial rehashes instead of trying to prevent them locally. The image-asset-in-flight scenario is a named test. | §4.3, §5.3 |
| 5 | Shared-pasteboard whole-snapshot suppression destroys iPhone-origin UC captures (282 live, 243 with image bytes) (blocking) | **Fixed.** Flavor-level handling: shared-pasteboard file-url is stored but never keys identity (rung 2 skip); snapshot skipped only when it is the sole substantive flavor. iPhone-origin image/text echoes key via rungs 1/4. Residual Finder-file Mac-to-Mac fork consciously accepted (low frequency; §4.6 sweep for history). | §2.4 |
| 6 | Replace-on-bump + iOS string-only copy strips rich flavors fleet-wide; assembled design self-contradictory (blocking) | **Fixed.** Graft conflict resolved explicitly: **union-preserving bump** — never delete, never overwrite same-UTI bytes; flavor-deletion pull parser descoped entirely. | §3 |
| 7 | Downgrade/stale-CLI skew silent; v10 never re-runs (serious) | **Fixed.** Two fences: DB path rename to `cpdb-v3.db` (only fence that stops un-retrofittable old binaries) + every-launch reconcile sweep for `hash_version=1` flavored rows; lockstep app+CLI in runbook; namespaced token key. | §4.2, §5.2 |
| 8 | No runtime path writes `hash_version=2`; constant `hashVersion: 2` mislabels kept-v1 records, corrupting the upgrade predicate (serious) | **Fixed.** Stamped on every insert path (Ingestor, importers, pull-insert copies decoded value); mapper writes row values; uuid-merge never mutates version on equal hash; tests incl. evicted-row-pushes-`hashVersion=1`. | §5.2 |
| 9 | Re-running PasteDbImporter duplicates every kept-v1 row (serious) | **Fixed.** Dual-era probe (`content_hash = v2 OR = v1 OR prev_content_hash = v1`) with `prev_content_hash` index; dropped in R2 when no v1 flavored rows remain; Windows handoff gates ContentIdentity.cs + Schema.cs migration into one release. | §5.5, §6.6 |
| 10 | uuid-conflict "tombstone and bump" destroys pins/pinboards/previews (serious) | **Fixed.** §4.3's coalesce factored into a shared helper called from the pull path's collision branch; test asserts the coalesced fields on a pinned, pinboard-member uuid-row. | §5.3 |
| 11 | Single-transaction 2.6 GB rehash inside the GRDB migration; iOS main-actor crash loop (serious) | **Fixed.** v10 = schema-only; rehash/merge/reseed moved to a chunked, resumable, off-main-actor cutover routine, foreground-gated with progress UI on iOS, sync disabled until complete. | §4.1, §4.3 |
| 12 | Merge losers re-keyed to the v2 hash → multiple rows per hash → systematic shadowing (serious) | **Fixed.** Losers keep their v1 hash and `hash_version=1` (inert in cpdb-v3; the tombstone-wins rationale applies only to standalone tombstones, which are rehashed + reseeded). Live-preference lookup retained as belt. | §4.3 step 3 |
| 13 | iOS drains its reseeded queue before its first pull — fleet-wide stale clobber + server tombstone resurrection (serious) | **Fixed.** Pull-before-push latch in `cloudkit_state`, set by the cutover, cleared after the first successful full pull; converts the cutover to pull-merge-push on every device. | §5.2 |
| 14 | Deletions/pins made during the cutover gap permanently stranded in cpdb-v2 (serious) | **Fixed.** Code-enforced quiesce: cutover step 0 drains the push queue to cpdb-v2 before migrating; recent (≤90 d) standalone tombstones included in the reseed so deletion state has first-class wire presence in cpdb-v3. | §4.3 steps 0/5 |
| 15 | Old-zone targeted GC hollows out any laggard (serious) | **Fixed.** Per-record deletes in cpdb-v2 prohibited; `gc-zone` refuses to run until every known device has written into cpdb-v3; whole-zone delete only, weeks later; `prev_content_hash` demoted to forensics. | §5.4 step 6 |
| 16 | Multi-Mac §3.5 dedupe sweep annihilates both siblings of a pair (serious) | **Fixed.** `--post-migration` freshness/queue gate + one-device runbook; Dedupe survivor selection made device-deterministic (created_at, uuid) so even concurrent runs converge. | §4.6 |
| 17 | Live ±2s pull rescue during the seeding storm swallows legitimately-distinct records and masks forks (serious) | **Fixed.** Rescue gated on `hashVersion < 2` — structurally dead in cpdb-v3; counter kept on the v1 branch; deleted in R2. Same gate principle applied to the capture window by making it log-only. | §7 |
| 18 | Trailing-slash graft contradicts pinned vectors #4/#5 — three normative texts disagree (serious) | **Fixed.** Rule decided once (strip, sim-gated); vectors regenerated (`7ce6868d…`) and verified; vectors JSON is the single source of truth; edge cases pinned in schema.md; graft prose superseded by this document. | §2.3, §2.6 |
| 19 | URL promotion hashes untrimmed bytes — pbcopy `\n` copies never converge; trim set unpinned (serious) | **Fixed.** Promotion returns the trimmed (and slash-stripped) value; URL_TRIM_SET pinned as explicit codepoints incl. U+00A0, shared constant both platforms; vectors #6/#7/#8. | §2.3 |
| 20 | best_text decode policy unpinned (BOM-less UTF-16 endianness, invalid-sequence handling, public.plain-text encoding) (serious) | **Fixed.** Pinned: BOM-less UTF-16 = little-endian everywhere; strict-decode-or-skip (never U+FFFD); plain-text = strict UTF-8 or skip; malformed-input vectors on both platforms. | §2.3 |
| 21 | html-as-text identity platform-divergent but undocumented (serious) | **Fixed (documented, not converged).** html-sourced text identity declared platform-local alongside images in §5.3-handoff and the relay-protocol note; paired vector asserts the documented not-equal relationship. Residual Mac-side html-byte jitter affects only the ~10-row html-only population and is accepted with the fallback rung's caveats. | §6.6, §6.7 |
| 22 | TransientFilter is macOS-watcher-only; v2 makes concealed leaks bump visible entries fleet-wide (serious) | **Fixed.** Marker set moved to CpdbShared, enforced at the Ingestor entry point for every capture path; added to schema.md never-store table with Windows analogues + disjointness assertion; ingest test asserts `.skipped`, not `.bumped`. | §3, §6.1 |
| 23 | Retained 30s window (no kind filter, truncated-preview match) merges entries v2 distinguishes (serious) | **Fixed.** Window is log-only in the cutover release (no merge path), deleted in R2. | §7 |
| 24 | Pre-migration snapshot WAL-unsafe and racy (minor) | **Fixed.** `VACUUM INTO`, one-time guard, single-process by cutover-state gating; restore procedure documented. | §4.3 step 1 |
| 25 | Equal-version forks (fallback rows, truncated blobs) have no convergence mechanism (minor) | **Fixed.** Deterministic equal-version tiebreak (rung, then smaller hash) + fork counter + record-deletions queue. | §5.3 rule 3 |
| 26 | Zero-flavor stragglers whose origin uuid lost the merge become permanent iPhone zombies (minor) | **Fixed.** Migration-time same-preview zombie sweep + sweep re-run on straggler upgrade; `--reap-stragglers` for the remainder. | §4.3 step 4 |
| 27 | uuid-merge re-key strands flavor bytes delivered in an earlier page (minor) | **Fixed.** Orphan-flavor stash (7-day TTL) drained after entry upserts/re-keys. | §5.2 |
| 28 | Zero-flavor stragglers never re-delivered (origin tombstoned/retired) — invisible local ghosts (minor) | **Fixed.** `cpdb storage --reap-stragglers`: after N days, log + tombstone locally (no wire presence to begin with); part of the post-cutover health check. | §5.4 step 5 |
| 29 | iOS background launches run the heavy rehash under the ~30 s BG budget (minor) | **Fixed.** Background launches never run the migrator/cutover; one-time snapshot guard; foreground progress UI. | §4.1 |
| 30 | Collision merge never reindexes the survivor's FTS row after salvage (minor) | **Fixed.** `FtsIndex.indexEntry` for the survivor with post-salvage values, same transaction; search-the-merged-OCR test. | §4.3 step 3 |
| 31 | Replace-on-bump flavor deletion has no blob refcount story (minor) | **Moot.** Union-preserving bump never deletes flavor rows; EntryEvictor remains the only deletion site. Noted for any future same-UTI byte-refresh feature: route through a shared refcount helper extracted from `EntryEvictor.swift:128-199`. | §3 |
| 32 | Fallback sort contract internally false (Ordinal ≠ UTF-8 byte order ≠ Swift `<`) (minor) | **Fixed.** Literal byte-wise UTF-8 sort in both implementations; boundary-spanning non-ASCII vector; stale CanonicalHash.cs comment corrected. | §2.3, §6.4 |

---

## 9. Implementation plan

**Step 0 — freeze the contract (no ship). ✅ DONE 2026-06-09.**
Write `Tools/gen_hash_vectors.py` (reference implementation of §2.3); generate `Tests/Fixtures/hash-vectors-v2.json`. Re-run the identity simulation against `/tmp/cpdb-audit.db` with the final ruleset (slash-strip, URL-context trim, html ladder, empty→fallback); flavor-inspect every cluster the slash-strip adds beyond V4's 441; record the final expected cluster count for the migration assertion. **Gate: zero false merges, or the slash-strip is dropped and vectors regenerate without it.**

> **Result — GATE PASSED.**
> - `Tools/gen_hash_vectors.py` is the frozen reference implementation; `Tests/Fixtures/hash-vectors-v2.json` (25 vectors) is the authoritative artifact. **Every hand-written hex in §2.6 reproduced exactly from the implementation** — including the two the synthesis flagged as hand-corrected (`342ef223…` sub-threshold PNG, `4d648625…` empty-text-fallback) and all `equals` relations. The contract is self-consistent; no §2.6 reconciliation was needed.
> - `Tools/sim_identity_final.py` imports the *same* `identity()` from the generator (one implementation, not two) and runs it over the 9,624 rehashable live entries. Final ruleset: **475 would-merge clusters, 538 excess rows (5.6% of the live corpus)** — up from V4's 441/502; the +34 clusters are the URL-promotion rung converging rich-link (`public.url`) copies with plain-text copies of the same URL, exactly as intended. Tag distribution: image=209, text=134, url=128, fallback=2, file=2.
> - **False merges: 0.** The detector flagged 7 candidate clusters (members whose stale `text_preview` display column differs); byte-level inspection of the identity *inputs* confirmed all 7 are legitimate — `public.utf8-plain-text` byte-identical (CWA address, preview rendering drifted over 262 days) or identical `public.url` / intended text→url promotion convergence. No cluster merges genuinely distinct content. The slash-strip + promotion stay in.
> - **Number recorded for the migration step-3 assertion:** ~475 live clusters on this snapshot (the migration computes it live; this is the sanity-check expectation). No-flavor (evicted, un-rehashable) rows: 6.

*Tests: the generator is the test (`python3 Tools/gen_hash_vectors.py --check` exits non-zero on any broken `equals` relation; re-run `Tools/sim_identity_final.py` to reconfirm the gate against a fresh snapshot).*

**Step 1 — identity core (mac/iOS lib). ✅ DONE 2026-06-10.**
`Sources/CpdbShared/Capture/ContentIdentity.swift` (rung chain, constants, rung indices, `revision = "idv2-r1"`); byte-wise sort fix in `CanonicalHash.swift` (retained as fallback emission); rewrote `HashVectors.swift` as the JSON loop.
*Tests: full vectors file green; rung-priority + promotion-negative spot checks.*

> **Result.** `ContentIdentity` is a faithful Swift port of `Tools/gen_hash_vectors.py` (UTF-16 manual decoder for surrogate-strict cross-platform parity, manual percent-decoder matching `urllib.unquote`, byte-wise UTF-8 fallback sort). `HashVectors.testV2PinnedVectors` loads `Tests/Fixtures/hash-vectors-v2.json` via `#filePath` (single fixture, no SPM-resource duplication; Windows cites the same file) and asserts all **26** vectors' tag + hex — green. The `CanonicalHash` byte-wise sort change is a no-op for the ASCII-UTI v1 vectors (`b22187…`, `17a95c…` still pass), pinning the invariant Windows + the v2 fallback rung rely on. Full suite 142 + the 3 XCTest vector cases green. Lives in CpdbShared, so iOS links it unchanged. **Not yet wired into capture — that's Step 2.**

**Step 2 — capture-path changes. ✅ DONE 2026-06-10.**
Move transient/concealed markers to CpdbShared + Ingestor enforcement; store `is-remote-clipboard` (delete `metadataOnlyUTIs`); file-reference URL resolution; shared-pasteboard sole-substantive skip; all-empty-snapshot skip; Ingestor/UrlImporter switch to `ContentIdentity` with `hash_version`/`identity_tag` stamping; union-preserving bump; 30s window → log-only.
*Tests: concealed snapshot → `.skipped` not `.bumped`; echo-text bump preserves RTF/HTML; UC image echo keys as image; empty skip; window fires counter but never merges; `IngestorDedupTests` converted to hash-hit assertions.*

> **Result.** All items landed; 149 tests green. Notes beyond the plan text:
> - The `v10_semantic_identity` schema migration (columns + `orphan_flavors` + `cutover_state`) shipped here rather than Step 3 — the Ingestor stamping needs the columns to exist, and nothing has shipped so the migration body stays amendable until R1. `cutover_pending` is only set for databases that already contain entries, so fresh installs and in-memory test stores start directly on v2 with no cutover gating.
> - `TransientGuard` was cherry-picked from the `claude/ios-readwrite` branch (identical file), so the branch rebases cleanly; macOS's watcher-side `TransientFilter.skipUTIs` now delegates to it — one marker set, enforced at both the NSPasteboardItem fast path and the Ingestor entry point.
> - Union-bump checks the existing UTI set *before* `storeForInsert` so blob spillover never writes orphaned blob files for already-present flavors; `total_size` is recomputed after a union. Union is skipped for body-evicted rows (their flavors were deliberately discarded; under v2 their v1 hash is unreachable from new captures anyway — belt and suspenders).
> - The capture-policy skips (`snapshotIsAllEmpty`, `isSoleSharedPasteboardEcho`) live on `ContentIdentity` (CpdbShared) since they need the rung chain's own definitions of "substantive" — explicitly marked as capture policy, NOT part of the hash contract.
> - File-reference URL resolution has a live test (creates a temp file, obtains the genuine `/.file/id=` NSURL via the ObjC runtime to dodge Swift's eager URL bridging, asserts resolution) plus pass-through cases for dead references and undecodable bytes.
> - `Ingestor.secondaryWindowFireCount` is the §7 observation counter; the probe logs and falls through to insert.
> - **PasteDbImporter intentionally still computes v1 hashes** (rows stamp `hash_version=1` via the column default) — its `ContentIdentity` switch + dual-era probe is Step 5 as planned.
> - ⚠️ **Do not install/deploy a build between this step and R1 completion**: a v2-hashing Ingestor against a v1 corpus would fork identities for every re-copy (no hash hits against existing rows) until the Step-3 migration rehashes the corpus.

**Step 3 — migration + cutover routine. ✅ DONE 2026-06-10.**
`v10_semantic_identity` schema migration; `cpdb-v3.db` path rename fence; cutover routine (drain → VACUUM INTO → chunked rehash with rung-input guard → collision merge with coalesce helper + FTS reindex → zombie sweep → reseed + latch); launch reconcile sweep; `cpdb storage --verify-hashes`.

> **Result.** `IdentityCutover` (runner + `reconcileSweep` + `verifyHashes`), `EntryCoalesce` (shared merge), the throwing `cpdb-v3.db` rename fence, the syncer cutover/latch gates, and `cpdb storage --verify-hashes` all landed. **162 tests + a real-data integration test** (`IdentityCutoverAuditTests`, gated on a `/tmp/cpdb-audit.db` copy) that runs the full cutover on the production snapshot: 479 clusters / 543 losers / **0 hash mismatches / 0 live duplicate hashes** / caddy pair 9807-9808 collapsed (counts drift slightly above the Step-0 frozen 475 as the live DB grows — invariants asserted, not exact counts).
>
> **Adversarial review** (4-lens workflow, 29 raw findings). Fixed in this step:
> - **Born-v2 loser kept the survivor's live v2 hash** (BLOCKING data-loss via `reconcileSweep` pushing a tombstone for the survivor's record). `retireLoser` now hard-deletes born-v2 losers (`hash_version=2 ∧ prev IS NULL` — never pushed under the cutover gate, byte-identical to the survivor) and tombstones rehashed/skew-v1 losers with an inert v1 hash. Two tests.
> - **`EntryCoalesce` injected flavors into a body-evicted survivor** — now guarded (mirrors the Ingestor union-bump), metadata salvage still runs. Test.
> - **Interrupted `VACUUM INTO` blessed a partial snapshot** — step 1 now trusts the completion marker, deleting + re-vacuuming when unset (safe: rehash hasn't started). Test.
> - **Rename fence orphaned the WAL** (main moved before `-wal`) and swallowed failures (→ `Store.open` created an empty DB stranding history) — now moves sidecars first / main last (crash self-heals) and throws so `Store.open` fails loudly. Test (asserts `-wal` moved).
> - **Step 0 re-ran the drain on every resume** — added a `cutover_drain_done` marker.
> - **Latch was write-only** — `pushPendingChanges` now also returns empty while `pull_before_push_latch` is set, so a pre-Step-4 build fails safe (push silent until Step 4 clears it after a full pull).
>
> **Deferred to Step 4** (recorded so they aren't lost — verified real but out of this step's scope):
> - **Step-0 drain hook is structurally a no-op** while the cutover push gate is live: the app's drain must be a dedicated `drainLegacyQueue()` that BYPASSES the `isPending` gate and targets the retained `cpdb-v2` zone. Until Step 4 wires it, `drainPushQueue` is nil and a non-empty queue simply blocks (conservative, correct).
> - **No production call site yet**: `IdentityCutover.run`/`reconcileSweep` are invoked only by tests. Step 4 (with the zone switch) wires them into `DaemonLifecycle`/`AppDelegate` — off-main, foreground-only, with the latch-clearing pull. Wiring them before the zone switch would re-enable sync against `cpdb-v2` with v2 hashes (the fork the "do not deploy" rule prevents), so this is correctly Step 4.
> - **`PushQueue.remove` races re-enqueue** (deletes by `entry_id` with no `enqueued_at` guard): a mutation during an in-flight batch loses its re-enqueue on batch success. Pre-existing syncer bug, amplified by the 9.3k-row reseed drain. Fix in Step 4 (peek returns `enqueued_at`, remove qualifies by it).
> - **No cross-process exclusion** around `run()` (daemon + CLI both `Store.open`). Moot until wired; add an flock sentinel (DaemonLock pattern) in Step 4.
> - **`reconcileSweep` re-selects permanent missing-blob rows every launch** (silent `try?`, 500-row limit can starve real skew rows). Persist a kept-v1 watermark / log blob-load failures in Step 4.
> - Minor/observability: persist Report counters across resume; §4.3 step-2.3 migration assertion + §4.5 expectation logging; loser-flavor blobs need `cpdb gc` orphan cleanup (existing gap); mid-cutover deletion of an un-rehashable v1 row gets no wire presence. Tracked for Step 4/5.

*Tests: idempotent resume (mid-step-2 kill); kept-v1 taxonomy (evicted/zero-flavor/missing-blob); merged pins/pinboards/previews/FTS; born-v2 hard-delete (merge + reconcile); body-evicted coalesce guard; partial-snapshot replacement; recent-vs-90-day tombstone reseed; rename fence + WAL; real-snapshot integration with 0 mismatches.*

**Step 4 — sync changes.**
Zone `cpdb-v3` + subscription + namespaced token key; `hashVersion`/`identityTag` per-row in `EntryRecordMapper`; pull-insert stamping; live-preferred lookups; full uuid-conflict resolution + shared coalesce helper; orphan-flavor stash; insert constraint catch; self-healing token errors; pull-before-push latch (SET in Step 3 / gate added in Step 3; Step 4 adds the **clear-after-first-full-pull**); ±2s rescue `hashVersion < 2` gate; `cloudkit_record_deletions` queue. **Plus the Step-3 deferred items above**: gate-bypassing `drainLegacyQueue()`, production launch wiring of `run()`/`reconcileSweep` (off-main, foreground-only), `PushQueue.remove` enqueued_at fix, cross-process cutover lock, reconcileSweep missing-blob watermark.
*Tests: the §5.3 list, verbatim — every branch, both devices' perspectives.*

**Step 5 — importer + CLI.**
PasteDbImporter dual-era probe + stamping; `cpdb dedupe` deterministic survivor + `--post-migration` gate; `cpdb storage --reap-stragglers`; `cpdb sync gc-zone` with fleet-upgrade refusal.
*Tests: re-import after migration with evicted/zero-flavor rows produces zero duplicates; concurrent dedupe simulation picks identical survivors; gc-zone refuses with a missing device.*

**Step 6 — docs.**
All §6 artifacts: schema.md rewrite, parity rows, `windows-hash-v2.md` handoff, relay-protocol note, cutover runbook.

**Step 7 — ship R1 (mac v2.11.0 + iOS build) and execute the §5.4 choreography.** Pre-ship gates: vectors green on both platforms; sim re-run matches; `--verify-hashes` clean on a migrated copy of the production snapshot.

**Step 8 — Windows release (own schedule, no sync dependency).** Execute the handoff: `ContentIdentity.cs` + `Schema.cs` rehash/merge **in one release**; `Ingestor.cs:43,144,247` + `UrlImporter.cs` switch; JSON vectors + disjointness test; parity rows; CHANGELOG + `Directory.Build.props` bump.

**Step 9 — R2 (mac v2.12), after ≥1 release of telemetry.**
Delete the 30s window + constant; delete the ±2s rescue (counter read zero); drop the importer dual probe once `SELECT COUNT(*) FROM entries WHERE hash_version=1 AND id IN (flavored)` is zero fleet-wide; run/ship the gated GC decision; delete pre-v10 snapshots. `Dedupe.swift` documented maintenance-only.

---

## 10. Maintainer decisions (resolved 2026-06-09)

1. **Database filename: `cpdb-v3.db`** — confirmed. The skew fence renames `~/Library/Application Support/net.phfactor.cpdb/cpdb.db` → `cpdb-v3.db` at first launch of the new build. Action items spawned to update anything outside the app that touches the old path (audit-snapshot workflow in `/tmp/cpdb-audit.db` copy step, any backup scripts, README's "open the SQLite file with…" section). The legacy `cpdb.db` path is left untouched on disk after the rename so a downgrade can in principle recover by restoring from snapshot.
2. **cpdb-v2 CloudKit zone: delete** — confirmed. `cpdb sync gc-zone cpdb-v2` runs whole-zone deletion no earlier than two weeks post-cutover, gated on every known device having written into cpdb-v3 (per the design's refusal predicate). No targeted per-record deletes are ever issued against cpdb-v2, only the whole-zone deletion. After deletion, `prev_content_hash` is retained for forensics only.
3. **Tombstone reseed window: 90 days** — confirmed. §4.3 step 5's `deleted_at >= :now - 90*86400 AND hash_version = 2` stays as written. Older tombstones become inert; standalone tombstones inside the window are rehashed and reseeded so deletion state has first-class wire presence in cpdb-v3.

All three answers match the design's defaults, so §4 / §5 / §6 require no edits — this section is the audit trail.