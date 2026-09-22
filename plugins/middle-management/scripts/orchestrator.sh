#!/usr/bin/env bash
# middle-management plugin — the coordinator seat: claim / release / status.
# Consumers: commands/orchestrator.md (the /orchestrator slash command), the
#   stale-marker hint printed by hooks/session-role.sh, tests/run.sh.
#   The marker it writes is read by hooks/session-role.sh.
#   Calls scripts/peer-state.py (stale-seat check on claim, holder line on status).
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
# Taking the marker is a read-check-write, and that is not one operation: three claims over the
# same stale holder each decided "take it" and each reported success (the role hook demoted the
# losers a turn later — after two ORCHESTRATOR banners had already been printed). Under flock the
# winner is decided before anyone writes; without flock the marker is written and read back, which
# still names whoever got there last. rc 3 = somebody else holds it now, rc 1 = the write itself
# failed. A failed write is never reported as a successful claim — a session that believes it holds
# a seat it does not is the same two-coordinator failure by another route.
take_marker() {
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null || return 1
  if command -v flock >/dev/null 2>&1; then
    ( flock 9 || exit 1
      [ "$(held_id)" = "$HID" ] || exit 3
      printf '%s\n' "$MY_ID" > "$MARKER" ) 9<>"$MARKER"
    return $?
  fi
  [ "$(held_id)" = "$HID" ] || return 3      # it changed while we were deciding
  printf '%s\n' "$MY_ID" > "$MARKER" || return 1
  [ "$(held_id)" = "$MY_ID" ] || return 3    # ...or a moment after we wrote
}
# True only when the user explicitly disabled Remote Control at startup. String-compared
# on purpose: jq's // operator would swallow an explicit false, and an ABSENT key must
# not trigger the reminder (RC-off is no default on other people's machines).
rc_off() { [ "$(jq -r '.remoteControlAtStartup' "$CFG_DIR/settings.json" 2>/dev/null)" = "false" ]; }

# How long a wrapped holder must have been quiet before its seat may be taken without asking it.
# 60 = the regular prompt-cache TTL: under the hour the holder's cache is usually still warm and
# an appeal ("please release the seat") costs it very little — past it the appeal makes it re-pay
# its ENTIRE conversation as fresh input tokens, which is the whole reason this route exists.
# Not a guarantee: under usage overage the TTL drops to five minutes, so 60 is an upper bound on
# "cheap to wake", not a promise — which is why it is an env var and not a constant.
STALE_MIN="${MM_STALE_SEAT_MIN:-60}"
# Checked inside `claim`, and only where the value is actually used — NOT at file scope. `status`
# and `release` must keep working whatever this variable contains: release is the emergency exit
# that switches the regime off after a coordinator died, and a stray export in someone's shell
# profile must not block it with a message about an unrelated feature.
check_stale_min() {
  case "$STALE_MIN" in
    ''|*[!0-9]*)  why="is not a whole number of minutes" ;;
    ????????*)    why="is far outside 1..525600 minutes" ;;   # 8+ digits, see the int64 note below
    # 10#: a leading zero is a minute count to a human and octal to bash — $((08 * 60)) aborts the
    # whole script with "value too great for base", no refusal, no explanation. The upper bound is
    # the other half of the same arithmetic: it is int64, so from ~1.5e17 on STALE_MIN * 60 wraps
    # NEGATIVE and every idle age clears the threshold — the huge value someone sets to switch this
    # route OFF would take every seat instead. Out of range keeps the seat; that is the direction
    # an absurd value was reaching for anyway.
    *) STALE_MIN=$((10#$STALE_MIN))
       [ "$STALE_MIN" -ge 1 ] && [ "$STALE_MIN" -le 525600 ] \
         || why="is not between 1 and 525600 minutes (one year)" ;;
  esac
  [ -z "${why:-}" ] && return 0
  echo "MM_STALE_SEAT_MIN=\"${MM_STALE_SEAT_MIN:-}\" $why — refused; the coordinator seat stays where it is."
  exit 1
}

# What the holder is doing, read off DISK (its registry entry, transcript and log) by
# peer-state.py — the holder itself is never messaged and pays nothing. Sets W (wrapped:
# yes/no/unknown), LOGOK (its session log entry says completed: true/false/null), IDLE_S/IDLE,
# CTX, EV (the signals that decided W), LAST (its own last line), and NOREAD when the reader
# could not be run at all. All empty when the reader is absent, fails, or answers unparseably:
# an empty W means "we do not know", and every caller must then treat the holder as working.
# Fail closed — two coordinators at once is a worse failure than one expensive wake.
read_peer() {  # $1 = sessionId
  W=""; LOGOK=""; IDLE_S=""; IDLE=""; CTX=""; EV=""; LAST=""; NOREAD=""
  [ -f "$DIR/peer-state.py" ] || { NOREAD="scripts/peer-state.py is not there"; return 0; }
  # jq is checked at the top of this script; python3 is checked here and not there, because
  # only this route needs it — status and release must not die on a machine without it.
  command -v python3 >/dev/null 2>&1 || { NOREAD="python3 is not installed"; return 0; }
  # Bounded on purpose: a reader that hangs (huge transcript, NFS-backed home) would stall an
  # interactive claim for as long as it hangs. A timeout is just another reader failure — no
  # answer, no takeover. Unquoted so an absent `timeout` drops out of the command line entirely.
  TMO=""; command -v timeout >/dev/null 2>&1 && TMO="timeout 10"
  PEER_JSON=$($TMO python3 "$DIR/peer-state.py" --session-id "$1" --json 2>/dev/null) || {
    NOREAD="peer-state.py failed or timed out"; return 0; }
  # log_completed is stringified, never empty: tab is IFS whitespace, so an empty field would
  # shift every column after it.
  PEER_ROW=$(printf '%s' "$PEER_JSON" | jq -er '.[0]
      | select(.wrapped != null and .idle_seconds != null)
      | [.wrapped, (.log_completed | tostring), .idle_seconds, (.idle // "?"), (.ctx // "?"),
         ((.evidence // []) | join("; ") | gsub("\t"; " ")),
         ((.last // "-") | gsub("\t"; " "))] | @tsv' 2>/dev/null) || return 0
  IFS=$'\t' read -r W LOGOK IDLE_S IDLE CTX EV LAST <<<"$PEER_ROW"
}

HID=$(held_id); HNAME=""; [ -n "$HID" ] && HNAME=$(alive_name "$HID")

case "${1:-status}" in
  claim)
    if [ -n "$HNAME" ] && [ "$HID" != "$MY_ID" ]; then
      # Its tab is open — but it may have wrapped last night and simply never been closed.
      # Ask the disk instead of the session: only a holder that demonstrably wrapped AND has
      # been quiet past the cache window loses its seat, and the evidence is printed so the
      # takeover is auditable in this transcript.
      check_stale_min
      read_peer "$HID"
      # TWO agreeing signals, not one. The tab list (peer-state.py --wrapped) runs on the closing
      # line alone and may be generous: its false positive costs the user one glance at a tab. The
      # seat may not be, because two coordinators at once is the worst failure this plugin can
      # produce — and the sentence that decides it ("the tab can be closed") is one a WORKING
      # coordinator writes after every wrap, about somebody else's tab. So a takeover needs the
      # holder's own closing line AND its session-log entry reading completed, and the idle age on
      # top of both. One signal short is an appeal, not a takeover.
      if [ "$W" = "yes" ] && [ "$LOGOK" = "true" ] \
         && [ "${IDLE_S:-x}" -ge "$((STALE_MIN * 60))" ] 2>/dev/null; then
        echo "STALE SEAT: \"$HNAME\" reads as wrapped — closing line AND session log agree — and has not moved in $IDLE. Taking it over."
        echo "  holder   : \"$HNAME\" ($HID), idle $IDLE, ctx $CTX tokens — what waking it would cost"
        echo "  signals  : $EV"
        echo "  last line: $LAST"
        echo "  (Read off disk by peer-state.py; the holder was NOT messaged. Threshold: ${STALE_MIN} min.)"
      else
        case "$W" in
          yes) case "$LOGOK" in
                 true)  why="it wrapped, but has been idle only $IDLE (threshold ${STALE_MIN} min) — its prompt cache is probably still warm, so appealing there is cheap" ;;
                 false) why="its last line reads as wrapped, but its own session log entry is not completed (idle $IDLE) — that is one of the two signals the seat needs, so this stays an appeal" ;;
                 *)     why="its last line reads as wrapped, but there is no session log entry under its name (idle $IDLE) — that is one of the two signals the seat needs, so this stays an appeal" ;;
               esac ;;
          no)  why="it is alive and still working (last activity $IDLE ago) — waking it costs it its whole context" ;;
          *)   why="peer-state.py gave no usable answer about it (${NOREAD:-no usable row in its output}), so it counts as working" ;;
        esac
        echo "BUSY: the coordinator is already \"$HNAME\" — $why."
        echo "Release it there (bash $SELF release) or ask your user, then claim again here."
        exit 1
      fi
    fi
    take_marker; TOOK=$?
    if [ "$TOOK" -eq 3 ]; then
      echo "RACE LOST: another session claimed the seat while this one was deciding — the marker"
      echo "now names $(held_id), not this session (\"$MY_NAME\"). This session is NOT the coordinator."
      echo "Check with 'bash $SELF status' and only claim again if your user still wants it here."
      exit 1
    fi
    if [ "$TOOK" -ne 0 ]; then
      echo "FAILED: could not write the marker $MARKER — this session is NOT the coordinator."
      echo "Is that path a directory, or the filesystem full or read-only? The seat is unchanged."
      exit 1
    fi
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
    # Invariant: only the holder gives up the seat. The one exception: the holder is not
    # visibly alive AND the calling session names its sessionId (printed by 'status') — nobody
    # types that by accident, and a coordinator in the middle of a reconnect looks dead for a
    # moment. This is also how the regime is switched OFF after the coordinator's process ended.
    if [ -z "$HID" ]; then echo "There is no coordinator — nothing to release."; exit 0; fi
    if [ "$HID" != "$MY_ID" ]; then
      if [ -n "$HNAME" ]; then
        echo "REFUSED: the coordinator is \"$HNAME\", not this session (\"$MY_NAME\")."
        echo "Only the holder gives up the seat — have it run release there (bash $SELF release)."
        exit 1
      fi
      if [ "${2:-}" != "$HID" ]; then
        echo "REFUSED: the marker points at $HID — this session is not the holder, and the holder"
        echo "is not visibly alive right now (ended OR in the middle of a reconnect)."
        echo "Only if your user says the coordinator session is gone:"
        echo "  bash $SELF release $HID"
        exit 1
      fi
    fi
    rm -f "$MARKER"
    if [ "$HID" = "$MY_ID" ]; then
      echo "OK: seat released. There is no coordinator now — the role regime is OFF."
    else
      echo "OK: the marker pointing at the no longer visible session $HID is removed."
      echo "There is no coordinator now — the role regime is OFF."
    fi
    ;;
  status)
    echo "This session: \"$MY_NAME\" ($MY_ID)"
    if [ -z "$HID" ];      then echo "Coordinator:  none — the role regime is OFF."
    elif [ -z "$HNAME" ];  then echo "Coordinator:  the marker points at a session that is not visibly alive ($HID) — 'claim' takes it over, 'release $HID' clears it."
    elif [ "$HID" = "$MY_ID" ]; then echo "Coordinator:  this session."
    else
      echo "Coordinator:  \"$HNAME\""
      # Same disk read as claim: "appeal or take it" should be answerable without a second command.
      read_peer "$HID"
      if [ -n "$W" ]; then
        echo "              idle $IDLE, wrapped $W, session log completed $LOGOK, ctx $CTX tokens"
        echo "              'claim' takes the seat only when BOTH read finished and it has been idle over ${STALE_MIN} min."
      fi
    fi
    ;;
  *) echo "Usage: orchestrator.sh [claim|release [<sessionId of the not visibly alive holder>]|status]"; exit 1 ;;
esac
