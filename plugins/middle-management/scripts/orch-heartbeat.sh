#!/usr/bin/env bash
# middle-management plugin — the stuck-coordinator heartbeat (one tick).
# Consumers: templates/systemd/orch-heartbeat.service (started every 10 min by
#            orch-heartbeat.timer; both installed as USER units by /middle-management-setup,
#            which copies this script's directory to <config dir>/middle-management-heartbeat/);
#            tests/heartbeat.sh (drives every branch against fixtures);
#            by hand: `orch-heartbeat.sh classify <transcript.jsonl>` when triaging a stall.
#            Nothing else calls this script.
#
# One tick does:
#   who coordinates  ->  is that session alive (liveness rule F1, incl. the procStart PID-reuse
#   guard)  ->  does its transcript show a turn that never got an answer  ->  alarm the user
#   ONCE through the configured notifyCommand, then poke the session over its own Unix socket
#   until it answers again or GIVE_UP_H hours are up.
# A poke is a socket write (poke-session.py beside this file): no `claude` process, no model
# call, no quota - the transport must not depend on the resource a usage limit exhausts.
# It re-triggers an IDLE session; a session asleep inside an API retry only buffers it. So this
# is a net for DEAD TURNS, and merely harmless otherwise.
# Linux only: /proc/<pid>/stat, systemd user units, GNU date. Arm, disarm, uninstall and the
# alarm lines: skill middle-management, section "Recovery after a kill".
#
# Never prints a secret: notifyCommand is executed, never echoed; the peer token is read by
# poke-session.py and never echoed either.
set -Eeuo pipefail

# --- thresholds (guesses, which is why they are named) -------------------------------------
STUCK_MIN=15        # transcript silent for longer than this AND an unanswered turn => STUCK
ALARM_MIN=45        # stuck for this long => alarm #1 + first poke
POKE_EVERY=60       # minutes between pokes afterwards
GIVE_UP_H=24        # stop poking after this long, one final alarm
TAIL_LINES=1000     # records read from the end of the transcript (one tail-read per tick).
                    # Headroom, not a guarantee: a fully burned retry budget is ~320-360 records
                    # after the prompt, and sidechain traffic is unbounded - classify() widens to
                    # the whole file when the window holds no user record.

# --- paths (env-overridable so the test can drive every branch without touching real state) --
# The config dir honors CLAUDE_CONFIG_DIR like Claude Code itself (empty = unset). No
# config-check.sh dependency on purpose: the installed copy keeps running when the plugin moves.
DIR=$(cd "$(dirname "$0")" && pwd)
CFG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CFG_FILE=${OHB_CONFIG:-$CFG_DIR/middle-management.json}
REG=${OHB_REG:-$CFG_DIR/sessions}
MARKER=${OHB_MARKER:-$CFG_DIR/state/orchestrator}
PROJECTS=${OHB_PROJECTS:-$CFG_DIR/projects}
STATE=${OHB_STATE_DIR:-$CFG_DIR/state/orch-heartbeat}
HB_DIR=${OHB_DIR:-$DIR}            # the poke prompt and the sender live beside this script
POKE_PROMPT=$HB_DIR/orch-heartbeat-poke.md
POKE_SENDER=$HB_DIR/poke-session.py
# Episodes are "<sessionId>.json"; the latch file deliberately has NO .json suffix, because
# housekeeping deletes *.json of foreign coordinators and both it and last-tick must survive.
LATCH=$STATE/latches
TICKFILE=$STATE/last-tick
# Test seams: when set, an alarm or a poke is appended to that file instead of being sent.
ALARM_SINK=${OHB_ALARM_SINK:-}
POKE_SINK=${OHB_POKE_SINK:-}

TICK_NOTE=started

log() { printf '%s\n' "$*" >&2; }   # goes to the journal

# --- alarm: the configured notifyCommand (config key), the text as $1 and on stdin. ---------
# Never gates anything: an alarm that cannot be delivered is journaled and the tick goes on.
# ponytail: the same lines live in unit-failure-alarm.sh on purpose - the two scripts have
# different contracts, and coupling them would make the heartbeat's alarm path depend on a
# script whose job is "a systemd unit failed".
alarm() {
  local text="[$(hostname -s 2>/dev/null || echo host)] $1" cmd rc=0
  if [ -n "$ALARM_SINK" ]; then
    printf '%s\n' "$text" >> "$ALARM_SINK" || log "heartbeat: alarm sink unwritable - $text"
    return 0
  fi
  cmd=$(jq -r '.notifyCommand // ""' "$CFG_FILE" 2>/dev/null || true)
  if [ -z "$cmd" ]; then
    log "heartbeat: no notifyCommand in $CFG_FILE - alarm NOT delivered: $text"; return 0
  fi
  # Output discarded, not journaled: a failing command may echo a URL that carries a token.
  printf '%s\n' "$text" | sh -c "$cmd" notify "$text" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || log "heartbeat: notifyCommand failed (exit $rc) - the message was: $text"
  return 0
}

# --- latches: keep a branch that fires in every tick from buzzing the user's phone ----------
# should_alarm <key> <once|seconds>
should_alarm() {
  local key=$1 ttl=$2 now last cur
  now=$(date +%s)
  # A corrupt latch file must not INVERT the latch (it would make every branch alarm on every
  # tick, forever): read it defensively and rewrite it from scratch when it is unreadable.
  cur=$(jq -c . "$LATCH" 2>/dev/null) || cur=""
  case "$cur" in ''|null) cur='{}' ;; esac
  last=$(printf '%s' "$cur" | jq -r --arg k "$key" '(.[$k] // 0) | tostring' 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$ttl" = once ]; then
    [ "$last" -gt 0 ] && return 1
  else
    [ $((now - last)) -lt "$ttl" ] && return 1
  fi
  printf '%s' "$cur" | jq -c --arg k "$key" --argjson t "$now" '. + {($k): $t}' \
    > "$LATCH.$$.tmp" && mv "$LATCH.$$.tmp" "$LATCH"
  return 0
}

# --- classifier ----------------------------------------------------------------------------
# Ignores every record type except user/assistant, ignores records without a timestamp, ignores
# local slash-command echoes and sidechain (sub-agent) records, and compares TIMESTAMPS - never
# file position, because retry records are flushed retroactively and out of order.
# prints: VERDICT<TAB>lastUserISO<TAB>lastAsstISO<TAB>lastUserEpoch
classify_jq() {  # reads transcript lines on stdin; $1 = mtime age in minutes
  jq -Rsr --argjson age "$1" --argjson stuck "$STUCK_MIN" '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def body:  (.message.content // "")
               | if type == "array" then map(if type == "object" then (.text // "") else "" end) | join(" ")
                 else tostring end;
    [ split("\n")[] | select(length > 0) | (fromjson? // empty)
      | select(.timestamp != null and .isSidechain != true) ] as $r
    | ([ $r[] | select(.type == "user")
               # Local slash commands write user records with no answer. The tags are ANCHORED:
               # a tool result that merely quotes one of them is a real turn, not an echo.
               | select((body | test("^\\s*<(local-command-caveat|command-name|local-command-stdout)>")) | not)
               | .timestamp ] | max) as $lu
    | ([ $r[] | select(.type == "assistant" and .isApiErrorMessage != true
                       and (.message.model // "") != "<synthetic>")
               | .timestamp ] | max) as $la
    # No user record at all is HEALTHY (a fresh session) - never RECOVERED: a "recovery"
    # without a prompt to recover from is the shape a truncated read produces, and it would
    # close an open episode on a coordinator that never answered.
    | (if   $lu != null and ($la == null or $lu > $la) then (if $age > $stuck then "STUCK" else "HEALTHY" end)
       elif $lu != null and $la > $lu                  then "RECOVERED"
       else "HEALTHY" end) as $v
    | [$v, ($lu // "-"), ($la // "-"), (if $lu != null then ($lu | epoch | tostring) else "0" end)] | @tsv'
}
classify() {
  local f=$1 age out
  age=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 60 ))
  out=$(tail -n "$TAIL_LINES" "$f" | classify_jq "$age")
  # The tail window is a cost optimisation, not a guarantee: a burned retry budget can flush
  # hundreds of records AFTER the prompt that got no answer, pushing it out of the window - and
  # a missing lastUser is the one input that flips the verdict to "healthy". So when the window
  # holds no user record at all, re-read the whole file before concluding anything.
  if [ "$(printf '%s' "$out" | cut -f2)" = "-" ]; then
    log "heartbeat: no user record in the last $TAIL_LINES lines of $f - re-reading it whole"
    out=$(classify_jq "$age" < "$f")
  fi
  printf '%s\n' "$out"
}

# --- liveness F1 (registry entry, kind==interactive, kill -0, procStart) --------------------
# prints "<pid>\t<name>"; returns 0 alive, 1 dead, 2 undecidable
entry_of() { cat "$REG"/*.json 2>/dev/null | jq -c --arg id "$1" 'select(.sessionId == $id)' 2>/dev/null | head -1; }
alive() {
  local id=$1 e pid name kind procstart rest actual
  [ -d "$REG" ] && [ -r "$REG" ] || { log "heartbeat: registry $REG unreadable"; return 2; }
  e=$(entry_of "$id")
  [ -z "$e" ] && return 1
  pid=$(printf '%s' "$e" | jq -r '.pid // empty')
  name=$(printf '%s' "$e" | jq -r '.name // "unnamed"')
  kind=$(printf '%s' "$e" | jq -r '.kind // ""')
  procstart=$(printf '%s' "$e" | jq -r '.procStart // ""')
  [ "$kind" = interactive ] || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # PID reuse guard: field 22 of /proc/<pid>/stat. comm may contain spaces, so cut after ") ".
  rest=$(cat "/proc/$pid/stat" 2>/dev/null) || { log "heartbeat: /proc/$pid/stat unreadable"; return 2; }
  rest=${rest##*') '}   # longest match: comm may itself contain ") ", the numeric fields cannot
  actual=$(printf '%s' "$rest" | awk '{print $20}')
  if [ -n "$procstart" ] && [ "$procstart" != "$actual" ]; then
    log "heartbeat: procStart mismatch for pid $pid ($procstart != $actual) - PID reuse"
    return 2
  fi
  printf '%s\t%s\n' "$pid" "$name"
  return 0
}

# --- episode state --------------------------------------------------------------------------
ep_file() { printf '%s/%s.json\n' "$STATE" "$1"; }
ep_get()  { jq -r --arg k "$2" '(.[$k] // "") | tostring' "$(ep_file "$1")" 2>/dev/null || true; }
ep_set()  { # ep_set <id> <k> <v> [<k> <v> ...]   (values are written as strings/numbers as given)
  local id=$1 f cur; shift; f=$(ep_file "$id")
  # Same defence as the latch file: an unreadable episode is rewritten, not carried forward.
  # Without it a corrupt file makes the "stuck" alarm fire on every single tick.
  cur=$(jq -c . "$f" 2>/dev/null) || cur=""
  case "$cur" in ''|null) cur='{}' ;; esac
  local args=() prog='.'
  while [ $# -gt 0 ]; do
    args+=(--arg "k$#" "$1" --arg "v$#" "$2"); prog="$prog + {(\$k$#): \$v$#}"; shift 2
  done
  printf '%s' "$cur" | jq -c "${args[@]}" "$prog" > "$f.$$.tmp" && mv "$f.$$.tmp" "$f"
}

hhmm() { date -d "@$1" +%H:%M; }

# --- the poke ------------------------------------------------------------------------------
poke() { # poke <sessionId> <name> <stuck_since_epoch> <poke_number>
  local id=$1 name=$2 since=$3 n=$4 body rc=0
  if [ -n "$POKE_SINK" ]; then printf '%s poke#%s\n' "$id" "$n" >> "$POKE_SINK"; return 0; fi
  # The prompt file carries a doc header for humans; everything after its first "---" line is
  # the message. Keeping both in one versioned file beats a second file nobody would find.
  # No "---" in the file => send the whole thing, never an empty checklist.
  local text; text=$(sed '1,/^---$/d' "$POKE_PROMPT")   # unreadable file => ERR trap, loudly
  [ -n "$text" ] || text=$(cat "$POKE_PROMPT")
  body=$(mktemp)   # after the text, so a missing prompt file leaves no temp file behind
  { printf 'HEARTBEAT POKE #%s - your session ("%s") has had no answer since %s.\n' \
      "$n" "$name" "$(hhmm "$since")"
    printf '%s\n' "$text"; } > "$body"
  python3 "$POKE_SENDER" "$id" "$body" >&2 || rc=$?
  rm -f "$body"
  case "$rc" in
    0) log "heartbeat: poke #$n handed to $name ($id)" ;;
    2) if [ "$(ep_get "$id" poke_error)" != yes ]; then
         ep_set "$id" poke_error yes
         alarm "heartbeat cannot poke coordinator \"$name\": no live session with id ${id:0:8} (poke-session exit 2)"
       fi ;;
    3) if [ "$(ep_get "$id" poke_error)" != yes ]; then
         ep_set "$id" poke_error yes
         alarm "heartbeat cannot poke coordinator \"$name\": its socket is gone (poke-session exit 3)"
       fi ;;
    *) if [ "$(ep_get "$id" poke_error)" != yes ]; then
         ep_set "$id" poke_error yes
         alarm "heartbeat cannot poke coordinator \"$name\": poke-session.py exit $rc"
       fi ;;
  esac
  return 0
}

# --- housekeeping: an episode belongs to exactly one coordinator ----------------------------
close_foreign_episodes() { # close_foreign_episodes [<current sessionId>]
  local cur=${1:-} f id
  rm -f "$STATE"/*.tmp    # leftovers from a write that died mid-flight; never episodes
  for f in "$STATE"/*.json; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .json)
    [ "$id" = "$cur" ] && continue
    # An episode that recovered is deleted on the spot, so an episode still here that was
    # alarmed never recovered - the user heard the "stuck" line and deserves the closing one.
    if [ "$(ep_get "$id" alarmed)" = yes ]; then
      alarm "heartbeat: episode for coordinator ${id:0:8} closed without a recovery - a different session holds the marker now, or the old one is gone."
    fi
    rm -f "$f"
    log "heartbeat: removed foreign episode $id"
  done
}

# --- cause, for the recovery line only (never for detection) -------------------------------
limit_cause() { # limit_cause <transcript> <episode start epoch>
  local f=$1 since=$2 r
  # Only a limit whose reset lies AFTER this episode began can be its cause - an older record
  # still inside the tail window belongs to an earlier episode. Printed with the date, because
  # a seven_day limit resets days out and a bare HH:MM would read as "in a few minutes".
  r=$(tail -n "$TAIL_LINES" "$f" | jq -Rsr --argjson since "$since" '
    [ split("\n")[] | select(length > 0) | (fromjson? // empty)
      | select(.type == "system" and .subtype == "api_error" and .error.status == 429
               and (.error.rateLimits.resetsAt // null) != null
               and .error.rateLimits.resetsAt >= $since)
      | .error.rateLimits.resetsAt ] | max // empty' 2>/dev/null || true)
  [ -n "$r" ] && printf ' Cause on record: usage limit, reset at %s.' "$(date -d "@$r" +'%d.%m. %H:%M')"
  return 0
}

# ============================ subcommands ===================================================
case "${1:-tick}" in
  # classify is the read-only diagnostic: it prints a verdict and touches NO state, so running
  # it by hand (or from the test) cannot overwrite last-tick or a live episode.
  classify) classify "$2"; exit 0 ;;
  tick) : ;;
  *) echo "usage: orch-heartbeat.sh [tick|classify <transcript.jsonl>]" >&2; exit 1 ;;
esac

mkdir -p "$STATE"
trap 'printf "%s %s\n" "$(date -Is)" "$TICK_NOTE" > "$TICKFILE"' EXIT   # step 10: every tick
# The script's own failure is loud but latched like every other branch: a persistent bug
# must not buzz the user's phone every ten minutes. Exit 0, never non-zero - a failing exit would
# make OnFailure= fire a SECOND, unthrottled alarm on top of this one.
# $BASHPID != $$ means the failure happened inside a command substitution: exiting 0 THERE would
# hand the parent an empty string and a success status, and the tick would sail on with missing
# data. In a subshell the trap re-raises; only the main shell alarms and swallows the exit code.
trap 'rc=$?; if [ "$BASHPID" != "$$" ]; then exit $rc; fi
      if should_alarm internal-error 3600 2>/dev/null; then
        alarm "heartbeat: internal error (exit $rc, line $LINENO) - journalctl --user -u orch-heartbeat.service"; fi
      TICK_NOTE="error(exit $rc)"; exit 0' ERR

# 1. Who coordinates? Marker first, then the name fallback session-role.sh implements.
ID=""; NAME=""; SRC=""
if [ -f "$MARKER" ]; then ID=$(head -1 "$MARKER" | tr -d '[:space:]'); SRC=marker; fi

LIVENESS=0
if [ -n "$ID" ]; then
  OUT=$(alive "$ID") || LIVENESS=$?
  if [ "$LIVENESS" = 0 ]; then NAME=${OUT#*$'\t'}; fi
fi

if [ -z "$ID" ] || [ "$LIVENESS" = 1 ]; then
  # No marker, or it points at a session that is not live: the orch*-name fallback.
  # The (possibly empty) name stays LAST in the jq array: `read` with tab-IFS collapses empty
  # middle fields, so a nameless registry entry would otherwise shift its sessionId into the
  # name column (same fix as hooks/session-role.sh).
  NAMED=$(cat "$REG"/*.json 2>/dev/null \
    | jq -r 'select(.pid and .kind == "interactive") | [.pid, (.sessionId // ""), (.name // "")] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r p s n; do kill -0 "$p" 2>/dev/null && printf '%s\t%s\n' "$n" "$s"; done \
    | grep -i '^orch' || true)
  COUNT=$(printf '%s' "$NAMED" | grep -c . || true)
  if [ "$COUNT" -gt 1 ]; then
    should_alarm "ambiguous" 3600 && \
      alarm "heartbeat cannot tell who coordinates: $COUNT live sessions named orch* and no valid marker. Not watching anyone until that is resolved."
    TICK_NOTE="ambiguous-coordinator"; exit 0
  elif [ "$COUNT" = 1 ]; then
    ID=$(printf '%s' "$NAMED" | cut -f2); SRC=name
    # The name route gets the SAME F1 check as the marker route - including the procStart
    # PID-reuse guard. The candidate already passed kind+kill -0 above, so this only ever
    # downgrades it to "undecidable", never the other way round.
    LIVENESS=0; OUT=$(alive "$ID") || LIVENESS=$?
    if [ "$LIVENESS" = 0 ]; then NAME=${OUT#*$'\t'}; else NAME=$(printf '%s' "$NAMED" | cut -f1); fi
  elif [ -n "$ID" ] && [ "$SRC" = marker ]; then
    # Marker names a session that is gone and nothing else coordinates: dead, not stuck.
    if should_alarm "dead:$ID" once; then
      alarm "the coordinator (${ID:0:8}) is gone, not stuck. No re-wake - the regime is down until someone runs /orchestrator claim."
    fi
    close_foreign_episodes ""
    TICK_NOTE="coordinator-dead"; exit 0
  else
    # No marker and no orch* session: the regime is genuinely off.
    close_foreign_episodes ""
    TICK_NOTE="regime-off"; exit 0
  fi
fi

# Anything but a clean "alive" at this point is undecidable: the marker route's "dead" was
# already consumed above, so a non-zero here is an unreadable registry, PID reuse, or a session
# that exited between the fallback's two checks.
if [ "$LIVENESS" != 0 ]; then
  should_alarm "undecidable:$ID" 3600 && \
    alarm "heartbeat cannot decide whether coordinator ${ID:0:8} is alive (registry or /proc unreadable, PID reuse, or it exited mid-check). Checking again next tick."
  TICK_NOTE="undecidable"; exit 0
fi

# 2. Housekeeping: episodes of any other coordinator are over.
close_foreign_episodes "$ID"

# 4. The transcript.
TRANSCRIPT=$(ls -1 "$PROJECTS"/*/"$ID".jsonl 2>/dev/null | head -1 || true)
if [ -z "$TRANSCRIPT" ]; then
  should_alarm "transcript:$ID" once && \
    alarm "heartbeat found no transcript for coordinator \"$NAME\" (${ID:0:8}) under $PROJECTS - it cannot watch this session."
  TICK_NOTE="no-transcript"; exit 0
fi

# 5. Classify.
IFS=$'\t' read -r VERDICT LAST_USER LAST_ASST LU_EPOCH < <(classify "$TRANSCRIPT")
NOW=$(date +%s)
EP=$(ep_file "$ID")

# 7. Transitions.
if [ "$VERDICT" = RECOVERED ]; then
  if [ -f "$EP" ]; then
    SINCE=$(ep_get "$ID" stuck_since); SINCE=${SINCE:-0}
    MINS=$(( (NOW - SINCE) / 60 ))
    if [ "$(ep_get "$ID" alarmed)" = yes ]; then
      alarm "coordinator \"$NAME\" is back (answered again; it was stuck $MINS min since $(hhmm "$SINCE")).$(limit_cause "$TRANSCRIPT" "$SINCE") Its workers were re-poked if it ran the heartbeat checklist."
    fi
    rm -f "$EP"
    log "heartbeat: episode for $ID closed (recovered)"
    TICK_NOTE="recovered ($NAME)"
  else
    TICK_NOTE="healthy ($NAME)"
  fi
  exit 0
fi

if [ "$VERDICT" = HEALTHY ]; then
  # NOT a recovery: HEALTHY also means "mtime is fresh", which says nothing about an answer.
  # An open episode therefore survives - only a real answer (RECOVERED) closes it.
  [ -f "$EP" ] && TICK_NOTE="stuck-but-quiet ($NAME)" || TICK_NOTE="healthy ($NAME)"
  exit 0
fi

# STUCK.
if [ ! -f "$EP" ]; then
  ep_set "$ID" stuck_since "$LU_EPOCH" last_user "$LAST_USER" pokes 0 alarmed no stopped no poke_error no
elif [ "$(ep_get "$ID" last_user)" != "$LAST_USER" ]; then
  # A DIFFERENT turn is now unanswered, so the episode on file is stale: the coordinator did
  # answer in between and no tick happened to observe it (every tick landed mid-turn). Carrying
  # the old episode forward would swallow this stall's alarm, quote the wrong time, and let the
  # 24 h cap fire against the wrong clock and then disarm the heartbeat for good.
  log "heartbeat: new unanswered turn for $ID - episode re-baselined"
  ep_set "$ID" stuck_since "$LU_EPOCH" last_user "$LAST_USER" pokes 0 alarmed no stopped no poke_error no
fi
SINCE=$(ep_get "$ID" stuck_since); SINCE=${SINCE:-$LU_EPOCH}
# stuck_since is the transcript's own lastUser timestamp, not the tick that noticed it.
STUCK_FOR=$(( (NOW - SINCE) / 60 ))

if [ "$(ep_get "$ID" stopped)" = yes ]; then
  TICK_NOTE="stuck ${STUCK_FOR}m, given up ($NAME)"; exit 0
fi

if [ "$STUCK_FOR" -ge $((GIVE_UP_H * 60)) ]; then
  ep_set "$ID" stopped yes
  alarm "coordinator \"$NAME\" has been stuck for over $GIVE_UP_H h (since $(hhmm "$SINCE")). The heartbeat gives up - no more pokes. Check the tab, then claim a fresh coordinator."
  TICK_NOTE="gave up ($NAME)"; exit 0
fi

if [ "$STUCK_FOR" -lt "$ALARM_MIN" ]; then
  TICK_NOTE="stuck ${STUCK_FOR}m, below alarm threshold ($NAME)"; exit 0
fi

PORT=$(ep_get "$ID" pokes); PORT=${PORT:-0}
LAST_POKE=$(ep_get "$ID" last_poke); LAST_POKE=${LAST_POKE:-0}
if [ "$(ep_get "$ID" alarmed)" != yes ]; then
  alarm "coordinator \"$NAME\" stuck since $(hhmm "$SINCE") ($STUCK_FOR min, no answer to its last turn). Cause unknown until it recovers, heartbeat armed: poking now and then at most every $POKE_EVERY min, giving up after $GIVE_UP_H h. Disarm: systemctl --user disable --now orch-heartbeat.timer"
  ep_set "$ID" alarmed yes
  PORT=$((PORT + 1)); poke "$ID" "$NAME" "$SINCE" "$PORT"
  ep_set "$ID" pokes "$PORT" last_poke "$NOW"
  TICK_NOTE="stuck ${STUCK_FOR}m, alarmed + poke #$PORT ($NAME)"
elif [ $((NOW - LAST_POKE)) -ge $((POKE_EVERY * 60)) ]; then
  PORT=$((PORT + 1)); poke "$ID" "$NAME" "$SINCE" "$PORT"
  ep_set "$ID" pokes "$PORT" last_poke "$NOW"
  TICK_NOTE="stuck ${STUCK_FOR}m, poke #$PORT ($NAME)"
else
  TICK_NOTE="stuck ${STUCK_FOR}m, next poke pending ($NAME)"
fi
exit 0
