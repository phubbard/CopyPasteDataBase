# cpdb SQLite schema reference

Canonical reference for the on-disk SQLite schema used by every cpdb
client (macOS, iOS, planned Windows). Extracted from
`Sources/CpdbShared/Store/Schema.swift` at git commit
`e169786` (app version 2.5.6).

**Goal:** a Windows port (cpdb-win v1, C#/WinUI) that stores
clipboard history in the same SQLite schema as the macOS app. Even
though v1 Windows won't sync, keeping the schema bit-compatible
leaves every cross-device option open later — shared-folder log
sync, self-hosted server, CloudKit Web Services, or even just
`.sqlite` file import/export.

Everything in this document is source-of-truth for new clients.
Ship the same column names, same types, same constraints, same
index shapes. Anything that diverges makes future sync harder.

---

## Current on-disk version

**Schema version:** v7 (migrations `v1` through
`v7_body_evicted`).

GRDB's `DatabaseMigrator` tracks applied migrations in the built-in
`grdb_migrations` table; a fresh client that emits the union DDL
below should seed that table with all seven migration names (or
just skip the table if it won't interoperate with a macOS client's
DB file).

## Database file location

- macOS CLI & app: `~/Library/Application Support/net.phfactor.cpdb/cpdb.db`
- iOS companion: sandboxed App Group container, same filename
- Windows (planned): `%LOCALAPPDATA%\cpdb\cpdb.db`

The file is a standard SQLite 3 database with WAL journal mode.

## Pragmas

cpdb opens the DB with GRDB defaults plus foreign-key enforcement.
Equivalent pragmas for a fresh connection:

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
```

---

## Tables

### `entries` — one row per captured clipboard event

```sql
CREATE TABLE entries (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid             BLOB NOT NULL UNIQUE,
    created_at       REAL NOT NULL,
    captured_at      REAL NOT NULL,
    kind             TEXT NOT NULL CHECK (kind IN ('text','link','image','file','color','other')),
    source_app_id    INTEGER REFERENCES apps(id),
    source_device_id INTEGER NOT NULL REFERENCES devices(id),
    title            TEXT,
    text_preview     TEXT,
    content_hash     BLOB NOT NULL,
    total_size       INTEGER NOT NULL,
    deleted_at       REAL,
    ocr_text         TEXT,                                    -- v2+
    image_tags       TEXT,                                    -- v2+
    analyzed_at      REAL,                                    -- v2+
    pinned           INTEGER NOT NULL DEFAULT 0,              -- v6+ (boolean: 0 / 1)
    body_evicted_at  REAL                                     -- v7+
);

CREATE INDEX idx_entries_created_at ON entries(created_at DESC);
CREATE INDEX idx_entries_kind ON entries(kind);
CREATE UNIQUE INDEX idx_entries_live_content_hash
    ON entries(content_hash) WHERE deleted_at IS NULL;
CREATE INDEX idx_entries_pinned                              -- v6+
    ON entries(created_at DESC)
    WHERE pinned = 1 AND deleted_at IS NULL;
```

Field semantics:

| Column | Type | Notes |
|---|---|---|
| `id` | autoincrement rowid | Local identity, never exposed over the wire |
| `uuid` | 16-byte BLOB | Stable identity across local operations. Currently also acts as the CloudKit local-side identity, but record IDs are content-hash-addressed as of v5 |
| `created_at` | Unix-epoch seconds (`REAL`) | Display sort key. Bumps when the user re-captures duplicate content (dedup bump) |
| `captured_at` | Unix-epoch seconds (`REAL`) | Immutable — when this specific clipboard event happened |
| `kind` | enum string | One of `text`, `link`, `image`, `file`, `color`, `other`. Classification rules in §Kind classification |
| `source_app_id` | FK → `apps` | Null when the capture had no identifiable source |
| `source_device_id` | FK → `devices` | Never null; every entry has a source device, even if it's "this one" |
| `title` | TEXT | First line of plain text, max 200 chars, or filename for file entries |
| `text_preview` | TEXT | Full plain-text flavor, truncated to 2048 chars |
| `content_hash` | 32-byte BLOB | SHA-256 of canonicalized flavor set (see §Canonical hash) |
| `total_size` | INTEGER bytes | Sum of all flavor sizes for this entry |
| `deleted_at` | Unix-epoch seconds (`REAL`) | NULL = live. Non-NULL = tombstone; row stays until `cpdb gc` purges it |
| `ocr_text` | TEXT | On-device OCR of image entries. NULL until analyzed |
| `image_tags` | TEXT | Space-separated classification tags. NULL until analyzed |
| `analyzed_at` | Unix-epoch seconds (`REAL`) | Sentinel for the image-analysis backfill |
| `pinned` | `INTEGER` 0/1 | v6+. User pinned the entry — skips eviction policies and floats to the top of the listing. See §Pinning |
| `body_evicted_at` | Unix-epoch seconds (`REAL`) | v7+. Set by the eviction policy when this device discarded the flavor body bytes. Metadata + thumbnails remain. See §Eviction |

The `UNIQUE INDEX idx_entries_live_content_hash` is the primary
dedup enforcement. It only applies to live rows (`deleted_at IS
NULL`), so a tombstoned duplicate doesn't block re-capture.

### `entry_flavors` — one row per pasteboard UTI

```sql
CREATE TABLE entry_flavors (
    entry_id  INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    uti       TEXT NOT NULL,
    size      INTEGER NOT NULL,
    data      BLOB,
    blob_key  TEXT,
    PRIMARY KEY (entry_id, uti),
    CHECK ((data IS NULL) <> (blob_key IS NULL))
);

CREATE INDEX idx_flavors_blob_key
    ON entry_flavors(blob_key) WHERE blob_key IS NOT NULL;
```

Exactly one of `data` / `blob_key` is non-NULL (enforced by the
CHECK). Small flavors (< 256 KB) live inline; larger ones spill
to a content-addressed on-disk blob store — see §Blob store.

UTI strings are Apple's Uniform Type Identifiers verbatim
(`public.utf8-plain-text`, `public.png`, etc.). A Windows port
should translate from Windows clipboard formats (`CF_UNICODETEXT`,
`CF_DIB`, etc.) to the closest UTI equivalent at capture time:

| Windows format | UTI to store |
|---|---|
| `CF_UNICODETEXT` | `public.utf8-plain-text` (decode UTF-16 LE → UTF-8) |
| `CF_TEXT` | `public.utf8-plain-text` (decode current codepage → UTF-8) |
| `CF_HTML` | `public.html` |
| `CF_DIB` / `CF_DIBV5` / `CF_BITMAP` | `public.png` (encode as PNG) |
| `PNG` | `public.png` |
| `JFIF` / `JPEG` | `public.jpeg` |
| `CF_HDROP` (file paths) | `public.file-url` (one row per path) |
| `UniformResourceLocatorW` | `public.url` |

Store raw bytes exactly as they'd be read back out of a Mac
pasteboard — the canonical hash depends on byte-exactness.

### `apps` — source application metadata

```sql
CREATE TABLE apps (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    bundle_id TEXT UNIQUE NOT NULL,
    name      TEXT NOT NULL,
    icon_png  BLOB
);
```

`bundle_id` is the Apple-style reverse-DNS bundle identifier on
macOS/iOS (e.g. `com.apple.Safari`). On Windows, synthesize from
the executable path — suggested convention: reverse-DNS of the
publisher if known, otherwise `win.<process-image-name-without-extension>`
(e.g. `win.notepad`, `win.cleanshot`). Stable per-install is the
priority; cosmetic is secondary.

`icon_png` is optional; null is fine.

### `devices` — machines that captured entries

```sql
CREATE TABLE devices (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    identifier TEXT UNIQUE NOT NULL,
    name       TEXT NOT NULL,
    kind       TEXT NOT NULL
);
```

| Column | Notes |
|---|---|
| `identifier` | Stable device ID. macOS: IOPlatformUUID. iOS: `identifierForVendor`. Windows: suggested `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`. Never user-visible; only for dedup across devices |
| `name` | Human-readable ("Paul's MacBook Pro"). Shown in entry detail |
| `kind` | Free-form string: `mac`, `ios`, `win` |

### `pinboards` + `pinboard_entries` — user-organized lists

```sql
CREATE TABLE pinboards (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid          BLOB UNIQUE NOT NULL,
    name          TEXT NOT NULL,
    color_argb    INTEGER,
    display_order INTEGER NOT NULL
);

CREATE TABLE pinboard_entries (
    pinboard_id   INTEGER NOT NULL REFERENCES pinboards(id) ON DELETE CASCADE,
    entry_id      INTEGER NOT NULL REFERENCES entries(id)  ON DELETE CASCADE,
    display_order INTEGER NOT NULL,
    PRIMARY KEY (pinboard_id, entry_id)
);
```

Inherited from the Paste.app import path. Not yet exposed in the
Mac UI; present in the schema so an import doesn't drop data.
Windows v1 can ignore these tables (create them empty).

### `previews` — JPEG thumbnails for image entries

```sql
CREATE TABLE previews (
    entry_id    INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
    thumb_small BLOB,
    thumb_large BLOB
);
```

Populated at capture time by the image pipeline. Dimensions:

- `thumb_small`: longest side ≤ 256 px
- `thumb_large`: longest side ≤ 640 px

Both are JPEG bytes, quality 0.8. NULL is allowed (entry had no
thumbnailable flavor).

### `cloudkit_push_queue` + `cloudkit_state` — sync bookkeeping

Apple-specific; Windows clients can ignore these. If a future
sync design reuses them, the columns are:

```sql
CREATE TABLE cloudkit_push_queue (
    entry_id          INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
    enqueued_at       REAL NOT NULL,
    last_attempted_at REAL,
    attempt_count     INTEGER NOT NULL DEFAULT 0,
    last_error        TEXT
);
CREATE INDEX idx_cloudkit_push_queue_enqueued_at
    ON cloudkit_push_queue(enqueued_at);

CREATE TABLE cloudkit_state (
    key   TEXT PRIMARY KEY,
    value BLOB NOT NULL
);
```

### `entries_fts` — FTS5 search index

```sql
CREATE VIRTUAL TABLE entries_fts USING fts5(
    title,
    text,
    app_name,
    ocr_text,
    image_tags,
    tokenize='porter unicode61 remove_diacritics 2'
);
```

Populated manually — **not** via FTS5 content-linking. The host
language code is responsible for calling an `INSERT`/`DELETE` on
this table whenever `entries` changes. The `rowid` of each FTS row
equals the `entries.id`.

The tokenizer is the specific sequence: `porter unicode61
remove_diacritics 2` — this enables Porter stemming on top of
the unicode61 tokenizer with aggressive diacritic folding.
Windows System.Data.SQLite ships FTS5 with the default tokenizers
compiled in; no extra work needed to use this chain.

**Re-index cost** is O(n) on migration or rebuild, but per-entry
`INSERT`/`DELETE` is constant-time.

---

## Kind classification

Classification happens at capture time based on the set of UTIs
present on the clipboard. The current rule hierarchy (first match
wins):

1. Any image UTI (`public.png`, `public.jpeg`, `public.tiff`,
   `public.heic`, `public.heif`, `public.image`) with ≥ 1024 bytes
   → `image`
2. `public.url` present → `link`
3. `public.file-url` present → `file`
4. `com.apple.cocoa.pasteboard.color` or `public.color` → `color`
5. Any plain-text flavor → `text`
6. Otherwise → `other`

The substantive-image rule wins over both `public.url` and
`public.file-url`: browsers emit a source URL alongside "Copy image",
and screenshot tools like CleanShot publish a file-url alongside the
inline PNG. In both cases the image bytes are the payload, the URL
is breadcrumb metadata.

The 1024-byte image threshold exists so zero-byte placeholder
flavors don't masquerade as the primary content (some apps
advertise image flavors lazily).

Windows equivalents: translate clipboard formats to UTIs per the
table above, then run the same rule list. A single PNG file on
the clipboard will end up as `image` in both ecosystems.

## Title derivation

1. If plain text is present, use the first non-empty line, trimmed,
   truncated to 200 characters.
2. Else, if a `public.file-url` is present, use the filename
   (`URL.lastPathComponent`, percent-decoded).
3. Else, NULL.

## Text preview

Full plain-text flavor (no first-line slice), truncated to 2048
characters. NULL when no text flavor exists. **Do not** fall back
to file URLs here — user-visible text is too valuable to pollute
with paths.

## Canonical hash — `content_hash`

> **⚠️ Superseded for primary identity (cpdb 3.0, macOS/iOS).** Entry
> identity is now **semantic content identity (canonical-hash v2)** — a
> SHA-256 over the *primary* content only (image → file → url →
> normalized text → color → fallback), not the full flavor set. The
> authoritative v2 spec is [`canonical-hash-v2.md`](canonical-hash-v2.md)
> and the executable contract is **`Tests/Fixtures/hash-vectors-v2.json`**
> (which wins over any prose). The full-flavor-set algorithm below is
> retained because it is still (a) the **fallback rung** emission, (b)
> what `prev_content_hash` holds after the v2 rehash, and (c) the
> permanent hash of body-evicted entries (`hash_version = 1`). Windows
> still computes v1 as primary identity pending
> [`handoffs/windows-hash-v2.md`](handoffs/windows-hash-v2.md).
> *TODO: fold a full §Content identity v2 section in here; for now the
> design doc + JSON vectors are authoritative.*

Order-independent SHA-256 over the flavor set. Byte-exact
reproducible from any client:

```
for each item in items:                # items in original order
    for each flavor in SORTED(item.flavors, by: uti):
        emit uti.utf8
        emit 0x00
        emit uint64_be(flavor.data.count)
        emit flavor.data
    emit 0x01                          # item separator
```

Then `SHA256` the full emission. Store the raw 32 bytes in
`entries.content_hash`. Used as the dedup key in the unique index
and as the on-wire record ID for CloudKit sync.

Hex/base64 encoding is only used for logging and for filenames in
the blob store — the column itself is always raw bytes.

Test vectors. Confirmed identical on macOS (Swift `CanonicalHash.hash`)
and Windows (C# `CanonicalHash.Compute`):

| Input | `content_hash` (hex) |
|---|---|
| `[[{"public.utf8-plain-text", "hello"}]]` | `b22187611777c1e9c84c3fdd054ed311a47d12f33cba6d1e7761bd3a7314073a` |
| `[[{"public.utf8-plain-text", "hello"}, {"public.html", "<b>hello</b>"}]]` | `17a95cac0686665cfe5342a3a041d7afedfa4c14a59d6d3c6b7b53a4bf0ad85a` |

These are the SHA-256 of the canonical byte stream above — *not*
`sha256("hello")`; the uti+len prefix and `0x01` separator change
every byte that goes into the digest. Re-derive locally with:

```
printf 'public.utf8-plain-text\x00\x00\x00\x00\x00\x00\x00\x00\x05hello\x01' | shasum -a 256
```

Any new client must reproduce both vectors exactly before being
trusted to write to the live content_hash unique index.

## Blob store — 256 KB spillover rule

`entry_flavors.data` is set for flavors under `256 * 1024` bytes;
`entry_flavors.blob_key` is set for larger ones. The CHECK
constraint enforces "exactly one of the two."

The blob key is the hex SHA-256 of the flavor bytes. Blobs live in
a content-addressed on-disk tree rooted at the DB's sibling
`blobs/` directory:

```
<blobs_root>/<hex[0:2]>/<hex[2:4]>/<hex>
```

Two-level fanout keeps per-directory file counts bounded. Blobs
are written atomically (temp + rename).

GC is manual via `cpdb gc`: the collector unlinks any file on disk
whose key is no longer referenced by any row in `entry_flavors`.

---

## Pinning (v6+)

> **Contract** — every client implementing pinning must honour:

- `entries.pinned` is `INTEGER NOT NULL DEFAULT 0`. A column value of
  `1` means pinned; `0` means not pinned.
- **Sort order.** The default listing query (recent + search results)
  uses `ORDER BY pinned DESC, created_at DESC` — pinned rows float
  to the top of the listing within whatever filter is active.
- **Eviction skip.** `WHERE pinned = 1` rows are skipped by every
  eviction policy. This is the user's escape valve.
- **UI.** Per-platform UI must offer a Pin / Unpin toggle and a
  visible pin glyph on pinned rows. Mac does this via the popup
  card's right-click menu; iOS via swipe-leading; the Windows port
  should pick the idiomatic equivalent (button on the row, hover
  context, etc.).
- **Sync.** When a sync substrate is available (CloudKit on Apple),
  the pinned bit must round-trip per the same conflict-resolution
  rules as other scalars (last writer wins).

## Eviction (v7+)

> **Contract** — every client implementing eviction must honour:

cpdb has a tiered storage model (see top of this doc):
metadata is cheap and forever, thumbnails are medium and forever,
flavor bodies are heavy and **evictable**.

- **Eviction targets only flavor bodies.** Eviction discards rows in
  `entry_flavors` and unlinks the corresponding files in the on-disk
  blob store. It does **not** touch `entries`, `previews`,
  `entries_fts`, `apps`, or `devices`.
- **`body_evicted_at` is the per-entry sentinel.** When this device
  evicts an entry, set `entries.body_evicted_at = now()`. NULL means
  "bodies still present locally"; non-NULL means "bodies were
  discarded here."
- **Eviction skip rules.** An entry is a candidate for eviction
  only if **all** of:
    - `deleted_at IS NULL` (not tombstoned)
    - `pinned = 0` (not user-pinned)
    - `body_evicted_at IS NULL` (not already evicted)
    - PLUS whichever policy-specific predicate applies (age window,
      LRU-out-of-budget, etc.)
- **Pull-side cooperation.** When syncing from a substrate that
  carries flavor bytes, the apply path must check
  `body_evicted_at` on the local entry before writing flavor rows.
  If non-NULL, drop the inbound bytes on the floor — otherwise a
  sibling device that hasn't evicted will undo our cleanup on every
  pull (the evict→pull→re-evict loop). The apply path **does** still
  honour metadata changes (title, pin state, etc.); only the body
  bytes are gated.
- **Sync of `body_evicted_at`.** The field round-trips through the
  sync substrate. Last writer wins is the right semantic — if any
  device intentionally re-hydrates (clears the field), siblings
  honour that.
- **Display.** A body-evicted entry must render in lists exactly the
  same as before (metadata + thumbnail are intact). Detail / paste /
  copy operations must surface a distinct error: "body discarded by
  retention policy" rather than "entry not found."

## Eviction policies (v7+, reference)

The Mac client today implements one policy; the architecture is
deliberately pluggable so the others can layer in over time.

| Policy | Predicate | Status |
|---|---|---|
| Time-window | `created_at < now - N days` | ✅ v2.6.2 (Mac) |
| Size-budget | LRU+size-weighted, total bytes > budget | ⏳ planned |
| Per-kind quota | Per-kind sub-budgets | ⏳ planned |

Each policy is "user opt-in" with sensible defaults. The Mac stores
its preferences in UserDefaults under the
`cpdb.eviction.<policy>.<key>` namespace; other clients should pick
a parallel convention.

## Test fixtures (v7+)

The Mac CLI exposes `cpdb fixture {snapshot, list, env, path,
delete}` for snapshotting the live data directory and running any
operation against the snapshot without risk to the real archive.
Implementation contract for porters who want feature parity:

- The data-directory path must be overridable at runtime via an
  environment variable (Mac uses `CPDB_SUPPORT_DIR`). The fallback
  remains the platform-default per-app directory.
- Snapshots use a copy primitive that preserves SQLite WAL files
  + xattrs (Mac uses `/usr/bin/ditto`). Plain `cp -R` *can* work
  but has known edge cases.
- Snapshots live next to (not inside) the live directory so the
  fixture machinery never collides with itself.

## Link metadata enrichment (v8 + v9)

Captured `kind=link` entries grow a human-readable title and a preview
image asynchronously, so search can find a YouTube URL by its video
title and the popup card can show a thumbnail. The columns + behaviour
are contracts; the fetcher implementation is per-platform.

### Schema

`entries` gains four columns total across two migrations:

| Column | Type | Migration | Meaning |
|---|---|---|---|
| `link_title` | TEXT? | v8 | Human-readable title from oEmbed / og:title / `<title>`. NULL when never tried OR fetched-but-page-had-no-title |
| `link_fetched_at` | REAL? | v8 | Unix timestamp of last attempt. NULL = never tried; non-NULL = attempt completed (success OR permanent failure). The retry queue skips non-NULL rows |
| `link_retry_count` | INTEGER NOT NULL DEFAULT 0 | v9 | Consecutive transient failures. Reset to 0 on success or permanent failure |
| `link_retry_after` | REAL? | v9 | Earliest epoch second to retry. NULL = ready now (or settled); non-NULL = backoff window |

`entries_fts` virtual table also gains a `link_title` column; v8
migration drops + rebuilds with the new column appended and re-indexes
every live row.

### Fetcher behaviour contract

> **Contract — link backfill scheduling**
>
> A row is in the candidate queue iff:
> ```
> kind = 'link' AND deleted_at IS NULL
>   AND link_fetched_at IS NULL
>   AND (link_retry_after IS NULL OR link_retry_after < now)
>   AND link_retry_count < MAX_RETRIES
>   AND text_preview LIKE 'http%'  -- mailto:, magnet:, etc. excluded at SQL
> ```
>
> Order: `created_at DESC` (newest first — a freshly-copied URL gets
> enriched before old backlog).
>
> `MAX_RETRIES = 6` on macOS. Beyond the cap a row falls out of the
> queue. The user can resurrect via "Retry empties" (clears retry
> state for rows whose `link_title` is null/empty).

> **Contract — fetcher resolution chain (per URL)**
>
> 1. **YouTube** (host matches `youtube.com` / `youtu.be` /
>    `m.youtube.com` / `www.youtube.com`): hit the public oEmbed
>    endpoint `https://www.youtube.com/oembed?url=<url>&format=json`.
>    Use `title` and `thumbnail_url` fields.
> 2. **Reddit comments** (host matches `(www\.|old\.)?reddit.com`
>    AND path matches `/r/<sub>/comments/<id>/…`): hit
>    `https://www.reddit.com/r/<sub>/comments/<id>.json`. Parse the
>    array; first listing's `data.children[0].data` has `title` +
>    optional `thumbnail` (reject sentinel values "self", "default",
>    "spoiler", "nsfw" — only use real `http*`-prefixed URLs).
>    Falls through to step 3 on any error so a malformed Reddit URL
>    doesn't dead-end.
> 3. **Generic HTML scrape** (everything else): GET the URL with a
>    browser-shaped User-Agent. Extract title in this priority:
>    `<meta property="og:title" content="…">` →
>    `<meta name="twitter:title" content="…">` →
>    `<title>…</title>`. Extract thumbnail in priority:
>    `og:image` / `og:image:secure_url` / `og:image:url` →
>    `twitter:image` / `twitter:image:src`.
> 4. **Bot-check rejection** (post-extraction, before stamping):
>    if the extracted title matches a CAPTCHA / "are you human"
>    pattern (`looksLikeBotCheck`), throw a transient error so the
>    row stays a candidate for retry. Pattern list:
>    `"please wait for verification"`, `"just a moment"`,
>    `"are you human"`, `"checking your browser"`,
>    `"attention required"`, `"access denied"`,
>    `"verify you are a human"`, `"please verify you are human"`,
>    `"human verification"`, `"captcha"` (case-insensitive
>    substring match).
> 5. **Wikipedia REST API fallback** (only when host matches
>    `*.wikipedia.org` AND step 3 produced no thumbnail URL): GET
>    `https://<host>/api/rest_v1/page/summary/<title>`, use
>    `thumbnail.source` then `originalimage.source`.
> 6. **Favicon fallback** (when no thumbnail yet): scan HTML head
>    for `<link rel="apple-touch-icon" href="…">` (preferred —
>    typically 180×180 PNG), then `<link rel="icon">` /
>    `rel="shortcut icon">`. Resolve relative hrefs against the page
>    URL. If still none, conventional `<scheme>://<host>/favicon.ico`.

> **Contract — outcome dispatch**
>
> | Outcome | `link_title` | `link_fetched_at` | `link_retry_count` | `link_retry_after` |
> |---|---|---|---|---|
> | Fetched a non-empty title | the title | now | 0 | NULL |
> | Fetched, page had no title | NULL | now | 0 | NULL |
> | Permanent failure (decode error, invalid URL, oversized body) | NULL | now | 0 | NULL |
> | Transient failure (HTTP 403/408/425/429/5xx, network timeout, network unreachable) | unchanged | unchanged (NULL) | += 1 | now + 60·min(60, 2^count) seconds |

> **Contract — connectivity gate**
>
> The backfill MUST short-circuit (no fetches, no retry-count bumps)
> when the OS reports no internet. macOS uses `NWPathMonitor`;
> Windows should use `NetworkInformation.GetInternetConnectionProfile()`
> from `Windows.Networking.Connectivity` or the equivalent .NET
> `NetworkInterface.GetIsNetworkAvailable()`. The offline→online
> edge SHOULD trigger an immediate catch-up batch.

> **Contract — capture-wake immediate enrichment**
>
> When a new `kind=link` entry is captured locally, the daemon
> SHOULD fire a small (e.g. 5-row) backfill batch immediately
> rather than wait for the periodic cycle. Reentry guard: skip if
> a previous batch is still in flight. Combined with the
> `created_at DESC` ordering, this means freshly-copied URLs
> typically render with title + thumbnail within 1–3 seconds.

> **Contract — kind reclassification on bump**
>
> When a content_hash dedup *bumps* an existing entry's
> `created_at`, the ingestor MUST compare the new snapshot's
> classified kind against the stored kind and update if they
> differ. This catches the case where the kind heuristic evolves
> after a row was first captured (e.g. the macOS v2.7.11 rule
> "URL-shaped plain text → kind=link"). On a text→link transition,
> ALSO null `link_fetched_at` so the next backfill cycle picks the
> row up.

### Preview thumbnails

Thumbnail bytes for link entries land in the same `previews` table
as image-kind thumbnails (small ≈ 256 px JPEG, large ≈ 640 px JPEG).
Thumbnailer downscales raw bytes ≤ 4 MB; oversized / non-image
content-types are rejected. The card renderer queries
`previews.thumb_small` / `thumb_large` regardless of entry kind.

## Schema evolution policy

- **Never edit a shipped migration.** Add a new one.
- New columns are ADDed via `ALTER TABLE`; FTS tables get dropped
  and rebuilt because SQLite's FTS5 doesn't support ALTER.
- New clients should emit the final DDL (union of all migrations)
  rather than replaying each migration — cheaper, same end state.
- When introducing a column that CloudKit needs to round-trip, add
  it to `CKSchema.swift` at the same time.

---

## Windows-port checklist

When bringing up cpdb-win with this schema:

- [ ] SQLite connection with `journal_mode=WAL`, `foreign_keys=ON`.
- [ ] Emit the DDL above in one transaction on first run.
- [ ] Implement canonical hash, test against macOS vectors.
- [ ] Capture → classify (kind rules above) → dedup by
      `content_hash` → write `entries` + `entry_flavors`.
- [ ] Maintain `entries_fts` manually on every insert/update/delete.
- [ ] Apply the 256 KB inline/spillover rule for flavor bytes.
- [ ] Populate `apps` with your chosen bundle-id convention and
      `devices` with a stable machine GUID.
- [ ] Leave `cloudkit_*` and `pinboards` tables empty but present —
      future sync / import paths assume they exist.
- [ ] Implement link metadata enrichment per the § Link metadata
      enrichment contract: schema columns, fetcher resolution
      chain, exponential backoff, connectivity gate, capture-wake
      immediate enrichment, kind reclassification on bump.
- [ ] Hover tooltips on cards exposing source app, originating
      device, and absolute capture timestamp (use WinUI `ToolTip`).
