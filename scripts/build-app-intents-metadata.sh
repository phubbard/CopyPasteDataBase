#!/usr/bin/env bash
# build-app-intents-metadata.sh — extract App Intents metadata for
# CpdbApp so Shortcuts/Siri/Spotlight can discover ClipIntents.swift's
# intents and `ClipAppShortcuts` phrases.
#
# Xcode runs `appintentsmetadataprocessor` as an invisible build phase
# whenever a target imports AppIntents; SwiftPM never runs the
# processor itself. Reproducing that outside Xcode needs two things
# the processor consumes:
#   1. A `.swiftconstvalues` file — the Swift compiler's structured
#      dump of every AppIntent/AppEnum/AppEntity/AppShortcutsProvider
#      declaration's shape.
#   2. A `--source-file-list` naming exactly the Swift files the
#      module was compiled from.
#
# How those two get produced changed with Xcode 27 (Swift 6.4):
#
#   Before: `swift build` drove the "native" build system, which knew
#   nothing about const values. This script forced a CpdbApp recompile
#   with `-Xfrontend -emit-const-values-path` (injected through an
#   env-gated `unsafeFlags` block in Package.swift), scraped the
#   whole-module frontend command out of `swift build --verbose`, and
#   re-ran a cleaned copy of it to get one combined dump.
#
#   Now: SwiftPM's default build system is Swift Build — the same
#   engine Xcode uses (the native one is deprecated). Like Xcode, it
#   notices that CpdbApp imports AppIntents and itself passes the
#   driver's `-emit-const-values -const-gather-protocols-list …`,
#   pointing the module-wide `const-values` entry of the target's
#   output file map at `CpdbApp-primary.swiftconstvalues`. So every
#   plain `swift build -c release` already leaves exactly the dump
#   the processor wants next to the object files, and the old
#   machinery is not just redundant but fatal: its extra
#   `-emit-const-values-path` collides with the engine's own and the
#   release compile dies with "this mode does not support emitting
#   extracted const values". (The frontend flag itself isn't removed
#   — raw swiftc/-frontend still accept it — it just can't coexist
#   with the driver-level flag.) The Package.swift gate is gone; this
#   script now only has to find the engine's outputs and hand them to
#   the processor.
#
# Output: Metadata.appintents landing at $METADATA_OUT (default
# .build/appintents/output/Metadata.appintents) — copy that into
# Contents/Resources/ of the .app bundle.
#
# Env:
#   SWIFT_BUILD_ARGS  extra `swift build` arguments, e.g. the Makefile's
#                     `--arch arm64 --arch x86_64`. They must match the
#                     product build that precedes this script: Swift
#                     Build shares one Products/ dir across arch sets,
#                     so a host-arch-only build here would relink an
#                     already-built universal CpdbApp down to one slice.
#   METADATA_OUT      where to write the bundle (see above).
#
# Only supports `-c release` (the Makefile only asks for it there).
# Only reads the host architecture's slice — App Intents metadata is
# derived from Swift declarations, not object code, so it doesn't vary
# by arch; a universal (arm64 + x86_64) build still needs just one
# extraction pass.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_CONFIG="release"
CONFIG_DIR="Release"       # Swift Build's spelling of BUILD_CONFIG in Intermediates paths
MODULE_NAME="CpdbApp"
DEPLOYMENT_TARGET="14.0"   # keep in sync with Package.swift's .macOS(.v14)
WORK_DIR="$ROOT/.build/appintents"
METADATA_OUT="${METADATA_OUT:-$WORK_DIR/output}"
# Deliberately unquoted below so "--arch a --arch b" splits into words.
SWIFT_BUILD_ARGS="${SWIFT_BUILD_ARGS:-}"
HOST_ARCH="$(uname -m)"

mkdir -p "$WORK_DIR"

TOOLCHAIN_DIR="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
SDK_ROOT="$(xcrun --show-sdk-path --sdk macosx)"
XCODE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' /Applications/Xcode.app/Contents/version.plist 2>/dev/null || echo unknown)"

# A no-op when the Makefile just built this product; makes the script
# safe to run standalone. The const-values file is an output of the
# module's compile job, so it's regenerated whenever any source's
# content changes — don't second-guess it with mtimes: Swift Build
# skips the recompile (leaving the dump older than its sources) when
# a source was merely touched or an upstream module rebuilt without
# an interface change.
echo "==> building $MODULE_NAME ($BUILD_CONFIG) so its const values are current"
# shellcheck disable=SC2086
swift build -c "$BUILD_CONFIG" $SWIFT_BUILD_ARGS --product "$MODULE_NAME" >/dev/null \
    || { echo "error: swift build failed — rerun it by hand for the log" >&2; exit 1; }

# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "$BUILD_CONFIG" $SWIFT_BUILD_ARGS --product "$MODULE_NAME" --show-bin-path)"
# Swift Build layout: <out>/Products/Release and <out>/Intermediates.noindex
INTERMEDIATES="$(dirname "$(dirname "$BIN_DIR")")/Intermediates.noindex"
OBJ_DIR="$(find "$INTERMEDIATES" -type d \
    -path "*/$CONFIG_DIR/$MODULE_NAME-*.build/Objects-normal/$HOST_ARCH" 2>/dev/null | head -1 || true)"
if [ -z "$OBJ_DIR" ] || [ ! -f "$OBJ_DIR/$MODULE_NAME-OutputFileMap.json" ]; then
    echo "error: couldn't find $MODULE_NAME's $HOST_ARCH $CONFIG_DIR build directory under $INTERMEDIATES" >&2
    echo "       (bin path was $BIN_DIR — is SwiftPM still using the Swift Build backend?)" >&2
    exit 1
fi

# Ask the module's output file map where the engine put the const
# values rather than guessing a filename: the module-wide entry is
# keyed by the empty string.
CONST_VALUES_FILE="$(/usr/bin/python3 -c "
import json, sys
print(json.load(open(sys.argv[1])).get('', {}).get('const-values', ''))
" "$OBJ_DIR/$MODULE_NAME-OutputFileMap.json")"
if [ -z "$CONST_VALUES_FILE" ]; then
    echo "error: $MODULE_NAME's output file map has no const-values entry — Swift Build didn't request" >&2
    echo "       const extraction; does the target still import AppIntents?" >&2
    exit 1
fi
if [ ! -s "$CONST_VALUES_FILE" ]; then
    echo "error: $CONST_VALUES_FILE is missing or empty — App Intents metadata extraction failed" >&2
    exit 1
fi

# The file list the engine compiled from, in the one-path-per-line
# format the processor wants — matches reality without a hand-rolled glob.
SOURCE_LIST="$OBJ_DIR/$MODULE_NAME.SwiftFileList"
if [ ! -s "$SOURCE_LIST" ]; then
    echo "error: $SOURCE_LIST is missing or empty" >&2
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
    --target-triple "$HOST_ARCH-apple-macos$DEPLOYMENT_TARGET" \
    --source-file-list "$SOURCE_LIST" \
    --swift-const-vals-list "$CONST_VALS_LIST" \
    --no-app-shortcuts-localization \
    --force \
    --output "$METADATA_OUT"

if [ ! -d "$METADATA_OUT/Metadata.appintents" ]; then
    echo "error: appintentsmetadataprocessor did not produce Metadata.appintents at $METADATA_OUT" >&2
    exit 1
fi

# The processor exits 0 even when it finds nothing to describe, and an
# app with an empty bundle quietly loses its Shortcuts/Spotlight
# actions — so refuse an empty result instead of shipping one.
/usr/bin/python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
n_actions, n_entities, n_shortcuts = len(d.get('actions', {})), len(d.get('entities', {})), len(d.get('autoShortcuts', []))
if n_actions == 0:
    sys.exit('error: extracted Metadata.appintents describes no actions — expected ClipIntents.swift\'s intents')
print(f'    {n_actions} actions, {n_entities} entities, {n_shortcuts} app shortcuts')
" "$METADATA_OUT/Metadata.appintents/extract.actionsdata"

echo "==> Metadata.appintents ready at $METADATA_OUT/Metadata.appintents"
