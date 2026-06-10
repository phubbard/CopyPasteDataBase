# Byte-Level Forensics: Why Same-Content Entries Get Different Hashes

DB: `/tmp/cpdb-audit.db` (copy). Method: live entries, same `TRIM(text_preview)`, different `content_hash`, captured within 300s → **266 pairs**. For each pair, every UTI was compared side-by-side (present/absent, size, bytes). Whole-DB burden (no time window): 281 preview-groups, 592 live entries, 311 excess rows.

## Headline finding: this is mostly ONE bug, not ten

**230 of 266 pairs (86%) are cross-device** — the same physical copy captured twice because **Universal Clipboard re-publishes the pasteboard on the receiving Mac and cpdb captures it there as a "new" copy**. Telltale: side A is the real app (Warp, Finder, Zen) on the origin Mac; side B is whatever was frontmost on the idle receiving Mac (`loginwindow`, `iMazing Mini`), 0.0–0.3s later. Example pair 8664/8667 (both 2026-04-23 04:29:37, Warp@air-15 vs loginwindow@axiom). 107 cross-device pairs are <5s apart; 56 are >30s (receiving Mac woke late) — **beyond any plausible dedup window**, and the capture-side text-dedup can't catch them anyway because the origin entry hasn't synced down yet when the second capture fires, and CloudKit pulls bypass the window in the other direction.

Per-pair differing-UTI signatures (a pair can be fully explained by its signature):

| n pairs | differing UTIs |
|---|---|
| 153 | `public.text` only |
| 24 | `is-remote-clipboard` + `public.text` |
| 21 | `is-remote-clipboard` + `public.text` + `public.file-url` |
| 11 | `com.apple.traditional-mac-plain-text` only |
| 9 | `public.utf8-plain-text` (real byte diffs — see below) |
| 5 | `org.chromium.source-url` only |
| remaining 43 | mixes: utf16 variants, icns, linkpresentation, html/rtf flavor-set differences |

`com.apple.is-remote-clipboard` stops appearing 2026-04-27 (when the capture filter shipped) — but the UC re-publication **also adds `public.text`**, so the filter only removed one of the jitter UTIs. That's why `public.text`-only is now the #1 signature.

## Answers to the specific questions

### public.file-url (32/33 pairs)
Three distinct mechanisms, byte-verified:
1. **Universal Clipboard path rewrite (27 size_diff pairs, dominant).** Origin Mac stores Finder's file-reference URL `file:///.file/id=6571367.13704961`; receiving Mac stores `file:///Users/pfh/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/<FRESH-UUID>/<filename>` — useractivityd materializes the remote file into a shared-pasteboard container with a **new UUID per transfer** (pairs 3587/3588, 7708/7709, 9330/9331; note 9330/9331 even crosses user homes, `/Users/pfh` vs `/Users/hubbard`). This URL can never dedup.
2. **only_a (4 pairs): file-copy vs text-copy.** E.g. 4878 (kind=file: file-url + utf16-external filename + utf8) vs 4879 (kind=text: utf8 only) — user copied the file, then copied the filename text. Genuinely different events; preview collision only.
3. **bytes_diff (1 pair, 5878/5879):** `id=6571367.54755290/` vs `id=6571367.54755283/` — two different "koreader" folders 12s apart. Genuine re-copy of a different file. Not jitter.

So: the `/.file/id=` form itself was stable within this dataset; the jitter is the **shared-pasteboard UUID path on the receiving device**.

### public.utf8-plain-text (14 size_diff pairs) — mostly NOT jitter
Byte-diffed all 14: **7 prefix-extension** (B = A + appended bytes, e.g. 8649→8650 Warp log output grew, 5631→5632 ChatGPT answer still streaming, 3071→7927 bytes), **4 real mid-content diffs** (different ChatGPT/script outputs sharing a prefix), **2 whitespace-only** (one or two extra *leading* spaces, strip-equal; selection-boundary slop in terminal/Safari), 1 blob-stored (skipped, 1.9MB Nova). No CRLF, no NBSP, no BOM, no trailing-newline jitter found in UTF-8 bytes. **These pairs match only because `text_preview` is a ~2048-char truncated prefix** — they are genuinely different copies. Implication: don't loosen identity to fix these; they're correct duplicates-in-preview-only.

### com.apple.linkpresentation.metadata (6+1 pairs)
NSKeyedArchiver bplist of `LPLinkMetadata`. Decoded both sides of pairs 9224/9228 and 9349/9351 (Safari link copies of the same URL): URL/title identical; the **differing keys are `iconMetadata`/`icon`/`contentImagesMetadata` — present or absent depending on whether the async favicon/preview fetch had completed at copy time** (archive carries an `isIncomplete` flag). One pair had a 34.6KB version (inlined icon) vs absent. Pure derived, fetch-timing-dependent metadata. Same conclusion as cpdb's own `link_title`/`link_fetched_at` columns: rich-link data is enrichment, not identity.

### public.html — not Chrome session junk in this dataset
6 pairs: 5 are present-on-one-side-only because the same text was copied from **different apps** (Safari vs Claude.app, Brave vs Parallels) — legitimately different flavor sets. 1 size_diff (ChatGPT 7116→16830 bytes) is the streaming-growth case, same head, more content. **No pair showed same-text HTML regenerated with embedded volatile fragments.** Chrome's volatility lives in its sidecar UTIs instead: `org.chromium.source-url` (the tab URL — observed flipping between `claude.ai/epitaxy/local_<uuid>`, `/chat/<uuid>`, `/cowork/<uuid>` for identical copied text) and `org.chromium.internal.source-rfh-token` (render-frame token). Likewise `com.apple.WebKit.custom-pasteboard-data` contains `x-webdoc://<per-page-UUID>` or the page origin — session-scoped by construction. RTF: 3 pairs, same routes-differ/growth story; no regeneration jitter observed (though `\cocoartf<build>` version stamps vary across OS updates and will jitter across devices on different OS builds).

### utf16 variants — encoding duplicates with BOM jitter
`public.utf16-plain-text` size_diff pairs differ by **exactly 2 bytes: the UC re-publication adds an FF FE BOM** the origin lacked; all decode to text byte-identical to the utf8 sibling (pairs 8794/8795, 8803/8804, 8805/8806, 8845/8847). `public.utf16-external-plain-text` only_a pairs are the file-copy-vs-text-copy route difference. Both UTIs are pure re-encodings of the utf8 text.

### Pairs >30s apart
Same split, cleanly: **cross-device >30s (56 pairs) show the identical UC signature** (`public.text` only_b ×48, `is-remote-clipboard` ×12, shared-pasteboard file-url ×7) — same bug, delayed second capture; a wider time window doesn't change the mechanism. **Same-device >30s (21 pairs) are dominated by genuine re-copies** (utf8 growth/real diffs ×11) and different-route copies (html/rtf/utf16 only_a) — these *should* remain distinct entries or be handled by preview-dedup, not identity changes.

## Evidence-ranked classification for identity redesign

**Tier 1 — provably volatile metadata, zero content, exclude from hash (fixes 207/266 = 78% of pairs):**
- `public.text` — byte-identical to `public.utf8-plain-text` in **1694/1694** co-occurrences DB-wide; added by UC re-publication. Biggest single offender (201 pairs involve it).
- `com.apple.is-remote-clipboard` — already capture-filtered; must also be excluded for pre-2026-04-27 rows if identity is recomputed.
- `com.apple.traditional-mac-plain-text` — lossy MacRoman re-encoding of the same text; UC-added (11 pairs alone).
- `org.chromium.source-url`, `org.chromium.internal.source-rfh-token` — tab URL / frame token, pure provenance.
- `com.apple.WebKit.custom-pasteboard-data` — `x-webdoc://<uuid>` session data.
- `com.apple.linkpresentation.metadata` — async-fetch-state snapshot.
- `com.apple.icns` — file icon, materialized on receiving side (4/5 only_b pairs cross-device).
- `com.raycast.RestoredType`, `com.apple.iWork.pasteboardState.*` (the documentId/countOfObject **value is baked into the UTI name** — 13 distinct names in 17 rows), `com.apple.security.sandbox-extension-dict` (4 rows).
- `public.utf16-plain-text` / `public.utf16-external-plain-text` — verified pure re-encodings of utf8 text with BOM jitter; exclude when a utf8 sibling exists (or normalize to decoded text).

**Tier 1.5 — `public.file-url`, content-bearing but device-relative (with Tier 1, fixes 235/266 = 88%):** it IS the content for file entries, but the receiving-side `shared-pasteboard/items/<UUID>/` rewrite means raw bytes can't be identity. Identity for file entries needs either the file basename + payload, or recognition that `group.com.apple.coreservices.useractivityd/shared-pasteboard` paths are remote mirrors (the path itself is a reliable remote-copy marker, like is-remote-clipboard).

**Tier 2 — content-bearing but route/regeneration-dependent (`public.html`, `public.rtf`, `com.apple.webarchive`):** in this dataset they differed only when copies were genuinely different events (different source app, or grown content) — no observed same-copy regeneration jitter — but they are absent-vs-present across copy routes, so including them in identity means "same text from Safari" ≠ "same text from Warp". Decision is policy, not forensics: if identity should be text-semantic, hash only the canonical text/url/file/image payload and demote html/rtf to stored-but-unhashed fidelity flavors.

**Tier 3 — genuinely content, must stay in identity:** `public.utf8-plain-text` bytes (every observed byte-diff was a real content difference or leading-whitespace selection slop — at most trim-normalize, never drop), `public.url`, image payloads, file payload/basename. `dyn.*` UTIs (2114 rows, 18 distinct) are deterministic encodings of app-private type strings, not per-copy volatile — harmless either way, but they carry app-private content (e.g. Nova/Warp selection state) and one pair showed them tracking a genuine route difference.

**Sizing the fix:** Tier 1 exclusion alone collapses 78% of observed dup pairs; +file-url handling reaches 88%. The residual 12% are genuine re-copies colliding on a truncated preview — correct behavior. Because 86% of dups are cross-device UC re-captures, no capture-side time-window tweak can substitute for hash-input canonicalization: the two captures happen on different Macs before sync converges, and both upload hash-derived CloudKit records (`entry-<sha256>`), permanently forking the record space.

---

# Identity-Function Simulation over /tmp/cpdb-audit.db

Script: `/tmp/identity_sim.py` (full output: `/tmp/identity_sim_out.txt`). Canonical serialization per spec: per flavor in UTI-sorted order, `uti_utf8 + 0x00 + 8-byte-BE-length + bytes`, SHA-256; blob-keyed flavors proxied as `BLOB:{blob_key}`; V4/V5 identity = `sha256(tag + 0x00 + bytes)`.

## Population

| metric | count |
|---|---|
| Total live entries (deleted_at IS NULL) | 9,630 |
| Live entries with NO flavor rows (evicted — cannot rehash, excluded) | 6 |
| Live entries with ONLY blob_key flavors | 11 |
| Entries rehashed per candidate | 9,624 |

Kind distribution of live entries: text 4,906 / link 3,800 / image 689 / file 174 / color 39 / other 22.

## Summary table

| candidate | hashed | fallback uses | would-merge clusters | excess rows eliminated | V1-distinct pairs merged | <30s | 30s–5min | 5min–1day | >1day | fm: preview differs | fm: rtf/html differ |
|---|---|---|---|---|---|---|---|---|---|---|---|
| V1_current | 9,624 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | — |
| V2_deny | 9,624 | 3 | 24 | 26 | 28 | 13 | 3 | 2 | 6 | 1 | — |
| V3_allow | 9,624 | 6 | 46 | 50 | 57 | 18 | 12 | 9 | 7 | 1 | — |
| V4_semantic | 9,624 | 19 | 441 | 502 | 574 | 344 | 55 | 13 | 29 | 5 | 5 |
| V5_semantic_trim | 9,624 | 19 | 502 | 569 | 677 | 358 | 61 | 24 | 59 | 7 | 25 |

V1 produced zero collisions, exactly matching the live unique index — the harness reproduces existing cluster structure, validating the blob-proxy approach.

## Headline findings

**V2/V3 (UTI filtering) massively undershoot.** They eliminate only 26 / 50 duplicate rows vs V4's 502. Reason: they still hash raw `public.utf8-plain-text` bytes and `public.file-url` bytes, so the two dominant jitter sources from the audit (file-url presence/value differences in 32/33 pairs, whitespace/line-ending text jitter) still split entries. UTI filtering alone cannot fix this corpus.

**V4 eliminates 502 duplicate rows (5.2% of live corpus) with zero verified false merges.** 344/441 clusters (78%) have <30s spread — exactly the same-copy jitter the 30s Ingestor text-preview window papers over locally, but which CloudKit pulls bypass. These are the cross-device sync duplicates.

**V5 adds +61 clusters / +67 excess rows / +103 pairs over V4** — almost entirely trailing-newline command re-copies (`brew services restart ollama\n` vs same without `\n`, `npm install -g @anthropic-ai/claude-code`, indented shell snippets). So outer-whitespace jitter contributes ~12% additional dedup. Cost: see false-merge analysis.

## False-merge investigation (flavor-level verification)

Every "trimmed text_preview differs" cluster for V2/V3/V4 was inspected at the raw flavor level — **all are legitimate merges**; the preview diff is preview-generation-era cosmetics, not content difference:

- ids 3165/5938 (`wcl.phfactor.net`): identical `public.url` bytes (`https://wcl.phfactor.net/`); only the utf8-plain-text differs by trailing slash. V4 keys links on `public.url` — correct merge.
- ids 116/9407 (venmo): byte-identical `public.url`; older entry has empty preview + `com.apple.is-remote-clipboard`.
- ids 7697/7340/9745 (movies.phfactor.net): byte-identical `public.url` across all three; differing extras are `is-remote-clipboard` / `linkpresentation.metadata` / `public.text` presence.
- ids 4572/9398 (CWA address, 262d apart): **byte-identical** `public.utf8-plain-text` (`CWA\nDept R Dock C2\n...`). The old preview rendered newlines as spaces. Their `public.rtf` differs only by Cocoa RTF writer version (`cocoartf2822` vs `cocoartf2869`) — pure formatting-engine noise.
- ids 1341/1711 (V5 cmake pair): utf8 bytes identical except trailing `\n`; the `\t1\t` in the old preview never existed in the text flavor.

**rtf/html-differ clusters (formatting variants collapsed):** V4 = 5 clusters, V5 = 25. Examined examples (part numbers `AQ4042-01P`, `SBQJ017`, `CTS57-0701` re-copied from web pages weeks apart; the CWA address) all have identical plain text with html/rtf differing in source-page styling or RTF writer version. Merging keeps one entry's formatting flavors and discards the other's — for this corpus that loss looks acceptable, but it is the one real semantic cost of V4/V5: the surviving entry's rich flavors may not match the page you copied from most recently.

## >1day merges by tag (suspicious-merge audit)

- **V4: 29 clusters (24 text, 5 url).** Manual review of all 29: USPS/UPS tracking numbers re-copied over 1–4 days (7 clusters), part/model numbers, hostnames (`nas.elk-mimosa.ts.net`), email addresses, URLs-as-text, repeated commands (`make upload-testflight`). All are genuine "user re-copied the same thing later" — legitimate identity, debatable only as UX (merge bumps recency vs. new history row).
- **V5: 59 clusters (54 text, 5 url)** — the additions are trailing-newline/indentation re-copies of commands; same character.
- **One real wart:** the empty/whitespace-text cluster. V4 merges 6 truly-empty text entries spanning 1,577 days; V5 collapses 11 whitespace-only entries to the empty string (`''` cluster, 4.3-year spread). Recommend special-casing empty/whitespace-only content (skip capture or exempt from identity) rather than letting `sha256('text\x00')` become a mega-entry.

## Fallback-path characterization

All fallback entries are kind `other` (22 in corpus):

- **V4/V5: 19 fallbacks** — Chromium-internal-only payloads (`org.chromium.*` + sometimes `public.html` with no plain-text flavor), `com.apple.WebKit.custom-pasteboard-data`-only, one `com.apple.traditional-mac-plain-text`-only, one `si.savage.dreams.entities`. Note: several have `public.html` but no text flavor — adding `public.html` to the text-priority chain would rescue ~10 of these from the fallback path.
- **V2: 3 fallbacks** (every flavor denied): ids 5542 (chromium-only), 8377, 8457 (WebKit-custom-data only).
- **V3: 6 fallbacks** (nothing on allowlist): the above plus ids 2047, 3135, 8817.

## Top clusters eyeball check (V4)

Largest: empty-text ×6 (see wart above); then 4-member link clusters with minutes-scale spread (`jdhodges.com` benchmark page ×4 in 1.8m, `happyjump.day/stats` ×4 in 24m, Cloudflare dashboard ×4 in 5.8m, cpdb GitHub release ×4 in 14m) — classic browser URL-copy jitter, all legitimate; Caddy config snippet ×4 in 21s; image triplets with 1–41s spread (screenshot re-copies). Nothing illegitimate in the top 15.

## Bottom line

- **V4_semantic is the clear winner**: 20× the dedup power of UTI deny/allow-listing (502 vs 26/50 rows), 78% of merges inside the 30s jitter window, and zero verified false merges after flavor-level inspection of every flagged cluster.
- **V5's trim adds modest real wins** (trailing-newline command re-copies) but triples >1day text merges, 5× the formatting-variant collapses (25 vs 5), and creates the whitespace-only mega-cluster. If trim is adopted, pair it with an empty-after-trim guard.
- Either way, special-case empty content, and consider `public.html` in the text-priority chain to shrink the V4 fallback path from 19 to ~9 entries.