#!/usr/bin/env bash
# middle-management plugin: install one copy set of scripts/copy-sets.json into <config dir>/<set>/.
# Consumers: commands/middle-management-setup.md steps 5-9 (via Bash), hooks/refresh-copies.sh,
#   tests/refresh-copies.sh. Calls config-check.sh (the config dir).
#
# Usage: copy-set.sh <set>      e.g. copy-set.sh middle-management-heartbeat
# The systemd units run COPIES, because the plugin's cache path is versioned and goes stale with each
# update. copy-sets.json is the ONE list of what each copy dir holds (setup and the refresh hook both
# read it). Every file is written as <file>.tmp and then mv'd into place: a new inode, so a timer
# script that is running right now keeps reading the old one. A file in "neverOverwrite" is copied
# only when it is absent (the user edits it). Exit 0 = the whole set is in place; 1 = a copy failed
# (named on stderr); 64 = unknown set; 3 = jq is not installed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MAN="$HERE/copy-sets.json"
SET="${1:-}"
command -v jq >/dev/null 2>&1 || { echo "copy-set.sh: jq is not installed" >&2; exit 3; }
# The set name becomes a directory: only a key of the manifest is accepted, never a path.
FILES="$(jq -r --arg s "$SET" '.sets | if has($s) then .[$s][] else empty end' "$MAN" 2>/dev/null)"
[ -n "$FILES" ] || { echo "copy-set.sh: unknown set \"$SET\" (known: $(jq -r '.sets | keys | join(", ")' "$MAN" 2>/dev/null))" >&2; exit 64; }
KEEP="$(jq -r '.neverOverwrite[]?' "$MAN")"
DST="$(bash "$HERE/config-check.sh" dir)/$SET"
mkdir -p "$DST" || { echo "copy-set.sh: cannot create $DST" >&2; exit 1; }
while IFS= read -r f; do
  if [ -e "$DST/$f" ] && grep -qxF -- "$f" <<<"$KEEP"; then continue; fi
  rm -f "$DST/$f.tmp"
  cp "$HERE/$f" "$DST/$f.tmp" && mv -f "$DST/$f.tmp" "$DST/$f" \
    || { rm -f "$DST/$f.tmp"; echo "copy-set.sh: cannot copy $f into $DST" >&2; exit 1; }
done <<<"$FILES"
