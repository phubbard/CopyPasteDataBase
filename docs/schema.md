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

**Schema version:** v5 (migrations `v1` through
`v5_content_addressed_records`).

GRDB's `DatabaseMigrator` tracks applied migrations in the built-in
`grdb_migrations` table; a fresh client that emits the union DDL
below should seed that table with all five migration names (or
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
    ocr_text         TEXT,       -- v2+
    image_tags       TEXT,       -- v2+
    analyzed_at      REAL        -- v2+
);

CREATE INDEX idx_entries_created_at ON entries(created_at DESC);
CREATE INDEX idx_entries_kind ON entries(kind);
CREATE UNIQUE INDEX idx_entries_live_content_hash
    ON entries(content_hash) WHERE deleted_at IS NULL;
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
