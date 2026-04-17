# cpdb

[![Tests](https://github.com/phubbard/CopyPasteDataBase/actions/workflows/tests.yml/badge.svg)](https://github.com/phubbard/CopyPasteDataBase/actions/workflows/tests.yml)

A from-scratch, native Swift replacement for the macOS clipboard app
[Paste](https://pasteapp.io) (`com.wiheads.paste`). Infinite disk-backed
clipboard history, SQLite + FTS5 incremental search, lossless NSPasteboard
fidelity, and a one-shot importer for your existing Paste database.

![cpdb popup](docs/popup.png)

## Status

Three milestones shipped; the app is in daily use.

| Phase | Scope | State |
|---|---|:-:|
| **1** | Headless core: daemon, SQLite+FTS5, Paste.db importer, CLI | ✅ |
| **2** | Menu-bar app, global hotkey, non-activating popup, paste-into-previous-app, single-writer lock shared with CLI | ✅ |
| **3** | Full-width popup, bigger cards, no-ellipsis text, hex-colour text → swatch, image file previews, URL-forward LinkCard | ✅ |
| 4+ | CloudKit sync, pinboards UI, retention policies, notarised build | ⏳ |

## Features

- **Lossless capture.** Every `NSPasteboardItem` UTI and flavor is stored
  verbatim; restore puts the full multi-flavor entry back on the pasteboard so
  copying RTF out of TextEdit still pastes as RTF into Pages.
- **Instant FTS5 search.** Apple's SQLite shipped with FTS5 is perfect for
  clipboard-scale corpora; search highlights hits and ranks by bm25.
- **Content-addressed blob spillover.** Flavors ≥ 256 KB are stored on disk
  by SHA-256 hex fan-out so identical pastes across days share a single copy.
- **Rich previews by kind.** Text shows full content (no ellipsis), links
  show their full URL prominently, images render their thumbnail, files
  show their real image if the file is an image, `#RRGGBB` renders as a
  colour swatch. See screenshot above.
- **Non-activating popup.** The hotkey summons a panel that floats over
  your current app without stealing focus, so paste lands exactly where you
  were typing.
- **Respects `nspasteboard.org` transient markers.** 1Password, Bitwarden,
  Universal Clipboard, and other temporary-clipboard tools opt out via UTI
  flags and cpdb honours them.
- **One-shot Paste.db importer.** Ingests
  `~/Library/Application Support/com.wiheads.paste/Paste.db` — Core Data
  transformable blobs, external-storage references under `.Paste_SUPPORT/`,
  all 5 Paste entity kinds, pinboards, source apps. Idempotent.
- **Local-first, no cloud, no telemetry.** Everything lives under
  `~/Library/Application Support/local.cpdb/` on your machine.

## Building

Requires Xcode (for `swift-testing`'s runtime framework and the
`#Preview` macro plugin — `KeyboardShortcuts` uses both). Apple Silicon,
macOS 14+.

```sh
git clone git@github.com:phubbard/CopyPasteDataBase.git cpdb
cd cpdb
make install-app        # builds, signs, and copies cpdb.app to /Applications
open -a cpdb
```

On first launch cpdb opens Preferences so you can pick a global hotkey.
After that, summoning the popup also requires **Accessibility** permission
(System Settings → Privacy & Security → Accessibility → enable cpdb) so
the synthesised ⌘V can paste into the previously-focused app.

To build just the CLI:

```sh
swift build -c release            # produces .build/release/cpdb
```

## Usage

### Menu-bar app

Press your hotkey from any app. The popup slides in over the active display:

- `←` / `→` — move selection between cards
- Typing — filters via FTS5
- `Return` — paste the selected entry into the app you were using
- `Esc` — dismiss
- Clicking elsewhere — dismiss

### CLI (`cpdb`)

Still works, useful alongside the app:

```sh
cpdb list                 # 20 most recent
cpdb list --kind image
cpdb search 'github'      # FTS5, highlighted snippets
cpdb show 8439            # full entry detail incl. every UTI
cpdb copy 8439            # rebuild the entry back onto the pasteboard
cpdb stats
cpdb import               # ingest ~/Library/.../com.wiheads.paste/Paste.db
cpdb daemon               # headless capture (mutex'd against cpdb.app)
```

The CLI daemon and the menu-bar app share a single-writer lock at
`~/Library/Application Support/local.cpdb/daemon.lock` — whichever starts
first owns capture; the other one reports the conflict and exits cleanly.

## Storage

- **Database:** `~/Library/Application Support/local.cpdb/cpdb.db` (WAL mode)
- **Spilled blobs:** `~/Library/Application Support/local.cpdb/blobs/<ab>/<cd>/<sha256>`
- **Logs:** `~/Library/Logs/cpdb/`
- **System log subsystem:** `log show --predicate 'subsystem == "local.cpdb"'`

## How capture works

macOS provides no clipboard-change notification, so cpdb polls
`NSPasteboard.general.changeCount` every 150 ms on a background dispatch
queue — the standard clipboard-manager technique. Each change is
canonicalised (SHA-256 over length-prefixed, UTI-sorted flavor payloads)
for dedup and persisted with a device id, source-app bundle id, and a
small thumbnail where relevant.

## How the importer works

Paste is a Core Data app with "Allows External Storage" enabled.
`ZSNIPPETDATA.ZPASTEBOARDITEMS` is a transformable BLOB whose first byte
signals storage mode:

- `0x01` — inline: remainder is a standard `bplist00` NSKeyedArchiver payload
- `0x02` — external: remainder is an ASCII UUID naming a file in
  `.Paste_SUPPORT/_EXTERNAL_DATA/`

The archived root is an `NSArray` of `PasteCore.PasteboardItem` objects —
Paste's own `NSSecureCoding` class. cpdb decodes without linking Paste by
registering a shim class via `NSKeyedUnarchiver.setClass(_:forClassName:)`.
See
[`Sources/CpdbCore/Import/TransformablePasteboardDecoder.swift`](Sources/CpdbCore/Import/TransformablePasteboardDecoder.swift).

Kind mapping follows Paste's `Z_ENT` numbering (7 Color, 8 File, 9 Image,
10 Link, 11 Text). Source apps, pinboards, and device rows all map across.
Paste's pre-computed `ZPREVIEW` / `ZPREVIEW1` JPEGs are copied into
`previews.thumb_small` / `thumb_large` verbatim.

## Project layout

```
Sources/
├── cpdb/                  # CLI target (ArgumentParser)
├── CpdbApp/               # menu-bar app target (SwiftUI)
│   ├── Popup/                 NSPanel + SwiftUI root
│   │   └── Cards/                 per-kind renderers
│   ├── Actions/               PasteAction (CGEvent ⌘V), Accessibility
│   ├── MenuBar/               NSStatusItem
│   ├── Hotkey/                KeyboardShortcuts glue
│   ├── Preferences/           Settings window
│   └── Resources/Info.plist   LSUIElement=true
└── CpdbCore/              # library shared between CLI and app
    ├── Store/                 GRDB schema, records, BlobStore
    ├── Capture/               PasteboardWatcher, CanonicalHash, Ingestor
    ├── Restore/               Restorer (legacy shim over PasteboardWriter)
    ├── Search/                FTS5 helpers
    └── Import/                PasteDbImporter + decoder + reader

Tests/CpdbCoreTests/       # swift-testing — 21 tests

Makefile                   # build-app / run-app / install-app
```

## Tests

```sh
swift test
```

From Command Line Tools you'll need to route via Xcode, since
`swift-testing` isn't in CLT:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Three of the 21 tests exercise a real `Paste.db` fixture and gracefully
skip when it isn't present (so CI skips them cleanly).

## Dependencies

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite + FTS5 + migrator
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) — CLI
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — global hotkey + SwiftUI recorder

That's it.
