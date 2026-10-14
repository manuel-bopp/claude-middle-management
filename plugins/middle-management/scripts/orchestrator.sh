#!/usr/bin/env bash
# middle-management plugin — the coordinator seat: claim / release / status.
# Consumers: commands/orchestrator.md (the /orchestrator slash command), the
#   stale-marker hint printed by hooks/session-role.sh, tests/run.sh.
#   The marker it writes is read by hooks/session-role.sh; the wrap entry it backfills on an
#   expired seat is read by scripts/peer-state.py.
#   Calls scripts/peer-state.py (stale-seat check on claim, holder line on status) and, only
#   when the config has a "scopes" key, scripts/scope.py (which seat this session's scope uses).
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
# The file peer-state.py reads the seat's second signal out of, resolved the same way it does
# ($MM_SESSION_LOG > the sessionLog config key > ~/logs/session-log.md). Named, not assumed: a
# refusal that cannot say WHICH file is missing leaves the user with nothing to create.
SESSION_LOG="$(bash "$DIR/config-check.sh" session-log)"
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

# Scopes (README "Scopes"): with a non-empty "scopes" key the seat is the one of THIS session's
# scope, decided by the directory it was started in (its registry cwd). No key: nothing here runs.
# Trade-off: with scopes, status and release need python3 too; the escape hatch is removing the key.
SCOPE=""
if jq -e '(.scopes | arrays | length) > 0' "$(bash "$DIR/config-check.sh" file)" >/dev/null 2>&1; then
  S=$(python3 "$DIR/scope.py" of "$(jq -r '.cwd | if type == "string" then . else "" end' "$REG/$me.json")" 2>/dev/null) || {
    echo "Scopes are configured, but this session's scope could not be resolved ($DIR/scope.py, python3). Nothing changed."; exit 1; }
  IFS=$'\t' read -r SCOPE SDIR _ <<<"$S"
  MARKER="$SDIR/orchestrator"
fi

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
# How long ANY holder must have been quiet before its seat counts as expired, closing line or not
# (issue #1). Six hours is past every prompt cache and past a working day's lunch break: a holder
# that quiet re-pays its whole context when woken, and the session log that the wrap would have
# completed is either already completed or the holder did nothing at all in that time. Observed:
# a coordinator idle 12h26m, log entry completed, no closing line - BUSY, and the only way out was
# waking it (~500k tokens) or deleting the marker by hand.
EXPIRED_MIN="${MM_EXPIRED_SEAT_MIN:-360}"
# Checked inside `claim`, and only where the value is actually used — NOT at file scope. `status`
# and `release` must keep working whatever this variable contains: release is the emergency exit
# that switches the regime off after a coordinator died, and a stray export in someone's shell
# profile must not block it with a message about an unrelated feature.
check_min() {  # $1 = the shell variable holding the value, $2 = the env name it came from
  local v="${!1}" why=""
  case "$v" in
    ''|*[!0-9]*)  why="is not a whole number of minutes" ;;
    ????????*)    why="is far outside 1..525600 minutes" ;;   # 8+ digits, see the int64 note below
    # 10#: a leading zero is a minute count to a human and octal to bash — $((08 * 60)) aborts the
    # whole script with "value too great for base", no refusal, no explanation. The upper bound is
    # the other half of the same arithmetic: it is int64, so from ~1.5e17 on the value * 60 wraps
    # NEGATIVE and every idle age clears the threshold — the huge value someone sets to switch this
    # route OFF would take every seat instead. Out of range keeps the seat; that is the direction
    # an absurd value was reaching for anyway.
    *) v=$((10#$v)); printf -v "$1" '%s' "$v"
       [ "$v" -ge 1 ] && [ "$v" -le 525600 ] \
         || why="is not between 1 and 525600 minutes (one year)" ;;
  esac
  [ -z "$why" ] && return 0
  echo "$2=\"${!2:-}\" $why — refused; the coordinator seat stays where it is."
  exit 1
}

# What the holder is doing, read off DISK (its registry entry, transcript and log) by
# peer-state.py — the holder itself is never messaged and pays nothing. Sets W (wrapped:
# yes/no/unknown), LOGOK (its session log entry says completed: true/false/null), IDLE_S/IDLE,
# CTX, EV (the signals that decided W), LAST (its own last line), TR (its transcript path), and
# NOREAD when the reader could not be run at all. All empty when the reader is absent, fails, or answers unparseably:
# an empty W means "we do not know", and every caller must then treat the holder as working.
# Fail closed — two coordinators at once is a worse failure than one expensive wake.
read_peer() {  # $1 = sessionId
  W=""; LOGOK=""; IDLE_S=""; IDLE=""; CTX=""; EV=""; LAST=""; TR=""; NOREAD=""
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
         ((.last // "-") | gsub("\t"; " ")), (.transcript // "-")] | @tsv' 2>/dev/null) || return 0
  IFS=$'\t' read -r W LOGOK IDLE_S IDLE CTX EV LAST TR <<<"$PEER_ROW"
}

# Expired (issue #1): past EXPIRED_MIN the holder's closing line is no longer required. The reader
# must still have READ the holder (W yes|no — "unknown" or no answer fails closed, as everywhere in
# this script), and nothing of that session may have moved in that time: not its transcript
# (IDLE_S) and not the folder beside it, where a foreground sub-agent and tool results keep writing
# while the main transcript stays quiet. A find that cannot read that folder counts as activity.
# ponytail: a background Bash job writes to /tmp/claude-<uid>/…/tasks/, not here, so a holder
# babysitting a 6 h+ job reads as expired; accepted, quiet that long is what the issue calls expired.
expired() {
  case "$W" in yes|no) ;; *) return 1 ;; esac
  [ "${IDLE_S:-x}" -ge "$((EXPIRED_MIN * 60))" ] 2>/dev/null || return 1
  local d="${TR%.jsonl}" hit
  [ -f "$TR" ] || return 1                   # no transcript read = nothing to measure the quiet on
  [ -d "$d" ] || return 0
  hit=$(find "$d" -type f -mmin "-$EXPIRED_MIN" -print -quit 2>/dev/null) || { FOLDER_MOVED=1; return 1; }
  [ -z "$hit" ] || { FOLDER_MOVED=1; return 1; }
}
log_state() {
  case "$LOGOK" in
    true)  echo "completed" ;;
    false) echo "NOT completed (its last entry says otherwise; work may be unfinished, see its transcript)" ;;
    *)     if [ -f "$SESSION_LOG" ]; then echo "no entry under its name"; else echo "none (no session log at $SESSION_LOG)"; fi ;;
  esac
}
# The holder's wrap entry, written FOR it by the session that took the expired seat: the documented
# shape (README, "The session log"), appended at the end, a day heading first when the file's last one
# is not today, and the closed marker keyed by the holder's sessionId, so the tab list reads it as
# finished from now on. Nothing in it is invented: idle, log state and last line are what was read.
backfill() {
  local day hhmm last
  day=$(date +%F); hhmm=$(date +%H:%M)
  mkdir -p "$(dirname "$SESSION_LOG")" 2>/dev/null
  last=$(sed -nE 's/^##[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]*$/\1/p' "$SESSION_LOG" 2>/dev/null | tail -1)
  {
    [ "$last" = "$day" ] || printf '\n## %s\n' "$day"
    printf '\n### %s – [%s] – coordinator seat expired, wrap backfilled\n' "$hhmm" "${HNAME%% *}"
    printf -- '- Backfilled by %s (%s) on taking the expired coordinator seat; the holder was NOT messaged.\n' "$MY_NAME" "$MY_ID"
    printf -- '- Idle %s (threshold %s min); its own session-log entry: %s.\n' "$IDLE" "$EXPIRED_MIN" "$(log_state)"
    printf -- '- Its last line: %s\n' "$LAST"
    printf -- '- Status: completed\n'
    printf -- '- Session: closed · %s — backfilled by %s at %s %s\n' "$HID" "$MY_NAME" "$day" "$hhmm"
  } >> "$SESSION_LOG" || return 1
  # Its open-items drop gets the WRAPPED line too: without it `open-items.py list` calls the holder
  # "died unwrapped" and routes the next ritual to resume it, the wake this takeover exists to avoid.
  local drop="$CFG_DIR/open-items/${HID:0:8}-session-notes.md"
  [ -f "$drop" ] && printf -- '- WRAPPED %s · backfilled by %s at %s (expired seat; items not swept, file the open keys from list)\n' \
    "$hhmm" "$MY_NAME" "$day" >> "$drop"
  return 0
}

HID=$(held_id); HNAME=""; [ -n "$HID" ] && HNAME=$(alive_name "$HID")
# A holder alive in ANOTHER scope (a root was added, moved or nested over its start dir) does not
# hold this seat: the role hook already calls it "not visibly alive", so claim and release <id> must
# work here too. Fail closed: only a successful resolution to a different scope clears HNAME.
HSCOPE=""
if [ -n "$SCOPE" ] && [ -n "$HNAME" ]; then
  HCWD=$(cat "$REG"/*.json 2>/dev/null \
    | jq -r --arg id "$HID" 'select(.sessionId==$id and .kind == "interactive")
        | [.pid, (.cwd | if type == "string" and . != "" then . else "-" end)] | @tsv' 2>/dev/null \
    | { while IFS=$'\t' read -r pid c; do kill -0 "$pid" 2>/dev/null && { printf '%s' "$c"; break; }; done; })
  HS=$(python3 "$DIR/scope.py" of "$HCWD" 2>/dev/null) && [ "${HS%%$'\t'*}" != "$SCOPE" ] \
    && { HSCOPE="${HS%%$'\t'*}"; HNAME=""; }
fi
moved_note() {  # the reason a living holder does not count, when that is the reason
  if [ -n "$HSCOPE" ]; then
    echo "(The holder $HID is alive, but it now belongs to scope $HSCOPE, so it no longer holds this seat.)"
  fi
}
if [ -n "$SCOPE" ]; then echo "Scope: $SCOPE (seat marker $MARKER)"; fi

case "${1:-status}" in
  claim)
    if [ -n "$HNAME" ] && [ "$HID" != "$MY_ID" ]; then
      # Its tab is open — but it may have wrapped last night and simply never been closed.
      # Ask the disk instead of the session: only a holder that demonstrably wrapped AND has
      # been quiet past the cache window loses its seat, and the evidence is printed so the
      # takeover is auditable in this transcript.
      check_min STALE_MIN MM_STALE_SEAT_MIN; check_min EXPIRED_MIN MM_EXPIRED_SEAT_MIN
      # An expiry under the stale threshold would take a seat the two-signal rule still protects.
      [ "$EXPIRED_MIN" -ge "$STALE_MIN" ] || {
        echo "MM_EXPIRED_SEAT_MIN=$EXPIRED_MIN is below MM_STALE_SEAT_MIN=$STALE_MIN — refused; the coordinator seat stays where it is."
        exit 1; }
      read_peer "$HID"
      # Below MM_EXPIRED_SEAT_MIN: TWO agreeing signals, not one. The tab list (peer-state.py --wrapped) runs on the closing
      # line alone and may be generous: its false positive costs the user one glance at a tab. The
      # seat may not be, because two coordinators at once is the worst failure this plugin can
      # produce — and the sentence that decides it ("the tab can be closed") is one a WORKING
      # coordinator writes after every wrap, about somebody else's tab. So a takeover needs the
      # holder's own closing line AND its session-log entry reading completed, and the idle age on
      # top of both. One signal short is an appeal, not a takeover — until the seat expires.
      if [ "$W" = "yes" ] && [ "$LOGOK" = "true" ] \
         && [ "${IDLE_S:-x}" -ge "$((STALE_MIN * 60))" ] 2>/dev/null; then
        echo "STALE SEAT: \"$HNAME\" reads as wrapped — closing line AND session log agree — and has not moved in $IDLE. Taking it over."
        echo "  holder   : \"$HNAME\" ($HID), idle $IDLE, ctx $CTX tokens — what waking it would cost"
        echo "  signals  : $EV"
        echo "  last line: $LAST"
        echo "  (Read off disk by peer-state.py; the holder was NOT messaged. Threshold: ${STALE_MIN} min.)"
      elif expired; then
        # Past the long threshold the appeal is the expensive route by definition: the holder's
        # cache is long cold. Take the seat and write the wrap it never wrote — never message it.
        if [ "$LOGOK" = "true" ]; then why="its session log entry reads completed"
        else why="nothing in its transcript or session folder moved in that time"; fi
        echo "EXPIRED SEAT: \"$HNAME\" has not moved in $IDLE (threshold ${EXPIRED_MIN} min) and $why. Taking it over."
        echo "  holder   : \"$HNAME\" ($HID), idle $IDLE, ctx $CTX tokens — what waking it would cost"
        echo "  log      : $(log_state)"
        echo "  signals  : $EV"
        echo "  last line: $LAST"
        echo "  (Read off disk by peer-state.py; the holder was NOT messaged. Its wrap entry is backfilled.)"
        BACKFILL=1
      else
        # "No entry for this session" and "no log on this machine at all" read identically in the
        # reader (log_completed stays null for both) and are completely different problems: the
        # first waits for that session's wrap, the second means nothing will EVER produce the
        # signal until a log exists. A stranger hitting the second one got told to look for an
        # entry in a file that was not there. So the file itself is tested here, and the refusal
        # names it, who writes it, and the way out when the holder is dead.
        NOLOG=""
        if [ -n "${FOLDER_MOVED:-}" ]; then W=folder; fi
        case "$W" in
          folder) why="its transcript is quiet for $IDLE, but its session folder (${TR%.jsonl}) moved within ${EXPIRED_MIN} min — a sub-agent or tool is still writing, so it is not expired" ;;
          yes) case "$LOGOK" in
                 true)  why="it wrapped, but has been idle only $IDLE (threshold ${STALE_MIN} min) — its prompt cache is probably still warm, so appealing there is cheap" ;;
                 false) why="its last line reads as wrapped, but its own session log entry is not completed (idle $IDLE) — that is one of the two signals the seat needs, so this stays an appeal" ;;
                 *)     if [ -f "$SESSION_LOG" ]; then
                          why="its last line reads as wrapped, but there is no session log entry under its name (idle $IDLE) — that is one of the two signals the seat needs, so this stays an appeal"
                        else
                          NOLOG=1
                          why="its last line reads as wrapped, but this machine has no session log at all (idle $IDLE) — the second signal the seat needs cannot exist yet, so this stays an appeal"
                        fi ;;
               esac ;;
          no)  why="it is alive and still working (last activity $IDLE ago) — waking it costs it its whole context" ;;
          *)   why="peer-state.py gave no usable answer about it (${NOREAD:-no usable row in its output}), so it counts as working" ;;
        esac
        echo "BUSY: the coordinator is already \"$HNAME\" — $why."
        if [ -n "$NOLOG" ]; then
          echo "  the log it reads: $SESSION_LOG   (set another path with sessionLog via /middle-management-setup)"
          echo "  who writes it   : the middle-management:wrap skill — ONE wrap in \"$HNAME\" files the entry, and this claim works"
          echo "  session is dead : bash $SELF release $HID   (only when your user says that tab is gone)"
        fi
        case "$W" in yes|no) echo "  expires  : once nothing of it moves for ${EXPIRED_MIN} min (MM_EXPIRED_SEAT_MIN) — then claim takes the seat and backfills its wrap" ;; esac
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
    # Only the winner of the marker writes the backfill, so a lost race never files a second one.
    if [ -n "${BACKFILL:-}" ]; then
      if backfill 2>/dev/null; then
        echo "BACKFILLED: wrap entry for \"$HNAME\" appended to $SESSION_LOG (- Session: closed · $HID)."
      else
        echo "WARNING: the seat is yours, but the backfill could not be appended to $SESSION_LOG —"
        echo "  write the holder's wrap entry by hand (middle-management:wrap, step 4) with: - Session: closed · $HID"
      fi
    fi
    # NB: an `[ … ] && echo` chain here would make a successful claim exit 1.
    if [ -n "$HID" ] && [ -z "$HNAME" ]; then
      echo "(The previous holder is no longer running — marker taken over.)"
      moved_note
    fi
    # Issue #2: the first coordinator of the day delivers the ritual (the user's to-do list at least)
    # when the headless run did not. The window is the epoch of the last delivered ritual.
    WIN="$(cat "$CFG_DIR/state/morning-ritual/window" 2>/dev/null)"; case "$WIN" in ''|*[!0-9]*) WIN=0 ;; esac
    MIDNIGHT=$(( $(date +%s) - 10#$(date +%H) * 3600 - 10#$(date +%M) * 60 - 10#$(date +%S) ))
    if [ "$WIN" -lt "$MIDNIGHT" ]; then
      echo "No morning ritual was delivered today — run middle-management:morning-ritual now (step 6, your user's to-do list, at least)."
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
      moved_note
    elif [ "$HID" = "$MY_ID" ]; then echo "Coordinator:  this session."
    else
      echo "Coordinator:  \"$HNAME\""
      # Same disk read as claim: "appeal or take it" should be answerable without a second command.
      read_peer "$HID"
      if [ -n "$W" ]; then
        echo "              idle $IDLE, wrapped $W, session log completed $LOGOK, ctx $CTX tokens"
        echo "              'claim' takes the seat when BOTH read finished and it has been idle over ${STALE_MIN} min,"
        echo "              or once nothing of it moved for ${EXPIRED_MIN} min (expired: its wrap is backfilled)."
      fi
    fi
    ;;
  *) echo "Usage: orchestrator.sh [claim|release [<sessionId of the not visibly alive holder>]|status]"; exit 1 ;;
esac
