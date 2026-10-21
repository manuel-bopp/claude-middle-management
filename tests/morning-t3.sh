#!/usr/bin/env bash
# middle-management plugin: the T3 morning chain (scripts/morning-t3.sh trigger + --check watchdog),
# the alarm fallback route (scripts/unit-failure-alarm.sh, notifyFallbackCommand) and the Stop hook's
# morning hold (hooks/t3-report.sh). Fake config dir, a local HTTP stub for the T3 webhook, a stub
# `claude` on PATH; sends nothing real.
# Consumers: tests/run.sh (runs it with the other matrices); by hand from the repo root:
#   bash tests/morning-t3.sh
#   A  trigger: URL file checks, free probe -> POST 202, relay URL -> local twin, failed POST -> cause
#      file + exit 1 -> the alarm sends it, limit wait -> free -> POST, limit past the deadline ->
#      cancelled, seat changed hands during the wait -> cancelled
#   B  watchdog: missing claim / ritual -> alarm, both today -> quiet, cancelled / waiting -> quiet
#   C  unit-failure-alarm: notifyFallbackCommand when notifyCommand fails or is missing
#   D  t3-report.sh: the morning thread's turn is not sent to the night coordinator before its claim
#   E  templates   F  config shape   Z  no webhook secret in any output
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=$ROOT/plugins/middle-management
TMP=$(mktemp -d /tmp/morning-t3-test.XXXXXX)
SP=""
trap '[ -n "$SP" ] && kill "$SP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; ALL=""
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "lacks: $2" "$3" ;; *) ok "$1" ;; esac; }

# The installed copy, as the unit runs it.
S=$TMP/s; mkdir -p "$S"
cp "$P"/scripts/{morning-t3.sh,config-check.sh,scope.py,unit-failure-alarm.sh} "$S/"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
cat > "$TMP/stub.py" <<'EOF'
import http.server, os, sys
D = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("content-length", 0)))
        open(os.path.join(D, "hook.log"), "ab").write(self.path.encode() + b" " + b + b"\n")
        f = "hook.mode.local" if self.path.startswith("/api/") and os.path.exists(os.path.join(D, "hook.mode.local")) else "hook.mode"
        try: code = int(open(os.path.join(D, f)).read().strip())
        except OSError: code = 202
        self.send_response(code); self.send_header("content-length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
python3 "$TMP/stub.py" "$PORT" "$TMP" & SP=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
SECRET="mornsecret$RANDOM$RANDOM"
URL="http://127.0.0.1:$PORT/api/hooks/task-m/$SECRET"

# The probe stub: the answer of call n is line n of $TMP/probe.plan (last line repeats): ok | limit |
# weird | seat (writes the marker anew, then ok).
BIN=$TMP/bin; mkdir -p "$BIN"
cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$TMP/probe.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$TMP/probe.n"
printf '%s\n' "\$*" >> "$TMP/probe.log"
m=\$(sed -n "\${n}p" "$TMP/probe.plan"); [ -n "\$m" ] || m=\$(tail -1 "$TMP/probe.plan")
case "\$m" in
  ok)    echo '{"is_error":false,"result":"ok"}' ;;
  limit) echo '{"is_error":true,"result":"You have hit your limit","api_error_status":429}'; exit 1 ;;
  weird) echo 'Something unexpected'; exit 1 ;;
  seat)  echo sess-new > "\$SEAT_MARKER"; echo '{"is_error":false,"result":"ok"}' ;;
esac
EOF
chmod +x "$BIN/claude"
# systemctl / journalctl stubs for the alarm (no real user manager in a test)
printf '#!/bin/sh\necho unknown\n' > "$BIN/systemctl"; printf '#!/bin/sh\necho journal line\n' > "$BIN/journalctl"
chmod +x "$BIN/systemctl" "$BIN/journalctl"

C=""; NOTE=""
setup() {  # fresh config dir; $1 = extra JSON for the config
  C=$(mktemp -d -p "$TMP"); NOTE=$C/notified; mkdir -p "$C/state"
  jq -n --arg n "printf '%s\\n---\\n' \"\$1\" >> $NOTE" --arg u "$C/morning-url" --arg t "http://127.0.0.1:$PORT" \
    "{notifyCommand:\$n, morningTaskUrlFile:\$u, t3Url:\$t, morningTakeover:{allowed:true, okBy:\"Alex, 2026-10-21\"}} + ${1:-{\}}" > "$C/middle-management.json"
  (umask 077; printf '%s\n' "$URL" > "$C/morning-url")
  echo ok > "$TMP/probe.plan"; rm -f "$TMP/probe.n" "$TMP/probe.log" "$TMP/hook.log" "$TMP/hook.mode" "$TMP/hook.mode.local"
}
trig() {  # extra VAR=value args
  env PATH="$BIN:$PATH" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$C" MM_MORNING_UNIT=orch-morning-t3.service \
    MM_MORNING_RETRY_SEC=1 SEAT_MARKER="$C/state/orchestrator" "$@" bash "$S/morning-t3.sh" 2>&1; }
check() { env PATH="$BIN:$PATH" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$C" MM_MORNING_UNIT=orch-morning-watchdog.service \
    bash "$S/morning-t3.sh" --check 2>&1; }
cause() { cat "$C/state/unit-failure-alarm/$1.cause" 2>/dev/null; }
status() { cut -f2 "$C/state/morning-t3/status" 2>/dev/null; }
notes() { cat "$NOTE" 2>/dev/null; }
mkdir -p "$TMP/home"

echo "== A: the trigger =="
setup; rm -f "$C/morning-url"
OUT=$(trig); RC=$?; ALL="$ALL$OUT"
is "no URL file -> exit 1" "$RC" 1; has "...the cause names the file and the setup step" "no webhook URL file $C/morning-url" "$(cause orch-morning-t3.service)"
setup; chmod 644 "$C/morning-url"
OUT=$(trig); RC=$?; ALL="$ALL$OUT"
is "URL file readable by others -> exit 1" "$RC" 1; has "...says chmod 600" "chmod 600" "$(cause orch-morning-t3.service)"
setup; printf 'not a url\n' > "$C/morning-url"
OUT=$(trig); is "URL file without a URL -> exit 1" "$?" 1
setup
OUT=$(trig); RC=$?; ALL="$ALL$OUT"
is "free probe -> POST -> exit 0" "$RC" 0
has "...posted to the task" "/api/hooks/task-m/$SECRET" "$(cat "$TMP/hook.log")"
is "...body: from + date" "$(cut -d' ' -f2- "$TMP/hook.log" | jq -c .)" "{\"from\":\"morning-t3\",\"date\":\"$(date +%F)\"}"
is "...status posted" "$(status)" posted
is "...status date is today" "$(cut -f1 "$C/state/morning-t3/status")" "$(date +%F)"
lacks "...the status file has no URL" "$SECRET" "$(cat "$C/state/morning-t3/status")"
has "...the probe ran with no tools, no MCP, no settings" '--tools  --setting-sources' "$(cat "$TMP/probe.log")"
is "...no notify on a plain morning" "$(notes)" ""
# relay URL -> the local twin at t3Url
setup; (umask 077; printf 'https://relay.t3.codes/v1/hooks/env-1/task-r/%s\n' "$SECRET" > "$C/morning-url")
OUT=$(trig); RC=$?; ALL="$ALL$OUT"
is "relay URL -> the local twin answers 202 -> exit 0" "$RC" 0
is "...posted to <t3Url>/api/hooks/<task>/<token>" "$(cut -d' ' -f1 "$TMP/hook.log")" "/api/hooks/task-r/$SECRET"
# the local twin was reached but did not answer 202 -> no second POST through the relay
setup; (umask 077; printf 'https://relay.t3.codes/v1/hooks/env-1/task-r/%s\n' "$SECRET" > "$C/morning-url"); echo 500 > "$TMP/hook.mode"
OUT=$(trig); RC=$?; ALL="$ALL$OUT"
is "local twin reached, HTTP 500 -> exit 1" "$RC" 1
has "...names the local URL" "HTTP 500 via the local URL" "$(cause orch-morning-t3.service)"
is "...one POST only (no relay retry, no second thread)" "$(grep -c "^/api/hooks/" "$TMP/hook.log")" 1
# the local twin answers 404 (no such route here) or cannot be reached -> the relay URL (a local stand-in)
RP="http://127.0.0.1:$PORT/relay/v1/hooks/"
setup; (umask 077; printf '%senv-1/task-r/%s\n' "$RP" "$SECRET" > "$C/morning-url"); echo 404 > "$TMP/hook.mode.local"
OUT=$(trig MM_MORNING_RELAY_PREFIX="$RP"); RC=$?; ALL="$ALL$OUT"
is "local twin 404 -> relay -> exit 0" "$RC" 0
is "...first the twin, then the relay" "$(grep -o '^/[a-z]*/' "$TMP/hook.log" | tr '\n' ' ')" "/api/ /relay/ "
setup; (umask 077; printf '%senv-1/task-r/%s\n' "$RP" "$SECRET" > "$C/morning-url")
CLOSED=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
jq --arg t "http://127.0.0.1:$CLOSED" '.t3Url = $t' "$C/middle-management.json" > "$C/x" && mv "$C/x" "$C/middle-management.json"
OUT=$(trig MM_MORNING_RELAY_PREFIX="$RP"); RC=$?; ALL="$ALL$OUT"
is "local twin unreachable -> relay -> exit 0" "$RC" 0
is "...one POST, to the relay" "$(grep -o '^/[a-z]*/' "$TMP/hook.log" | tr '\n' ' ')" "/relay/ "
# no takeover word -> alarm, no probe, no POST
setup '{"morningTakeover":{"allowed":false}}'
OUT=$(trig); RC=$?; ALL="$ALL$OUT"
is "no takeover word -> exit 1" "$RC" 1
has "...cause says so" "no takeover word" "$(cause orch-morning-t3.service)"
[ -e "$TMP/probe.log" ] || [ -e "$TMP/hook.log" ] && bad "...no probe, no POST" none "$(cat "$TMP/probe.log" "$TMP/hook.log" 2>/dev/null)" || ok "...no probe, no POST"
# failed POST -> cause file, exit 1, and the alarm sends that cause
setup; echo 500 > "$TMP/hook.mode"
OUT=$(trig); RC=$?; ALL="$ALL$OUT"
is "failed POST (HTTP 500) -> exit 1" "$RC" 1
has "...cause names the HTTP code" "answered HTTP 500 via the configured URL (expected 202)" "$(cause orch-morning-t3.service)"
is "...status failed" "$(status)" failed
env PATH="$BIN:$PATH" CLAUDE_CONFIG_DIR="$C" bash "$S/unit-failure-alarm.sh" orch-morning-t3.service >/dev/null 2>&1
has "...the OnFailure alarm sends that cause" "morning thread NOT started" "$(notes)"
lacks "...and no secret" "$SECRET" "$(notes)"
# limit wait: limited, then free -> one wait notice, one free notice, then the POST
setup; printf 'limit\nlimit\nok\n' > "$TMP/probe.plan"
OUT=$(trig MM_MORNING_WAIT_UNTIL=23:59); RC=$?; ALL="$ALL$OUT"
is "limit wait then free -> exit 0" "$RC" 0
is "...three probes" "$(cat "$TMP/probe.n")" 3
is "...one wait notice" "$(notes | grep -c 'morning thread waits')" 1
has "...names the deadline" "until 23:59" "$(notes)"
is "...one free notice" "$(notes | grep -c 'account free again')" 1
is "...posted once" "$(grep -c "^/api/hooks/" "$TMP/hook.log")" 1
is "...status posted" "$(status)" posted
# limited at the deadline -> cancelled, no POST, exit 0 (its own notice went out)
setup; echo limit > "$TMP/probe.plan"
OUT=$(trig MM_MORNING_WAIT_UNTIL=00:00); RC=$?; ALL="$ALL$OUT"
is "limited past the deadline -> exit 0" "$RC" 0
has "...cancel notice" "morning thread cancelled today" "$(notes)"
has "...the hint carries a later deadline" "MM_MORNING_WAIT_UNTIL=<HH:MM> bash" "$(notes)"
[ -e "$TMP/hook.log" ] && bad "...no POST" none "$(cat "$TMP/hook.log")" || ok "...no POST"
is "...status cancelled" "$(status)" cancelled
# ...and when that notice cannot go out: exit 1, so the unit alarm (and its fallback) carries it
setup '{"notifyCommand":"exit 9"}'; echo limit > "$TMP/probe.plan"
OUT=$(trig MM_MORNING_WAIT_UNTIL=00:00); is "cancel notice not sent -> exit 1" "$?" 1
# the seat changed hands during the wait -> cancelled, no POST
setup; echo sess-night > "$C/state/orchestrator"; printf 'limit\nseat\n' > "$TMP/probe.plan"
OUT=$(trig MM_MORNING_WAIT_UNTIL=23:59); RC=$?; ALL="$ALL$OUT"
is "seat changed hands during the wait -> exit 0" "$RC" 0
has "...notice says so" "seat changed hands while it waited" "$(notes)"
[ -e "$TMP/hook.log" ] && bad "...no POST" none "$(cat "$TMP/hook.log")" || ok "...no POST"
# unclear probe -> go on
setup; echo weird > "$TMP/probe.plan"
OUT=$(trig); RC=$?; is "unclear probe -> POST anyway, exit 0" "$RC" 0; has "...says unclear" "limit probe unclear" "$OUT"
# scopes: morningRoot decides the seat dir
setup; mkdir -p "$TMP/proj"; git -C "$TMP/proj" init -q
jq --arg r "$TMP/proj" '. + {scopes: [{name: "pj", root: $r, board: "/b"}], morningRoot: $r}' "$C/middle-management.json" > "$C/x" && mv "$C/x" "$C/middle-management.json"
OUT=$(trig); is "with scopes: posted" "$?" 0
is "...status in the scope's seat dir" "$(cut -f2 "$C/state/scopes/pj/morning-t3/status")" posted
jq '. + {scopeMode: "per-root"} | del(.morningRoot) | del(.scopes)' "$C/middle-management.json" > "$C/x" && mv "$C/x" "$C/middle-management.json"
OUT=$(trig); is "per-root without morningRoot -> exit 1" "$?" 1; has "...names the key" "morningRoot" "$OUT"

echo "== B: the watchdog =="
setup
OUT=$(check); RC=$?
is "nothing today -> exit 1" "$RC" 1
has "...no claim" "no coordinator claimed the seat today" "$(cause orch-morning-watchdog.service)"
has "...no ritual" "no morning ritual was stamped today" "$(cause orch-morning-watchdog.service)"
has "...the trigger did not run" "the trigger did not run today" "$(cause orch-morning-watchdog.service)"
setup; echo sess-m > "$C/state/orchestrator"; mkdir -p "$C/state/morning-ritual"; date +%s > "$C/state/morning-ritual/window"
OUT=$(check); is "claimed + stamped today -> exit 0" "$?" 0; is "...no cause file" "$(cause orch-morning-watchdog.service)" ""
touch -d "yesterday 12:00" "$C/state/orchestrator"
OUT=$(check); is "stamped but the seat not claimed today -> exit 1" "$?" 1
lacks "...only the claim is missing" "no morning ritual" "$(cause orch-morning-watchdog.service)"
setup; mkdir -p "$C/state/morning-t3"; printf '%s\tcancelled\t%s\t1\n' "$(date +%F)" "$(date +%s)" > "$C/state/morning-t3/status"
OUT=$(check); is "the trigger cancelled itself today -> quiet" "$?" 0
sleep 60 & WP=$!
printf '%s\twaiting\t%s\t%s\n' "$(date +%F)" "$(date +%s)" "$WP" > "$C/state/morning-t3/status"
OUT=$(check); is "the trigger still waits (pid alive) -> quiet" "$?" 0
kill "$WP" 2>/dev/null; wait "$WP" 2>/dev/null
OUT=$(check); is "waiting, but the pid is gone -> alarm" "$?" 1
has "...names the trigger's state" "the trigger's state today: waiting" "$(cause orch-morning-watchdog.service)"

echo "== C: the alarm fallback route =="
ufa() { env PATH="$BIN:$PATH" CLAUDE_CONFIG_DIR="$C" UFA_LATCH_DIR="$C/latch-$RANDOM" bash "$S/unit-failure-alarm.sh" x.service 2>&1; }
FB=$TMP/fb; FBCMD=$(jq -n --arg f "$FB" '"printf \"%s\\n\" \"$1\" >> " + $f')
fbcfg() { rm -f "$FB"; setup "{$1\"notifyFallbackCommand\":$FBCMD}"; }
fbcfg '"notifyCommand":"exit 7",'
OUT=$(ufa); is "main fails, fallback delivers -> exit 0" "$?" 0
has "...the fallback got the alarm" "x.service FAILED" "$(cat "$FB" 2>/dev/null)"
has "...marked as the fallback route" "[fallback route" "$(cat "$FB" 2>/dev/null)"
has "...journal says so" "delivered through notifyFallbackCommand" "$OUT"
rm -f "$FB"; setup "{\"notifyCommand\":null,\"notifyFallbackCommand\":$FBCMD}"
OUT=$(ufa); is "no main route, fallback set -> exit 0" "$?" 0; has "...delivered" "x.service FAILED" "$(cat "$FB" 2>/dev/null)"
fbcfg ''
OUT=$(ufa); is "main works -> exit 0" "$?" 0; [ -e "$FB" ] && bad "...fallback not used" none "$(cat "$FB")" || ok "...fallback not used"
setup '{"notifyCommand":"exit 7","notifyFallbackCommand":"exit 8"}'
OUT=$(ufa); is "both fail -> exit 1" "$?" 1; has "...says so" "notifyFallbackCommand failed too" "$OUT"

echo "== D: the Stop hook holds the morning thread's turn =="
H=$TMP/hd; CD=$H/.claude; mkdir -p "$CD/sessions" "$CD/state/morning-t3" "$H/.t3"
SIDE=$CD/state/orchestrator.t3.json
(umask 077; jq -n --arg u "$URL" '{sessionId:"sess-night",threadId:"mcp:night",reportUrl:$u}' > "$SIDE")
touch -d "1 hour ago" "$SIDE"
NOWS=$(date +%s)
printf '{"pid":1,"sessionId":"sess-m","kind":"interactive","cwd":"/x","name":"morning","startedAt":%s}\n' "$((NOWS * 1000))" > "$CD/sessions/1.json"
printf '{"pid":2,"sessionId":"sess-w","kind":"interactive","cwd":"/x","name":"worker","startedAt":%s}\n' "$(( (NOWS - 7200) * 1000))" > "$CD/sessions/2.json"
stop() { rm -f "$TMP/hook.log"; jq -n --arg s "$1" '{session_id:$s, last_assistant_message:"REFUSED: something"}' \
  | HOME="$H" CLAUDE_CONFIG_DIR="" T3CODE_HOME="$H/.t3" CLAUDE_PLUGIN_ROOT="$P" T3CODE_PORT=1 bash "$P/hooks/t3-report.sh" >/dev/null 2>&1; }
printf '%s\tposted\t%s\t1\n' "$(date +%F)" "$((NOWS - 30))" > "$CD/state/morning-t3/status"
stop sess-m; [ -e "$TMP/hook.log" ] && bad "the morning thread before its claim -> nothing sent" none "$(cat "$TMP/hook.log")" || ok "the morning thread before its claim -> nothing sent"
stop sess-w; has "a worker started before the trigger still reports" "REFUSED: something" "$(cat "$TMP/hook.log" 2>/dev/null)"
printf '%s\tposted\t%s\t1\n' "$(date -d yesterday +%F)" "$((NOWS - 30))" > "$CD/state/morning-t3/status"
stop sess-m; has "yesterday's post -> the hold is off" "REFUSED: something" "$(cat "$TMP/hook.log" 2>/dev/null)"
printf '%s\tposted\t%s\t1\n' "$(date +%F)" "$((NOWS - 30))" > "$CD/state/morning-t3/status"; rm -f "$CD/state/t3-report/sess-m"
touch "$SIDE"; stop sess-m; has "a sidecar newer than the post (the thread bound) -> the hold is off" "REFUSED: something" "$(cat "$TMP/hook.log" 2>/dev/null)"
# the hold is never silent, and it ends with the claim's outcome or after 30 min
touch -d "1 hour ago" "$SIDE"; rm -f "$CD/state/t3-report/"sess-* "$CD/state/t3-report/failures.log"
printf '%s\tposted\t%s\t1\n' "$(date +%F)" "$((NOWS - 30))" > "$CD/state/morning-t3/status"
stop sess-m; has "a held turn becomes a failures.log line (the watcher tells the user)" "held: the morning thread has not claimed" "$(cat "$CD/state/t3-report/failures.log" 2>/dev/null)"
printf '{"pid":3,"sessionId":"sess-w2","kind":"interactive","cwd":"/x","name":"late worker","startedAt":%s}\n' "$((NOWS * 1000))" > "$CD/sessions/3.json"
printf '%s\trefused\t%s\t1\n' "$(date +%F)" "$NOWS" > "$CD/state/morning-t3/status"
stop sess-w2; has "claim refused -> a worker started after the post reports again" "REFUSED: something" "$(cat "$TMP/hook.log" 2>/dev/null)"
printf '%s\trefused\t%s\t1\tsess-m\n' "$(date +%F)" "$NOWS" > "$CD/state/morning-t3/status"; rm -f "$CD/state/t3-report/"sess-*
stop sess-m; [ -e "$TMP/hook.log" ] && bad "the refused morning thread itself stays held (no wake into the night coordinator)" none "$(cat "$TMP/hook.log")" || ok "the refused morning thread itself stays held (no wake into the night coordinator)"
OUT=$(jq -n '{session_id:"sess-m", last_assistant_message:"another turn"}' | HOME="$H" CLAUDE_CONFIG_DIR="" T3CODE_HOME="$H/.t3" CLAUDE_PLUGIN_ROOT="$P" T3CODE_PORT=1 bash "$P/hooks/t3-report.sh" 2>&1)
is "...told once per day, then quiet" "$OUT" ""
stop sess-w2; has "...every other session reports" "REFUSED: something" "$(cat "$TMP/hook.log" 2>/dev/null)"
printf '%s\tclaimed\t%s\t1\n' "$(date +%F)" "$NOWS" > "$CD/state/morning-t3/status"; rm -f "$CD/state/t3-report/sess-w2"
stop sess-w2; has "claimed (not bound yet) -> no hold" "REFUSED: something" "$(cat "$TMP/hook.log" 2>/dev/null)"
printf '%s\tposted\t%s\t1\n' "$(date +%F)" "$((NOWS - 2400))" > "$CD/state/morning-t3/status"; rm -f "$CD/state/t3-report/sess-w2"
printf '{"pid":3,"sessionId":"sess-w2","kind":"interactive","cwd":"/x","name":"late worker","startedAt":%s}\n' "$(( (NOWS - 2300) * 1000))" > "$CD/sessions/3.json"
stop sess-w2; has "posted 40 min ago, no thread ever claimed -> the hold has ended" "REFUSED: something" "$(cat "$TMP/hook.log" 2>/dev/null)"

echo "== E: templates =="
TPL=$P/templates/systemd
for u in orch-morning-t3.service orch-morning-t3.timer orch-morning-watchdog.service orch-morning-watchdog.timer; do
  sed "s|__MORNING_DIR__|/tmp/mr|g; s|__CONFIG_DIR__|/tmp/cfg|g; s|__PATH__|/usr/bin|g; s|__MORNING_TIME__|Mon..Fri 07:30|g; s|__CHECK_TIME__|Mon..Fri 08:15|g" "$TPL/$u" > "$TMP/$u"
done
is "no placeholder left" "$(cat "$TMP"/orch-morning-t3.* "$TMP"/orch-morning-watchdog.* | grep -c '__')" 0
has "trigger: OnFailure alarm" "OnFailure=unit-failure-alarm@%n.service" "$(cat "$TMP/orch-morning-t3.service")"
has "watchdog: OnFailure alarm" "OnFailure=unit-failure-alarm@%n.service" "$(cat "$TMP/orch-morning-watchdog.service")"
has "watchdog runs --check" "morning-t3.sh --check" "$(cat "$TMP/orch-morning-watchdog.service")"
has "the units name themselves for the cause file" "MM_MORNING_UNIT=%n" "$(cat "$TMP/orch-morning-t3.service")"
has "trigger timer: weekdays 07:30" "OnCalendar=Mon..Fri 07:30" "$(cat "$TMP/orch-morning-t3.timer")"
has "...not caught up after a reboot" "Persistent=false" "$(cat "$TMP/orch-morning-t3.timer")"
if command -v systemd-analyze >/dev/null 2>&1; then
  OUT=$(cd "$TMP" && systemd-analyze --user verify orch-morning-t3.timer orch-morning-watchdog.timer 2>&1 | grep -v 'unit-failure-alarm\|/tmp/mr\|Command .* is not executable' || true)
  is "systemd-analyze verify: clean" "$OUT" ""
fi

echo "== F: config shape (config-check.sh validate) =="
vcfg() { printf '%s' "$1" > "$C/middle-management.json"; CLAUDE_CONFIG_DIR="$C" bash "$P/scripts/config-check.sh" validate; echo $?; }
setup
for c in '{"morningTakeover":{"allowed":true,"okBy":"Alex, 2026-10-21"}}' '{"morningTakeover":{"allowed":false}}' \
         '{"morningWaitUntil":"9:30"}' '{"morningRoot":"/x","morningTaskUrlFile":"~/u","notifyFallbackCommand":"x"}'; do
  is "valid: $c" "$(vcfg "$c")" 0
done
for c in '{"morningTakeover":{"allowed":true}}' '{"morningTakeover":{"allowed":true,"okBy":" "}}' '{"morningTakeover":true}' \
         '{"morningWaitUntil":"25:00"}' '{"morningRoot":"rel"}' '{"notifyFallbackCommand":3}' '{"morningTaskUrlFile":false}'; do
  is "invalid: $c" "$(vcfg "$c")" 1
done

echo "== Z =="
lacks "no webhook secret in any output" "$SECRET" "$ALL"
EM=$(printf '\xe2\x80\x94')   # the em dash, spelled as bytes so this file carries none
is "no em dash in the new files" "$(grep -l "$EM" "$P/scripts/morning-t3.sh" "$P"/templates/systemd/orch-morning-t3.* "$P"/templates/systemd/orch-morning-watchdog.* "$0" 2>/dev/null)" ""
lacks "...nor in any notice" "$SECRET" "$(cat "$TMP"/tmp.*/notified 2>/dev/null; find "$TMP" -name notified -exec cat {} + 2>/dev/null)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
