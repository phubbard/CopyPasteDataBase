#!/usr/bin/env bash
# deploy.sh — push the current signed cpdb.app to one or more remote Macs.
#
# Usage:   ./deploy.sh <host> [<host> ...]
# Example: ./deploy.sh axiom mini.local pfh@studio
#
# Requires:
#   - Passwordless SSH (publickey) to each host; we don't prompt.
#   - The current Mac has a fresh .build/app/cpdb.app (we rebuild via
#     `make install-app` before pushing, so this is automatic).
#   - Every target host is registered by Provisioning UDID in the
#     embedded provisioning profile (check with
#     `security cms -D -i cpdb.provisionprofile | grep UDID`).
#
# What happens on each remote host:
#   1. Quit any running cpdb.
#   2. Replace /Applications/cpdb.app with the freshly-built bundle.
#   3. Clear the quarantine xattr so Gatekeeper doesn't prompt.
#   4. Launch the app (which starts the capture daemon + syncer).
#   5. Print brief confirmation + tail the cpdb log for a few seconds.
#
# Notes:
#   - The CLI lives at (menu bar → Pull from iCloud) on
#     the target — use that path if you want to run `cpdb sync status`
#     etc. after the app is quit.
#   - Second and subsequent deploys replace the bundle in place; the
#     local SQLite + blob store under
#     ~/Library/Application Support/net.phfactor.cpdb/ is preserved.
#   - We force UNIVERSAL=1 so the bundle works on both Apple Silicon
#     and Intel hosts. About 30s extra build time, no other downside;
#     better than discovering "bad CPU type" the first time you SSH
#     into an Intel Mac.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <host> [<host> ...]" >&2
    exit 2
fi

HOSTS=("$@")
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$REPO_DIR/.build/app/cpdb.app"
TARBALL="/tmp/cpdb-deploy-$(date +%s).tar.gz"

cd "$REPO_DIR"

echo "==> building locally (universal)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make UNIVERSAL=1 install-app >/dev/null

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: $APP_BUNDLE not found after build" >&2
    exit 1
fi

# Relaunch the locally-installed copy too. `make install-app` quits any
# running instance and replaces /Applications/cpdb.app, so the next
# capture won't happen until someone opens it again. Do that now so the
# build machine is running the freshly-deployed bits alongside the
# remotes.
echo "==> launching local copy"
open -a cpdb

echo "==> packaging $APP_BUNDLE → $TARBALL"
tar -czf "$TARBALL" -C "$(dirname "$APP_BUNDLE")" "$(basename "$APP_BUNDLE")"
TARBALL_SIZE=$(ls -lh "$TARBALL" | awk '{print $5}')
echo "    ($TARBALL_SIZE)"

for HOST in "${HOSTS[@]}"; do
    echo
    echo "==> deploying to $HOST"

    # Copy the tarball to the remote /tmp. scp preserves permissions.
    scp -q "$TARBALL" "$HOST:$TARBALL"

    # The remote-side install is a heredoc piped to ssh. Runs as the
    # user's own account; needs sudo-free write access to /Applications
    # (default on a personal Mac).
    ssh -T "$HOST" bash -s -- "$TARBALL" <<'REMOTE'
set -euo pipefail

TARBALL="$1"

# Quit any running copy cleanly. AppleScript form so the app's
# applicationWillTerminate handler gets a chance to run (flush the
# syncer, drop the daemon lock).
osascript -e 'tell application "cpdb" to quit' >/dev/null 2>&1 || true
# Give it a beat to actually exit before we clobber the bundle.
sleep 1

# Replace the bundle.
rm -rf /Applications/cpdb.app
tar -xzf "$TARBALL" -C /Applications/
rm -f "$TARBALL"

# Strip the quarantine xattr so Gatekeeper's "first launch" nag box
# doesn't pop up. Developer-ID signed bundles should survive this,
# but belt-and-braces.
xattr -dr com.apple.quarantine /Applications/cpdb.app 2>/dev/null || true

echo "  installed: $(defaults read /Applications/cpdb.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo '?')"
echo "  cli path : (menu bar → Pull from iCloud)"

# Launch. `open -a` ensures Launch Services picks up the refreshed
# bundle rather than any cached .app we just replaced.
open -a /Applications/cpdb.app

# Give the app a second to start logging, then show the last few lines
# of the cpdb subsystem so we can eyeball the outcome.
sleep 3
echo "  recent log lines:"
log show --predicate 'subsystem == "net.phfactor.cpdb"' --last 30s --style compact 2>/dev/null \
    | tail -n 15 | sed 's/^/    /' || echo "    (no log entries yet)"
REMOTE

    echo "==> $HOST done"
done

rm -f "$TARBALL"
echo
echo "all hosts updated. first-time installs pull your full history in the background."
echo "drive sync from the menu bar (Sync Now / Pull from iCloud) or watch:"
echo "    ssh <host> log stream --predicate 'subsystem == \"net.phfactor.cpdb\"' --level info"
