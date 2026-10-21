#!/usr/bin/env bash
# middle-management plugin: the morning chain under T3 Code: start a FRESH, visible coordinator
# thread every weekday morning (README "Morning coordinator in T3 Code").
# Consumers: templates/systemd/orch-morning-t3.service (the trigger, started by orch-morning-t3.timer),
#   templates/systemd/orch-morning-watchdog.service (--check, started by orch-morning-watchdog.timer),
#   manual runs, tests/morning-t3.sh. /middle-management-setup step 7b copies it next to
#   config-check.sh, scope.py and unit-failure-alarm.sh.
#   Calls config-check.sh (paths), scope.py (only with "scopes" or "scopeMode": the seat dir of
#   morningRoot), `claude -p` (the limit probe), curl (the POST), the notifyCommand config key.
#   Writes <seat dir>/morning-t3/status, read by scripts/t3-watch.py (a morning thread that has not
#   claimed yet must never cause a wake of the old coordinator) and by --check. Leaves the cause file
#   scripts/unit-failure-alarm.sh sends on failure.
#
# Usage: morning-t3.sh            the trigger
#        morning-t3.sh --check    the watchdog
#
# Trigger, in order:
#  1. Limit wait. Probe `claude -p ok` (no tools, no MCP, no settings). Limited (429 text, or no answer
#     within MM_MORNING_PROBE_SEC: a limited login retries and hangs) -> one notify, probe again every
#     MM_MORNING_RETRY_SEC until morningWaitUntil (config, default 09:30); still limited then -> one
#     "cancelled" notify and exit 0 (exit 1 when that notify failed: the unit alarm is the fallback).
#     Free after a wait -> one notify. Unclear (another error) -> go on: the thread tells for itself.
#     After a wait, a seat that changed hands meanwhile cancels: the ritual runs at the new holder.
#  2. POST {"from":"morning-t3","date":"<today>"} to the T3 webhook task whose URL sits in
#     morningTaskUrlFile (mode 600; default ~/.config/t3-threads/morning-task-url). The local twin of a
#     relay URL first, as in t3-wake.sh. HTTP 202 = the thread is started: status "posted <epoch>".
#     Anything else -> cause file, exit 1 -> OnFailure=unit-failure-alarm@%n.service.
# Watchdog (--check): quiet when today's ritual window is stamped AND the seat marker was written
#   today (a coordinator claimed it), or when the trigger cancelled itself today (it already said
#   why), or when it is still waiting (its pid is alive). Otherwise cause file + exit 1 -> the alarm.
#
# Env (optional): MM_MORNING_UNIT (this unit's name, for the cause file; unset = a manual run, no
#   cause file), MM_MORNING_WAIT_UNTIL (HH:MM, wins over the config key: a late manual run),
#   MM_MORNING_RETRY_SEC (600), MM_MORNING_PROBE_SEC (60), MM_MORNING_MODEL (the probe's model).
# The webhook URL is a capability into a full-access thread: it never reaches argv, stdout, stderr,
# the status file or a log line. curl reads it from a process substitution.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG_DIR="$(bash "$HERE/config-check.sh" dir)"
CFG_FILE="$(bash "$HERE/config-check.sh" file)"
cfg() { jq -r "$1" "$CFG_FILE" 2>/dev/null; }
HOST="$(hostname -s 2>/dev/null || echo host)"
UNIT="${MM_MORNING_UNIT:-}"
CAUSE=""
[ -n "$UNIT" ] && CAUSE="$CFG_DIR/state/unit-failure-alarm/$(printf '%s' "$UNIT" | tr -c 'A-Za-z0-9._-' '_').cause"
RERUN="systemctl --user start orch-morning-t3.service"
LATE="MM_MORNING_WAIT_UNTIL=<HH:MM> bash $HERE/morning-t3.sh"   # a manual run with a later deadline
TODAY="$(date +%F)"

fail() {  # $1 = headline, $2 = cause, $3 = fix
  local text="[$HOST] $1${UNIT:+ ($UNIT)}
Cause: $2
Fix: $3"
  printf '%s\n' "$text" >&2
  if [ -n "$CAUSE" ]; then mkdir -p "$(dirname "$CAUSE")" && printf '%s\n' "$text" > "$CAUSE"; fi
  [ -n "${STATUS:-}" ] && [ -z "${CHECK:-}" ] && setstatus failed
  exit 1
}
notify() {  # $1 = text; the contract of unit-failure-alarm.sh and morning-headless.sh
  local cmd; cmd="$(cfg '.notifyCommand // ""')"
  [ -n "$cmd" ] || return 2
  printf '%s\n' "$1" | sh -c "$cmd" notify "$1" >/dev/null 2>&1   # output dropped: may carry a token
}

command -v jq >/dev/null || fail "morning thread FAILED" "jq is not installed" "install jq"

# The seat this chain serves: the default seat, or with scopes the one of morningRoot (the folder of
# the T3 project the morning task runs in). Resolved exactly as orchestrator.sh resolves the marker.
SDIR="$CFG_DIR/state"
if [ "$(cfg '([.scopes | arrays | .[]] | length > 0) or (.scopeMode == "per-root")')" = true ]; then
  MR="$(cfg '.morningRoot // ""')"
  S="$(python3 "$HERE/scope.py" of "$MR" 2>/dev/null)" || S=""
  IFS=$'\t' read -r SNAME SDIR _ <<<"$S"
  [ -n "$S" ] && [ "${SNAME:-none}" != none ] \
    || fail "morning thread FAILED" "scopes are configured, but morningRoot (\"$MR\") resolves to no seat" \
            "set morningRoot to the folder of the T3 project the morning task runs in (/middle-management-setup)"
fi
MARKER="$SDIR/orchestrator"
STATE="$SDIR/morning-t3"
STATUS="$STATE/status"
mkdir -p "$STATE" || fail "morning thread FAILED" "cannot create $STATE" "check the permissions of $SDIR"
# One line: date, state, epoch, pid. Read by t3-watch.py and --check; never carries the URL.
setstatus() { printf '%s\t%s\t%s\t%s\n' "$TODAY" "$1" "$(date +%s)" "$$" > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"; }
midnight() { echo $(( $(date +%s) - 10#$(date +%H) * 3600 - 10#$(date +%M) * 60 - 10#$(date +%S) )); }

# --------------------------------------------------------------------------------- watchdog --
if [ "${1:-}" = --check ]; then
  CHECK=1; RERUN_T="systemctl --user start orch-morning-t3.service"
  IFS=$'\t' read -r SD SS _ SP < "$STATUS" 2>/dev/null || { SD=""; SS=""; SP=""; }
  if [ "$SD" = "$TODAY" ]; then
    case "$SS" in
      cancelled) echo "morning-t3 --check: the trigger cancelled itself today; it said why"; exit 0 ;;
      waiting)   kill -0 "$SP" 2>/dev/null && { echo "morning-t3 --check: the trigger still waits for the usage limit"; exit 0; } ;;
    esac
  fi
  M0="$(midnight)"
  WIN="$(cat "$SDIR/morning-ritual/window" 2>/dev/null)"; case "$WIN" in ''|*[!0-9]*) WIN=0 ;; esac
  MT=0; [ -s "$MARKER" ] && MT="$(stat -c %Y "$MARKER" 2>/dev/null || echo 0)"
  MISSING=""
  [ "$MT" -ge "$M0" ] || MISSING="no coordinator claimed the seat today"
  [ "$WIN" -ge "$M0" ] || MISSING="${MISSING:+$MISSING; }no morning ritual was stamped today ($SDIR/morning-ritual/window)"
  [ -z "$MISSING" ] && { echo "morning-t3 --check: claimed and ritual stamped today"; exit 0; }
  if [ "$SD" = "$TODAY" ]; then TRIG="the trigger's state today: $SS"
  else TRIG="the trigger did not run today"; fi
  fail "morning coordinator MISSING" "$MISSING; $TRIG" \
       "open T3 and look for today's morning thread (a usage limit or a refused claim stops it there); start a new one: $RERUN_T"
fi

# ---------------------------------------------------------------------------------- trigger --
[ -n "$CAUSE" ] && rm -f "$CAUSE"        # a cause left from an earlier failure is not this run's
command -v curl >/dev/null || fail "morning thread FAILED" "curl is not on PATH" "set Environment=PATH= in the unit"
command -v claude >/dev/null || fail "morning thread FAILED" "claude is not on PATH (the limit probe)" "set Environment=PATH= in the unit"
command -v timeout >/dev/null || fail "morning thread FAILED" "timeout (coreutils) is not on PATH" "set Environment=PATH= in the unit"

UF="$(cfg '.morningTaskUrlFile // "~/.config/t3-threads/morning-task-url"')"
case "$UF" in "~/"*) UF="$HOME/${UF#\~/}" ;; esac
[ -f "$UF" ] || fail "morning thread FAILED" "no webhook URL file $UF" \
  "create the T3 webhook task (/middle-management-setup step 7b) and store its URL there, mode 600"
case "$(stat -c %a "$UF" 2>/dev/null)" in 600|400) ;; *)
  fail "morning thread FAILED" "the webhook URL file $UF is readable by others (it is a key into a full-access thread)" "chmod 600 $UF" ;;
esac
URL="$(head -c 4096 "$UF" | tr -d '[:space:]')"
printf '%s' "$URL" | grep -Eq '^https?://[^"\\[:space:]]+$' \
  || fail "morning thread FAILED" "$UF holds no usable http(s) URL" "store the webhook URL of the T3 morning task there"

# The standing word first: without it the thread could only be refused (and sit there all morning).
[ "$(cfg 'if (.morningTakeover | type) == "object" and .morningTakeover.allowed == true then "yes" else "no" end')" = yes ] \
  || fail "morning thread NOT started" "the morning trigger is armed, but the config has no takeover word (morningTakeover.allowed is not true), so the thread could not take the seat" \
          "/middle-management-setup item 16b, or disarm: systemctl --user disable --now orch-morning-t3.timer orch-morning-watchdog.timer"

WAIT_UNTIL="${MM_MORNING_WAIT_UNTIL:-$(cfg '.morningWaitUntil // "09:30"')}"
DEADLINE="$(date -d "$TODAY $WAIT_UNTIL" +%s 2>/dev/null)" \
  || fail "morning thread FAILED" "morningWaitUntil \"$WAIT_UNTIL\" is no time of day" "HH:MM in the config"
RETRY="${MM_MORNING_RETRY_SEC:-600}"; PROBE_SEC="${MM_MORNING_PROBE_SEC:-60}"
HOLDER0="$(head -1 "$MARKER" 2>/dev/null)"

probe() {  # PROBE = free | limited | unclear (+ WHY)
  local out rc
  # The CLI reads ~/.claude.json only while CLAUDE_CONFIG_DIR is unset (morning-headless.sh, same fix).
  out="$(cd "$STATE" && { [ "${CLAUDE_CONFIG_DIR:-}" = "$HOME/.claude" ] && unset CLAUDE_CONFIG_DIR; :; } \
         && CLAUDE_CODE_MAX_RETRIES=2 timeout -k 5 "$PROBE_SEC" claude -p ok --output-format json \
            --no-session-persistence --strict-mcp-config --tools "" --setting-sources "" \
            ${MM_MORNING_MODEL:+--model "$MM_MORNING_MODEL"} </dev/null 2>&1)"; rc=$?
  WHY=""
  if [ "$rc" -eq 0 ] && [ "$(jq -r '.is_error | tostring' <<<"$out" 2>/dev/null)" = false ]; then PROBE=free
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then PROBE=limited; WHY="no answer within ${PROBE_SEC}s"
  elif grep -qiE 'usage limit|hit your ([a-z]+ )?limit|limit reached|out of (extra )?usage|"api_error_status": ?429|rate_limit' <<<"$out"; then
    PROBE=limited; WHY="usage limit"
  else PROBE=unclear; WHY="$(head -c 160 <<<"$out" | tr '\n' ' ')"; fi
}

WAITED=""; SLEEPER=""
trap '[ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; setstatus cancelled; echo "morning-t3: stopped by hand" >&2; exit 1' TERM
while :; do
  probe
  [ "$PROBE" = limited ] || break
  NOW="$(date +%s)"
  if [ "$NOW" -ge "$DEADLINE" ]; then
    setstatus cancelled
    notify "[$HOST] morning thread cancelled today: the account is still usage-limited at $WAIT_UNTIL ($WHY). Start it by hand later, with a later deadline: $LATE" \
      || fail "morning thread cancelled" "usage limit until $WAIT_UNTIL, and the notice could not be sent" "once the limit is over: $LATE"
    echo "morning-t3: cancelled, usage limit until the deadline $WAIT_UNTIL"
    exit 0
  fi
  if [ -z "$WAITED" ]; then
    WAITED=1
    notify "[$HOST] morning thread waits: the account is usage-limited ($WHY). Probing every $((RETRY / 60)) min until $WAIT_UNTIL." \
      || echo "morning-t3: the wait notice could not be sent" >&2
  fi
  setstatus waiting
  S=$RETRY; [ "$S" -gt $((DEADLINE - NOW)) ] && S=$((DEADLINE - NOW)); [ "$S" -lt 1 ] && S=1
  echo "morning-t3: usage limit ($WHY), next probe in ${S}s"
  sleep "$S" & SLEEPER=$!; wait "$SLEEPER"; SLEEPER=""
done
trap - TERM
if [ -n "$WAITED" ]; then
  H1="$(head -1 "$MARKER" 2>/dev/null)"
  if [ "$H1" != "$HOLDER0" ] && [ -n "$H1" ]; then
    setstatus cancelled
    notify "[$HOST] morning thread not started: the coordinator seat changed hands while it waited; the ritual runs there." \
      || fail "morning thread cancelled" "the seat changed hands during the wait, and the notice could not be sent" "nothing to do"
    echo "morning-t3: cancelled, the seat changed hands during the wait"
    exit 0
  fi
  if [ "$PROBE" = free ]; then
    notify "[$HOST] account free again ($(date +%H:%M)): starting the morning thread." || true
  else
    notify "[$HOST] morning thread: the limit probe is unclear ($WHY); starting it anyway." || true
  fi
fi
[ "$PROBE" = unclear ] && echo "morning-t3: limit probe unclear ($WHY), starting anyway" >&2

# The POST. Local before cloud: the relay URL https://relay.t3.codes/v1/hooks/<env>/<task>/<token>
# has the local twin <t3Url>/api/hooks/<task>/<token> (t3-wake.sh, proven 2026-10-20).
BASE="$(cfg '.t3Url // ""')"; [ -n "$BASE" ] || BASE="http://127.0.0.1:${T3CODE_PORT:-8470}"
LOCAL=""
RELAY="${MM_MORNING_RELAY_PREFIX:-https://relay.t3.codes/v1/hooks/}"   # test seam: a local stand-in for the relay
case $URL in
  "$RELAY"*/*/*) R=${URL#"$RELAY"}; LOCAL="${BASE%/}/api/hooks/${R#*/}" ;;
esac
BODY="$(jq -cn --arg d "$TODAY" '{from: "morning-t3", date: $d}')"
post() {  # $1 = url; prints "<HTTP code> <connect seconds>"; the URL is in no argv (printf is a builtin)
  curl -sS --connect-timeout 5 -m "${MM_MORNING_POST_TIMEOUT:-20}" -o /dev/null -w '%{http_code} %{time_connect}' \
    -K <(printf 'url = "%s"\n' "$1") -H 'content-type: application/json' --data-binary @- <<<"$BODY" 2>/dev/null
}
# The relay after the local twin only when the twin cannot have started a thread: it could not be
# reached at all, or it answered 404/405 (no such route here; the twin path is not verified live).
# Any other answer from a reached twin (5xx, a read timeout) may have started one already, and a
# second POST would start a second thread.
CODE=""; WHERE=configured
if [ -n "$LOCAL" ]; then
  read -r CODE TC <<<"$(post "$LOCAL")"; WHERE=local
  if [ "$CODE" = 404 ] || [ "$CODE" = 405 ] \
     || { [ "$CODE" != 202 ] && awk -v t="${TC:-0}" 'BEGIN { exit !(t + 0 == 0) }'; }; then LOCAL=""; fi
fi
[ -z "$LOCAL" ] && { read -r CODE _ <<<"$(post "$URL")"; WHERE=configured; }
[ "$CODE" = 202 ] || fail "morning thread NOT started" "the T3 webhook task answered HTTP ${CODE:-000} via the $WHERE URL (expected 202)" \
  "is t3code running and the task still there (list_scheduled_tasks)? Then: $RERUN"
setstatus posted
echo "morning-t3: morning thread started (HTTP 202)${WAITED:+ after a usage-limit wait}"
