# cpdb relay sync — wire protocol v1

Cross-platform sync substrate for cpdb. Replaces the Apple-only
CloudKit path described in the v2.0 plan. The relay (a single
Cloudflare Worker + Durable Object + R2) is a **blind store**: it
sees ciphertext, opaque envelope identifiers, and timestamps, and
nothing else.

This document is the **wire-format contract**. Both the Mac, iOS,
and Windows clients implement against it; the relay implements the
server side. Changes here are versioned (the URL prefix is `/v1/`)
and require corresponding client + server release.

> **Heads-up — superseding design parked.** New product
> requirements (user accounts, per-tier device limits, rate
> limits, OAuth/SSO for enterprise) mean the blind-PSK model in
> this doc is **not** the long-term target. The future direction
> is captured in
> [`relay-v2-accounts-roadmap.md`](relay-v2-accounts-roadmap.md)
> (deferred, not started). This v1 doc + the `cpdb-relay/`
> scaffold remain the current shipped state and a code reference;
> don't begin a client implementation against v1 without
> re-confirming scope.
>
> **⚠️ Do NOT implement against this spec (2026-07-05).** A deep
> design review found v1 unimplementable as written — the server
> has no way to learn `auth_key` (§Authentication), the Diceware
> pairing derivation is not reversible as described (§Pairing),
> and `envelope_id` keyed by the public `workspace_id` lets the
> relay confirm guessable content, among ~a dozen further
> protocol/scaffold defects. The findings, verified cost model,
> and the agreed v2 revision (meta/body envelope split, seq
> change-log, versioned writes, retained tombstones, IETF
> ChaCha20-Poly1305, reseed-as-migration) are in
> [`relay-deep-analysis.md`](relay-deep-analysis.md). This doc
> stays as the v1 reference until the v2 rewrite lands.

---

## Threat model

- **Server compromise must not reveal clipboard contents.** The
  Worker, the Durable Object, and R2 all see only ciphertext and
  metadata that's load-bearing for the protocol (envelope size,
  timestamp, content_hash truncation, online-device tracking).
- **Network observation must not reveal contents.** All traffic is
  TLS to `*.workers.dev` / a custom domain.
- **Loss or theft of one device must not compromise the workspace
  beyond that device's local state.** Re-pairing creates a new PSK;
  the old PSK becomes invalid for *new* writes (server enforces by
  rejecting auth from old PSK on next rotate). Already-stored
  envelopes encrypted under the old PSK remain readable by anyone
  who still has it — there's no forward-secrecy guarantee inside
  the existing buffer.
- **The relay operator must not be trusted.** The whole design
  assumes a curious, possibly-adversarial relay. Encryption +
  authentication is end-to-end between paired devices.

Out of scope: per-record forward secrecy, denial-of-service
protection beyond Cloudflare's defaults, traffic analysis (an
observer can count envelopes and infer copy frequency).

---

## Workspace concepts

A **workspace** is a set of paired devices that share a clipboard
history. One PSK per workspace.

### Pre-shared key (PSK)

A 32-byte uniformly-random key generated on the device that creates
the workspace. The user never sees the raw bytes — they see a
**Diceware encoding** for transcription.

```
PSK = 32 random bytes from CSPRNG
Diceware = HKDF-SHA256(PSK, salt="cpdb.diceware.v1", length=11 bytes)
           → split into 8 indices of 0..7775
           → look up each in EFF long-word list
```

8 EFF long-list words ≈ 103 bits of selectable entropy at the user
layer; the 32-byte PSK is the cryptographic entity used everywhere
else.

User flow:
1. Mac creating workspace generates PSK, displays Diceware.
2. New device receives Diceware (typed or QR'd), reverses to PSK.
3. New device authenticates against the relay using PSK-derived
   keys. First authenticated request from this device joins the
   workspace.

### Derived keys

All from the 32-byte PSK via HKDF-SHA256 with distinct labels:

| Key | Length | Salt / label | Purpose |
|---|---|---|---|
| `workspace_id` | 16 bytes | `cpdb.workspace.v1` | Routing key sent in the clear; server uses to address the right DO |
| `auth_key` | 32 bytes | `cpdb.auth.v1` | HMAC-SHA256 key for request signing |
| `content_key` | 32 bytes | `cpdb.content.v1` | XChaCha20-Poly1305 key for envelope payloads |

`workspace_id` is base32-encoded for URL use (`a-z2-7`, no padding,
26 chars) → typical request URL: `https://relay.cpdb.example/v1/<workspace_id>/envelopes`.

---

## Envelope format

An **envelope** is one clipboard entry's payload, encrypted under
`content_key`.

```
plaintext = MessagePack-encoded {
    schema_version: 1,                  // mirrors local schema migration version
    kind: "text" | "link" | "image" | "file" | "color" | "other",
    content_hash: bytes(32),            // SHA-256 of canonical flavor set
    captured_at: float64,               // unix epoch seconds
    created_at: float64,
    source_device_id: bytes(16),
    source_app_bundle_id: string?,
    source_app_name: string?,
    title: string?,
    text_preview: string?,
    link_title: string?,
    link_fetched_at: float64?,
    pinned: bool,
    body_evicted_at: float64?,
    deleted_at: float64?,
    flavors: [
        { uti: string, size: int, sha256: bytes(32), bytes: bytes },
        ...
    ],
    previews: [
        { kind: "small" | "large", bytes: bytes },
        ...
    ],
}

ciphertext = XChaCha20-Poly1305(
    plaintext = msgpack(plaintext),
    key       = content_key,
    nonce     = random 24 bytes,
    aad       = workspace_id || envelope_id,
)

envelope_wire = nonce(24) || ciphertext_with_tag(...)
```

**Envelope ID.** `envelope_id = HMAC-SHA256(content_hash, key=workspace_id)[:16]`
Truncated content-hash MAC. Stable across devices that captured the
same content (same content_hash → same envelope_id), so the server
naturally dedupes cross-device re-captures by overwriting under the
same key. Adversary who controls the relay sees only the MAC, not
the content_hash.

**Per-envelope size limit:** 5 MB on the wire. Larger payloads are
not transmitted via the relay; the originating device keeps them
local-only until peer-to-peer relay (post-v1) is implemented.

---

## Authentication

Every request carries an HMAC over the canonical request string.

```
canonical = method.upper() || "\n" ||
            path             || "\n" ||
            query_string     || "\n" ||  // sorted, %-encoded
            timestamp_ms     || "\n" ||
            sha256(body_bytes).hex
hmac = HMAC-SHA256(auth_key, canonical)
```

Sent as headers:

```
X-Cpdb-Workspace:  <base32 workspace_id>
X-Cpdb-Device:     <base32 16-byte device_id>
X-Cpdb-Timestamp:  <integer ms-epoch>
X-Cpdb-Auth:       <hex 32-byte HMAC>
X-Cpdb-Protocol:   1
```

**Replay protection:** Timestamp must be within ±300 seconds of
server time. Server keeps a rolling LRU of seen `(timestamp,
hmac[:8])` per workspace for the last 600 seconds; duplicates are
rejected with 409.

**Device IDs** are 16 random bytes generated locally per cpdb
install. Not authenticated separately — the PSK is the only auth.
Server uses device_id only for fan-out scoping (so a push isn't
echoed back to its sender).

---

## Endpoints

All endpoints are scoped under `/v1/<workspace_id>/`. The Worker
inspects the URL and dispatches to the per-workspace Durable Object.

### `POST /v1/<ws>/envelopes`

Push one envelope.

Body: `envelope_wire` (raw bytes, `Content-Type: application/octet-stream`).

Response 201 on success:
```json
{ "envelope_id": "<base32 16 bytes>", "size": 12345, "stored_at": 1735000000.123 }
```

Response 413 if the envelope exceeds 5 MB.
Response 409 if a *different* envelope with the same id already
exists (collision under workspace_id-keyed MAC — should be
vanishingly rare). Server keeps the existing one.

### `POST /v1/<ws>/envelopes/batch`

Push multiple envelopes at once. Body is a length-prefixed
concatenation:

```
[ uvarint(count), { uvarint(size), envelope_wire } * count ]
```

Server processes atomically per-envelope (failures don't roll back
successes). Response is a JSON array of per-envelope outcomes in
input order.

### `GET /v1/<ws>/envelopes?since=<ts>&limit=<n>`

Pull envelopes captured since `ts` (server-stored_at, not
captured_at — clients can resume by saving the latest stored_at
they observed). `limit` defaults to 100, max 500.

Response 200:
```json
{
  "envelopes": [
    { "envelope_id": "...", "size": 12345, "stored_at": 1735000000.123 },
    ...
  ],
  "next_since": 1735000123.456,
  "more": true
}
```

The response carries metadata only. Clients then fetch each
envelope's bytes via:

### `GET /v1/<ws>/envelopes/<envelope_id>`

Returns raw `envelope_wire`. 404 if unknown / evicted.

### `DELETE /v1/<ws>/envelopes/<envelope_id>`

Tombstone. Server records the deletion in the index and removes the
R2 object immediately. Online devices receive a `{"type":"delete",
"envelope_id":"..."}` event over their WebSocket. Returns 204 on
success, 404 if unknown.

Tombstones are themselves eligible for LRU eviction; we don't keep
them forever.

### `GET /v1/<ws>/info`

Response 200:
```json
{
  "envelope_count": 1234,
  "total_bytes": 67890123,
  "byte_cap": 104857600,
  "oldest_stored_at": 1734000000.0,
  "latest_stored_at": 1735000000.0,
  "online_devices": 2,
  "protocol": 1
}
```

Used by clients for the "iCloud-style" status row in Preferences.

### `GET /v1/<ws>/sync` (WebSocket upgrade)

Realtime push. After upgrade, server sends one of these JSON
messages whenever something changes:

```json
{ "type": "new",       "envelope_id": "...", "size": 1234, "stored_at": 1735000000.123 }
{ "type": "delete",    "envelope_id": "...", "stored_at": 1735000000.123 }
{ "type": "evicted",   "envelope_id": "...", "stored_at": 1735000000.123 }
{ "type": "ping" }     // keepalive every 30s
```

Devices echo `{"type":"pong"}` to keep the connection alive. Server
disconnects on no-pong-for-60s.

The WebSocket carries **signaling only**, never bytes. Devices fetch
envelope payloads via the GET endpoint when they receive a `new`
message. Decouples the realtime push from per-message size and
rate-limit behaviour.

---

## Eviction rules

Authoritative on the server:

```
per-envelope size:    ≤ 5 MB              (rejected at write)
per-workspace bytes:  ≤ 100 MB            (LRU evict on every write)
```

Eviction policy: when a write would push `total_bytes` past
`byte_cap`, repeatedly evict the oldest envelope (by `stored_at`)
until the new write fits. Both the index entry and the R2 object
are deleted atomically.

Pinned envelopes are NOT exempt from eviction at the server. Server
doesn't see `pinned`. Pin status is preserved via the encrypted
plaintext, so when an evicted envelope is later re-uploaded by any
device, it comes back with its pin intact.

Eviction sends an `{"type":"evicted"}` event to online devices.
Clients use this to keep their "what's on the relay" mental model
in sync with the server but typically take no action — their local
copy is the source of truth.

---

## Pairing

No explicit "pair" endpoint. The PSK *is* the pairing.

When a new device knows the PSK:

1. Derive `workspace_id`, `auth_key`, `content_key` from PSK.
2. Make `GET /v1/<workspace_id>/info`. If 200: workspace exists,
   we're paired.
3. Optionally pull all envelopes for cold-start hydration:
   loop `GET /v1/<ws>/envelopes?since=0` until `more=false`,
   fetching each envelope's bytes.
4. Open the WebSocket for live updates.

When a device wants to *create* a new workspace:

1. Generate a fresh 32-byte PSK.
2. Derive keys.
3. Make `POST /v1/<workspace_id>/envelopes` with the first envelope.
   First write to a non-existent workspace creates the DO.
4. Display Diceware to the user for transcription to other devices.

There is no server-side notion of "workspace ownership" or "device
revocation." The user owns the workspace by holding the PSK. Losing
it means generating a new PSK and re-pairing all devices; the old
workspace is orphaned and will time-bound itself away (after 30
days idle the DO is reclaimed).

---

## Error codes

| HTTP | Meaning |
|---|---|
| 200 | OK |
| 201 | Created (envelope stored) |
| 204 | No content (delete OK) |
| 400 | Malformed request (bad headers, decode failure) |
| 401 | Auth check failed (HMAC mismatch, expired timestamp) |
| 404 | Envelope unknown / workspace not yet created |
| 409 | Replay (same timestamp + HMAC seen recently) OR envelope_id collision |
| 413 | Envelope exceeds 5 MB |
| 429 | Rate limited (Cloudflare default) |
| 500 | Server-side bug (worth a bug report) |

---

## Versioning

`X-Cpdb-Protocol` header asserts client protocol version. Server
rejects mismatched versions with 400. Future protocol changes ship
as `/v2/` and clients negotiate which to use via the
`/v1/<ws>/info` response (will gain a `supported_protocols: [1, 2]`
field).

---

## What's NOT in v1

- **Per-record forward secrecy.** All envelopes use the same
  `content_key`. Acceptable trade-off given clipboard data's
  ephemeral usefulness.
- **Group / shared workspaces (multiple PSKs).** Out of scope; cpdb
  is a personal tool.
- **Server-side push notifications (APNs / FCM).** WebSocket-only
  for v1. Mac/iOS keep their existing CloudKit silent-push wake for
  capture wake; the relay path is poll-on-foreground + WS-while-open.
- **Peer-to-peer envelope transfer for >5 MB items.** Deferred. Big
  flavors stay local-only.
- **Server-side dedup beyond envelope_id collisions.** Clients are
  responsible for not pushing the same content twice.
