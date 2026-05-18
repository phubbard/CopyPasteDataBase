#!/usr/bin/env bash
# scripts/sign-nested.sh — re-sign Sparkle.framework *inside-out*.
#
# Why this exists: `codesign --deep` (which the release path uses to
# sign the GRDB / KeyboardShortcuts resource bundles — it has always
# handled those correctly) mis-signs Sparkle's helper tools. --deep
# re-signs XPCServices/*.xpc, Updater.app, and Autoupdate but does
# NOT preserve the per-helper requirements Sparkle needs, and Apple
# notarization rejects the result.
#
# The fix Sparkle documents: after the broad signing pass, re-sign
# Sparkle's nested code explicitly, inside-out, so the *last*
# signature on each helper is the correct one. This script does
# only that — resource bundles are left to the caller's --deep /
# outer pass exactly as before Sparkle was introduced.
#
# Usage:
#   sign-nested.sh <app_bundle_dir> <signing_identity> <timestamp_flag>
#
#   timestamp_flag: "none" → --timestamp=none  (dev / Apple Development)
#                   "tsa"  → --timestamp       (Developer ID / notarizable)
#
# Run AFTER the outer/--deep signing pass, BEFORE notarization.
# No-op (clean exit) when Sparkle.framework isn't embedded.

set -euo pipefail

APP="$1"
IDENTITY="$2"
TS_MODE="$3"

case "$TS_MODE" in
    none) TS_FLAG="--timestamp=none" ;;
    tsa)  TS_FLAG="--timestamp" ;;
    *) echo "sign-nested: bad timestamp flag '$TS_MODE' (want none|tsa)" >&2; exit 2 ;;
esac

FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$FW" ]; then
    echo "  (no Sparkle.framework — skipping inside-out re-sign)"
    exit 0
fi

sign() {
    codesign --force --options runtime --sign "$IDENTITY" $TS_FLAG "$1"
}

V="$FW/Versions/B"
# Inside-out order: deepest helpers first, framework last.
[ -e "$V/XPCServices/Downloader.xpc" ] && sign "$V/XPCServices/Downloader.xpc"
[ -e "$V/XPCServices/Installer.xpc" ]  && sign "$V/XPCServices/Installer.xpc"
[ -e "$V/Autoupdate" ]                 && sign "$V/Autoupdate"
[ -e "$V/Updater.app" ]                && sign "$V/Updater.app"
sign "$FW"
echo "  re-signed Sparkle.framework inside-out ($TS_MODE)"
