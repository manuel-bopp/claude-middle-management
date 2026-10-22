#!/usr/bin/env bash
# middle-management plugin: SessionStart hook, keeps the unit copies on the plugin's version.
# Consumers: hooks/hooks.json (SessionStart registration), tests/refresh-copies.sh. Calls
#   scripts/copy-set.sh (one set) and scripts/config-check.sh; reads scripts/copy-sets.json and
#   .claude-plugin/plugin.json; runs the notifyCommand / notifyFallbackCommand config keys.
#
# The systemd units of setup steps 5-9 run COPIES under <config dir>/middle-management-*/, because
# the plugin's cache path is versioned. When this plugin's version differs from the stamp
# <config dir>/state/plugin-version: under flock, every copy dir of scripts/copy-sets.json that EXISTS
# (= that step is installed) gets its full set again (copy-set.sh: <file>.tmp + mv, a new inode, so a
# running timer script keeps its old file; the user-edited poke prompt is never overwritten), then the
# stamp is written. Touches no unit, restarts nothing: a release that changes a unit template says
# "re-run setup step N" in the CHANGELOG. A matching stamp exits at once.
# A failure never blocks the session (exit 0): a systemMessage every time, the stamp stays old so the
# next session start retries, and ONE notify per plugin version through notifyCommand (the fallback
# route when that one is missing or fails, as in scripts/unit-failure-alarm.sh).
# ponytail: no trail file; the t3-report failures.log would be sent by t3-watch.py as "report lost".
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
S="$PLUGIN_ROOT/scripts"
msg() { printf '{"systemMessage":"middle-management: %s"}\n' "$1"; }   # $1 carries no quote or backslash
command -v jq >/dev/null 2>&1 || { msg "jq is not installed, the unit copies cannot be refreshed"; exit 0; }

V="$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
CFG_DIR="$(bash "$S/config-check.sh" dir)"
STAMP="$CFG_DIR/state/plugin-version"
[ -n "$V" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$V" ] && exit 0

fail() {  # $1 = cause
  local text cmd fb latch="$STAMP.failed"
  text="[$(hostname -s 2>/dev/null || echo host)] middle-management ${V:-?}: the unit copies were NOT refreshed. $1. The units still run the previous version; the next session start retries (or re-run the setup steps of the installed copies)."
  jq -cn --arg t "middle-management: $text" '{systemMessage: $t}'
  [ "$(cat "$latch" 2>/dev/null)" = "${V:-?}" ] && exit 0   # told once per version already
  mkdir -p "${latch%/*}" 2>/dev/null; printf '%s\n' "${V:-?}" > "$latch" 2>/dev/null
  cmd="$(jq -r '.notifyCommand // ""' "$(bash "$S/config-check.sh" file)" 2>/dev/null)"
  fb="$(jq -r '.notifyFallbackCommand // ""' "$(bash "$S/config-check.sh" file)" 2>/dev/null)"
  # Output dropped: a failing command may echo a URL that carries a token.
  { [ -n "$cmd" ] && printf '%s\n' "$text" | sh -c "$cmd" notify "$text" >/dev/null 2>&1; } \
    || { [ -n "$fb" ] && text="[fallback route: the main alarm channel failed] $text" \
         && printf '%s\n' "$text" | sh -c "$fb" notify "$text" >/dev/null 2>&1; } \
    || rm -f "$latch"   # not delivered: the next session start tries again
  exit 0
}
[ -n "$V" ] || fail "no version in $PLUGIN_ROOT/.claude-plugin/plugin.json"

SETS="$(jq -r '.sets | keys[]' "$S/copy-sets.json" 2>/dev/null)" || fail "scripts/copy-sets.json is unreadable"
HAVE=""
for d in $SETS; do [ -d "$CFG_DIR/$d" ] && HAVE="$HAVE $d"; done
mkdir -p "$CFG_DIR/state" || fail "cannot create $CFG_DIR/state"
if [ -n "$HAVE" ]; then
  # Two sessions starting at once: the second waits, then finds the stamp written.
  command -v flock >/dev/null 2>&1 || fail "flock is not installed"
  exec 9>"$STAMP.lock" && flock -w 20 9 || fail "the refresh lock $STAMP.lock is held by another session"
  [ "$(cat "$STAMP" 2>/dev/null)" = "$V" ] && exit 0
  for d in $HAVE; do
    ERR="$(bash "$S/copy-set.sh" "$d" 2>&1 >/dev/null)" || fail "${ERR:-copy-set.sh $d failed}"
  done
fi
# Own tmp name: on a host without copy dirs no lock is taken, and two sessions may stamp at once.
printf '%s\n' "$V" > "$STAMP.$$.tmp" && mv -f "$STAMP.$$.tmp" "$STAMP" || { rm -f "$STAMP.$$.tmp"; fail "cannot write $STAMP"; }
rm -f "$STAMP.failed"
exit 0
