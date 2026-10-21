#!/usr/bin/env bash
# middle-management plugin: the copy manifest (scripts/copy-sets.json), its installer
# (scripts/copy-set.sh) and the SessionStart hook that refreshes the unit copies after an update
# (hooks/refresh-copies.sh). Fake config dir, notifyCommand writes into a file; sends nothing real.
# Consumers: tests/run.sh (runs it with the other matrices); by hand: bash tests/refresh-copies.sh
#   A  manifest: every listed file exists, the setup steps use copy-set.sh, no inline cp list left
#   B  copy-set.sh: unknown set refused, a fresh set installed, the poke prompt never overwritten
#   C  the hook: stamp equal -> no-op, refresh of existing copy dirs only, full set, poke untouched,
#      new inode (atomic mv), no .tmp left, stamp written, a second sessions finds it done
#   D  failure: systemMessage, exit 0, stamp unchanged, one notify per version, fallback route
#   E  registration in hooks.json
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=$ROOT/plugins/middle-management
HOOK=$P/hooks/refresh-copies.sh
CS=$P/scripts/copy-set.sh
V=$(jq -r .version "$P/.claude-plugin/plugin.json")
TMP=$(mktemp -d /tmp/refresh-copies-test.XXXXXX)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "lacks: $2" "$3" ;; *) ok "$1" ;; esac; }

C=""; NOTE=""
setup() {  # fresh config dir; $1 = extra JSON for the config
  C=$(mktemp -d -p "$TMP"); NOTE=$C/notified; mkdir -p "$C/state"
  jq -n --arg n "printf '%s\\n---\\n' \"\$1\" >> $NOTE" "{notifyCommand:\$n} + ${1:-{\}}" > "$C/middle-management.json"
}
hook() { printf '{"session_id":"s1","source":"startup"}' | CLAUDE_CONFIG_DIR="$C" CLAUDE_PLUGIN_ROOT="$P" bash "$HOOK" 2>&1; }
notes() { cat "$NOTE" 2>/dev/null; }
ino() { stat -c %i "$1" 2>/dev/null; }

echo "== A: the manifest =="
MISSING=""
for f in $(jq -r '.sets[][]' "$P/scripts/copy-sets.json" | sort -u); do [ -f "$P/scripts/$f" ] || MISSING="$MISSING $f"; done
is "every file of every set exists in scripts/" "$MISSING" ""
is "the poke prompt is never overwritten" "$(jq -r '.neverOverwrite | join(",")' "$P/scripts/copy-sets.json")" "orch-heartbeat-poke.md"
SETUP=$P/commands/middle-management-setup.md
for s in heartbeat reaper morning t3watch canary prreview; do
  is "setup installs middle-management-$s through copy-set.sh" "$(grep -cF "copy-set.sh\" middle-management-$s" "$SETUP")" \
     "$([ "$s" = morning ] && echo 2 || echo 1)"   # steps 7 and 7b share the morning dir
done
is "no inline cp list left in the setup" "$(grep -cF 'cp "${CLAUDE_PLUGIN_ROOT}"/scripts/{' "$SETUP")" 0
# every ExecStart script of a template is in the set of the dir it runs from
for pair in __HEARTBEAT_DIR__:middle-management-heartbeat __REAPER_DIR__:middle-management-reaper \
            __MORNING_DIR__:middle-management-morning __T3WATCH_DIR__:middle-management-t3watch \
            __CANARY_DIR__:middle-management-canary __PRREVIEW_DIR__:middle-management-prreview; do
  ph=${pair%%:*}; set=${pair#*:}
  for f in $(grep -ho "$ph/[A-Za-z0-9._-]*" "$P"/templates/systemd/* | sed "s|$ph/||" | sort -u); do
    [ "$ph" = __HEARTBEAT_DIR__ ] && [ "$f" = unit-failure-alarm.sh ] && continue   # every set carries it
    jq -e --arg s "$set" --arg f "$f" '.sets[$s] | index($f)' "$P/scripts/copy-sets.json" >/dev/null \
      && ok "$f (ExecStart of a template) is in $set" || bad "$f is in $set" "listed" "missing"
  done
done
for s in $(jq -r '.sets | keys[]' "$P/scripts/copy-sets.json"); do
  jq -e --arg s "$s" '.sets[$s] | index("unit-failure-alarm.sh")' "$P/scripts/copy-sets.json" >/dev/null \
    && ok "$s carries unit-failure-alarm.sh (the alarm unit points at whichever step ran last)" || bad "$s carries unit-failure-alarm.sh" listed missing
done

echo "== B: copy-set.sh =="
setup
OUT=$(CLAUDE_CONFIG_DIR="$C" bash "$CS" ../evil 2>&1); is "a path as the set name -> exit 64" "$?" 64
has "...names the known sets" "middle-management-heartbeat" "$OUT"
[ -e "$C/../evil" ] && bad "...creates nothing" none exists || ok "...creates nothing"
OUT=$(CLAUDE_CONFIG_DIR="$C" bash "$CS" middle-management-heartbeat 2>&1); is "a fresh set -> exit 0" "$?" 0
is "...every file in place" "$(ls "$C/middle-management-heartbeat" | sort | tr '\n' ' ')" \
   "$(jq -r '.sets["middle-management-heartbeat"][]' "$P/scripts/copy-sets.json" | sort | tr '\n' ' ')"
[ -x "$C/middle-management-heartbeat/orch-heartbeat.sh" ] && ok "...the exec bit survives" || bad "...the exec bit survives" "-x" "not executable"
echo "my poke" > "$C/middle-management-heartbeat/orch-heartbeat-poke.md"
CLAUDE_CONFIG_DIR="$C" bash "$CS" middle-management-heartbeat
is "a second run keeps the user's poke prompt" "$(cat "$C/middle-management-heartbeat/orch-heartbeat-poke.md")" "my poke"

echo "== C: the hook =="
setup; mkdir -p "$C/middle-management-heartbeat" "$C/middle-management-reaper"
echo old > "$C/middle-management-reaper/lane-reaper.sh"
echo "my poke" > "$C/middle-management-heartbeat/orch-heartbeat-poke.md"
printf '%s\n' "$V" > "$C/state/plugin-version"
OUT=$(hook); is "stamp equal -> exit 0" "$?" 0; is "...no output" "$OUT" ""
is "...nothing copied" "$(cat "$C/middle-management-reaper/lane-reaper.sh")" old
[ -e "$C/middle-management-heartbeat/orch-heartbeat.sh" ] && bad "...heartbeat untouched" none copied || ok "...heartbeat untouched"
printf '0.0.1\n' > "$C/state/plugin-version"
I0=$(ino "$C/middle-management-reaper/lane-reaper.sh")
exec 7<"$C/middle-management-reaper/lane-reaper.sh"   # a running timer script holds the old file
OUT=$(hook); is "stamp differs -> exit 0" "$?" 0; is "...no output on success" "$OUT" ""
cmp -s "$P/scripts/lane-reaper.sh" "$C/middle-management-reaper/lane-reaper.sh" && ok "...reaper refreshed" || bad "...reaper refreshed" "the plugin's file" "old"
[ "$(ino "$C/middle-management-reaper/lane-reaper.sh")" != "$I0" ] && ok "...a new inode (mv, not an overwrite in place)" || bad "...a new inode" "changed" "$I0"
is "...the open old file still reads the old text" "$(cat <&7)" old
exec 7<&-
[ -e "$C/middle-management-reaper/wt" ] && [ -e "$C/middle-management-reaper/unit-failure-alarm.sh" ] \
  && ok "...the FULL set: files the dir never had arrive too" || bad "...the full set" "wt + unit-failure-alarm.sh" "$(ls "$C/middle-management-reaper")"
[ -e "$C/middle-management-heartbeat/orch-heartbeat.sh" ] && ok "...heartbeat refreshed" || bad "...heartbeat refreshed" copied none
is "...the poke prompt untouched" "$(cat "$C/middle-management-heartbeat/orch-heartbeat-poke.md")" "my poke"
for d in morning t3watch canary prreview; do
  [ -e "$C/middle-management-$d" ] && bad "...no copy dir created for an uninstalled step ($d)" absent created || ok "...no copy dir created for an uninstalled step ($d)"
done
is "...no .tmp left" "$(find "$C" -name '*.tmp' | wc -l)" 0
is "...stamp written" "$(cat "$C/state/plugin-version")" "$V"
is "...no notify on success" "$(notes)" ""
echo old > "$C/middle-management-reaper/lane-reaper.sh"
OUT=$(hook); is "the next session start -> no-op" "$(cat "$C/middle-management-reaper/lane-reaper.sh")" old
setup
OUT=$(hook); is "no copy dir at all -> exit 0" "$?" 0; is "...the stamp is written anyway" "$(cat "$C/state/plugin-version")" "$V"
is "...nothing created" "$(ls "$C" | grep -c middle-management-)" 0

echo "== D: failure =="
setup; mkdir -p "$C/middle-management-canary"; chmod 555 "$C/middle-management-canary"
OUT=$(hook); RC=$?
is "a copy fails -> exit 0 (never blocks the session)" "$RC" 0
has "...systemMessage" '"systemMessage":"middle-management: ' "$OUT"
has "...names the cause" "cannot copy" "$OUT"
jq -e . <<<"$OUT" >/dev/null 2>&1 && ok "...valid JSON" || bad "...valid JSON" json "$OUT"
[ -e "$C/state/plugin-version" ] && bad "...no stamp (the next start retries)" absent "$(cat "$C/state/plugin-version")" || ok "...no stamp (the next start retries)"
has "...notified" "the unit copies were NOT refreshed" "$(notes)"
OUT=$(hook)
has "the second start -> systemMessage again" "systemMessage" "$OUT"
is "...but no second notify for the same version" "$(notes | grep -c 'NOT refreshed')" 1
chmod 755 "$C/middle-management-canary"
OUT=$(hook); is "fixed -> the next start refreshes" "$(cat "$C/state/plugin-version")" "$V"
[ -e "$C/state/plugin-version.failed" ] && bad "...the notify latch is cleared" absent present || ok "...the notify latch is cleared"
setup; jq --arg fb "printf '%s\\n' \"\$1\" >> $TMP/fb" '.notifyCommand = "exit 1" | .notifyFallbackCommand = $fb' \
  "$C/middle-management.json" > "$C/x" && mv "$C/x" "$C/middle-management.json"
mkdir -p "$C/middle-management-canary"; chmod 555 "$C/middle-management-canary"
OUT=$(hook)
has "notifyCommand fails -> the fallback route" "[fallback route: the main alarm channel failed]" "$(cat "$TMP/fb" 2>/dev/null)"
chmod 755 "$C/middle-management-canary"
setup '{"notifyCommand":"exit 1"}'; mkdir -p "$C/middle-management-canary"; chmod 555 "$C/middle-management-canary"
hook >/dev/null
[ -e "$C/state/plugin-version.failed" ] && bad "nothing delivered -> no latch (the next start tries again)" absent present || ok "nothing delivered -> no latch (the next start tries again)"
chmod 755 "$C/middle-management-canary"

echo "== E: registration =="
is "hooks.json registers it under SessionStart" \
   "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("refresh-copies.sh"))] | length' "$P/hooks/hooks.json")" 1
EM=$(printf '\xe2\x80\x94')   # the em dash, spelled as bytes so this file carries none
is "no em dash in the new files" "$(grep -l "$EM" "$HOOK" "$CS" "$P/scripts/copy-sets.json" "$0" 2>/dev/null)" ""

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
