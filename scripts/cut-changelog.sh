#!/usr/bin/env bash
# scripts/cut-changelog.sh — promote CHANGELOG.md's [Unreleased] section
# to a dated [X.Y.Z] section, prepend a fresh empty [Unreleased],
# print the promoted body to stdout (caller uses it as release notes).
#
# Idempotent against an already-cut version: if CHANGELOG.md already
# has a [X.Y.Z] section, abort with a clear message rather than
# double-tagging.
#
# Usage:
#   scripts/cut-changelog.sh X.Y.Z
#   scripts/cut-changelog.sh X.Y.Z --check    (print body, no rewrite)

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 X.Y.Z [--check]" >&2
    exit 2
fi

# We delegate the actual text manipulation to Python because awk -v
# can't carry multi-line strings cleanly and sed in-place edits across
# a region with arbitrary content + newlines is fragile. Python's
# string slicing is the natural fit.
exec python3 -c '
import re
import sys
from datetime import date

version = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else "rewrite"
file = "CHANGELOG.md"

try:
    with open(file, "r") as f:
        text = f.read()
except FileNotFoundError:
    sys.stderr.write(f"error: {file} not found in CWD ({__import__(chr(111)+chr(115)).getcwd()})\n")
    sys.exit(1)

# Reject double-cut.
if re.search(rf"^## \[{re.escape(version)}\]", text, re.MULTILINE):
    sys.stderr.write(
        f"error: {file} already has a [{version}] section. "
        f"Did you forget to bump VERSION_NEW?\n"
    )
    sys.exit(1)

# Locate `## [Unreleased]` and the next `## [...]` heading after it.
unreleased = re.search(r"^## \[Unreleased\]\s*$", text, re.MULTILINE)
if not unreleased:
    sys.stderr.write(f"error: no [Unreleased] heading in {file}\n")
    sys.exit(1)

body_start = unreleased.end()
next_heading = re.search(r"^## \[", text[body_start:], re.MULTILINE)
if next_heading:
    body_end = body_start + next_heading.start()
else:
    body_end = len(text)

body = text[body_start:body_end].strip()

if not body:
    sys.stderr.write(
        f"error: [Unreleased] section in {file} is empty. "
        f"Add at least one bullet before cutting.\n"
    )
    sys.exit(1)

if mode == "--check":
    print(body)
    sys.exit(0)

# Rewrite: replace the [Unreleased] section with a fresh empty one
# followed by a dated [X.Y.Z] section carrying the body.
today = date.today().isoformat()
replacement = (
    f"## [Unreleased]\n"
    f"\n"
    f"## [{version}] – {today}\n"
    f"\n"
    f"{body}\n"
)
# Preserve a single blank line before the next heading.
new_text = text[:unreleased.start()] + replacement + "\n" + text[body_end:].lstrip("\n")
# Collapse triple+ blank lines down to double.
new_text = re.sub(r"\n{3,}", "\n\n", new_text)

with open(file, "w") as f:
    f.write(new_text)

# Echo the promoted body so callers can use it as release notes.
print(body)
' "$@"
