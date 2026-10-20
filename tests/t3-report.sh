#!/usr/bin/env bash
# middle-management plugin: the T3 Stop hook matrix (hooks/t3-report.sh), fake HOME, sends nothing real.
# Consumers: tests/run.sh (runs it with the other matrices); by hand from the repo root:
#   bash tests/t3-report.sh
# Part 1 runs the hook from a plugin copy whose scripts/t3-wake.sh is a stub (records what it was
# asked to send, answers with the exit code in $TMP/wake.rc). Part 2 runs the REAL t3-wake.sh
# against a local HTTP stub (202 / 500) and checks that the webhook URL never reaches any output.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=$ROOT/plugins/middle-management
TMP=$(mktemp -d /tmp/t3-report-test.XXXXXX)
SP=""
trap '[ -n "$SP" ] && kill "$SP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "lacks: $2" "$3" ;; *) ok "$1" ;; esac; }

# --- the plugin copy with the stub sender ---
C=$TMP/plugin; mkdir -p "$C/hooks" "$C/scripts"
cp "$P/hooks/t3-report.sh" "$C/hooks/"; cp "$P/scripts/config-check.sh" "$P/scripts/scope.py" "$C/scripts/"
cat > "$C/scripts/t3-wake.sh" <<EOF
#!/usr/bin/env bash
{ printf 'from=%s session=%s cwd=%s\n' "\$1" "\$MM_SESSION_ID" "\$MM_SCOPE_CWD"; cat "\$2"; printf '\n--\n'; } >> "$TMP/wake.log"
exit "\$(cat "$TMP/wake.rc" 2>/dev/null || echo 0)"
EOF
H=$TMP/home; CFG=$H/.claude; mkdir -p "$CFG/state" "$CFG/sessions" "$H/.t3"
reg() {  # $1 sessionId $2 name $3 cwd
  printf '{"pid":1,"sessionId":"%s","name":"%s","cwd":"%s","kind":"interactive"}\n' "$1" "$2" "$3" > "$CFG/sessions/$1.json"; }
side() {  # $1 sidecar dir $2 coordinator sessionId [$3 url]
  mkdir -p "$1"; printf '{"sessionId":"%s","threadId":"mcp:coord-1","title":"lane coordinator","model":"m","reportTaskId":"task-1","reportUrl":"%s"}\n' \
    "$2" "${3:-http://127.0.0.1:9/never}" > "$1/orchestrator.t3.json"; chmod 600 "$1/orchestrator.t3.json"; }
hook() {  # $1 = Stop input JSON; env T3 = T3CODE_HOME (default set)
  printf '%s' "$1" | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$C" T3CODE_HOME="${T3-$H/.t3}" bash "$C/hooks/t3-report.sh" 2>&1; }
inp() {  # $1 sid $2 text [$3 extra json fields]
  jq -cn --arg s "$1" --arg t "$2" --argjson x "${3:-{\}}" '{session_id: $s, cwd: "/tmp", last_assistant_message: $t} + $x'; }
calls() { grep -c '^from=' "$TMP/wake.log" 2>/dev/null || echo 0; }

reg sess-w worker-1 "$H"; reg sess-c coord "$H"; reg sess-old old-coord "$H"

echo "== gates =="
OUT=$(T3="" hook "$(inp sess-w "done 1")"); is "no T3CODE_HOME -> silent" "$OUT" ""; is "...nothing sent" "$(calls)" 0
OUT=$(hook "$(inp sess-w "done 1")"); is "no sidecar -> silent" "$OUT" ""; is "...nothing sent" "$(calls)" 0
side "$CFG/state" sess-c
OUT=$(hook "$(inp sess-c "coordinator text")"); is "the coordinator itself -> silent" "$OUT" ""; is "...nothing sent" "$(calls)" 0

echo "== worker report =="
OUT=$(hook "$(inp sess-w "READY: lane x merged")"); is "worker -> no output on success" "$OUT" ""
is "worker -> one send" "$(calls)" 1
has "...the last text is the report" "READY: lane x merged" "$(cat "$TMP/wake.log")"
has "...from = registry name, session id passed" "from=worker-1 session=sess-w cwd=$H" "$(cat "$TMP/wake.log")"
[ -s "$CFG/state/t3-report/sess-w" ] && ok "...sha recorded" || bad "...sha recorded" "file" "none"
hook "$(inp sess-w "READY: lane x merged")" >/dev/null; is "duplicate text -> not sent again" "$(calls)" 1
hook "$(inp sess-w "the continued answer" '{"stop_hook_active":true}')" >/dev/null
is "stop_hook_active continuation still posts" "$(calls)" 2
hook "$(inp sess-w "interim" '{"background_tasks":[{"type":"subagent","status":"running"}]}')" >/dev/null
is "a running sub-agent -> interim turn, not sent" "$(calls)" 2
hook "$(inp sess-w "interim" '{"background_tasks":[{"type":"shell","status":"running"}]}')" >/dev/null
is "a background shell does not hold the report" "$(calls)" 3
hook "$(inp sess-w "after agents" '{"background_tasks":[{"type":"subagent","status":"completed"}]}')" >/dev/null
is "a completed sub-agent does not hold it" "$(calls)" 4
hook "$(inp sess-w "OK")" >/dev/null; hook "$(inp sess-w " OK
")" >/dev/null; is "exactly OK (a Keepalive answer) -> not echoed" "$(calls)" 4
hook "$(inp sess-w "")" >/dev/null; is "empty text, no transcript -> nothing" "$(calls)" 4
TR=$TMP/tr.jsonl
printf '%s\n' '{"type":"user","message":{"content":"go"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"from the transcript"},{"type":"tool_use","name":"x"}]}}' > "$TR"
hook "$(jq -cn --arg t "$TR" '{session_id:"sess-w", transcript_path:$t}')" >/dev/null
is "transcript fallback -> sent" "$(calls)" 5; has "...its text" "from the transcript" "$(tail -3 "$TMP/wake.log")"

echo "== former coordinator =="
side "$CFG/state" sess-c; jq '.previous = {sessionId:"sess-old", threadId:"mcp:old"}' "$CFG/state/orchestrator.t3.json" > "$TMP/x" \
  && cat "$TMP/x" > "$CFG/state/orchestrator.t3.json"
hook "$(inp sess-old "wrap of the old coordinator")" >/dev/null
is "a former coordinator reports into its successor" "$(calls)" 6

echo "== not delivered =="
echo 4 > "$TMP/wake.rc"
OUT=$(hook "$(inp sess-w "lost report")")
has "rc 4 -> block" '"decision":"block"' "$OUT"
has "...names the coordinator thread" "send it yourself with t3_thread_send mcp:coord-1" "$OUT"
has "...exact reason text" "report NOT delivered to the coordinator" "$OUT"
OUT=$(hook "$(inp sess-w "lost report")"); is "same text again -> no second block" "$OUT" ""
OUT=$(hook "$(inp sess-w "lost again" '{"stop_hook_active":true}')"); is "continuation -> never a block (no loop)" "$OUT" ""
[ -s "$CFG/state/t3-report/sess-w" ] && [ "$(cat "$CFG/state/t3-report/sess-w")" != "$(printf '%s' "lost report" | sha256sum | cut -d' ' -f1)" ] \
  && ok "a lost report is not recorded as sent" || bad "a lost report is not recorded as sent" "old sha" "lost sha"
echo 3 > "$TMP/wake.rc"; OUT=$(hook "$(inp sess-w "no sidecar any more")"); is "rc 3 -> silent" "$OUT" ""
echo 0 > "$TMP/wake.rc"

echo "== per-root scopes =="
mkdir -p "$TMP/A" "$TMP/B" "$TMP/plain"; git -C "$TMP/A" init -q; git -C "$TMP/B" init -q
printf '{"scopeMode":"per-root"}\n' > "$CFG/middle-management.json"
rm -f "$CFG/state/orchestrator.t3.json"
SA=$(HOME="$H" CLAUDE_CONFIG_DIR="" python3 "$C/scripts/scope.py" of "$TMP/A" | cut -f2)
side "$SA" sess-ca
reg sess-a worker-a "$TMP/A"; reg sess-b worker-b "$TMP/B"; reg sess-p worker-p "$TMP/plain"
N=$(calls); hook "$(inp sess-a "report from A")" >/dev/null; is "root A worker -> sent to A's coordinator" "$(calls)" $((N+1))
hook "$(inp sess-b "report from B")" >/dev/null; is "root B worker (no coordinator there) -> standalone" "$(calls)" $((N+1))
hook "$(inp sess-p "report from nowhere")" >/dev/null; is "outside every root -> standalone (no catch-all)" "$(calls)" $((N+1))
rm -f "$CFG/middle-management.json"

echo "== real t3-wake.sh against a local stub =="
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
SECRET="hooksecret$RANDOM$RANDOM"; URL="http://127.0.0.1:$PORT/api/hooks/task/$SECRET"
cat > "$TMP/stub.py" <<'EOF'
import http.server, os, sys
D = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("content-length", 0)))
        open(os.path.join(D, "hook.log"), "ab").write(b + b"\n")
        code = int(open(os.path.join(D, "hook.code")).read().strip())
        self.send_response(code); self.send_header("content-length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
echo 202 > "$TMP/hook.code"; python3 "$TMP/stub.py" "$PORT" "$TMP" & SP=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
side "$CFG/state" sess-c "$URL"
OUT=$(printf '%s' "$(inp sess-w "real delivery")" | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" T3CODE_HOME="$H/.t3" bash "$P/hooks/t3-report.sh" 2>&1)
is "202 -> silent" "$OUT" ""
has "...the stub got the report" '"report":"real delivery"' "$(cat "$TMP/hook.log" 2>/dev/null)"
echo 500 > "$TMP/hook.code"
OUT2=$(printf '%s' "$(inp sess-w "real failure")" | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" T3CODE_HOME="$H/.t3" bash "$P/hooks/t3-report.sh" 2>&1)
has "500 -> block" '"decision":"block"' "$OUT2"
has "...failures.log line" "http 500" "$(cat "$CFG/state/t3-report/failures.log" 2>/dev/null)"
ALL="$OUT$OUT2$(cat "$CFG/state/t3-report/"* 2>/dev/null)"
lacks "no URL secret in any output or state file" "$SECRET" "$ALL"
lacks "no [HH:MM] prefix demanded" "[HH:MM]" "$(cat "$P/hooks/t3-report.sh")"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
