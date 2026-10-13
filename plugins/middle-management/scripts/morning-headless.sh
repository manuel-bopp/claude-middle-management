#!/usr/bin/env bash
# middle-management plugin — the coordinator's morning ritual as an unattended `claude -p` run.
# Consumers: templates/systemd/orch-morning-ritual.service (started by orch-morning-ritual.timer;
#   /middle-management-setup step 7 copies this script next to config-check.sh, open-items.py,
#   peer-state.py and unit-failure-alarm.sh), manual runs, tests/morning-headless.sh.
#   Calls config-check.sh (paths), open-items.py (todo, todo --delivered), the notifyCommand config
#   key (every message it sends); leaves the cause file unit-failure-alarm.sh sends on failure.
#
# In order:
#  1. Empty window: the session log, the board, the open-items drops, the commits of every
#     protectedCheckouts repo and $MM_MORNING_WATCH unchanged since the last delivered ritual ->
#     one line "no progress since <date>" through notifyCommand, NO model run, exit 0.
#  2. Probe: `claude -p OK --max-turns 1` under `timeout`. 429 / 401 / no answer (a rate-limited
#     account retries with backoff and simply hangs) -> load ANTHROPIC_API_KEY or
#     CLAUDE_CODE_OAUTH_TOKEN from $MM_MORNING_FALLBACK_ENV and probe once more. Names only: no
#     value is ever printed or logged.
#  3. The ritual (middle-management:morning-ritual, its to-do step 6 included), bounded twice:
#     --max-budget-usd and a hard `timeout`. The model writes the day plan to a file; this script
#     sends it, marks the to-dos delivered and stamps the window.
#  4. Failure: a headline, the cause (429 / 401 / timeout / budget / other) and the one fix
#     command, to stderr and to <config dir>/state/unit-failure-alarm/<unit>.cause, which the
#     OnFailure= alarm sends INSTEAD of the journal tail. Exit 1.
#
# Env (all optional; the unit template sets MM_MORNING_UNIT=%n):
#   MM_MORNING_UNIT            this unit's name; unset (a manual run) = no cause file
#   MM_MORNING_FALLBACK_ENV    env file (KEY=value lines, mode 600) with ANTHROPIC_API_KEY and/or
#                              CLAUDE_CODE_OAUTH_TOKEN; read ONLY after a failed probe
#   MM_MORNING_MAX_BUDGET_USD  default 3     MM_MORNING_TIMEOUT_MIN  default 20
#   MM_MORNING_PROBE_SEC       default 25    MM_MORNING_MODEL        default: the CLI's
#   MM_MORNING_PERMISSION_MODE default: the CLI's. The run needs Bash (git, open-items.py) and
#                              file writes: allow them in settings.json or set e.g. bypassPermissions
#   MM_MORNING_WATCH           more files/dirs whose change counts as progress (space-separated),
#                              e.g. the inbox your team's chat bridge writes
#   MM_MORNING_FORCE=1         run the model even when the window is empty
# Paths come from the plugin config, never from here: config dir (CLAUDE_CONFIG_DIR, else
# ~/.claude), sessionLog, board, protectedCheckouts[].root, notifyCommand. State:
# <config dir>/state/morning-ritual/ (window = epoch of the last delivered ritual, runs/<stamp>/).
#
# Porting a site-local runner (e.g. one that wraps `claude -p` with its own paths and sender) onto
# this one — mechanical, nothing else to carry over:
#   config keys   its board path -> "board", its session log -> "sessionLog", the repos it fetches
#                 -> "protectedCheckouts"[].root, its own sender (Telegram curl, bot script) ->
#                 "notifyCommand" (message as $1 and on stdin). All in <config dir>/middle-management.json.
#   env file      a 429/401 fallback credential goes into a mode-600 file of KEY=value lines,
#                 ANTHROPIC_API_KEY=… or CLAUDE_CODE_OAUTH_TOKEN=… (from `claude setup-token` of a
#                 second account); never into the unit itself.
#   env names     its budget variable -> MM_MORNING_MAX_BUDGET_USD, its --model -> MM_MORNING_MODEL,
#                 its --permission-mode -> MM_MORNING_PERMISSION_MODE, extra inputs it watched ->
#                 MM_MORNING_WATCH, its dry-run/force switches -> MM_MORNING_FORCE=1.
#   unit lines    ExecStart= points at the installed copy of this script (no arguments);
#                 TimeoutStartSec= drops to MM_MORNING_TIMEOUT_MIN + 5 min (the model run fails on
#                 its own first); Environment=MM_MORNING_UNIT=%n and
#                 Environment=MM_MORNING_FALLBACK_ENV=<that file> are new; OnFailure= stays
#                 unit-failure-alarm@%n.service; Environment=PATH= must find claude, git, jq,
#                 python3 and timeout; the timer keeps its OnCalendar=.
#   drops out     its own gather step, proxy wrap / seat release / poke (claim does that now, issue
#                 #1), its own watchdog and journal-dump alarm, its runs log.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG_DIR="$(bash "$HERE/config-check.sh" dir)"
CFG_FILE="$(bash "$HERE/config-check.sh" file)"
SESSION_LOG="$(bash "$HERE/config-check.sh" session-log)"
STATE="$CFG_DIR/state/morning-ritual"
WINDOW_FILE="$STATE/window"
UNIT="${MM_MORNING_UNIT:-}"
CAUSE=""
[ -n "$UNIT" ] && CAUSE="$CFG_DIR/state/unit-failure-alarm/$(printf '%s' "$UNIT" | tr -c 'A-Za-z0-9._-' '_').cause"
FALLBACK="${MM_MORNING_FALLBACK_ENV:-}"
BUDGET="${MM_MORNING_MAX_BUDGET_USD:-3}"
TMO_MIN="${MM_MORNING_TIMEOUT_MIN:-20}"
PROBE_SEC="${MM_MORNING_PROBE_SEC:-25}"
RERUN="systemctl --user start ${UNIT:-orch-morning-ritual.service}"
HOST="$(hostname -s 2>/dev/null || echo host)"
FELL_BACK=""
PHASE=probe

cfg() { jq -r "$1" "$CFG_FILE" 2>/dev/null; }

notify() {  # $1 = text; the same contract as unit-failure-alarm.sh and the heartbeat
  local cmd; cmd="$(cfg '.notifyCommand // ""')"
  [ -n "$cmd" ] || return 2
  # Output discarded: a failing sender may echo a URL that carries its token.
  printf '%s\n' "$1" | sh -c "$cmd" notify "$1" >/dev/null 2>&1
}

fail() {  # $1 = cause word, $2 = what happened
  local fix cause="$1" log="journalctl --user -u ${UNIT:-orch-morning-ritual.service} -n 50"
  # A probe that does not answer is what a rate-limited login looks like (the CLI retries its 429
  # with backoff), so its fix is the 429 one; a ritual run that does not finish is a different story.
  [ "$cause:$PHASE" = timeout:probe ] && cause=429
  case "$cause" in
    429)     if [ -n "$FELL_BACK" ]; then fix="the fallback is limited too: wait for the reset or put another account's credential into $FALLBACK, then: $RERUN"
             else fix="put ANTHROPIC_API_KEY=… or CLAUDE_CODE_OAUTH_TOKEN=… into a mode-600 file named by MM_MORNING_FALLBACK_ENV in the unit, then: $RERUN"; fi ;;
    401)     fix="log in again as this user (claude, then /login) or renew the credential in ${FALLBACK:-the MM_MORNING_FALLBACK_ENV file}, then: $RERUN" ;;
    timeout) fix="$log   (a run that is only long: raise MM_MORNING_TIMEOUT_MIN, now $TMO_MIN)" ;;
    budget)  fix="raise MM_MORNING_MAX_BUDGET_USD in the unit (now $BUDGET), then: $RERUN" ;;
    *)       fix="$log" ;;
  esac
  local text="[$HOST] morning ritual FAILED: $1${UNIT:+ ($UNIT)}
Cause: $2
Fix: $fix"
  printf '%s\n' "$text" >&2
  if [ -n "$CAUSE" ]; then mkdir -p "$(dirname "$CAUSE")" && printf '%s\n' "$text" > "$CAUSE"; fi
  exit 1
}

classify() {  # $1 = exit code, $2 = file with the CLI's output -> 429 | 401 | timeout | budget | other
  case "$1" in 124|137) echo timeout; return ;; esac
  # The status codes only as whole tokens: a cost of 0.0429 or a sessionId with "c429f" is no 429.
  local t; t="$(head -c 20000 "$2" 2>/dev/null)"
  if   grep -qi 'error_max_budget' <<<"$t"; then echo budget
  elif grep -qiE '(^|[^0-9a-z.])429([^0-9a-z]|$)|rate_limit|rate limit|usage limit' <<<"$t"; then echo 429
  elif grep -qiE '(^|[^0-9a-z.])401([^0-9a-z]|$)|authentication_error|unauthorized|invalid api key|/login' <<<"$t"; then echo 401
  else echo other; fi
}

said() { if [ "$1" = timeout ]; then echo "no answer within ${PROBE_SEC}s (a rate-limited login retries and hangs)"; else echo "$1"; fi; }

probe() {  # sets PROBE to ok or a cause word
  local rc
  ( cd "$STATE" && timeout -k 5 "$PROBE_SEC" claude -p "OK" --max-turns 1 </dev/null ) > "$STATE/probe.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then PROBE=ok; return 0; fi
  PROBE="$(classify "$rc" "$STATE/probe.out")"; return 1
}

mkdir -p "$STATE" || { echo "morning-headless: cannot create $STATE" >&2; exit 1; }
[ -n "$CAUSE" ] && rm -f "$CAUSE"        # a cause left from an earlier failure is not this run's
command -v jq >/dev/null || fail other "jq is not installed"
command -v claude >/dev/null || fail other "claude is not on PATH (set Environment=PATH= in the unit)"
command -v timeout >/dev/null || fail other "timeout (coreutils) is not on PATH"
[ -n "$(cfg '.notifyCommand // ""')" ] || fail other "no notifyCommand in $CFG_FILE, so no report could reach anyone"

# 1. Empty window. Without a window file (first run) there is nothing to compare: run.
W="$(cat "$WINDOW_FILE" 2>/dev/null)"; case "$W" in ''|*[!0-9]*) W="" ;; esac
SINCE="yesterday evening (no earlier delivered ritual on record)"
[ -n "$W" ] && SINCE="$(date -d "@$W" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "@$W")"
if [ -n "$W" ] && [ "${MM_MORNING_FORCE:-}" != 1 ]; then
  moved=""
  # shellcheck disable=SC2086  # MM_MORNING_WATCH is a space-separated list on purpose
  for p in "$SESSION_LOG" "$(cfg '.board // ""')" "$CFG_DIR/open-items" ${MM_MORNING_WATCH:-}; do
    [ -n "$p" ] && [ -e "$p" ] || continue
    [ -n "$(find -L "$p" -newermt "@$W" -print -quit 2>/dev/null)" ] && { moved="$p"; break; }
  done
  if [ -z "$moved" ]; then
    while IFS= read -r r; do
      [ -d "$r" ] || continue
      timeout 60 git -C "$r" fetch -q --all >/dev/null 2>&1   # best effort: a remote that moved is progress too
      [ -n "$(git -C "$r" log --all --since="@$W" -1 --format=%h 2>/dev/null)" ] && { moved="$r"; break; }
    done < <(cfg '.protectedCheckouts[]?.root // empty')
  fi
  if [ -z "$moved" ]; then
    notify "[$HOST] morning ritual: no progress since $SINCE (no session-log entry, board change, open item, repo change or watched file) — no model run." \
      || fail other "the \"no progress\" line could not be sent through notifyCommand"
    echo "morning-headless: window empty since $SINCE, no model run"
    exit 0
  fi
  echo "morning-headless: progress since $SINCE ($moved)"
fi

# 2. Probe, then the fallback credential once.
if ! probe; then
  FIRST="$PROBE"
  [ -n "$FALLBACK" ] || fail "$FIRST" "probe: $(said "$FIRST"); no fallback configured (MM_MORNING_FALLBACK_ENV)"
  [ -r "$FALLBACK" ] || fail "$FIRST" "probe: $(said "$FIRST"); the fallback file $FALLBACK is not readable"
  # KEY=value lines, read and never executed; only the two names, never echoed.
  while IFS='=' read -r k v; do
    k="${k#export }"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    case "$k" in ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN) [ -n "$v" ] && export "$k=$v" && FELL_BACK="$FELL_BACK $k" ;; esac
  done < "$FALLBACK"
  [ -n "$FELL_BACK" ] || fail "$FIRST" "probe: $(said "$FIRST"); $FALLBACK sets neither ANTHROPIC_API_KEY nor CLAUDE_CODE_OAUTH_TOKEN"
  echo "morning-headless: probe: $(said "$FIRST"); retrying with$FELL_BACK from $FALLBACK"
  probe || fail "$PROBE" "probe: $(said "$FIRST"); with$FELL_BACK from $FALLBACK: $(said "$PROBE")"
fi

# 3. The ritual.
PHASE=run
RUN="$STATE/runs/$(date +%Y-%m-%d-%H%M%S)"; mkdir -p "$RUN" || fail other "cannot create $RUN"
find "$STATE/runs" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>/dev/null
python3 "$HERE/open-items.py" todo > "$RUN/todo.txt" 2>&1 || echo "open-items.py todo failed, see $RUN/todo.txt" >&2
REPORT="$RUN/report.txt"
PROMPT="Run the middle-management:morning-ritual skill headless. Nobody is at the keyboard and nobody can answer.
Window: since $SINCE.
Limits of this run: read, reconcile and report. No kills, no deletes, no pushes, no messages to other sessions and nothing sent outward: this script sends your report. Step 3 backfills and step 5 clean-ups become lines in the report instead of actions. Write the board only as step 4 says, and nothing into the session log.
Step 6: its input is already gathered in $RUN/todo.txt (the output of open-items.py todo); group it as the step says. Do NOT run todo --delivered and do not stamp the window: this script does both after sending.
Step 7: write the day plan, step 6 included, as plain text of at most 3500 characters to $REPORT and nothing else into that file."
( cd "$RUN" && timeout -k 30 "${TMO_MIN}m" claude -p "$PROMPT" --output-format json \
    --max-budget-usd "$BUDGET" ${MM_MORNING_MODEL:+--model "$MM_MORNING_MODEL"} \
    ${MM_MORNING_PERMISSION_MODE:+--permission-mode "$MM_MORNING_PERMISSION_MODE"} --add-dir "$RUN" \
    </dev/null ) > "$RUN/claude.json" 2> "$RUN/claude.err"
RC=$?
cat "$RUN/claude.json" "$RUN/claude.err" > "$RUN/claude.all" 2>/dev/null
# Not `.is_error // true`: jq's // treats an explicit false as missing.
if [ "$RC" -ne 0 ] || [ "$(jq -r '.is_error | tostring' "$RUN/claude.json" 2>/dev/null)" != false ]; then
  WHY="$(classify "$RC" "$RUN/claude.all")"
  case "$WHY" in
    timeout) fail timeout "the ritual run did not finish within $TMO_MIN min and was stopped" ;;
    budget)  fail budget "the ritual run hit --max-budget-usd $BUDGET" ;;
    *)       fail "$WHY" "the ritual run ended with exit $RC ($(jq -r '.subtype // empty' "$RUN/claude.json" 2>/dev/null | head -c 80)); output in $RUN" ;;
  esac
fi
[ -s "$REPORT" ] || fail other "the ritual run finished but wrote no report to $REPORT"
notify "$(head -c 3800 "$REPORT")" || fail other "the report could not be sent through notifyCommand (it is in $REPORT)"
KEYS="$(sed -n 's/.* todo --delivered //p' "$RUN/todo.txt" | tail -1)"
# shellcheck disable=SC2086  # the keys are one word each by construction
[ -z "$KEYS" ] || python3 "$HERE/open-items.py" todo --delivered $KEYS >/dev/null \
  || echo "morning-headless: to-dos sent but not marked delivered: $KEYS" >&2
date +%s > "$WINDOW_FILE"
echo "morning-headless: report sent ($REPORT), cost $(jq -r '.total_cost_usd // "?"' "$RUN/claude.json") USD${FELL_BACK:+, auth fallback$FELL_BACK}"
