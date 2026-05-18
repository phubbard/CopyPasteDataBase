#!/usr/bin/env bash
# scripts/sign-nested.sh — sign every nested code item inside the
# cpdb.app bundle *inside-out*, in the order codesign requires.
#
# Why this exists: `codesign --deep` mis-signs Sparkle's helper
# tools (XPCServices/*.xpc, Updater.app, Autoupdate) — it re-signs
# them but strips the per-helper requirements Sparkle needs, and
# notarization rejects the result. Sparkle's documented approach is
# explicit inside-out signing. KeyboardShortcuts / GRDB resource
# `.bundle`s also need their own signature before the outer app
# (hardened runtime won't load unsigned nested bundles).
#
# Usage:
#   sign-nested.sh <app_bundle_dir> <signing_identity> <timestamp_flag>
#
#   timestamp_flag: "none"  → --timestamp=none   (dev / Apple Development)
#                   "tsa"   → --timestamp        (Developer ID / notarizable)
#
# The caller signs the OUTER app bundle afterwards (with
# entitlements). This script never touches the outer signature.

set -euo pipefail

APP="$1"
IDENTITY="$2"
TS_MODE="$3"

case "$TS_MODE" in
    none) TS_FLAG="--timestamp=none" ;;
    tsa)  TS_FLAG="--timestamp" ;;
    *) echo "sign-nested: bad timestamp flag '$TS_MODE' (want none|tsa)" >&2; exit 2 ;;
esac

sign() {
    # $1 = path. Hardened runtime (-o runtime) on every nested
    # Mach-O; no entitlements (helpers don't claim capabilities —
    # the main app does).
    codesign --force --options runtime --sign "$IDENTITY" $TS_FLAG "$1"
}

FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    V="$FW/Versions/B"
    # Inside-out: XPC services → Autoupdate → Updater.app → framework.
    [ -e "$V/XPCServices/Downloader.xpc" ] && sign "$V/XPCServices/Downloader.xpc"
    [ -e "$V/XPCServices/Installer.xpc" ]  && sign "$V/XPCServices/Installer.xpc"
    [ -e "$V/Autoupdate" ]                 && sign "$V/Autoupdate"
    [ -e "$V/Updater.app" ]                && sign "$V/Updater.app"
    sign "$FW"
    echo "  signed Sparkle.framework (inside-out, $TS_MODE)"
fi

# SPM resource bundles live in Contents/Resources/*.bundle (build-app
# copies them there). Sign each so the hardened-runtime main binary
# can load them.
shopt -s nullglob
for b in "$APP"/Contents/Resources/*.bundle; do
    if [ -d "$b" ]; then
        codesign --force --sign "$IDENTITY" $TS_FLAG "$b"
        echo "  signed $(basename "$b")"
    fi
done
