#!/usr/bin/env bash
# middle-management plugin — regression matrix (fake-HOME, no real state touched).
# Consumers: run by hand or CI from the repo root: bash tests/run.sh
# Builds throwaway HOMEs under mktemp; never reads or writes the real ~/.claude.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/plugins/middle-management"
ROLE="$P/hooks/session-role.sh"
GUARD="$P/hooks/protect-main-checkouts.sh"
GITADD="$P/hooks/block-blanket-git-add.sh"
ORCH="$P/scripts/orchestrator.sh"
WT="$P/scripts/wt"
PASS=0; FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); say "  ok  - $1"; }
bad()  { FAIL=$((FAIL+1)); say "  FAIL- $1"; [ -n "${2:-}" ] && say "        got: $2"; }
# assert <name> <needle> <haystack>
assert_has()    { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$3" ;; esac; }
assert_empty()  { [ -z "$3" ] && ok "$1" || bad "$1" "$3"; }
assert_rc()     { [ "$3" -eq "$2" ] && ok "$1" || bad "$1" "rc=$3 (want $2)"; }

new_home() {  # fresh fake HOME with a live registry entry for THIS process tree
  T="$(mktemp -d)"; mkdir -p "$T/.claude/sessions" "$T/.claude/state"
  printf '{"pid":%s,"name":"alpha","sessionId":"sess-alpha","kind":"interactive"}\n' "$$" \
    > "$T/.claude/sessions/$$.json"
  echo "$T"
}
PEERS=""
add_peer() {  # $1=home  -> registers live peer "beta" (a sleep process), echoes its pid
  # stdout/stderr detached: a sleep inheriting the capture pipe would block $(add_peer …)
  sleep 300 >/dev/null 2>&1 </dev/null & SPID=$!
  PEERS="$PEERS $SPID"
  printf '{"pid":%s,"name":"beta","sessionId":"sess-beta","kind":"interactive"}\n' "$SPID" \
    > "$1/.claude/sessions/$SPID.json"
  echo "$SPID"
}
cleanup() { for p in $PEERS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
role() {  # $1=home $2=my session_id [$3=extra env assignments via env]
  printf '{"session_id":"%s"}' "$2" | HOME="$1" CLAUDE_CONFIG_DIR="" bash "$ROLE" 2>&1
}
edit_json() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }
bash_json() { printf '{"tool_input":{"command":"%s"}}' "$1"; }

say "== role hook: preconditions =="
H="$(new_home)"
# a PATH with everything except jq (a bare broken PATH would not even find bash)
JQLESS="$(mktemp -d)"; ln -s /usr/bin/* /bin/* "$JQLESS"/ 2>/dev/null; rm -f "$JQLESS/jq"
OUT="$(printf '{"session_id":"x"}' | HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$JQLESS" bash "$ROLE" 2>&1)"
assert_has "jq missing -> warning" "jq not installed" "$OUT"
OUT="$(role "${H}/nosuch" "x")"
assert_has "registry absent -> warning" "session registry not found" "$OUT"
OUT="$(role "$H" "sess-alpha")"
assert_empty "no config, no marker -> silent" "" "$OUT"

say "== role hook: config warnings =="
printf '{oops' > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-alpha")"
assert_has "broken JSON -> invalid warning" "is invalid" "$OUT"
assert_has "broken JSON -> forced-staging clause" "forced ON" "$OUT"
printf '{"protectedCheckouts":[{"name":"x","root":"/tmp"}]}' > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-alpha")"
assert_has "shape-invalid (no base) -> invalid warning" "is invalid" "$OUT"
mkdir -p "$H/repo"
printf '{"protectedCheckouts":[{"name":"gone","root":"%s/vanished","base":"origin/main"}]}' "$H" > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-alpha")"
assert_has "vanished root -> warning" "not a directory" "$OUT"
rm -f "$H/.claude/middle-management.json"
touch "$H/.claude/state/allow-main-checkout-edits"
OUT="$(role "$H" "sess-alpha")"
assert_has "override marker -> warning" "override marker" "$OUT"
rm -f "$H/.claude/state/allow-main-checkout-edits"

say "== roles: claim/release/status =="
H="$(new_home)"; PEER="$(add_peer "$H")"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "claim succeeds" 0 "$RC"
OUT="$(role "$H" "sess-alpha")"
assert_has "claimer sees ORCHESTRATOR" "ORCHESTRATOR" "$OUT"
OUT="$(role "$H" "sess-beta")"
assert_has "peer sees WORKER" "WORKER" "$OUT"
assert_has "worker told coordinator name" "alpha" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" status 2>&1)"
assert_has "status names holder" "alpha" "$OUT"
# dead holder: point marker at a dead session id/pid
DEADPID=999999
printf '{"pid":%s,"name":"ghost","sessionId":"sess-ghost","kind":"interactive"}\n' "$DEADPID" > "$H/.claude/sessions/$DEADPID.json"
printf 'sess-ghost\n' > "$H/.claude/state/orchestrator"
OUT="$(role "$H" "sess-alpha")"
assert_has "dead holder -> stale hint with human gate" "your user" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" release 2>&1)"; RC=$?
assert_rc "release of DEAD holder succeeds" 0 "$RC"
OUT="$(role "$H" "sess-alpha")"
assert_empty "after release -> silent" "" "$OUT"
kill "$PEER" 2>/dev/null

say "== remote-control reminder on claim =="
H2="$(new_home)"
printf '{"remoteControlAtStartup":false}' > "$H2/.claude/settings.json"
OUT="$(HOME="$H2" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "claim with RC-off setting still exits 0" 0 "$RC"
assert_has "explicit RC-off -> reminder" "/remote-control" "$OUT"
H3="$(new_home)"
printf '{"unrelated":true}' > "$H3/.claude/settings.json"
OUT="$(HOME="$H3" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"
case "$OUT" in *"/remote-control"*) bad "absent key -> no reminder" "$OUT" ;; *) ok "absent key -> no reminder" ;; esac

say "== worktree guard =="
H="$(new_home)"
mkdir -p "$H/code/app" "$H/code/.worktrees-app" "$H/code/app/.wt-inside"
CFG="{\"protectedCheckouts\":[{\"name\":\"app\",\"root\":\"$H/code/app\",\"base\":\"origin/main\"}]}"
printf '%s' "$CFG" > "$H/.claude/middle-management.json"
OUT="$(edit_json "$H/code/app/src/x.ts" | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GUARD" 2>&1)"
assert_has "edit in root -> deny" '"deny"' "$OUT"
assert_has "deny carries runnable wt cmd" 'scripts/wt\" app new' "$OUT"
assert_has "deny carries escape hatch" "allow-main-checkout-edits" "$OUT"
OUT="$(edit_json "$H/code/.worktrees-app/topic/x.ts" | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GUARD" 2>&1)"
assert_empty "edit in default sibling worktreeDir -> allow" "" "$OUT"
CFG="{\"protectedCheckouts\":[{\"name\":\"app\",\"root\":\"$H/code/app\",\"base\":\"origin/main\",\"worktreeDir\":\"$H/code/app/.wt-inside\"}]}"
printf '%s' "$CFG" > "$H/.claude/middle-management.json"
OUT="$(edit_json "$H/code/app/.wt-inside/topic/x.ts" | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GUARD" 2>&1)"
assert_empty "worktreeDir INSIDE root -> still allowed" "" "$OUT"
OUT="$(edit_json "$H/elsewhere/x.ts" | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GUARD" 2>&1)"
assert_empty "edit outside any root -> allow" "" "$OUT"
printf '{oops' > "$H/.claude/middle-management.json"
OUT="$(edit_json "$H/code/app/src/x.ts" | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GUARD" 2>&1)"
assert_empty "unusable config -> guard fails open (role hook shouts instead)" "" "$OUT"
rm -f "$H/.claude/middle-management.json"
OUT="$(edit_json "$H/code/app/src/x.ts" | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GUARD" 2>&1)"
assert_empty "no config -> guard silent" "" "$OUT"
printf '%s' "$CFG" > "$H/.claude/middle-management.json"
mkdir -p "$H/.claude/state" && touch "$H/.claude/state/allow-main-checkout-edits"
OUT="$(edit_json "$H/code/app/src/x.ts" | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GUARD" 2>&1)"
assert_empty "override marker -> guard allows" "" "$OUT"
rm -f "$H/.claude/state/allow-main-checkout-edits"

say "== CLAUDE_CONFIG_DIR branch =="
ALT="$(mktemp -d)"; mkdir -p "$ALT/state"
CFG="{\"protectedCheckouts\":[{\"name\":\"app\",\"root\":\"$H/code/app\",\"base\":\"origin/main\"}]}"
printf '%s' "$CFG" > "$ALT/middle-management.json"
OUT="$(edit_json "$H/code/app/src/x.ts" | HOME="$H" CLAUDE_CONFIG_DIR="$ALT" bash "$GUARD" 2>&1)"
assert_has "config found via CLAUDE_CONFIG_DIR -> deny" '"deny"' "$OUT"
assert_has "deny text carries RESOLVED config-dir path" "$ALT" "$OUT"

say "== git-add blocker =="
H="$(new_home)"
OUT="$(bash_json 'git add -A' | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GITADD" 2>&1)"
assert_has "no config: git add -A -> deny" '"deny"' "$OUT"
assert_has "deny self-identifies" "middle-management" "$OUT"
OUT="$(bash_json 'git add src/main.ts docs/x.md' | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GITADD" 2>&1)"
assert_empty "explicit paths -> allow" "" "$OUT"
printf '{"surgicalStaging":false}' > "$H/.claude/middle-management.json"
OUT="$(bash_json 'git add -A' | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GITADD" 2>&1)"
assert_empty "surgicalStaging=false -> allow" "" "$OUT"
printf '{"surgicalStaging":false,"protectedCheckouts":[{"name":"x","root":"/tmp"}]}' > "$H/.claude/middle-management.json"
OUT="$(bash_json 'git add -A' | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GITADD" 2>&1)"
assert_has "shape-invalid + false -> forced ON" '"deny"' "$OUT"
assert_has "forced-ON reason names invalid config" "invalid" "$OUT"
OUT="$(bash_json 'git commit -am x' | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GITADD" 2>&1)"
assert_has "git commit -am -> deny" '"deny"' "$OUT"

say "== wt against throwaway repos =="
H="$(new_home)"
W="$(mktemp -d)"
git -C "$W" init -qb main remote-repo-src 2>/dev/null
REMOTE="$W/remote-repo-src"
git -C "$REMOTE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REMOTE" branch -q dev
git clone -q -b dev "$REMOTE" "$W/app" 2>/dev/null
CFG="{\"protectedCheckouts\":[{\"name\":\"app\",\"root\":\"$W/app\",\"base\":\"origin/dev\"}]}"
printf '%s' "$CFG" > "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app new topic1 2>&1)"; RC=$?
assert_rc "wt new (remote repo) succeeds" 0 "$RC"
[ -d "$W/.worktrees-app/topic1" ] && ok "worktree created at sibling default" || bad "worktree created at sibling default" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app list 2>&1)"
assert_has "wt list shows topic1" "topic1" "$OUT"
# local-only repo, base = local branch
git -C "$W" init -qb main solo 2>/dev/null
git -C "$W/solo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
CFG="{\"protectedCheckouts\":[{\"name\":\"app\",\"root\":\"$W/app\",\"base\":\"origin/dev\"},{\"name\":\"solo\",\"root\":\"$W/solo\",\"base\":\"main\"}]}"
printf '%s' "$CFG" > "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" solo new t2 2>&1)"; RC=$?
assert_rc "wt new (no remote, local base) succeeds" 0 "$RC"
CFG="{\"protectedCheckouts\":[{\"name\":\"nb\",\"root\":\"$W/solo\",\"base\":\"origin/nope\"}]}"
printf '%s' "$CFG" > "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" nb new t3 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "unresolvable base -> loud refusal" || bad "unresolvable base -> loud refusal" "$OUT"
assert_has "refusal points at setup" "middle-management-setup" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" ghost new x 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "unknown name -> loud error" || bad "unknown name -> loud error" "$OUT"

say ""
say "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
