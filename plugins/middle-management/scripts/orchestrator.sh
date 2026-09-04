#!/usr/bin/env bash
# middle-management plugin — the coordinator seat: claim / release / status.
# Consumers: commands/orchestrator.md (the /orchestrator slash command), the
#   stale-marker hint printed by hooks/session-role.sh, tests/run.sh.
#   The marker it writes is read by hooks/session-role.sh.
#
# Why a marker file and not the session name: an editor tab title never reaches the
# session registry, and `claude -n <name>` only exists at start — but the coordinator
# seat must be handed over mid-conversation. Paths resolve through config-check.sh.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$DIR/orchestrator.sh"
CFG_DIR="$(bash "$DIR/config-check.sh" dir)"
MARKER="$CFG_DIR/state/orchestrator"
REG="$CFG_DIR/sessions"
command -v jq >/dev/null 2>&1 || { echo "jq is not installed — aborted."; exit 1; }

# Identify this session: walk up the process tree until a registry file matches.
me=""; p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
  [ -f "$REG/$p.json" ] && { me="$p"; break; }
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done
[ -z "$me" ] && {
  echo "No session registry entry found for this process (looked in $REG)."
  echo "Are you running inside a Claude Code session? A sandboxed bash can hide the process tree from this script."
  exit 1; }
MY_ID=$(jq -r '.sessionId' "$REG/$me.json")
MY_NAME=$(jq -r '.name // "unnamed"' "$REG/$me.json")

# Alive = a registry entry with this sessionId, kind "interactive" and a pid that answers
# kill -0 — the same rule hooks/session-role.sh applies (the sessionId is the identity, .name
# is display only). A bg/daemon entry counts as a holder for NEITHER of the two.
alive_name() {  # $1 = sessionId -> name, if its process is still running
  cat "$REG"/*.json 2>/dev/null \
    | jq -r --arg id "$1" 'select(.sessionId==$id and .kind == "interactive") | [.pid, .name // "unnamed"] | @tsv' 2>/dev/null \
    | { while IFS=$'\t' read -r pid name; do
          kill -0 "$pid" 2>/dev/null && { printf '%s' "$name"; break; }
        done; }
}
held_id() { [ -f "$MARKER" ] && head -1 "$MARKER" | tr -d '[:space:]'; }
# True only when the user explicitly disabled Remote Control at startup. String-compared
# on purpose: jq's // operator would swallow an explicit false, and an ABSENT key must
# not trigger the reminder (RC-off is no default on other people's machines).
rc_off() { [ "$(jq -r '.remoteControlAtStartup' "$CFG_DIR/settings.json" 2>/dev/null)" = "false" ]; }

HID=$(held_id); HNAME=""; [ -n "$HID" ] && HNAME=$(alive_name "$HID")

case "${1:-status}" in
  claim)
    if [ -n "$HNAME" ] && [ "$HID" != "$MY_ID" ]; then
      echo "BUSY: the coordinator is already \"$HNAME\"."
      echo "Release it there (bash $SELF release) or ask your user, then claim again here."
      exit 1
    fi
    mkdir -p "$(dirname "$MARKER")"
    printf '%s\n' "$MY_ID" > "$MARKER"
    echo "OK: this session (\"$MY_NAME\") is the coordinator from now on."
    # NB: an `[ … ] && echo` chain here would make a successful claim exit 1.
    if [ -n "$HID" ] && [ -z "$HNAME" ]; then
      echo "(The previous holder is no longer running — marker taken over.)"
    fi
    if rc_off; then
      echo ""
      echo "Remote Control is disabled at startup on this machine — coordinator sessions"
      echo "usually want it ON so your user can follow along remotely. If so, type"
      echo "/remote-control in THIS session (no script can do that for you)."
      echo "A fresh coordinator session can start with it on: claude --rc -n orchestrator"
    fi
    ;;
  release)
    if [ -z "$HID" ]; then echo "There is no coordinator — nothing to release."; exit 0; fi
    # A living OTHER holder refuses; a dead holder may be released by anyone.
    if [ "$HID" != "$MY_ID" ] && [ -n "$HNAME" ]; then
      echo "REFUSED: the coordinator is \"$HNAME\", not this session (\"$MY_NAME\")."
      echo "Only the holder gives up the seat — have it run release there."
      exit 1
    fi
    rm -f "$MARKER"
    if [ "$HID" = "$MY_ID" ]; then
      echo "OK: seat released. There is no coordinator now — the role regime is OFF."
    else
      echo "OK: the marker pointed at a session that is no longer running ($HID) — removed."
      echo "There is no coordinator now — the role regime is OFF."
    fi
    ;;
  status)
    echo "This session: \"$MY_NAME\" ($MY_ID)"
    if [ -z "$HID" ];      then echo "Coordinator:  none — the role regime is OFF."
    elif [ -z "$HNAME" ];  then echo "Coordinator:  the marker points at a session that has ENDED ($HID) — 'claim' takes it over, 'release' clears it."
    elif [ "$HID" = "$MY_ID" ]; then echo "Coordinator:  this session."
    else echo "Coordinator:  \"$HNAME\""; fi
    ;;
  *) echo "Usage: orchestrator.sh [claim|release|status]"; exit 1 ;;
esac
