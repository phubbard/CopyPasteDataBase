# cpdb

A from-scratch, native Swift rewrite of the macOS clipboard app
[Paste](https://pasteapp.io) (`com.wiheads.paste`). Infinite disk-backed
clipboard buffer, SQLite + FTS5 incremental search, lossless NSPasteboard
fidelity, and a one-shot importer for your existing Paste database.

Milestone 1 is **headless**: a capture daemon, an importer, and a CLI. A
menu-bar UI and iCloud (CloudKit) sync come later.

## Building

Requires Xcode (or Command Line Tools + Xcode installed at
`/Applications/Xcode.app`). Swift 6.x, macOS 14+, Apple Silicon.

```sh
swift build -c release
```

`swift build` works with just Command Line Tools. `swift test` needs
`swift-testing`'s runtime framework, which ships with full Xcode:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Usage

### Capture daemon

Run in the foreground (useful for tailing logs while you try it out):

```sh
.build/release/cpdb daemon
```

Install as a LaunchAgent (writes the plist — you then bootstrap it
explicitly so nothing surprises you):

```sh
.build/release/cpdb daemon --install
# cpdb prints the exact launchctl command to run
```

Uninstall: `cpdb daemon --uninstall`.

### Import from Paste

The importer opens Paste's Core Data SQLite store **read-only** and walks every
snippet into cpdb's schema losslessly. All NSPasteboard UTIs are preserved per
entry. Re-runs are idempotent.

```sh
# Default: ~/Library/Application Support/com.wiheads.paste/Paste.db
cpdb import

# Or an explicit copy
cpdb import /tmp/Paste.db
```

### Day-to-day

```sh
cpdb list                 # 20 most recent captures
cpdb list --limit 100
cpdb list --kind image    # filter by kind

cpdb search 'github'      # FTS5, with [highlighted] snippets
cpdb show 8439            # detailed view incl. every UTI
cpdb copy 8439            # restore that entry to the pasteboard

cpdb stats                # counts + disk usage
cpdb gc                   # VACUUM (orphan-blob sweep TBD)
```

## Storage

- Database: `~/Library/Application Support/local.cpdb/cpdb.db` (WAL mode)
- Spilled blobs: `~/Library/Application Support/local.cpdb/blobs/<ab>/<cd>/<sha256>`
- Logs:       `~/Library/Logs/cpdb/`
- System log: `log show --predicate 'subsystem == "local.cpdb"'`

Flavors ≥ 256 KB spill to the content-addressed blob store; smaller flavors
stay inline in SQLite. Same bytes in two entries get a single on-disk copy.

## How capture works

macOS has no clipboard notification API, so cpdb polls
`NSPasteboard.general.changeCount` every 150 ms on a background dispatch
queue. Each change is canonicalised (SHA-256 over sorted UTIs, with length
prefixes to prevent boundary collisions), deduplicated against the live set,
and persisted.

Transient/concealed items are skipped per the `org.nspasteboard.*`
convention, so 1Password / Bitwarden / Universal Clipboard copies don't
land in the history.

## How the importer works

Paste is a Core Data app with "Allows External Storage" enabled.
`ZSNIPPETDATA.ZPASTEBOARDITEMS` is a transformable BLOB whose first byte is
a tag:

- `0x01` — inline: remainder is a standard `bplist00` `NSKeyedArchiver` payload
- `0x02` — external: remainder is an ASCII UUID pointing at
  `.Paste_SUPPORT/_EXTERNAL_DATA/<UUID>` (itself a `bplist00`)

The archived root is an `NSArray` of `PasteCore.PasteboardItem` objects —
Paste's own `NSSecureCoding` class. cpdb decodes without linking Paste by
registering a shim class (`PasteCoreItemShim`) and calling
`NSKeyedUnarchiver.setClass(_:forClassName:)`. See
`Sources/CpdbCore/Import/TransformablePasteboardDecoder.swift`.

Kind mapping follows Paste's Z_ENT numbering (7 ColorSnippet, 8 FileSnippet,
9 ImageSnippet, 10 LinkSnippet, 11 TextSnippet). Source apps, pinboards, and
device rows all map across. `ZPREVIEW` / `ZPREVIEW1` JPEGs are copied into
`previews.thumb_small` / `thumb_large` verbatim.

## Current shape

```
Sources/
├── cpdb/                   # executable — ArgumentParser CLI
│   ├── cpdbCommand.swift
│   ├── Output.swift
│   └── Commands/
└── CpdbCore/               # library — all real logic
    ├── Paths.swift
    ├── Logging.swift
    ├── LaunchAgent.swift
    ├── Store/              # GRDB schema, records, BlobStore
    ├── Capture/            # PasteboardWatcher, CanonicalHash, Ingestor, filters
    ├── Restore/            # NSPasteboardItem reconstruction
    ├── Search/             # FTS5 helpers
    └── Import/             # PasteCoreDataReader, TransformablePasteboardDecoder, PasteDbImporter

Tests/CpdbCoreTests/        # swift-testing
```

## Next milestones

- **Menu-bar app** (SwiftUI) with global hotkey and a popup picker.
- **CloudKit sync** — requires a signed app bundle with iCloud entitlements;
  schema already has `uuid` / `content_hash` / `deleted_at` ready for it.
- **Retention policies** (`cpdb gc --older-than`, `--over-size`).
- **Orphan blob sweep** in `cpdb gc`.
- **Multi-item NSPasteboard** grouping in `Restorer` (rare in practice).
