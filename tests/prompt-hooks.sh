#!/usr/bin/env bash
# middle-management plugin: the two optional UserPromptSubmit hooks (hooks/reply-timestamp.sh,
# hooks/intent-check.sh) with a fake config dir; the hooks.json registration; the skills'
# frontmatter (self-wakeup is new in 0.11.1).
# Consumers: tests/run.sh (runs it with the other matrices); by hand: bash tests/prompt-hooks.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=$ROOT/plugins/middle-management
TMP=$(mktemp -d /tmp/prompt-hooks-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }

cfg() { printf '%s' "$1" > "$TMP/middle-management.json"; }
hook() {  # $1 = hook file, $2 = prompt
  jq -n --arg p "$2" '{session_id:"s1", prompt:$p}' | CLAUDE_CONFIG_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$P" bash "$P/hooks/$1" 2>&1; }
WORK="please migrate the thread writes to the new service and keep the reads"

echo "== reply-timestamp.sh =="
rm -f "$TMP/middle-management.json"
is "no config -> silent" "$(hook reply-timestamp.sh hi)" ""
cfg '{"replyTimestamp": false}'; is "off -> silent" "$(hook reply-timestamp.sh hi)" ""
cfg '{"replyTimestamp": true}'; OUT=$(hook reply-timestamp.sh hi); NOW=$(date +%H:%M)
has "on -> the literal prefix" "Your reply starts literally with: [" "$OUT"
case "$OUT" in *"[$NOW]"*|*"[$(date -d '1 minute ago' +%H:%M)]"*) ok "...the current local time" ;; *) bad "...the current local time" "[$NOW]" "$OUT" ;; esac
has "...the wrap recap stamp with the date" "a wrap recap starts with [$(date +%d.%m.%Y)" "$OUT"
is "...one line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1

echo "== intent-check.sh =="
rm -f "$TMP/middle-management.json"
is "no config -> silent" "$(hook intent-check.sh "$WORK")" ""
cfg '{"intentCheck": true}'
has "work order -> reminder" "Intent check before you start" "$(hook intent-check.sh "$WORK")"
has "...user-neutral wording" "what your user wants to ACHIEVE" "$(hook intent-check.sh "$WORK")"
has "German work order -> reminder" "Intent check" "$(hook intent-check.sh "bitte die Schreibwege auf die Plattform umstellen und testen")"
is "short prompt -> silent" "$(hook intent-check.sh "fix it")" ""
is "no work verb -> silent" "$(hook intent-check.sh "what is the status of the review on the platform today")" ""
is "system turn -> silent" "$(hook intent-check.sh "<task-notification> migrate the database now please </task-notification>")" ""
cfg '{"intentCheck": true, "intentCheckVerbs": "deploy"}'
is "custom verbs: old verb -> silent" "$(hook intent-check.sh "$WORK")" ""
has "custom verbs: new verb -> reminder" "Intent check" "$(hook intent-check.sh "please deploy the new build to staging today")"
cfg '{"intentCheck": false}'; is "off -> silent" "$(hook intent-check.sh "$WORK")" ""

echo "== config shape and registration =="
v() { cfg "$1"; CLAUDE_CONFIG_DIR="$TMP" bash "$P/scripts/config-check.sh" validate; echo $?; }
is "valid: both on + verbs" "$(v '{"replyTimestamp":true,"intentCheck":true,"intentCheckVerbs":"x|y"}')" 0
is "invalid: replyTimestamp a string" "$(v '{"replyTimestamp":"yes"}')" 1
is "invalid: empty intentCheckVerbs" "$(v '{"intentCheckVerbs":""}')" 1
H=$(jq -r '.hooks.UserPromptSubmit[0].hooks[].command' "$P/hooks/hooks.json")
has "hooks.json registers reply-timestamp.sh" "hooks/reply-timestamp.sh" "$H"
has "hooks.json registers intent-check.sh" "hooks/intent-check.sh" "$H"

echo "== skills =="
for d in "$P"/skills/*/; do
  n=$(basename "$d"); f=$d/SKILL.md
  is "skill $n: name matches its folder" "$(sed -n 's/^name: //p' "$f" | head -1)" "$n"
  [ -n "$(sed -n 's/^description: //p' "$f")" ] && ok "skill $n: has a description" || bad "skill $n: has a description" text none
done
is "self-wakeup carries no user-specific name or path" "$(grep -ciE 'manu|/home/|buildos|telegram' "$P/skills/self-wakeup/SKILL.md")" 0

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
