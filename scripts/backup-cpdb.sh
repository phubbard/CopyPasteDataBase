#!/usr/bin/env bash
#
# backup-cpdb.sh — make a consistent, timestamped backup of the live cpdb
# database before a risky operation (e.g. the canonical-hash v2 identity
# cutover). Uses `VACUUM INTO`, which produces a single WAL-merged file and
# is safe to run while the app holds a WAL connection.
#
# The blob store (content-addressed flavor bodies, ~2 GB) is NOT copied:
# the identity migration only READS blobs, never mutates or deletes them,
# so the existing blobs/ directory serves both the live DB and any restored
# backup. A DB-only backup is the complete revert artifact.
#
# Revert procedure (to roll back to the pre-cutover state on cpdb ≤ 2.10.x):
#   1. Quit cpdb.
#   2. rm  "$SUPPORT/cpdb-v3.db"      (and -wal/-shm if present)
#   3. cp  <this-backup>  "$SUPPORT/cpdb.db"
#   4. Reinstall the pre-cutover build (2.10.1).
#   (blobs/ is untouched and shared, so nothing else is needed.)
set -euo pipefail

SUPPORT="${CPDB_SUPPORT_DIR:-$HOME/Library/Application Support/net.phfactor.cpdb}"
# The live DB is cpdb.db pre-cutover, cpdb-v3.db post-cutover. Back up
# whichever exists (so this is useful before AND after, just in case).
if [[ -f "$SUPPORT/cpdb.db" ]]; then
  SRC="$SUPPORT/cpdb.db"
elif [[ -f "$SUPPORT/cpdb-v3.db" ]]; then
  SRC="$SUPPORT/cpdb-v3.db"
else
  echo "no cpdb database found under $SUPPORT" >&2
  exit 1
fi

DEST_DIR="${1:-$HOME/cpdb-backups}"
mkdir -p "$DEST_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$DEST_DIR/$(basename "${SRC%.db}")-backup-$STAMP.db"

echo "source:  $SRC ($(du -h "$SRC" | cut -f1))"
echo "dest:    $DEST"
echo "backing up via VACUUM INTO…"
sqlite3 "$SRC" "VACUUM INTO '$DEST';"

# Verify the backup opens and carries the same live-row count.
SRC_COUNT="$(sqlite3 "$SRC" 'SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL;')"
DST_COUNT="$(sqlite3 "$DEST" 'SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL;')"
INTEGRITY="$(sqlite3 "$DEST" 'PRAGMA integrity_check;')"
echo "live rows: source=$SRC_COUNT  backup=$DST_COUNT"
echo "integrity_check: $INTEGRITY"
if [[ "$SRC_COUNT" != "$DST_COUNT" || "$INTEGRITY" != "ok" ]]; then
  echo "BACKUP VERIFICATION FAILED" >&2
  exit 1
fi
echo "backup OK: $DEST"
