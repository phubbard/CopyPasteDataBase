# Relay sync — deep analysis (Cloudflare substrate)

> **Status: analysis, 2026-07-05.** Input to the next revision of
> [`relay-protocol.md`](relay-protocol.md) and to the go/no-go on client
> work. Produced by a 19-agent review (7 research lenses, each
> adversarially verified against current Cloudflare/Apple/NuGet docs +
> the repo, plus a completeness pass). Platform numbers were fetched
> 2026-07-05, not recalled from memory; load-bearing sources are cited
> inline. Workload numbers are measured from the live library.
>
> **Headline: Cloudflare is the right substrate and the design is
> salvageable at $0/mo, but the v1 spec as written cannot be implemented
> (three critical defects), the scaffold has two one-way doors that must
> be fixed before the FIRST `wrangler deploy`, and the protocol needs a
> revision (call it v2) before any client work starts.**

---

## 1. The measured workload (what we're actually designing for)

One user; 3 Macs (usually one LAN) + iPhone + ≥1 Windows box.

| Metric | Value |
|---|---|
| Entries | 10,117 (text 5,127 · link 3,967 · image 752 · file 206 · color 39) |
| Logical size | 2.7 GB (384 MB SQLite + 2.0 GB blobs) |
| ≤64 KB | 8,612 entries (85%) = 26 MB |
| 64 KB–1 MB | 1,155 entries = 328 MB |
| 1–5 MB | 257 entries = 517 MB |
| **>5 MB** | **93 entries = 1,805 MB — 1% of entries, ~67% of bytes** |
| Syncable under the 5 MB envelope cap | ~10,024 entries ≈ 871 MB |
| Steady-state rate | 20–200 entries/day; reseed burst ≈ 10k envelopes |

Two design facts fall straight out: the relay's economics are set by a
tiny heavy tail that the 5 MB cap already excludes, and the v1 spec's
100 MB workspace cap holds only ~1–8 weeks of history — a policy choice,
not a cost necessity (§4).

## 2. Verdict and topology

**Substrate: Cloudflare Workers + one Durable Object per workspace +
R2, as scaffolded — confirmed.** D1 was evaluated and rejected (no
WebSockets, single-threaded global DB, extra hop; the DO is needed for
fan-out and replay consistency regardless). The wire protocol contains
zero Cloudflare-isms; the exit ramp to a VPS (one process per workspace
+ SQLite + disk) is real and should be kept real as a design rule.

**Topology: hybrid (B), not relay-for-all (A).** Apple devices keep
CloudKit (silent-push iPhone wake, full-history cloud copy, working
ActionRequest — all irreplaceable on the relay today, which has no
APNs); the relay bridges Windows, with **all Macs** dual-writing rather
than a single bridge Mac (no single point of failure; envelope-id
idempotency makes redundant bridging harmless — but add the cheap
check: skip push when the relay index already lists the envelope_id).
Honest caveats the verifier forced:

- In B, the iPhone↔Windows path stalls when **all** Macs sleep. The
  $0 mitigation is `pmset` never-sleep on one desktop (axiom or thor);
  a VPS is not needed for this.
- The bridging invariant is load-bearing: Macs must push the **stored
  content_hash verbatim** when relaying entries that arrived via
  CloudKit — never re-derive — or platform-local image identities
  echo-duplicate.
- Convergence to A is possible later (the protocol deliberately mirrors
  CloudKit semantics) but is *not* a flag-flip: it needs an iOS relay
  client and a push story. Define concrete triggers during the trial
  (e.g. relay uptime + duplicate-rate over 3–6 months) instead of
  "if CloudKit grates."

Rejected: LAN-only mesh (breaks when remote; new protocol for less
capability), Syncthing (file-syncing a live WAL SQLite is torn-page
last-writer-wins corruption; the envelope-per-file variant has no iOS
story), self-host on Tailscale (free for 6 users, but inverts the opex
win and is unreachable exactly when traveling). CloudKit Web Services
for Windows was scored and rejected: Apple-ID web-auth token friction,
no server-to-server private-DB access, and it would weld Windows to the
substrate we're trying to outgrow.

**Prerequisite gate (hard): Windows must land
[`handoffs/windows-hash-v2.md`](handoffs/windows-hash-v2.md) before any
sync topology exists.** envelope_id derives from content_hash; a
v1-hash Windows creates parallel envelopes for identical content and
nothing dedupes. Image + html-only identities stay platform-local by
design — accept visibly doubled cross-platform images.

## 3. Cost: $0/mo is real, with three caveats

Verified against the current pricing pages
([DO](https://developers.cloudflare.com/durable-objects/platform/pricing/),
[R2](https://developers.cloudflare.com/r2/pricing/),
[Workers limits](https://developers.cloudflare.com/workers/platform/limits/)).
Free plan: 100k Worker req/day, 100k DO req/day, 13,000 GB-s DO
duration/day, 100k SQLite row-writes/day, 5M row-reads/day, 5 GB DO
storage (account-wide); R2 free: 10 GB-month, 1M Class A + 10M Class B
ops/month, free egress, free deletes. Steady state (≤200 entries/day ×
5 devices ≈ 1–3k req/day) sits at **<5% of every meter**; a 10k reseed
day reaches ~60% of the request caps — pace it. Workers Paid is a flat
$5/mo escape hatch that nothing in the model ever forces.

The caveats that keep $0 honest:

1. **WebSocket Hibernation is the entire cost model.** A DO pinned by
   ordinary (`server.accept()`) sockets bills wall-clock duration:
   0.125 GB × 86,400 s ≈ **10,800 GB-s/day — ~83% of the free daily
   duration budget for one idle workspace** (duration is per-DO, not
   per-socket, so more sockets don't multiply it — but one is enough).
   With the Hibernation API, hibernated time is unbilled and the cost
   rounds to zero. The scaffold uses the legacy API; see §6.
2. **The free request/duration caps are account-wide**, shared with any
   other Workers hobby projects on the same account. The Workers/DO
   meters fail closed (Error 1027 — sync pauses, nothing lost); **R2 is
   pay-as-you-go, not fail-closed** — beyond free tier it bills cents,
   it does not stop. No usage alerts exist for Workers/R2, so the
   in-DO per-device token bucket (§7) is the alert substitute.
3. **12-month TCO:** CF free $0 · CF paid $60 · Hetzner entry VPS ~$78
   (CX23 is €5.49/mo since June 2026 — the old ~$4 anchor is stale) +
   10× the attention (TLS, patches, backups, uptime). The VPS is
   strictly dominated as a *first* deployment; it survives as the exit
   ramp.

## 4. Raise the workspace cap; restate what the relay is

The 100 MB LRU was designed for a many-users cost profile that doesn't
exist here. At 2 GB the full syncable library (871 MB today) fits with
headroom **inside R2's free tier** (worst case on paid: ~$0.014/mo),
and three problems disappear at once: new-device bootstrap becomes the
full syncable history instead of a ~1,150-entry stub; "reseed to
relay" actually works (under 100 MB a 10k reseed self-evicts ~90% as it
runs); and eviction stops thrashing on enrichment churn.

Keep: the 5 MB envelope cap (the 93-entry/1.8 GB tail stays local-only
— revisit only if it ever hurts in practice), LRU as a safety valve,
newest-first ordering for every bulk push, and the stance that the
relay is a **reconstructible cache, never the archive** — local SQLite
remains the only source of truth. Compression (§9) roughly doubles the
effective cap for free.

## 5. Protocol defects — the spec cannot ship as written

Full detail lives in the review; these are the accepted findings, each
with its resolution. C = critical, H = high, M = medium.

**C1 — The server can never verify the HMAC.** `auth_key` is
PSK-derived and client-side only; no endpoint conveys it, so
§Authentication is unimplementable — the scaffold's verify is a TODO
that accepts anything. *Fix:* explicit bootstrap `PUT /v1/<ws>` carrying
`{auth_key}` over TLS, persisted trust-on-first-use in the DO (HKDF
independence means `auth_key` reveals nothing about `content_key`);
verify with WebCrypto HMAC + Cloudflare's `crypto.subtle.timingSafeEqual`
(both available in Workers). The same signed-header auth MUST be
enforced on the WebSocket upgrade — today an unauthenticated party who
learns the (cleartext) workspace_id could stream envelope events:
live copy-activity surveillance with no credential.

**C2 — The "blind store" claim fails for guessable content.**
`envelope_id = HMAC(content_hash, key=workspace_id)` uses a key the
server sees on every request. The relay can canonical-hash any
*candidate* content (a known URL, a circulating file — 39% of the
library is URLs) and confirm its presence offline at two hash ops per
guess. *Fix:* fourth derived key `id_key = HKDF(PSK, "cpdb.id.v1")`;
`envelope_id = HMAC(id_key, content_hash)[:16]`. Dedupe is preserved
(all devices hold the PSK); the relay can no longer test membership.
16-byte truncation is fine (collision p ≈ 10⁻²⁷ at 10⁶ envelopes).

**C3 — Pairing is mathematically impossible as specified.** The doc
derives 8 Diceware words *from* the PSK via HKDF (one-way, and 11
bytes cannot rebuild 32) yet has the joining device "reverse to PSK";
the stated ~103-bit entropy also exceeds the 88 bits available. A
second device can never join. *Fix (invert):* the words ARE the root
secret — 8 EFF-long-list words from CSPRNG (103.4 bits),
`PSK = HKDF(ikm = NFKD(words), salt = "cpdb.psk.v1")`. QR carries the
words. No Argon2 needed at machine-generated full entropy.

**H1 — Rotation/revocation is fiction.** No rotate endpoint exists; a
new PSK is simply a different workspace, and the old one stays
readable/writable to a thief indefinitely (polling defeats the 30-day
reclaim). *Fix:* authenticated `DELETE /v1/<ws>` (wipe) + a rotation
runbook (new words → re-pair → republish from local SQLite → wipe old
workspace), and rewrite the threat-model paragraph honestly.

**H2 — XChaCha20-Poly1305 is native on none of the three clients**
(CryptoKit: AES-GCM + IETF ChaChaPoly only; .NET BCL: same; Workers
never need content crypto — correct in the design). Keeping XChaCha
buys nonce headroom we don't need (random 96-bit nonces collide at
p ≈ 6×10⁻¹⁸ for 10⁶ envelopes) at the price of a libsodium native
dependency on every platform. Two lenses disagreed here; **adjudicated:
drop XChaCha.** Spec **IETF ChaCha20-Poly1305**
(`envelope_wire = nonce(12) ‖ ct ‖ tag`); run
`ChaCha20Poly1305.IsSupported` on the actual Windows box first (it
rides CNG — effectively Win11/Server2022+), and if it fails, standardize
on **AES-256-GCM** instead. Exactly one cipher, no agility. Zero native
crypto deps on any client is worth more to a solo maintainer than
theoretical nonce comfort, and the AEAD swap is free pre-deploy (§8).

**M-class (all accepted):** fold `X-Cpdb-Device` + `X-Cpdb-Protocol`
into the signed canonical string and mandate header-vs-path workspace
equality (today a middlebox can rewrite device-id on a valid request);
resolve the spec's self-contradiction between dedupe-by-overwrite and
409-on-collision (fresh nonces make every re-encryption byte-different,
so as written every enrichment/pin re-push is rejected — see §6's
versioned writes, which subsume it); persist or explicitly accept the
volatile replay cache; clock-skew 401s should return `server_time_ms`
with the client offset **bounded** (an unbounded trusted offset hands a
malicious relay a clock-steering lever); gate workspace creation with a
deploy-time provisioning secret checked in the Worker **before**
`stub.fetch` (otherwise any probe instantiates and bills a DO, and
`GET /info` currently 200s on never-written workspaces, breaking
pairing UX); pin HKDF salt-vs-info slots and byte-exact encodings for
every MAC/AAD input (three language stacks will otherwise silently
derive different keys — the AAD becomes
`"cpdb.env.v1" ‖ ws(16 raw) ‖ id(16 raw)`).

**Accepted residual leaks (document, don't fix):** within-workspace
content-equality (that *is* dedupe), size/timing fingerprinting
(mitigated by padding, §9), relay freshness/withholding (local SQLite
is truth), and deleted-content re-serving by a malicious relay
(tombstone LWW heals state; bytes of a deleted entry may reappear on a
device that never saw the delete — inherent to a blind store).

## 6. Sync-semantics gaps — what CloudKit does that v1 can't

The envelope schema is missing the fields the convergence machinery
runs on: `modified_at`, `uuid`, `hash_version`, `identity_tag`,
`ocr_text`, `image_tags`, `analyzed_at`. Without `modified_at`,
**the system provably does not converge**: A flips a pin and re-uploads;
B re-uploads with a fetched link title; the server (blind, unversioned)
keeps the last write; A can't distinguish a newer unpin from a stale
echo. Lost update, permanent divergence. Server-side field merge is
impossible on ciphertext — the spec must say so and put merge on the
client. The accepted redesign, as one coherent package:

1. **Meta/body envelope split.** Every entry becomes a small **meta**
   envelope (scalars + `text_preview` + small preview thumbnail,
   ~1–64 KB, `id = HMAC(id_key, content_hash ‖ "m")`) and an immutable
   **body** envelope (flavors + large previews,
   `id = … ‖ "b"`, uploaded exactly once). Pin flips and enrichment
   become KB-scale writes instead of 4 MB re-uploads; LRU stops being
   reshuffled by OCR passes. This mirrors CloudKit's Entry/Flavor
   record split, and it gives Windows **metadata-first browsing for
   free**: render history from metas, fetch bodies lazily on
   paste/preview (bootstrap becomes ~25–55 MB of metas instead of
   871 MB up front).
2. **Schema additions** (bump `schema_version`): `modified_at`, `uuid`,
   `hash_version`, `identity_tag`, `ocr_text`, `image_tags`,
   `analyzed_at`, `device_name`; declare `flavors: []` legal
   (body-evicted entries are real and keep permanent v1 hashes).
3. **Versioned conditional writes.** Server keeps a per-envelope
   integer version; writes carry `If-Match`; mismatch → 412 + current
   version → client GETs, merges with the same per-field LWW code
   CloudKit uses, re-pushes. Converges in ≤1 extra round. This also
   deletes the broken 409-collision branch.
4. **Seq change-log cursor.** Replace `since=stored_at` with a
   DO-maintained monotonic sequence over ops `{upsert, delete}` —
   today the list endpoint returns only live envelopes, so **a device
   offline during a DELETE never learns of it** (and the float-cursor
   spec text can skip same-timestamp envelopes at page boundaries; a
   WS-event-advanced cursor can skip a failed fetch permanently).
   Cursor advances **only** via list responses. Reconnect choreography:
   open WS and buffer → poll to head → apply buffer → go live; poll
   fallback ~5 min.
5. **Soft tombstones, retained.** Delete = overwrite the meta
   (`deleted_at`, `modified_at`) + hard-delete only the body. Metas are
   LRU-exempt and kept effectively forever (10k tombstones ≈ 20–30 MB ≈
   nothing) — otherwise a 60-day-offline device resurrects deleted
   entries fleet-wide on its reseed. Relay `DELETE` demotes to a GC
   tool. **Reseeds must include tombstone metas** (CloudKit's
   `requeueAll` pattern only enqueues live entries — safe there, wrong
   here). Pinned bodies: clients re-push if evicted (server can't see
   `pinned`; the meta's exemption doesn't protect the body).
6. **ActionRequest stays CloudKit** for iOS→Mac paste (APNs wake, works
   today). If Windows-target paste is ever wanted: tiny
   `POST /v1/<ws>/actions` with encrypted payload, WS delivery, 10-min
   TTL, outside the envelope index.
7. **Shared merge code.** Extract CloudKitSyncer's per-field LWW upsert
   into a `RemoteChangeApplier` used by both stacks, and gate push
   enqueues on actual state change — that's what makes dual-stack Apple
   devices idempotent and enables Windows→relay→Mac→CloudKit→iPhone
   bridging without echo loops (the scaffold currently echoes events
   back to their sender, too — one-line fix). One bug found in the code
   to be extracted: `bodyEvictedAt` is adopted unconditionally on pull
   (CloudKitSyncer.swift:1246), so a sibling pushing before it pulls an
   eviction can clear the marker and re-hydrate deliberately-discarded
   bytes — make it sticky (max/LWW) in the shared applier.

## 7. Substrate + scaffold: the one-way doors and the defect list

Two decisions are **irreversible after the first `wrangler deploy`**:

1. **`wrangler.toml` migration must be `new_sqlite_classes`, not
   `new_classes`.** As written it creates a key-value-backend DO class:
   paid-plan-only (kills the $0 case), no `sql.exec`, no PITR, and a
   deployed class can never be converted in place.
2. **The WebSocket code must be on the Hibernation API before deploy**
   (`ctx.acceptWebSocket`, class-level `webSocketMessage/Close/Error`
   handlers, `serializeAttachment({deviceId})`, fan-out via
   `ctx.getWebSockets()`, `setWebSocketAutoResponse` for heartbeats —
   protocol ping frames don't wake the DO; JSON heartbeats do, billed
   20:1). No `setTimeout`/`setInterval` in the DO. Also bump
   `compatibility_date` ≥ 2026-04-07 so Close frames don't wake it.

Storage layout (adjudicating a cross-lens conflict: DO-SQLite rows take
blobs to 2 MB via `sql.exec` — the "can never inline" claim was based
on the KV-API limit): put the **index, meta envelopes, and small bodies
inline in DO SQLite** (atomic with the index — kills the
put-then-index orphan window; no R2 round-trip on the hot path; row
writes are cheaper than R2 Class A) and send **bodies above a
256 KB–1 MB threshold to R2** (decide the exact threshold at
implementation; the 5 GB free SQLite allowance is account-wide, R2's
10 GB is roomier). Keep the R2-put-then-index order for the R2 leg, add
an alarm-driven orphan sweep (R2 deletes are free) plus one bucket-wide
"expire after 400 days" lifecycle rule as backstop.

Scaffold defects to fix before any client work (all confirmed by
line-level reads): envelope_id is a placeholder `""` — every upload
lands on the same R2 key, and the adjacent comment proposes deriving it
from the body, which random nonces make impossible (the id must be
client-supplied in the signed path: `PUT /v1/<ws>/envelopes/<id>`);
`indexUpsert` never deletes the previous `idx:<ms>:<id>` key, so every
enrichment re-push duplicates index rows, double-counts bytes, and can
evict the stale key's shared R2 object leaving a dangling 404 index
entry; eviction re-lists the whole index per evicted envelope (O(n²)
rows-read — a reseed burst can hard-fail the 5M rows-read/day free cap
mid-bootstrap); the replay record is written *before* the (unwritten)
HMAC check — an unauthenticated sender could pre-insert replay tuples
to 409 legitimate requests; replay LRU is in-memory and silently resets
on every hibernation wake. The rewrite to a real SQLite schema with a
maintained `total_bytes` counter subsumes most of these.

Client-side rules that platform behavior forces: **every deploy
restarts every DO and drops all WebSockets** (hibernated or not), so
reconnect-with-backoff + since-cursor catch-up is a day-one
requirement, not resilience polish; treat per-envelope 404 as
"evicted", 409-replay as success-equivalent, 429 (including R2's
1-write/sec-per-key during same-content races) as retryable with
jittered backoff honoring `Retry-After`; batch uploads chunk at ~20–25
envelopes (the binding constraints are the 100 MB body cap and the
free plan's 50 subrequests, not the old ~40 guess). `PushQueue.swift`
ports as-is — it's transport-agnostic.

## 8. Versioning: reseed-as-migration

Because every device's SQLite is the source of truth and envelope_ids
are deterministic, the relay never needs migration machinery. Adopted
three-plane discipline:

- **Protocol `P`** (`X-Cpdb-Protocol` + URL prefix): server accepts
  exactly one value; mismatch → 400, client pauses sync, keeps
  capturing locally, shows "update cpdb". No negotiation, no N-1
  window for a 1-user fleet.
- **Envelope schema `S`** (inside ciphertext): **additive-only** within
  a generation. Decoders: MessagePack map, string keys, ignore unknown
  keys, per-generation required-field floor, skip higher versions,
  **never re-encode a received envelope** (always encode from the local
  model).
- **Generation `G`** (integer suffix in every HKDF label): any breaking
  change anywhere — AEAD swap, envelope_id construction, meta/body
  split, key schedule — bumps G, which derives a fresh workspace_id,
  i.e. a fresh empty DO. Migration = reseed, newest-first, batch
  endpoint. A mandatory **generation-reconcile pass** (list `since=0`,
  push local entries absent from the index) un-strands anything a
  laggard captured against the old generation. The old DO is
  garbage-collected by the 30-day idle alarm (which must be
  implemented — Cloudflare deletes nothing on its own).

Everything this analysis proposes (meta/body split, id_key, ChaCha swap,
seq log, If-Match, schema fields) batches into **one G=2/P=2 cut** that
costs nothing because nothing is deployed. Delete the planned
`supported_protocols` negotiation from the spec.

## 9. Compression + padding (covers the two curtailed review threads)

Compress-then-pad-then-encrypt, per envelope: DEFLATE/zlib is native on
all three clients (.NET `DeflateStream`, Apple Compression framework;
the Worker never decompresses) — no new dependencies, so no reason to
shop for zstd. The 739 MB of text entries is mostly RTF/HTML flavor
redundancy and should compress ~3–10×; realistic effect is the 871 MB
syncable set landing near 300–450 MB, doubling the effective cap and
halving bootstrap time. Add `compression: 0|1` to the envelope header;
skip below ~256 B. Then pad the compressed plaintext to 4 KiB buckets
before encryption: this simultaneously blunts the classic
compression-length side channel (ciphertext length otherwise leaks
plaintext redundancy) and the §5 size-fingerprinting leak, at trivial
overhead against the cap. Padding lives *inside* the AEAD; bucket sizes
are pinned in the spec.

## 10. Anti-entropy and sync health (or: every failure mode above is silent)

Every defect in §5–§7 diverges silently — nothing detects or repairs
drift. Adopted, priced at <1% of free-tier budgets:

- **Maintained set digest** in a single `ws_meta` row (epoch, seq_head,
  live_count/bytes/xor, tomb_count/xor — XOR of envelope_ids is
  order-independent and O(1) per write), updated transactionally with
  every mutation and **piggybacked on every list response and WS
  hello** — every routine sync is a free divergence check.
- **`GET /v1/<ws>/envelopes/ids`** (complete live + tombstone id sets,
  ~65 KB) + a six-step client reconcile on digest mismatch
  (fetch-unknown / mark-evicted / LWW-apply-tombstones /
  re-push-missing), rate-limited hourly + weekly scheduled. Absence
  from the relay is **never** treated as deletion.
- **Workspace epoch**: 16 random bytes minted with `ws_meta`,
  regenerated only when the row is missing (state loss / 30-day
  reclaim). Clients persist `(epoch, cursor)` and on mismatch discard
  the cursor and reconcile from zero — the CloudKit token-expiry
  self-heal, rebuilt.
- **Health UI** (Mac + Windows): last *verified* sync age, WS state,
  relay occupancy, last-reconcile repairs, push-queue depth. One
  warning: no verified sync for 24 h while the network is reachable.
- **DO error ring buffer** (200 rows, `GET /v1/<ws>/debug`) as the
  primary error record — Workers Logs' free retention is 3 days, which
  evaporates before a hobby user notices; the user's own devices become
  the pager.

## 11. Client stacks (verified availability)

- **Windows (.NET 8):** BCL covers HKDF + HMAC + (probably) the AEAD
  (`ChaCha20Poly1305.IsSupported` / `AesGcm`); MessagePack-CSharp
  ≥3.1.7 (earlier 3.x have high-severity advisories — pin and
  subscribe); SimpleBase for base32; `ClientWebSocket` with
  `KeepAliveInterval` (built-in protocol pings — don't hand-roll).
  New project `windows/CpdbWin.Relay` + vector tests, keeping ONNX out
  of the crypto test graph. If XChaCha had been kept: Sodium.Core, not
  NSec (current NSec targets .NET 9 only).
- **Apple:** CryptoKit end-to-end after the H2 cipher swap (no
  libsodium); nnabeyang/swift-msgpack (Codable) — encoder byte-equality
  is *not* identity-bearing (ids derive from content_hash), which
  lowers the codec maturity bar; `URLSessionWebSocketTask` needs a
  manual reconnect/backoff actor.
- **Test vectors before any network code**, mirroring the hash-v2
  discipline: `Tools/gen_relay_vectors.py` →
  `Tests/Fixtures/relay-vectors-v1.json` (hkdf, base32, envelope_id,
  auth canonical string, fixed-nonce AEAD, one golden envelope) with
  Swift + C# + vitest consumers all green first. Note: the hash-v2
  fixture currently has no Windows consumer — that discipline is
  prescribed, not yet practiced; relay vectors should ship with all
  three consumers from day one.
- **Engineering mass, descending:** Windows client (a sync engine from
  scratch: cursor store, scheduler, LWW merge, tombstones — ≈2× the Mac
  work) > server hardening (small code, highest stakes) > Mac client
  (transport adaptation of existing semantics) > iOS (deferred to ~0
  under topology B).

## 12. Decision list

Numbered for ratification; recommendation first.

| # | Decision | Recommendation |
|---|---|---|
| D1 | Substrate | Cloudflare Workers + per-workspace SQLite-backed DO + R2. Free plan first; $5 Paid only if reseed-day 1027s ever bite. |
| D2 | Topology | Hybrid: CloudKit for Apple, relay bridges Windows, all Macs dual-write. Revisit relay-for-all after a 3–6-month trial with concrete triggers. |
| D3 | Sequencing gate | `windows-hash-v2` lands before any client sync work. |
| D4 | AEAD | IETF ChaCha20-Poly1305, pending a 5-minute `IsSupported` check on the real Windows box; else AES-256-GCM. No XChaCha, no libsodium, no agility. |
| D5 | Key schedule | Words-are-root pairing (C3 fix) + fourth `id_key` (C2 fix) + TOFU `auth_key` bootstrap (C1 fix) + provisioning secret at the Worker. |
| D6 | Envelope model | Meta/body split; schema gains modified_at/uuid/hash_version/identity_tag/enrichment fields; compression+padding per §9. |
| D7 | Consistency | Seq change-log cursor + If-Match versioned writes + retained soft tombstones + client-side LWW merge (shared `RemoteChangeApplier`). |
| D8 | Caps | Workspace cap ~2 GB; envelope cap stays 5 MB; newest-first bulk pushes. |
| D9 | Versioning | Three-plane (P/S/G) reseed-as-migration; batch all pending changes into one G2/P2 cut pre-deploy. |
| D10 | Anti-entropy | ws_meta digest + epoch + `/envelopes/ids` reconcile + health UI, shipped in the same revision (10× harder to retrofit). |
| D11 | ActionRequest | Stays on CloudKit; relay equivalent only if Windows-target paste is wanted. |
| D12 | Exit ramp | Keep the protocol CF-ism-free; document the VPS port (DO→process-per-workspace, R2→disk) as the standing hedge. |

**Sequence:** (1) revise `relay-protocol.md` to v2 per D4–D10 →
(2) `gen_relay_vectors.py` + fixtures, three consumers green →
(3) server rewrite (SQLite schema, hibernation, auth, one-way doors) +
deploy behind the provisioning secret → (4) Mac dual-write client →
(5) Windows client (after D3) → (6) iOS: nothing.

---

*Corrections adopted from adversarial verification are folded in
throughout; the notable refutations: the Hetzner ~$4/mo anchor was
stale (entry box is now €5.49/mo), Tailscale's free tier is 6 users
(not 3/100), "three Macs exhaust the free plan by lunch" mis-modeled
per-DO duration billing, the ~40-envelope batch guess violated the
100 MB body cap (~20 is the real bound), and the claimed hash-v2
Windows vector consumer does not exist yet. Two review threads
(compression sizing, metadata-first browsing) were curtailed by an
agent session limit and are covered first-hand in §9 and §6.1.*
