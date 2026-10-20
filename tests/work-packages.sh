#!/usr/bin/env bash
# middle-management plugin: tests for the work-packages gate and the SubagentStop report check.
# Consumers: run by hand or CI from the repo root: bash tests/work-packages.sh
# Fake HOME and fake transcripts under mktemp; never reads or writes the real ~/.claude.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/plugins/middle-management"
GATE="$P/hooks/require-work-packages.sh"
CHECK="$P/hooks/subagent-report-check.sh"
PASS=0; FAIL=0
TMPBASE="$(mktemp -d -t mm-wp-tests.XXXXXX)"
trap 'case "$TMPBASE" in /tmp/*) find "$TMPBASE" -depth -delete 2>/dev/null ;; esac' EXIT

ok()  { PASS=$((PASS+1)); printf '  ok  - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL- %s\n        got: %s\n' "$1" "$2"; }
assert_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$3" ;; esac; }
assert_empty() { [ -z "$3" ] && ok "$1" || bad "$1" "$3"; }

H="$TMPBASE/home"; mkdir -p "$H/.claude"
run() { HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" bash "$1" 2>&1; }
agent() {  # $1=prompt [$2=subagent_type]
  jq -n --arg p "$1" --arg t "${2:-}" '{tool_name:"Agent",tool_input:({prompt:$p,description:"x"} + (if $t == "" then {} else {subagent_type:$t} end))}'
}

echo "== gate: PreToolUse on Agent =="
OUT=$(agent "Build the thing." | run "$GATE")
assert_has "no Report file line -> deny" '"permissionDecision": "deny"' "$OUT"
assert_has "deny reason carries the template block" 'Report file: <absolute path' "$OUT"
assert_has "deny reason names the skill" 'middle-management:work-packages' "$OUT"
OUT=$(agent $'Build it.\nReport file: /tmp/x/report.md\nGo.' | run "$GATE")
assert_empty "absolute Report file -> allow" "" "$OUT"
OUT=$(agent $'Build it.\n- **Report file:** `/tmp/x/r.md`' | run "$GATE")
assert_empty "markdown around the line -> allow" "" "$OUT"
OUT=$(agent $'Look up one fact.\nReport file: none' | run "$GATE")
assert_empty "Report file: none -> allow" "" "$OUT"
OUT=$(agent $'Look up one fact.\nReport file: None (quick lookup)' | run "$GATE")
assert_empty "Report file: None (note) -> allow" "" "$OUT"
OUT=$(agent $'Report file: <absolute path, e.g. x>' | run "$GATE")
assert_has "unfilled template -> deny" 'must name an absolute path' "$OUT"
OUT=$(agent $'Report file: notes/r.md' | run "$GATE")
assert_has "relative path -> deny" '"permissionDecision": "deny"' "$OUT"
OUT=$(agent "Find where X lives." Explore | run "$GATE")
assert_empty "subagent_type Explore -> allow" "" "$OUT"
OUT=$(agent "Find where X lives." general-purpose | run "$GATE")
assert_has "general-purpose without line -> deny" '"permissionDecision": "deny"' "$OUT"
# The plugin's own dispatch templates pass the gate once their placeholders are filled (review r1 F3).
RULES=$(sed -n '/^> You are a fresh-context reviewer/,/^$/p' "$P/skills/review-loop/SKILL.md" \
  | sed 's|<scratch dir>|/tmp/sid-1|; s|<deliverable>|plan|; s|<N>|1|')
assert_has "review-loop rules carry a Report file line" "Report file: /tmp/sid-1/review-plan-r1.md" "$RULES"
OUT=$(agent "$RULES" | run "$GATE")
assert_empty "review-loop's verbatim reviewer rules, filled -> allow" "" "$OUT"
assert_has "morning ritual's cleanup sub-agent names its Report file" 'its
prompt carries `Report file: <absolute path>`' "$(cat "$P/skills/morning-ritual/SKILL.md")"
OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | run "$GATE")
assert_empty "other tool -> silent" "" "$OUT"
printf '{"workPackagesGate": false}' > "$H/.claude/middle-management.json"
OUT=$(agent "Build the thing." | run "$GATE")
assert_empty "gate off -> allow" "" "$OUT"
printf '{"workPackagesGate": true}' > "$H/.claude/middle-management.json"
OUT=$(agent "Build the thing." | run "$GATE")
assert_has "gate explicitly on -> deny" '"permissionDecision": "deny"' "$OUT"
printf '{oops' > "$H/.claude/middle-management.json"
OUT=$(agent "Build the thing." | run "$GATE")
assert_has "broken config -> gate stays on" '"permissionDecision": "deny"' "$OUT"
rm -f "$H/.claude/middle-management.json"
JQLESS="$TMPBASE/nojq"; mkdir -p "$JQLESS"; ln -s /usr/bin/* /bin/* "$JQLESS"/ 2>/dev/null; rm -f "$JQLESS/jq"
OUT=$(printf '{"tool_name":"Agent","tool_input":{"prompt":"x"}}' | HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$JQLESS" bash "$GATE" 2>&1)
assert_has "jq missing -> one warning line, no deny" 'jq not installed' "$OUT"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ] && ok "jq missing -> exactly one line" || bad "jq missing -> exactly one line" "$OUT"

echo "== check: SubagentStop =="
S="sess-1"; A="a123"; PDIR="$TMPBASE/proj"; mkdir -p "$PDIR/$S/subagents"
TR="$PDIR/$S/subagents/agent-$A.jsonl"; REP="$TMPBASE/lane/r.md"; mkdir -p "$TMPBASE/lane"
transcript() {  # $1=prompt, run started 60 s ago; plus a tool result and a later injected notification
  local t0 t1; t0=$(date -u -d '-60 sec' +%Y-%m-%dT%H:%M:%S.123Z); t1=$(date -u +%Y-%m-%dT%H:%M:%S.456Z)
  { jq -cn --arg p "$1" --arg t "$t0" '{type:"user",timestamp:$t,message:{role:"user",content:$p}}'
    jq -cn --arg t "$t0" '{type:"user",timestamp:$t,message:{content:[{type:"tool_result",content:"ok"}]}}'
    jq -cn --arg t "$t1" '{type:"user",isMeta:true,timestamp:$t,message:{content:"[SYSTEM NOTIFICATION]"}}'
    echo 'not json'; } > "$TR"
}
stopin() {  # $1=stop_hook_active [$2=agent_transcript_path, default the real one]
  jq -n --arg tp "$PDIR/$S.jsonl" --arg s "$S" --arg a "$A" --arg atp "${2-$TR}" --argjson act "$1" \
    '{session_id:$s,transcript_path:$tp,hook_event_name:"SubagentStop",stop_hook_active:$act,agent_id:$a,agent_type:"general-purpose",agent_transcript_path:$atp,last_assistant_message:"done"}'
}
transcript $'Do it.\nReport file: '"$REP"
rm -f "$REP"
OUT=$(stopin false | run "$CHECK")
assert_has "report missing -> block" '"decision": "block"' "$OUT"
assert_has "block names the file state" 'does not exist' "$OUT"
assert_has "block carries the resume line with the id" "resume it with SendMessage to its id $A" "$OUT"
echo x > "$REP"; touch -d '-2 min' "$REP"
OUT=$(stopin false | run "$CHECK")
assert_has "report unchanged during the run -> block" 'did not change during this run' "$OUT"
touch "$REP"
OUT=$(stopin false | run "$CHECK")
assert_empty "report changed during the run -> silent (later isMeta entry ignored)" "" "$OUT"
touch -d '-2 min' "$REP"
OUT=$(stopin false "" | run "$CHECK")
assert_has "empty agent_transcript_path -> fallback path finds the transcript" '"decision": "block"' "$OUT"
OUT=$(stopin true | run "$CHECK")
assert_empty "stop_hook_active -> silent (no loop)" "" "$OUT"
OUT=$(stopin false "$TMPBASE/nosuch.jsonl" | run "$CHECK")
assert_empty "transcript missing -> silent" "" "$OUT"
transcript $'Look up X.\nReport file: none'
OUT=$(stopin false | run "$CHECK")
assert_empty "Report file: none -> silent" "" "$OUT"
transcript "No line at all."
OUT=$(stopin false | run "$CHECK")
assert_empty "no Report file line -> silent" "" "$OUT"
transcript $'Do it.\nReport file: '"$REP"; rm -f "$REP"
printf '{"workPackagesGate": false}' > "$H/.claude/middle-management.json"
OUT=$(stopin false | run "$CHECK")
assert_empty "gate off -> silent" "" "$OUT"
rm -f "$H/.claude/middle-management.json"
OUT=$(stopin false | HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$JQLESS" bash "$CHECK" 2>&1)
assert_empty "jq missing -> silent" "" "$OUT"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
