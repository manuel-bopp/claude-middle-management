#!/usr/bin/env bash
# middle-management plugin — the coordinator's morning ritual as an unattended `claude -p` run.
# Consumers: templates/systemd/orch-morning-ritual.service (started by orch-morning-ritual.timer;
#   /middle-management-setup step 7 copies this script next to config-check.sh, open-items.py,
#   peer-state.py, scope.py and unit-failure-alarm.sh), manual runs, tests/morning-headless.sh.
#   With a "scopes" key it serves the DEFAULT scope only (README "Scopes"): it runs in no session,
#   so open-items.py todo resolves to the default scope's board and drop files.
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
#     --max-budget-usd and a hard `timeout`, read-only. Its final message is the day plan; this
#     script sends it, marks the to-dos whose keys it carries as delivered and stamps the window.
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
#   MM_MORNING_PERMISSION_MODE default: the CLI's. The report needs no tool; the ritual's reads
#                              (Bash: git, gh, open-items.py) need your settings.json allow rules
#                              or a mode set here — unattended, anything else is refused
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
#                 TimeoutStartSec= drops to MM_MORNING_TIMEOUT_MIN + 10 min (the model run fails on
#                 its own first; the fetch of each protected checkout takes up to 1 min more);
#                 Environment=MM_MORNING_UNIT=%n and Environment=MM_MORNING_FALLBACK_ENV=<that file>
#                 are new; OnFailure= becomes unit-failure-alarm@%n.service if it pointed at a site
#                 alarm (only the plugin's alarm reads the cause file); Environment=PATH= must find
#                 claude, git, jq, python3 and timeout; the timer keeps its OnCalendar=.
#   drops out     its own gather step, proxy wrap / seat release / poke (claim does that now, issue
#                 #1), its own watchdog and journal-dump alarm, its runs log.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG_DIR="$(bash "$HERE/config-check.sh" dir)"
CFG_FILE="$(bash "$HERE/config-check.sh" file)"
SESSION_LOG="$(bash "$HERE/config-check.sh" session-log)"
# The unit sets CLAUDE_CONFIG_DIR for the helpers, but the CLI reads its global config from
# $CLAUDE_CONFIG_DIR/.claude.json when it is set and from ~/.claude.json when not: the default dir
# must stay unset for claude, or the probe tests a stale copy instead of the user's real login.
[ "${CLAUDE_CONFIG_DIR:-}" = "$HOME/.claude" ] && unset CLAUDE_CONFIG_DIR
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
  elif grep -qiE '(^|[^0-9a-z.])429([^0-9a-z]|$)|rate_limit|rate limit|usage limit|hit your ([a-z]+ )?(spend )?limit|limit reached' <<<"$t"; then echo 429
  elif grep -qiE '(^|[^0-9a-z.])401([^0-9a-z]|$)|authentication_error|unauthorized|invalid api key|/login|token (has )?expired|token is invalid|revoked' <<<"$t"; then echo 401
  else echo other; fi
}

said() {  # a probe cause in words; `other` carries the CLI's own first line
  case "$1" in
    timeout) echo "no answer within ${PROBE_SEC}s (a rate-limited login retries and hangs)" ;;
    other)   echo "other: $(head -c 160 "$STATE/probe.out" 2>/dev/null | tr '\n' ' ')" ;;
    *)       echo "$1" ;;
  esac
}

probe() {  # sets PROBE to ok or a cause word
  local rc
  # Same model as the run (limits are per model family too); two retries, so a 429 comes back as a
  # 429 within seconds instead of a backoff loop; no MCP servers on the probe's clock.
  ( cd "$STATE" && CLAUDE_CODE_MAX_RETRIES=2 timeout -k 5 "$PROBE_SEC" claude -p "OK" --max-turns 1 \
      --strict-mcp-config ${MM_MORNING_MODEL:+--model "$MM_MORNING_MODEL"} </dev/null ) > "$STATE/probe.out" 2>&1; rc=$?
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
  B="$(cfg '.board // ""')"; B="${B/#\~/$HOME}"
  for p in "$SESSION_LOG" "$B" "$CFG_DIR/open-items" ${MM_MORNING_WATCH:-}; do
    [ -n "$p" ] && [ -e "$p" ] || continue
    # a find that fails (no GNU -newermt) counts as progress: never a silent "no progress" every day
    hit="$(find -L "$p" -newermt "@$W" -print -quit 2>/dev/null)" || hit="find failed"
    [ -n "$hit" ] && { moved="$p"; break; }
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
  while IFS='=' read -r k v || [ -n "$k" ]; do          # a last line without newline counts too
    k="${k#export }"; v="${v%$'\r'}"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
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
PROMPT="You are the unattended stand-in for the coordinator, started by the middle-management plugin's scripts/morning-headless.sh: the session-role banner does not apply to this run. Run the middle-management:morning-ritual skill. Nobody is at the keyboard and nobody can answer.
Window: since $SINCE.
Limits of this run: read and report only. Write no file at all (no board, no session log), kill and delete nothing, push nothing, message no session, send nothing outward: this script sends your report. Step 3 backfills, step 4 filings and step 5 clean-ups become lines in the report for the coordinator.
Step 6: its input is already gathered in $RUN/todo.txt (the output of open-items.py todo); group it as the step says and end every to-do line with its key. What does not fit becomes one line \"+N more: open-items.py todo --all\". Do NOT run todo --delivered and do not stamp the window: this script marks exactly the keys your report carries.
Step 7: your final message is the day plan, step 6 included, plain text of at most 3500 characters, and nothing else."
( cd "$RUN" && timeout -k 30 "${TMO_MIN}m" claude -p "$PROMPT" --output-format json \
    --max-budget-usd "$BUDGET" ${MM_MORNING_MODEL:+--model "$MM_MORNING_MODEL"} \
    ${MM_MORNING_PERMISSION_MODE:+--permission-mode "$MM_MORNING_PERMISSION_MODE"} \
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
# The report is the run's final message (.result): no Write call, so the CLI's default permission
# mode is enough for it.
jq -r '.result // empty' "$RUN/claude.json" 2>/dev/null > "$REPORT"
grep -q '[^[:space:]]' "$REPORT" || fail other "the ritual run ended without a day plan in its final message (output in $RUN; tool calls your settings do not allow are refused unattended: MM_MORNING_PERMISSION_MODE)"
# Last guard before the channel: the fallback credential sits in the run's environment.
if grep -qE 'sk-ant-[A-Za-z0-9_-]{8,}|(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)=[^ ]' "$REPORT" \
   || { [ -n "${ANTHROPIC_API_KEY:-}" ] && grep -qF -- "$ANTHROPIC_API_KEY" "$REPORT"; } \
   || { [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && grep -qF -- "$CLAUDE_CODE_OAUTH_TOKEN" "$REPORT"; }; then
  fail other "the report contains a secret-looking string and was NOT sent ($REPORT)"
fi
SENT="$(cat "$REPORT")"
[ "$(wc -c < "$REPORT")" -le 3800 ] || SENT="$(head -c 3800 "$REPORT" | sed '$d')"   # whole lines only
notify "$SENT" || fail other "the report could not be sent through notifyCommand (it is in $REPORT)"
# Delivered = what reached your user: only the keys the sent text carries.
KEYS="$(for k in $(sed -n 's/.* todo --delivered //p' "$RUN/todo.txt" | tail -1); do
          case "$SENT" in *"$k"*) printf '%s ' "$k" ;; esac; done)"
# shellcheck disable=SC2086  # the keys are one word each by construction
[ -z "$KEYS" ] || python3 "$HERE/open-items.py" todo --delivered $KEYS >/dev/null \
  || echo "morning-headless: to-dos sent but not marked delivered: $KEYS" >&2
date +%s > "$WINDOW_FILE"
echo "morning-headless: report sent ($REPORT), cost $(jq -r '.total_cost_usd // "?"' "$RUN/claude.json") USD${FELL_BACK:+, auth fallback$FELL_BACK}"
