#!/usr/bin/env bash
# middle-management plugin: scripts/morning-headless.sh against a stub `claude` on PATH (fake config
# dir, sends nothing: notifyCommand appends to a file).
# Consumers: tests/run.sh (folded into the main matrix); run by hand: bash tests/morning-headless.sh
# Covers: empty window -> "no progress" and no model run; 429 / 401 / hang probe -> fallback
# credential, never printed; run timeout / budget / other with the cause file the OnFailure alarm
# sends instead of the journal; report sent, to-dos marked delivered, window stamped; the templates.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/plugins/middle-management"
MH="$P/scripts/morning-headless.sh"
PASS=0; FAIL=0
TMPBASE="$(mktemp -d -t mm-morning.XXXXXX)"
trap 'case "$TMPBASE" in /tmp/*|/var/tmp/*) rm -rf "$TMPBASE" ;; esac' EXIT

say() { printf '%s\n' "$*"; }
ok()  { PASS=$((PASS+1)); say "  ok  - $1"; }
bad() { FAIL=$((FAIL+1)); say "  FAIL- $1"; [ -n "${2:-}" ] && say "        got: $2"; }
assert_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$3" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) bad "$1" "$3" ;; *) ok "$1" ;; esac; }
assert_rc()    { [ "$3" -eq "$2" ] && ok "$1" || bad "$1" "rc=$3 (want $2)"; }

# The stub: auth = which credential is in its environment; STUB_PRIMARY / STUB_FALLBACK decide how
# that credential is answered (ok | 429 | 401 | hang), STUB_RUN how the ritual run ends.
BIN="$TMPBASE/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if [ -n "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then auth=fallback; mode="${STUB_FALLBACK:-ok}"
else auth=primary; mode="${STUB_PRIMARY:-ok}"; fi
case "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" in *$'\r') mode=401 ;; esac   # a CRLF value is a bad key
kind=run; [ "${2:-}" = OK ] && kind=probe
printf '%s %s\n' "$kind" "$auth" >> "$STUB_LOG"
printf '%s\n' "$*" > "$STUB_LOG.$kind-args"
printf '%s\n' "${CLAUDE_CONFIG_DIR-unset}" > "$STUB_LOG.$kind-cfgdir"
case "$mode" in   # the CLI's own wording
  429)     echo 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your account'"'"'s rate limit"}}' >&2; exit 1 ;;
  limit)   echo "You've hit your limit · resets 3am (Europe/Berlin)"; exit 1 ;;
  401)     echo 'Invalid API key · Please run /login'; exit 1 ;;
  expired) echo 'OAuth token has expired. Please obtain a new token or refresh your existing token.'; exit 1 ;;
  weird)   echo 'Something unexpected happened in the CLI'; exit 1 ;;
  hang)    sleep 30; exit 0 ;;
esac
[ "$kind" = probe ] && { echo OK; exit 0; }
res() { jq -n --arg r "$1" '{type:"result",subtype:"success",is_error:false,total_cost_usd:0.12,result:$r}'; }
case "${STUB_RUN:-ok}" in
  hang)     sleep 30 ;;
  budget)   echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":3.0429}'; exit 1 ;;
  other)    echo '{"type":"result","subtype":"error_during_execution","is_error":true,"total_cost_usd":0.0429,"session_id":"c429f401-0000"}'; exit 1 ;;
  noreport) res "" ;;
  secret)   res "Day plan. env: ANTHROPIC_API_KEY=sk-ant-api03-LEAKEDVALUE" ;;
  long)     res "$(python3 -c "print('\\n'.join('ü'*60 for _ in range(60)))")" ;;
  partial)  res "$(printf 'Day plan for today\n%s\n+1 more: open-items.py todo --all' "$(grep '^- ' todo.txt | head -1)")" ;;
  *)        res "$(printf 'Day plan for today\n%s' "$(grep '^- ' todo.txt)")" ;;
esac
STUB
chmod +x "$BIN/claude"

setup() {  # fresh config dir, notify sink, stub log; $1 = extra JSON for the config (optional)
  C="$(mktemp -d -p "$TMPBASE")"; NOTE="$C/notified"; export STUB_LOG="$C/stub.log"
  mkdir -p "$C/logs" "$C/sessions"; : > "$C/logs/session-log.md"; : > "$STUB_LOG"
  jq -n --arg n "printf '%s\\n---\\n' \"\$1\" >> $NOTE" --arg l "$C/logs/session-log.md" --arg b "$C/board.md" \
    "{notifyCommand:\$n, sessionLog:\$l, board:\$b} + ${1:-{\}}" > "$C/middle-management.json"
  printf '# board\n' > "$C/board.md"
  unset STUB_PRIMARY STUB_FALLBACK STUB_RUN
}
run() { env PATH="$BIN:$PATH" CLAUDE_CONFIG_DIR="$C" MM_SESSION_LOG="" MM_MORNING_PROBE_SEC="${PSEC:-5}" \
          MM_MORNING_UNIT=orch-morning-ritual.service "$@" bash "$MH" 2>&1; }   # $@ = more VAR=value
CAUSEF() { cat "$C/state/unit-failure-alarm/orch-morning-ritual.service.cause" 2>/dev/null; }
age() { find "$C" -mindepth 1 -exec touch -d "2 hours ago" {} +; }   # everything older than a window of now
stamp() { mkdir -p "$C/state/morning-ritual"; date -d "1 hour ago" +%s > "$C/state/morning-ritual/window"; }

say "== first run: probe, ritual, report sent, to-dos delivered, window stamped =="
setup
SID=aaaaaaaa-1111-4000-8000-000000000001
CLAUDE_CONFIG_DIR="$C" CLAUDE_CODE_SESSION_ID="$SID" python3 "$P/scripts/open-items.py" add --owner user "Decide the keep-alive default" >/dev/null
OUT="$(run)"; RC=$?
assert_rc "a healthy run exits 0" 0 "$RC"
assert_has "the probe ran first, then the ritual" "$(printf 'probe primary\nrun primary')" "$(cat "$STUB_LOG")"
ARGS="$(cat "$STUB_LOG.run-args")"
assert_has "the run invokes the morning-ritual skill" "middle-management:morning-ritual" "$ARGS"
assert_has "...with the to-do step's gathered input" "todo.txt" "$ARGS"
assert_has "...bounded by --max-budget-usd (default 3)" "--max-budget-usd 3" "$ARGS"
assert_has "the report went out through notifyCommand" "Day plan for today" "$(cat "$C/notified")"
assert_has "...with the to-do the run was given, key included" "- aaaaaaaa-W1 · Decide the keep-alive default" "$(cat "$C/notified")"
assert_lacks "the run is not told to write files (r1 m6: the report is its final message)" "--add-dir" "$ARGS"
assert_has "the to-do is marked delivered" "aaaaaaaa-W1" "$(cat "$C/state/morning-ritual/delivered" 2>/dev/null)"
[ -s "$C/state/morning-ritual/window" ] && ok "the window is stamped" || bad "the window is stamped"
assert_has "the run says what it cost" "cost 0.12 USD" "$OUT"

say "== empty window: one line, no model run =="
setup; age; stamp
OUT="$(run)"; RC=$?
assert_rc "nothing moved -> exit 0" 0 "$RC"
assert_has "one 'no progress since' line was sent" "morning ritual: no progress since $(date -d "1 hour ago" '+%Y-%m-%d %H:%M')" "$(cat "$C/notified")"
[ -s "$STUB_LOG" ] && bad "no claude call at all, not even the probe" "$(cat "$STUB_LOG")" || ok "no claude call at all, not even the probe"
W0="$(cat "$C/state/morning-ritual/window")"
OUT="$(run)"
[ "$(cat "$C/state/morning-ritual/window")" = "$W0" ] && ok "the window keeps its date, so 'since' stays honest" || bad "window unchanged on an empty run"
OUT="$(run MM_MORNING_FORCE=1)"; RC=$?
assert_rc "MM_MORNING_FORCE=1 runs anyway" 0 "$RC"
assert_has "...through the model" "run primary" "$(cat "$STUB_LOG")"

for what in session-log board drop watch repo; do
  setup; age; stamp; extra=()
  case "$what" in
    session-log) printf '### 07:00 – [x] – y\n' >> "$C/logs/session-log.md" ;;
    board)       printf -- '- moved\n' >> "$C/board.md" ;;
    drop)        mkdir -p "$C/open-items"; printf -- '- W1 · owner: lane · x\n' > "$C/open-items/bbbbbbbb-session-notes.md" ;;
    watch)       : > "$C/inbox"; extra=(MM_MORNING_WATCH="$C/nothing $C/inbox") ;;
    repo)        R="$C/repo"; git init -q "$R"; git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m new
                 jq --arg r "$R" '.protectedCheckouts=[{name:"r",root:$r,base:"main"}]' "$C/middle-management.json" > "$C/j" && mv "$C/j" "$C/middle-management.json"
                 touch -d "2 hours ago" "$C/middle-management.json" ;;
  esac
  OUT="$(run "${extra[@]}")"
  assert_has "a change in the $what is progress -> the ritual runs" "run primary" "$(cat "$STUB_LOG")"
done
setup; R="$C/repo"; git init -q "$R"
GIT_COMMITTER_DATE="$(date -d '3 hours ago' -R)" git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m old
jq --arg r "$R" '.protectedCheckouts=[{name:"r",root:$r,base:"main"}]' "$C/middle-management.json" > "$C/j" && mv "$C/j" "$C/middle-management.json"
age; stamp
OUT="$(run)"
[ -s "$STUB_LOG" ] && bad "a commit older than the window is no progress" "$(cat "$STUB_LOG")" || ok "a commit older than the window is no progress"

say "== probe: 429 / 401 / hang switch to the fallback credential, names only =="
SECRET="sk-ant-api03-TESTSECRETVALUE"
setup; printf 'ANTHROPIC_API_KEY="%s"\n' "$SECRET" > "$C/fallback.env"; chmod 600 "$C/fallback.env"
OUT="$(STUB_PRIMARY=429 run MM_MORNING_FALLBACK_ENV="$C/fallback.env")"; RC=$?
assert_rc "429 on the primary login, fallback key works -> exit 0" 0 "$RC"
assert_has "probe primary, probe fallback, run fallback" "$(printf 'probe primary\nprobe fallback\nrun fallback')" "$(cat "$STUB_LOG")"
assert_has "the switch is announced by name" "retrying with ANTHROPIC_API_KEY from $C/fallback.env" "$OUT"
assert_has "the run notes the fallback by name" "auth fallback ANTHROPIC_API_KEY" "$OUT"
assert_lacks "the key value is never printed" "TESTSECRETVALUE" "$OUT$(cat "$C/notified")$(CAUSEF)"
setup; printf 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-TESTSECRETTOKEN\n' > "$C/fallback.env"
OUT="$(STUB_PRIMARY=401 run MM_MORNING_FALLBACK_ENV="$C/fallback.env")"; RC=$?
assert_rc "401 on the primary login, second account's token works -> exit 0" 0 "$RC"
assert_has "...switched to the token by name" "retrying with CLAUDE_CODE_OAUTH_TOKEN" "$OUT"
assert_lacks "...whose value is never printed" "TESTSECRETTOKEN" "$OUT"
setup; printf 'ANTHROPIC_API_KEY=%s\n' "$SECRET" > "$C/fallback.env"
START=$(date +%s)
OUT="$(PSEC=2 STUB_PRIMARY=hang run MM_MORNING_FALLBACK_ENV="$C/fallback.env")"; RC=$?
assert_rc "a hanging probe (429 retry loop) -> fallback -> exit 0" 0 "$RC"
[ $(( $(date +%s) - START )) -lt 20 ] && ok "...decided within seconds, not after the hang" || bad "hang decided fast" "$(( $(date +%s) - START ))s"
assert_has "...naming the hang" "no answer within 2s" "$OUT"

say "== failures: one headline, the cause, the fix — in a cause file the alarm sends =="
setup
OUT="$(STUB_PRIMARY=429 run)"; RC=$?
assert_rc "429 and no fallback -> exit 1" 1 "$RC"
assert_has "the headline names the cause" "morning ritual FAILED: 429 (orch-morning-ritual.service)" "$(CAUSEF)"
assert_has "the fix names the fallback variable" "MM_MORNING_FALLBACK_ENV" "$(CAUSEF)"
assert_has "...and the rerun command" "systemctl --user start orch-morning-ritual.service" "$(CAUSEF)"
[ -s "$STUB_LOG.run-args" ] && bad "no ritual run after a failed probe" || ok "no ritual run after a failed probe"
# the OnFailure alarm sends the cause file instead of the journal, once
OUT2="$(CLAUDE_CONFIG_DIR="$C" UFA_THROTTLE_SEC=0 bash "$P/scripts/unit-failure-alarm.sh" orch-morning-ritual.service 2>&1)"; RC=$?
assert_rc "the alarm delivers" 0 "$RC"
assert_has "the alarm carries the cause" "Cause: probe: 429" "$(cat "$C/notified")"
assert_lacks "...not the journal tail" "Last lines:" "$(cat "$C/notified")"
[ -e "$C/state/unit-failure-alarm/orch-morning-ritual.service.cause" ] && bad "the cause file is consumed" || ok "the cause file is consumed"
: > "$C/notified"
OUT2="$(CLAUDE_CONFIG_DIR="$C" UFA_THROTTLE_SEC=0 bash "$P/scripts/unit-failure-alarm.sh" orch-morning-ritual.service 2>&1)"
assert_has "without a cause file the alarm falls back to the journal" "Last lines:" "$(cat "$C/notified")"

setup; printf 'ANTHROPIC_API_KEY=%s\n' "$SECRET" > "$C/fallback.env"
OUT="$(STUB_PRIMARY=429 STUB_FALLBACK=429 run MM_MORNING_FALLBACK_ENV="$C/fallback.env")"; RC=$?
assert_rc "the fallback limited too -> exit 1" 1 "$RC"
assert_has "...and the fix says so" "the fallback is limited too" "$(CAUSEF)"
setup
OUT="$(PSEC=1 STUB_PRIMARY=hang run)"; RC=$?
assert_rc "a hanging probe without a fallback -> exit 1" 1 "$RC"
assert_has "...cause: no answer" "no answer within 1s" "$(CAUSEF)"
assert_has "...fix: the fallback, as for 429" "MM_MORNING_FALLBACK_ENV" "$(CAUSEF)"
setup; START=$(date +%s)
OUT="$(STUB_RUN=hang run MM_MORNING_TIMEOUT_MIN=0.05)"; RC=$?
assert_rc "a hanging ritual run -> exit 1" 1 "$RC"
[ $(( $(date +%s) - START )) -lt 25 ] && ok "...stopped by the hard timeout" || bad "run timeout" "$(( $(date +%s) - START ))s"
assert_has "...cause timeout" "FAILED: timeout" "$(CAUSEF)"
assert_has "...fix: the journal and the knob" "MM_MORNING_TIMEOUT_MIN" "$(CAUSEF)"
setup
OUT="$(STUB_RUN=budget run MM_MORNING_MAX_BUDGET_USD=0.5)"; RC=$?
assert_rc "budget hit -> exit 1" 1 "$RC"
assert_has "...cause budget" "FAILED: budget" "$(CAUSEF)"
assert_has "...the passed cap" "--max-budget-usd 0.5" "$(cat "$STUB_LOG.run-args")"
setup
OUT="$(STUB_RUN=other run)"; RC=$?
assert_rc "another error -> exit 1" 1 "$RC"
assert_has "...cause other (a cost of 0.0429 or an id with 429 is no 429)" "FAILED: other" "$(CAUSEF)"
setup
OUT="$(STUB_RUN=noreport run)"; RC=$?
assert_rc "a run that writes no report -> exit 1" 1 "$RC"
assert_has "...says so" "without a day plan in its final message" "$(CAUSEF)"
assert_has "...and names the permission knob (r1 m6)" "MM_MORNING_PERMISSION_MODE" "$(CAUSEF)"
setup; jq 'del(.notifyCommand)' "$C/middle-management.json" > "$C/j" && mv "$C/j" "$C/middle-management.json"
OUT="$(run)"; RC=$?
assert_rc "no notifyCommand -> exit 1 before any model run" 1 "$RC"
[ -s "$STUB_LOG" ] && bad "...and nothing was spent" || ok "...and nothing was spent"
setup
OUT="$(STUB_PRIMARY=429 PATH="$BIN:$PATH" CLAUDE_CONFIG_DIR="$C" MM_SESSION_LOG="" bash "$MH" 2>&1)"; RC=$?
assert_rc "a manual run (no MM_MORNING_UNIT) fails the same way" 1 "$RC"
assert_has "...with the cause on stderr" "FAILED: 429" "$OUT"
[ -z "$(ls "$C/state/unit-failure-alarm" 2>/dev/null)" ] && ok "...and leaves no cause file" || bad "manual run cause file"

say "== r1 fold =="
# M1: delivered = what the sent report carries, not everything gathered
setup
for t in "Decide A" "Click B"; do
  CLAUDE_CONFIG_DIR="$C" CLAUDE_CODE_SESSION_ID="$SID" python3 "$P/scripts/open-items.py" add --owner user "$t" >/dev/null
done
OUT="$(STUB_RUN=partial run)"; RC=$?
assert_rc "a report that carries one of two to-dos -> exit 0" 0 "$RC"
D="$(cat "$C/state/morning-ritual/delivered" 2>/dev/null)"
assert_has "the to-do in the report is marked delivered" "aaaaaaaa-W1" "$D"
assert_lacks "the one left out is not" "aaaaaaaa-W2" "$D"
# M1: an over-long report (7200 bytes of umlauts) is cut on a line boundary, never mid-character
setup; OUT="$(STUB_RUN=long run)"; RC=$?
assert_rc "an over-long report -> exit 0" 0 "$RC"
LENS="$(sed '/^---$/d' "$C/notified" | LC_ALL=C awk '{print length}' | sort -u)"
[ "$LENS" = 120 ] && ok "every sent line is whole (120 bytes)" || bad "whole lines only" "$LENS"
[ "$(sed '/^---$/d' "$C/notified" | wc -l)" -lt 60 ] && ok "...and the text was cut" || bad "the text was cut"
# m1: a fallback file without a trailing newline, and one with CRLF
setup; printf 'ANTHROPIC_API_KEY=sk-ant-api03-NONEWLINE' > "$C/fb"
OUT="$(STUB_PRIMARY=429 run MM_MORNING_FALLBACK_ENV="$C/fb")"; RC=$?
assert_rc "a fallback file whose only line has no newline is read" 0 "$RC"
setup; printf 'ANTHROPIC_API_KEY=sk-ant-api03-CRLFVALUE\r\n' > "$C/fb"
OUT="$(STUB_PRIMARY=429 run MM_MORNING_FALLBACK_ENV="$C/fb")"; RC=$?
assert_rc "a CRLF fallback file exports the key without the CR" 0 "$RC"
# m2: the CLI's own limit and expiry wording is classified, not "other"
setup; OUT="$(STUB_PRIMARY=limit run)"
assert_has "\"You've hit your limit\" -> 429" "FAILED: 429" "$(CAUSEF)"
setup; OUT="$(STUB_PRIMARY=expired run)"
assert_has "\"OAuth token has expired\" -> 401" "FAILED: 401" "$(CAUSEF)"
setup; OUT="$(STUB_PRIMARY=weird run)"
assert_has "an unknown error carries the CLI's own first line" "other: Something unexpected happened" "$(CAUSEF)"
# m3: the probe tests the run's model
setup; OUT="$(run MM_MORNING_MODEL=sonnet)"
assert_has "the probe uses MM_MORNING_MODEL" "--model sonnet" "$(cat "$STUB_LOG.probe-args")"
assert_has "...and so does the run" "--model sonnet" "$(cat "$STUB_LOG.run-args")"
# m4: the default config dir is not exported to claude (it would read ~/.claude/.claude.json)
setup; H="$(mktemp -d -p "$TMPBASE")"; mv "$C" "$H/.claude"; C="$H/.claude"
sed -i "s|$(dirname "$NOTE")|$C|g" "$C/middle-management.json"; NOTE="$C/notified"; export STUB_LOG="$C/stub.log"
OUT="$(HOME="$H" run)"; RC=$?
assert_rc "a run with the default config dir -> exit 0" 0 "$RC"
assert_has "claude sees CLAUDE_CONFIG_DIR unset" "unset" "$(cat "$STUB_LOG.probe-cfgdir")"
setup; OUT="$(run)"
assert_has "a non-default config dir still reaches claude" "$C" "$(cat "$STUB_LOG.probe-cfgdir")"
# n8: a report with a secret-looking string is not sent
setup; OUT="$(STUB_RUN=secret run)"; RC=$?
assert_rc "a secret-looking report -> exit 1" 1 "$RC"
assert_lacks "...and nothing reached the channel" "LEAKEDVALUE" "$(cat "$C/notified" 2>/dev/null)"
assert_has "...the cause says why" "secret-looking" "$(CAUSEF)"

say "== templates =="
TPL="$P/templates/systemd"; U="$TMPBASE/units"; mkdir -p "$U"
for u in orch-morning-ritual.service orch-morning-ritual.timer; do
  sed "s|__MORNING_DIR__|/tmp/mm|g; s|__CONFIG_DIR__|/tmp/cfg|g; s|__PATH__|/usr/bin:/bin|g; s|__FALLBACK_ENV__|/tmp/fb.env|g" "$TPL/$u" > "$U/$u"
done
[ -z "$(grep -h '__' "$U"/orch-morning-ritual.*)" ] && ok "no placeholder left" || bad "placeholders" "$(grep -h '__' "$U"/*)"
S="$(cat "$U/orch-morning-ritual.service")"
assert_has "OnFailure= points at the alarm" "OnFailure=unit-failure-alarm@%n.service" "$S"
assert_has "the unit names itself for the cause file" "Environment=MM_MORNING_UNIT=%n" "$S"
assert_has "the fallback file is named, not loaded" "Environment=MM_MORNING_FALLBACK_ENV=/tmp/fb.env" "$S"
[ "$(grep -c '^EnvironmentFile=' "$U/orch-morning-ritual.service")" = 0 ] \
  && ok "...no EnvironmentFile= line (it would make the key primary)" || bad "no EnvironmentFile= line" "$S"
assert_has "ExecStart runs the copied runner" "ExecStart=/tmp/mm/morning-headless.sh" "$S"
assert_has "the timer starts it" "Unit=orch-morning-ritual.service" "$(cat "$U/orch-morning-ritual.timer")"

say ""
say "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
