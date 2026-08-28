#!/usr/bin/env bash
# build-app-intents-metadata.sh — extract App Intents metadata for
# CpdbApp so Shortcuts/Siri/Spotlight can discover ClipIntents.swift's
# intents and `ClipAppShortcuts` phrases.
#
# Xcode runs `appintentsmetadataprocessor` as an invisible build phase
# whenever a target imports AppIntents; plain `swift build` never does.
# Reproducing that outside Xcode needs two things the processor
# consumes:
#   1. A `.swiftconstvalues` file — the Swift frontend's structured
#      dump of every AppIntent/AppEnum/AppEntity/AppShortcutsProvider
#      declaration's shape. Only comes from a *whole-module* frontend
#      job (one job = one valid `-emit-const-values-path` output),
#      which is what `-c release` already builds with — see the
#      `appIntentsConstValuesFlags` gate in Package.swift for how that
#      flag pair reaches the compiler.
#   2. The exact frontend command line SwiftPM used, since
#      `appintentsmetadataprocessor --source-file-list` must name
#      precisely the files that job compiled. There's no supported way
#      to ask SwiftPM for that command without asking it to run the
#      job — so this script forces CpdbApp's module to rebuild, parses
#      the printed command out of `swift build --verbose`, and runs a
#      cleaned copy of it a second time.
#
#      That second run strips SwiftPM's own
#      `-supplementary-output-file-map` — empirically, its presence
#      makes the compiler silently ignore `-emit-const-values-path`
#      (no error, no file). Everything else about the line is left
#      alone, so it recompiles the same sources with the same flags —
#      redundant, but CpdbApp is one target among many in this
#      package and the whole build is already the slow, infrequent
#      release/signing path (`make build-app`), not the dev loop.
#
# Output: Metadata.appintents landing at $METADATA_OUT (default
# .build/appintents/output/Metadata.appintents) — copy that into
# Contents/Resources/ of the .app bundle.
#
# Only supports `-c release` (see point 1 above). Only extracts for
# the host architecture — App Intents metadata is derived from Swift
# declarations, not object code, so it doesn't vary by arch; a
# universal (arm64 + x86_64) `build-app-universal` still only needs
# one extraction pass.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_CONFIG="release"
MODULE_NAME="CpdbApp"
DEPLOYMENT_TARGET="14.0"   # keep in sync with Package.swift's .macOS(.v14)
WORK_DIR="$ROOT/.build/appintents"
METADATA_OUT="${METADATA_OUT:-$WORK_DIR/output}"

mkdir -p "$WORK_DIR"

TOOLCHAIN_DIR="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
SDK_ROOT="$(xcrun --show-sdk-path --sdk macosx)"
XCODE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' /Applications/Xcode.app/Contents/version.plist 2>/dev/null || echo unknown)"

# Flatten Xcode's `{"version":1,"constValueProtocols":[…]}` envelope
# to the bare JSON array `-const-gather-protocols-file` actually wants
# (see Package.swift for why — verified against this toolchain).
PROTOCOLS_SRC="$TOOLCHAIN_DIR/usr/share/swift/SwiftConstantValues/AppIntents.json"
PROTOCOLS_FILE="$WORK_DIR/protocols.json"
if [ ! -f "$PROTOCOLS_SRC" ]; then
    echo "error: $PROTOCOLS_SRC not found — Xcode toolchain layout changed?" >&2
    exit 1
fi
/usr/bin/python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
json.dump(d['constValueProtocols'], open(sys.argv[2], 'w'))
" "$PROTOCOLS_SRC" "$PROTOCOLS_FILE"

CONST_VALUES_FILE="$WORK_DIR/CpdbApp.swiftconstvalues"
rm -f "$CONST_VALUES_FILE"

echo "==> building CpdbApp ($BUILD_CONFIG) so dependencies are cached"
swift build -c "$BUILD_CONFIG" --product "$MODULE_NAME" >/dev/null

# Force SwiftPM to recompile just this target so the next --verbose
# build actually prints its frontend command (an up-to-date target
# prints nothing).
BIN_DIR="$(swift build -c "$BUILD_CONFIG" --product "$MODULE_NAME" --show-bin-path)"
MODULE_BUILD_DIR="$(dirname "$BIN_DIR")/$MODULE_NAME.build"
rm -rf "$MODULE_BUILD_DIR"
rm -f "$BIN_DIR/Modules/$MODULE_NAME.swiftmodule"*

echo "==> capturing the real compile command (extraction flags enabled)"
VERBOSE_LOG="$WORK_DIR/verbose.log"
CPDB_EXTRACT_APPINTENTS=1 \
CPDB_APPINTENTS_CONSTVALUES_PATH="$CONST_VALUES_FILE" \
CPDB_APPINTENTS_PROTOCOLS_FILE="$PROTOCOLS_FILE" \
    swift build -c "$BUILD_CONFIG" --product "$MODULE_NAME" --verbose > "$VERBOSE_LOG" 2>&1 \
    || { echo "error: swift build failed — see $VERBOSE_LOG" >&2; tail -40 "$VERBOSE_LOG" >&2; exit 1; }

# The one whole-module frontend job for CpdbApp: anchored on its entry
# point file, which every build of this target compiles, rather than
# an arbitrary source file that might move.
FRONTEND_LINE_FILE="$WORK_DIR/frontend_line.txt"
grep -E '\-frontend -c ' "$VERBOSE_LOG" | grep -F 'Sources/CpdbApp/CpdbAppMain.swift' | head -1 > "$FRONTEND_LINE_FILE" || true
if [ ! -s "$FRONTEND_LINE_FILE" ]; then
    echo "error: couldn't find CpdbApp's frontend job in $VERBOSE_LOG (did the build actually recompile it?)" >&2
    exit 1
fi

# The captured line is long enough to exceed argv limits, so every
# script below reads it from this file rather than as an argument.
CLEAN_CMD_FILE="$WORK_DIR/frontend_cmd.sh"
SOURCE_LIST="$WORK_DIR/sources.txt"
TARGET_TRIPLE_FILE="$WORK_DIR/target_triple.txt"
/usr/bin/python3 -c "
import re
line = open('$FRONTEND_LINE_FILE').read()

# Strip SwiftPM's own supplementary-output-file-map — its presence
# makes the compiler silently drop -emit-const-values-path.
clean = re.sub(r'-supplementary-output-file-map \S+', '', line)
open('$CLEAN_CMD_FILE', 'w').write(clean)

# Pull the file list SwiftPM actually compiled (between '-frontend -c'
# and the first flag) straight from the same line, so
# --source-file-list matches reality instead of a hand-rolled glob.
m = re.search(r'-frontend -c (.*?) -supplementary-output-file-map', line)
files = m.group(1).split() if m else []
open('$SOURCE_LIST', 'w').write('\n'.join(files) + '\n')

m = re.search(r'-target (\S+)', line)
open('$TARGET_TRIPLE_FILE', 'w').write(m.group(1) if m else '')
"
if [ ! -s "$SOURCE_LIST" ]; then
    echo "error: extracted an empty source file list from the frontend job" >&2
    exit 1
fi

TARGET_TRIPLE="$(cat "$TARGET_TRIPLE_FILE")"
if [ -z "$TARGET_TRIPLE" ]; then
    echo "error: couldn't recover -target from the captured frontend job" >&2
    exit 1
fi

echo "==> re-running the compile with const-values extraction wired up"
bash "$CLEAN_CMD_FILE"

if [ ! -s "$CONST_VALUES_FILE" ]; then
    echo "error: $CONST_VALUES_FILE was not produced — App Intents metadata extraction failed" >&2
    exit 1
fi

CONST_VALS_LIST="$WORK_DIR/constvals.txt"
echo "$CONST_VALUES_FILE" > "$CONST_VALS_LIST"

rm -rf "$METADATA_OUT"
mkdir -p "$METADATA_OUT"

echo "==> appintentsmetadataprocessor"
xcrun appintentsmetadataprocessor \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name "$MODULE_NAME" \
    --sdk-root "$SDK_ROOT" \
    --xcode-version "$XCODE_VERSION" \
    --platform-family macOS \
    --deployment-target "$DEPLOYMENT_TARGET" \
    --target-triple "$TARGET_TRIPLE" \
    --binary-file "$BIN_DIR/$MODULE_NAME" \
    --source-file-list "$SOURCE_LIST" \
    --swift-const-vals-list "$CONST_VALS_LIST" \
    --no-app-shortcuts-localization \
    --force \
    --output "$METADATA_OUT"

if [ ! -d "$METADATA_OUT/Metadata.appintents" ]; then
    echo "error: appintentsmetadataprocessor did not produce Metadata.appintents at $METADATA_OUT" >&2
    exit 1
fi

echo "==> Metadata.appintents ready at $METADATA_OUT/Metadata.appintents"
