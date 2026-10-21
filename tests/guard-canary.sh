#!/usr/bin/env bash
# middle-management plugin: scripts/guard-canary.sh against a fake config dir and a stub `claude`
# (the stub plays the model: it makes the tool call or refuses; it never runs a real hook).
# Consumers: tests/run.sh (runs it with the other matrices); by hand: bash tests/guard-canary.sh
#   A  static checks: config, enabled, installPath, hooks registered, double wiring, validate, probes
#   B  end-to-end probe: haiku refuses -> sonnet retry, no call at all -> alarm, the file written ->
#      alarm + moved aside, daily latch      C  templates
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=$ROOT/plugins/middle-management
GC=$P/scripts/guard-canary.sh
TMP=$(mktemp -d /tmp/guard-canary-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "lacks: $2" "$3" ;; *) ok "$1" ;; esac; }

BIN=$TMP/bin; mkdir -p "$BIN"
# stub claude: STUB_<model>=call|refuse|write decides; the deny text is the plugin's own wording
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
model=""; tool=""; while [ $# -gt 0 ]; do case "$1" in --model) model=$2; shift ;; --tools) tool=$2; shift ;; esac; shift; done
echo "$model $tool" >> "$STUB_LOG"
v="STUB_$model"; mode=${!v:-call}
[ "$mode" = refuse ] && { echo '{"type":"assistant","message":{"content":[{"type":"text","text":"I will not do that."}]}}'; exit 0; }
echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"$tool\"}]}}"
if [ "$mode" = write ] && [ "$tool" = Write ]; then echo x > "$PROBE_ROOT/.mm-guard-probe"; exit 0; fi
case "$tool" in
  Write) echo '{"type":"user","message":{"content":"Direct edits in the protected checkout are blocked"}}' ;;
  Bash)  echo '{"type":"user","message":{"content":"blanket git staging is blocked"}}' ;;
esac
STUB
chmod +x "$BIN/claude"

C=""; REPO=""
setup() {  # a healthy machine: config with one protected checkout, plugin installed and enabled
  C=$(mktemp -d -p "$TMP"); REPO=$C/repo; mkdir -p "$REPO" "$C/plugins"; git -C "$REPO" init -q
  jq -n --arg r "$REPO" '{surgicalStaging: true, protectedCheckouts: [{name: "app", root: $r, base: "origin/main"}]}' > "$C/middle-management.json"
  jq -n '{enabledPlugins: {"middle-management@mk": true}}' > "$C/settings.json"
  jq -n --arg ip "$P" '{version: 2, plugins: {"middle-management@mk": [{installPath: $ip}]}}' > "$C/plugins/installed_plugins.json"
  export STUB_LOG=$C/stub.log; : > "$STUB_LOG"; unset STUB_haiku STUB_sonnet
}
run() { env PATH="$BIN:$PATH" CLAUDE_CONFIG_DIR="$C" MM_CANARY_UNIT=mm-guard-canary.service PROBE_ROOT="$REPO" "$@" bash "$GC" 2>&1; }
cause() { cat "$C/state/unit-failure-alarm/mm-guard-canary.service.cause" 2>/dev/null; }

echo "== A: static checks =="
setup; OUT=$(run MM_CANARY_NO_E2E=1); is "healthy -> exit 0" "$?" 0; has "...says ok" "guard-canary: ok" "$OUT"
is "...no model call" "$(cat "$STUB_LOG")" ""
setup; rm "$C/middle-management.json"; OUT=$(run MM_CANARY_NO_E2E=1); is "no config -> exit 1" "$?" 1
has "...cause file names it" "config missing" "$(cause)"
setup; jq '.enabledPlugins["middle-management@mk"] = false' "$C/settings.json" > "$C/x" && mv "$C/x" "$C/settings.json"
OUT=$(run MM_CANARY_NO_E2E=1); is "plugin disabled -> exit 1" "$?" 1; has "...names the key" "middle-management@mk is not enabled" "$OUT"
setup; jq '.plugins["middle-management@mk"][0].installPath = "/nonexistent"' "$C/plugins/installed_plugins.json" > "$C/x" && mv "$C/x" "$C/plugins/installed_plugins.json"
OUT=$(run MM_CANARY_NO_E2E=1); is "installPath gone -> exit 1" "$?" 1
setup; jq '.hooks.PreToolUse = [{matcher: "Bash", hooks: [{type: "command", command: "~/.claude/hooks/block-blanket-git-add.sh"}]}]' "$C/settings.json" > "$C/x" && mv "$C/x" "$C/settings.json"
OUT=$(run MM_CANARY_NO_E2E=1); is "a second wiring in settings.json -> exit 1" "$?" 1; has "...says they fire twice" "fire twice" "$OUT"
setup; printf '{"surgicalStaging": 5}' > "$C/middle-management.json"
OUT=$(run MM_CANARY_NO_E2E=1); is "invalid config -> exit 1" "$?" 1; has "...says so" "validate fails" "$OUT"
setup; jq '.surgicalStaging = false | .protectedCheckouts = []' "$C/middle-management.json" > "$C/x" && mv "$C/x" "$C/middle-management.json"
OUT=$(run MM_CANARY_E2E_HOUR=0); is "staging off, no checkout -> nothing to probe, exit 0" "$?" 0
is "...no model call" "$(cat "$STUB_LOG")" ""

echo "== B: the end-to-end probe =="
setup; OUT=$(run MM_CANARY_E2E_HOUR=0); is "both probes denied -> exit 0" "$?" 0; has "...e2e ok" "e2e ok" "$OUT"
is "...one haiku call per probe" "$(cat "$STUB_LOG" | tr '\n' ',')" "haiku Write,haiku Bash,"
[ -f "$C/state/guard-canary/e2e-$(date +%F)" ] && ok "...latched for today" || bad "...latched for today" file none
: > "$STUB_LOG"; OUT=$(run MM_CANARY_E2E_HOUR=0); is "latched -> no second probe today" "$(cat "$STUB_LOG")" ""
setup; export STUB_haiku=refuse
OUT=$(run MM_CANARY_E2E_HOUR=0); is "haiku refuses -> sonnet retry -> exit 0" "$?" 0
is "...haiku then sonnet per probe" "$(cat "$STUB_LOG" | tr '\n' ',')" "haiku Write,sonnet Write,haiku Bash,sonnet Bash,"
setup; export STUB_haiku=refuse STUB_sonnet=refuse
OUT=$(run MM_CANARY_E2E_HOUR=0); is "no call on either model -> exit 1" "$?" 1; has "...cause" "no plugin deny text for the edit probe" "$(cause)"
[ -f "$C/state/guard-canary/e2e-$(date +%F)" ] && bad "...not latched" none file || ok "...not latched"
setup; export STUB_haiku=write
OUT=$(run MM_CANARY_E2E_HOUR=0); is "the probe file got written -> exit 1" "$?" 1; has "...cause" "checkout guard not live" "$(cause)"
[ -e "$REPO/.mm-guard-probe" ] && bad "...the file is moved out of the checkout" gone present || ok "...the file is moved out of the checkout"
has "...into the leftovers" "mm-guard-probe-" "$(ls "$C/state/guard-canary/leftovers" 2>/dev/null)"
setup; OUT=$(run MM_CANARY_E2E_HOUR=24); is "before the e2e hour -> no model call" "$(cat "$STUB_LOG")" ""

echo "== C: templates =="
for u in mm-guard-canary.service mm-guard-canary.timer; do
  sed "s|__CANARY_DIR__|/tmp/gc|g; s|__CONFIG_DIR__|/tmp/cfg|g; s|__PATH__|/usr/bin|g" "$P/templates/systemd/$u" > "$TMP/$u"
done
is "no placeholder left" "$(cat "$TMP"/mm-guard-canary.* | grep -c '__')" 0
has "OnFailure alarm" "OnFailure=unit-failure-alarm@%n.service" "$(cat "$TMP/mm-guard-canary.service")"
has "the unit names itself for the cause file" "MM_CANARY_UNIT=%n" "$(cat "$TMP/mm-guard-canary.service")"
lacks "nothing user-specific in the script" "/home/" "$(cat "$GC")"
EM=$(printf '\xe2\x80\x94')
is "no em dash in the new files" "$(grep -l "$EM" "$GC" "$P"/templates/systemd/mm-guard-canary.* "$0" 2>/dev/null)" ""

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
