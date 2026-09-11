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
TMPBASE="$(mktemp -d -t mm-plugin-tests.XXXXXX)"   # every fake HOME and fixture repo lives here

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); say "  ok  - $1"; }
bad()  { FAIL=$((FAIL+1)); say "  FAIL- $1"; [ -n "${2:-}" ] && say "        got: $2"; }
# assert <name> <needle> <haystack>
assert_has()    { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$3" ;; esac; }
assert_lacks()  { case "$3" in *"$2"*) bad "$1" "$3" ;; *) ok "$1" ;; esac; }
assert_empty()  { [ -z "$3" ] && ok "$1" || bad "$1" "$3"; }
assert_rc()     { [ "$3" -eq "$2" ] && ok "$1" || bad "$1" "rc=$3 (want $2)"; }

new_home() {  # [$1 = registry name of THIS process, default alpha] -> fresh fake HOME with a live entry for $$
  T="$(mktemp -d -p "$TMPBASE")"; [ "$T" = "$HOME" ] && { echo "refusing: real HOME"; exit 2; }
  mkdir -p "$T/.claude/sessions" "$T/.claude/state"
  printf '{"pid":%s,"name":"%s","sessionId":"sess-%s","kind":"interactive"}\n' "$$" "${1:-alpha}" "${1:-alpha}" \
    > "$T/.claude/sessions/$$.json"
  echo "$T"
}
PEERS=""
add_peer() {  # $1=home [$2=name, default beta] [$3=kind, default interactive] -> live peer (a sleep), echoes its pid
  # stdout/stderr detached: a sleep inheriting the capture pipe would block $(add_peer …)
  sleep 300 >/dev/null 2>&1 </dev/null & SPID=$!
  PEERS="$PEERS $SPID"
  printf '{"pid":%s,"name":"%s","sessionId":"sess-%s","kind":"%s"}\n' "$SPID" "${2:-beta}" "${2:-beta}" "${3:-interactive}" \
    > "$1/.claude/sessions/$SPID.json"
  echo "$SPID"
}
cleanup() { for p in $PEERS; do kill "$p" 2>/dev/null; done; case "$TMPBASE" in /tmp/*|/var/tmp/*) find "$TMPBASE" -depth -delete 2>/dev/null ;; esac; }
trap cleanup EXIT
role() {  # $1=home $2=my session_id [$3=extra env assignments via env]
  printf '{"session_id":"%s"}' "$2" | HOME="$1" CLAUDE_CONFIG_DIR="" bash "$ROLE" 2>&1
}
as_peer() {  # $1=home $2=name, rest = orchestrator.sh args — run as ANOTHER session (its own registry entry)
  HOME="$1" CLAUDE_CONFIG_DIR="" bash -c 'printf "{\"pid\":%s,\"name\":\"%s\",\"sessionId\":\"sess-%s\",\"kind\":\"interactive\"}\n" "$$" "$1" "$1" > "$HOME/.claude/sessions/$$.json"
    bash "$2" "${@:3}"; rc=$?; rm -f "$HOME/.claude/sessions/$$.json"; exit $rc' _ "$2" "$ORCH" "${@:3}" 2>&1
}
edit_json() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }
bash_json() { printf '{"tool_input":{"command":"%s"}}' "$1"; }

REAL_MARKER="$(bash "$P/scripts/config-check.sh" dir)/state/allow-main-checkout-edits"
REAL_MARKER_BEFORE="$([ -e "$REAL_MARKER" ] && echo yes || echo no)"

say "== role hook: preconditions =="
H="$(new_home)"
# a PATH with everything except jq (a bare broken PATH would not even find bash)
JQLESS="$(mktemp -d -p "$TMPBASE")"; ln -s /usr/bin/* /bin/* "$JQLESS"/ 2>/dev/null; rm -f "$JQLESS/jq"
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
OUT="$(printf '{"session_id":"x"}' | HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$JQLESS" bash "$ROLE" 2>&1)"
assert_has "override nag fires even without jq" "override marker" "$OUT"
rm -f "$H/.claude/state/allow-main-checkout-edits"
mkdir -p "$H/.claude/state/allow-main-checkout-edits"   # a DIRECTORY disarms the guard too (-e)
OUT="$(role "$H" "sess-alpha")"
assert_has "override marker as a directory -> warning" "override marker" "$OUT"
rmdir "$H/.claude/state/allow-main-checkout-edits"
[ "$([ -e "$REAL_MARKER" ] && echo yes || echo no)" = "$REAL_MARKER_BEFORE" ] && ok "real override marker untouched" || bad "real override marker untouched"

say "== roles: claim/release/status =="
H="$(new_home)"; PEER="$(add_peer "$H")"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "claim succeeds" 0 "$RC"
OUT="$(role "$H" "sess-alpha")"
assert_has "claimer sees ORCHESTRATOR" "ORCHESTRATOR" "$OUT"
assert_has "orchestrator banner: sub-agents return ten lines" "at most ten lines" "$OUT"
assert_has "orchestrator banner: model choice announced" "whether the strongest model was" "$OUT"
# no config file at all (roles-only install): the off-keyboard line must stay away, and the
# hook must survive `set -u` with no config branch taken.
assert_lacks "no config -> no off-keyboard line" "notifyCommand" "$OUT"
OUT="$(role "$H" "sess-beta")"
assert_has "peer sees WORKER" "WORKER" "$OUT"
assert_has "worker told coordinator name" "alpha" "$OUT"
printf '{"board":"%s/board.md"}' "$H" > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-alpha")"
assert_has "orchestrator banner: sole writer of the board" "sole writer of the board $H/board.md" "$OUT"
assert_has "orchestrator banner: RE-WAKE checklist first" "RE-WAKE checklist" "$OUT"
assert_lacks "board but no notifyCommand -> no off-keyboard line" "off-keyboard channel" "$OUT"
printf '{"board":"%s/board.md","notifyCommand":"true"}' "$H" > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-alpha")"
assert_has "notifyCommand configured -> off-keyboard line" "off-keyboard channel" "$OUT"
printf '{"board":"%s/board.md"}' "$H" > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-beta")"
assert_has "worker banner: board read-only" "read-only for you" "$OUT"
rm -f "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" status 2>&1)"
assert_has "status names holder" "alpha" "$OUT"
OUT="$(as_peer "$H" gamma release)"; RC=$?
assert_rc "release by a non-holder while the holder is ALIVE -> refused" 1 "$RC"
assert_has "refusal says REFUSED" "REFUSED" "$OUT"
[ -f "$H/.claude/state/orchestrator" ] && ok "marker survives the refused release" || bad "marker survives the refused release"
OUT="$(as_peer "$H" gamma claim)"; RC=$?
assert_rc "claim over a live holder -> BUSY" 1 "$RC"
assert_has "BUSY names a runnable release command" "orchestrator.sh release" "$OUT"
# dead holder: point marker at a dead session id/pid
DEADPID=999999
printf '{"pid":%s,"name":"ghost","sessionId":"sess-ghost","kind":"interactive"}\n' "$DEADPID" > "$H/.claude/sessions/$DEADPID.json"
printf 'sess-ghost\n' > "$H/.claude/state/orchestrator"
OUT="$(role "$H" "sess-alpha")"
assert_has "dead holder -> stale hint with human gate" "your user" "$OUT"
assert_has "stale hint names claim" "orchestrator.sh claim" "$OUT"
assert_has "stale hint names release <id>" "orchestrator.sh release sess-ghost" "$OUT"
assert_has "stale hint: workers keep working their lane" "keep working their lane" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" status 2>&1)"
assert_has "status names the dead holder's id" "sess-ghost" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" release 2>&1)"; RC=$?
assert_rc "release of a DEAD holder WITHOUT its id -> refused" 1 "$RC"
assert_has "refusal names the runnable release <id>" "release sess-ghost" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" release wrong-id 2>&1)"; RC=$?
assert_rc "release <wrong id> -> refused" 1 "$RC"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" release sess-ghost 2>&1)"; RC=$?
assert_rc "release <dead holder's id> by a non-holder succeeds" 0 "$RC"
[ -f "$H/.claude/state/orchestrator" ] && bad "marker gone after release <id>" || ok "marker gone after release <id>"
OUT="$(role "$H" "sess-alpha")"
assert_empty "after release -> silent" "" "$OUT"
printf 'sess-ghost\n' > "$H/.claude/state/orchestrator"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "claim over a dead holder succeeds" 0 "$RC"
assert_has "claim says the marker was taken over" "taken over" "$OUT"
kill "$PEER" 2>/dev/null

say "== liveness rule (F1): identity by sessionId, kind interactive =="
H="$(new_home)"
printf '{"pid":%s,"sessionId":"sess-noname","kind":"interactive"}\n' "$$" > "$H/.claude/sessions/$$.json"
printf 'sess-noname\n' > "$H/.claude/state/orchestrator"
OUT="$(role "$H" "sess-noname")"
assert_has "unnamed LIVE holder -> ORCHESTRATOR banner" 'ORCHESTRATOR ("unnamed"' "$OUT"
assert_lacks "unnamed LIVE holder -> no stale hint" "not visibly alive" "$OUT"
H="$(new_home)"; BG="$(add_peer "$H" daemon bg)"
printf 'sess-daemon\n' > "$H/.claude/state/orchestrator"
OUT="$(role "$H" "sess-alpha")"
assert_has "bg holder with a live pid -> hook treats the marker as stale" "not visibly alive" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "bg holder with a live pid -> claim succeeds (script agrees with the hook)" 0 "$RC"

say "== name route =="
H="$(new_home orchestrator)"; PEER="$(add_peer "$H" beta)"
OUT="$(role "$H" "sess-orchestrator")"
assert_has "orch* name, no marker -> ORCHESTRATOR by name" 'ORCHESTRATOR ("orchestrator", by name)' "$OUT"
OUT="$(role "$H" "sess-beta")"
assert_has "peer of the named coordinator -> WORKER" 'The coordinator is "orchestrator"' "$OUT"
printf 'sess-beta\n' > "$H/.claude/state/orchestrator"
OUT="$(role "$H" "sess-beta")"
assert_has "marker->beta while orchestrator lives -> WARNING" 'WARNING: the marker says the coordinator is "beta"' "$OUT"
assert_has "marker wins: beta gets the ORCHESTRATOR banner" "Session role: ORCHESTRATOR" "$OUT"
rm -f "$H/.claude/state/orchestrator"
X="$(add_peer "$H" orch-x)"
OUT="$(role "$H" "sess-orchestrator")"
assert_has "two orch* names, no marker -> BROKEN" "SESSION ROLES BROKEN" "$OUT"
kill "$PEER" "$X" 2>/dev/null

say "== registry error (the script cannot find its own session) =="
H="$(new_home)"; rm -f "$H/.claude/sessions/$$.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" status 2>&1)"; RC=$?
assert_rc "no registry entry in this process tree -> rc 1" 1 "$RC"
assert_has "error names the directory it searched" "looked in $H/.claude/sessions" "$OUT"

say "== remote-control reminder on claim =="
H2="$(new_home)"
printf '{"remoteControlAtStartup":false}' > "$H2/.claude/settings.json"
OUT="$(HOME="$H2" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "claim with RC-off setting still exits 0" 0 "$RC"
assert_has "explicit RC-off -> reminder" "/remote-control" "$OUT"
assert_has "RC off -> names the --rc start" "claude --rc -n orchestrator" "$OUT"
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
assert_has "deny carries the /add-dir hint" "/add-dir" "$OUT"
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
ALT="$(mktemp -d -p "$TMPBASE")"; mkdir -p "$ALT/state"
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

OUT="$(bash_json 'git add -A' | HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$JQLESS" bash "$GITADD" 2>&1)"
assert_has "blanket staging without jq -> still deny" '"deny"' "$OUT"
OUT="$(bash_json 'git add src/main.ts' | HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$JQLESS" bash "$GITADD" 2>&1)"
assert_empty "explicit paths without jq -> allow" "" "$OUT"

say "== wt against throwaway repos =="
H="$(new_home)"
W="$(mktemp -d -p "$TMPBASE")"
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
assert_has "wt new prints the session-access hint" "/add-dir" "$OUT"
assert_has "wt new prints the dev-server hint" "dev server:" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app list 2>&1)"
assert_has "wt list shows topic1" "topic1" "$OUT"
git -C "$W/.worktrees-app/topic1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c1
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app done topic1 2>&1)"; RC=$?
assert_rc "wt done with an unpushed commit -> refused" 1 "$RC"
assert_has "refusal names the branch" "branch topic1 has commits" "$OUT"
# a slash topic lands in a dash directory; `done` by the directory name must still name the real branch
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app new 'feat/slash' >/dev/null 2>&1
OUT="$(cd "$W/.worktrees-app/feat-slash" && HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app done feat-slash 2>&1)"; RC=$?
assert_rc "wt done from a cwd inside the worktree -> refused" 1 "$RC"
assert_has "refusal names the cwd" "cwd is inside" "$OUT"
[ -d "$W/.worktrees-app/feat-slash" ] && ok "refused done left the worktree alone" || bad "refused done left the worktree alone"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app done feat-slash 2>&1)"; RC=$?
assert_rc "wt done by directory name succeeds" 0 "$RC"
assert_has "merged branch deleted under its real name, not the directory" "branch feat/slash deleted" "$OUT"
assert_has "deletion prints the way back" "restore with: git -C $W/app branch feat/slash" "$OUT"
git -C "$W/app" rev-parse --verify --quiet 'refs/heads/feat/slash' >/dev/null \
  && bad "merged branch ref really gone" || ok "merged branch ref really gone"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app done feat-slash 2>&1)"; RC=$?
assert_rc "wt done on an already removed worktree -> rc 0" 0 "$RC"
assert_has "second done says already removed" "already removed" "$OUT"
# pushed but not merged: the branch survives, and the hint is update-ref (branch -D is deny-listed)
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app new pushed1 >/dev/null 2>&1
git -C "$W/.worktrees-app/pushed1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c2
git -C "$W/.worktrees-app/pushed1" push -q -u origin pushed1 2>/dev/null
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app done pushed1 2>&1)"; RC=$?
assert_rc "wt done on a pushed, unmerged branch succeeds" 0 "$RC"
assert_has "unmerged branch kept" "branch pushed1 kept" "$OUT"
assert_has "delete hint uses update-ref" "update-ref -d refs/heads/pushed1" "$OUT"
git -C "$W/app" rev-parse --verify --quiet refs/heads/pushed1 >/dev/null \
  && ok "unmerged branch ref still there" || bad "unmerged branch ref still there"
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
say "== heartbeat (tests/heartbeat.sh) =="
HB_OUT="$(bash "$ROOT/tests/heartbeat.sh" 2>&1)"; HB_RC=$?
printf '%s\n' "$HB_OUT" | grep -E '^\s+(FAIL|skip)' || true
HB_LINE="$(printf '%s\n' "$HB_OUT" | grep -E '^[0-9]+ passed' | tail -1)"
say "  ${HB_LINE:-heartbeat matrix did not report}"
[ "$HB_RC" -eq 0 ] || FAIL=$((FAIL+1))

say ""
say "RESULT: $PASS passed, $FAIL failed (plus heartbeat: ${HB_LINE:-FAILED TO RUN})"
[ "$FAIL" -eq 0 ]
