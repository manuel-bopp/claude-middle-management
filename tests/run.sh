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
assert_has "orchestrator banner: one lane one session" "One lane = one session" "$OUT"
assert_has "orchestrator banner: closable tabs get their own message" "close this tab" "$OUT"
assert_has "orchestrator banner: waiting items carry their link" "in the SAME" "$OUT"
assert_has "orchestrator banner: housekeeping vs destruction" "housekeeping, not" "$OUT"
# no config file at all (roles-only install): the off-keyboard line must stay away, and the
# hook must survive `set -u` with no config branch taken.
assert_lacks "no config -> no off-keyboard line" "notifyCommand" "$OUT"
OUT="$(role "$H" "sess-beta")"
assert_has "peer sees WORKER" "WORKER" "$OUT"
assert_has "worker told coordinator name" "alpha" "$OUT"
assert_has "worker banner: sub-orchestrator of its lane" "SUB-ORCHESTRATOR of your lane" "$OUT"
assert_has "worker banner: sub-agents return ten lines" "at most ten lines" "$OUT"
assert_has "worker banner: report the context fill" "context fill" "$OUT"
assert_has "worker banner: the lane ends with its resources released" "resources released" "$OUT"
assert_has "worker banner: hold when the slot must stay" "/wt <name> hold" "$OUT"
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
assert_rc "wt done from a cwd inside the worktree -> refused with 3" 3 "$RC"
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
# a tag of the same name shadows the branch: the short forms return "heads/tagged" and the
# delete would target refs/heads/heads/tagged
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app new tagged >/dev/null 2>&1
git -C "$W/app" tag tagged
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app done tagged 2>&1)"; RC=$?
assert_rc "wt done with a tag shadowing the branch name -> rc 0" 0 "$RC"
assert_has "shadowed branch deleted under its real ref" "branch tagged deleted" "$OUT"
git -C "$W/app" rev-parse --verify --quiet refs/heads/tagged >/dev/null \
  && bad "shadowed branch ref really gone" || ok "shadowed branch ref really gone"
git -C "$W/app" rev-parse --verify --quiet refs/tags/tagged >/dev/null \
  && ok "the tag itself survived" || bad "the tag itself survived"
# detached HEAD: the printed tip is the only record of the commits the removal orphans, so it
# must come from the worktree, not from the root checkout
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app new det >/dev/null 2>&1
git -C "$W/.worktrees-app/det" checkout -q --detach
WTIP="$(git -C "$W/.worktrees-app/det" rev-parse HEAD)"
git -C "$W/app" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root-moved
RTIP="$(git -C "$W/app" rev-parse HEAD)"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app done det 2>&1)"; RC=$?
assert_rc "wt done on a detached worktree -> rc 0" 0 "$RC"
assert_has "detached worktree prints its OWN tip" "$WTIP" "$OUT"
assert_lacks "detached worktree does not print the root's tip" "$RTIP" "$OUT"
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

say "== wt lanes: list columns, hold, run =="
CFG="{\"protectedCheckouts\":[{\"name\":\"app\",\"root\":\"$W/app\",\"base\":\"origin/dev\"}]}"
printf '%s' "$CFG" > "$H/.claude/middle-management.json"
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app new lane1 >/dev/null 2>&1
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" list 2>&1)"
assert_has "wt list prints the documented header" "# checkout worktree branch unit owner alive started mem hold state merged pr" "$OUT"
ROW="$(printf '%s\n' "$OUT" | grep '^app lane1 ' || true)"
# a lane that has produced nothing is NOT merged, however much its HEAD is an ancestor of the
# base: `wt new` sets its upstream to the base, which would otherwise read as "landed already"
assert_has "a fresh lane: no unit, no owner, clean, NOT merged" "app lane1 lane1 - - - - - - clean no" "$ROW"
assert_rc "the row has exactly 12 fields" 12 "$(printf '%s' "$ROW" | wc -w)"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app hold lane1 3 2>&1)"; RC=$?
assert_rc "wt hold succeeds" 0 "$RC"
assert_has "hold names the lane key" "hold for app-lane1 until" "$OUT"
ROW="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app list 2>&1 | grep '^app lane1 ' || true)"
assert_lacks "the hold column is no longer empty" "- - - - - clean" "$ROW"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app hold lane1 0 2>&1)"
assert_has "hold 0 clears it" "hold cleared for app-lane1" "$OUT"
ROW="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app list 2>&1 | grep '^app lane1 ' || true)"
assert_has "the cleared hold reads as -" "app lane1 lane1 - - - - - - clean no" "$ROW"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app hold lane1 soon 2>&1)"; RC=$?
assert_rc "hold with a non-numeric duration -> refused" 1 "$RC"
printf 'x' > "$W/.worktrees-app/lane1/dirt.txt"
ROW="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app list 2>&1 | grep '^app lane1 ' || true)"
assert_has "an uncommitted file shows as dirty" " dirty " "$ROW"
git -C "$W/.worktrees-app/lane1" add dirt.txt
git -C "$W/.worktrees-app/lane1" -c user.email=t@t -c user.name=t commit -q -m dirt
ROW="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app list 2>&1 | grep '^app lane1 ' || true)"
assert_has "a commit that is nowhere else shows as unpushed, not merged" " unpushed no " "$ROW"
# a lane that was pushed under its own name and whose commits landed in the base IS merged
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app new landed >/dev/null 2>&1
git -C "$W/.worktrees-app/landed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m landed
git -C "$W/.worktrees-app/landed" push -q -u origin landed 2>/dev/null
git -C "$W/.worktrees-app/landed" push -q origin HEAD:dev 2>/dev/null
git -C "$W/app" fetch -q origin
ROW="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app list 2>&1 | grep '^app landed ' || true)"
assert_has "a pushed lane whose work landed in the base reads merged" " clean yes " "$ROW"
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app done landed >/dev/null 2>&1
# run: refused without a systemd user manager, and refused without a command
NOSD="$(mktemp -d -p "$TMPBASE")"; ln -s /usr/bin/* /bin/* "$NOSD"/ 2>/dev/null
rm -f "$NOSD/systemctl" "$NOSD/systemd-run"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$NOSD" bash "$WT" app run lane1 -- sleep 60 2>&1)"; RC=$?
assert_rc "wt run without systemd -> refused" 1 "$RC"
assert_has "the refusal names the systemd user manager" "systemd user manager" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$NOSD" bash "$WT" app list 2>&1)"
assert_has "wt list still works without systemd" "app lane1 lane1 - " "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app run lane1 2>&1)"; RC=$?
assert_rc "wt run with neither a command nor a serve key -> refused" 1 "$RC"
assert_has "the refusal names the serve key" '"serve"' "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app run nolane -- sleep 60 2>&1)"; RC=$?
assert_rc "wt run for a lane that does not exist -> refused" 1 "$RC"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$NOSD" bash "$WT" cap -- true 2>&1)"; RC=$?
assert_rc "wt cap without systemd -> refused" 1 "$RC"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" cap true 2>&1)"; RC=$?
assert_rc "wt cap without -- -> refused" 1 "$RC"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app new 'two words' 2>&1)"; RC=$?
assert_rc "a topic with whitespace -> refused (it would break the list columns)" 1 "$RC"
# chown: a lane handed over does not go ownerless when the session that started it ends
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app chown lane1 someone 2>&1)"; RC=$?
assert_rc "wt chown succeeds" 0 "$RC"
ROW="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app list 2>&1 | grep '^app lane1 ' || true)"
assert_has "the new owner shows in the list" " someone " "$ROW"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app chown lane1 2>&1)"; RC=$?
assert_rc "chown without an owner -> refused" 1 "$RC"
# stop drops the owner marker but keeps a valid hold — the hold protects the lane, not the unit
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app hold lane1 3 >/dev/null
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$NOSD" bash "$WT" app stop lane1 2>&1)"
assert_has "stop says the hold survived" "hold kept until" "$OUT"
ROW="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app list 2>&1 | grep '^app lane1 ' || true)"
assert_lacks "the owner marker is gone after stop" " someone " "$ROW"
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app hold lane1 0 >/dev/null
# a checkout whose root cannot be read must fail loudly, not vanish from the view
CFGBAD="{\"protectedCheckouts\":[{\"name\":\"gone\",\"root\":\"$W/vanished\",\"base\":\"origin/dev\"}]}"
printf '%s' "$CFGBAD" > "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" list 2>&1)"; RC=$?
assert_rc "wt list with an unreadable checkout root -> loud failure" 1 "$RC"
assert_has "the failure names the checkout" "checkout 'gone'" "$OUT"
printf '%s' "$CFG" > "$H/.claude/middle-management.json"

say "== long-runners as units (optional hook) =="
LRU="$P/hooks/long-running-as-unit.sh"
lru() {  # $1 = cwd, $2 = command -> the hook's stdout
  jq -n --arg d "$1" --arg c "$2" '{cwd:$d,tool_input:{command:$c}}' \
    | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$LRU" 2>&1
}
LANE="$W/.worktrees-app/lane1"
CFG="{\"protectedCheckouts\":[{\"name\":\"app\",\"root\":\"$W/app\",\"base\":\"origin/dev\"}]}"
printf '%s' "$CFG" > "$H/.claude/middle-management.json"
assert_empty "config without the key -> hook silent" "" "$(lru "$LANE" 'next dev')"
CFG="{\"longRunningAsUnit\":true,\"protectedCheckouts\":[{\"name\":\"app\",\"root\":\"$W/app\",\"base\":\"origin/dev\"}]}"
printf '%s' "$CFG" > "$H/.claude/middle-management.json"
OUT="$(lru "$LANE" 'next dev')"
assert_has "long-runner in a lane -> allowed" '"allow"' "$OUT"
assert_has "long-runner in a lane -> rewritten to wt run" "app run lane1 -- next dev" "$OUT"
OUT="$(lru "$LANE/apps/web" 'pnpm run dev')"
assert_has "a subdirectory of the lane still names the lane" "app run lane1 --" "$OUT"
OUT="$(lru "$W/app" 'next dev')"
assert_empty "long-runner outside every lane -> left alone" "" "$OUT"
OUT="$(lru "$LANE" 'cd apps/web && next dev')"
assert_has "long-runner inside a compound command -> denied" '"deny"' "$OUT"
assert_has "the denial carries the replacement line" "app run lane1 -- bash -lc" "$OUT"
OUT="$(lru "$LANE" 'nohup next dev &')"
assert_has "nohup … & -> the replacement drops both" "bash -lc 'next dev'" "$OUT"
OUT="$(lru "$W/app" 'bun test')"
assert_has "heavy one-shot -> allowed" '"allow"' "$OUT"
assert_has "heavy one-shot -> rewritten to wt cap" "cap -- bun test" "$OUT"
OUT="$(lru "$W/app" 'bun test 2>&1 | tail -5')"
assert_has "heavy one-shot in a pipe -> wrapped in bash -lc" "cap -- bash -lc" "$OUT"
assert_empty "prose about a command -> no match" "" "$(lru "$W/app" 'echo "bun test"')"
assert_empty "grep for a command -> no match" "" "$(lru "$LANE" "grep 'next dev' package.json")"
assert_empty "already routed through wt -> no match" "" "$(lru "$LANE" "bash \"$P/scripts/wt\" app run lane1 -- next dev")"
touch "$H/.claude/state/allow-hand-start"
assert_empty "override marker -> hook stands down" "" "$(lru "$LANE" 'next dev')"
rm -f "$H/.claude/state/allow-hand-start"
printf '{oops' > "$H/.claude/middle-management.json"
assert_empty "unusable config -> hook silent (the role hook shouts instead)" "" "$(lru "$LANE" 'next dev')"

say "== lane reaper: decisions against a stub wt =="
REAPER="$P/scripts/lane-reaper.sh"
H="$(new_home)"
printf '{"reaperMaxHours":10,"reaperOwnerlessMinutes":30}' > "$H/.claude/middle-management.json"
STUB="$(mktemp -d -p "$TMPBASE")"
cat > "$STUB/wt" <<'STUBEOF'
#!/usr/bin/env bash
[ "$1" = list ] && { cat "$STUB_LIST"; exit 0; }
printf '%s\n' "$*" >> "$STUB_LOG"
if [ -n "${STUB_ACT_RC:-}" ]; then
  echo "wt: refusing to remove it — these processes have their cwd inside it:" >&2
  echo "  pid 4242  bash  cwd /lane" >&2
  exit "$STUB_ACT_RC"
fi
echo "removed it; branch b deleted, tip was abc1234"
STUBEOF
chmod +x "$STUB/wt"
export STUB_LIST="$STUB/list.txt" STUB_LOG="$STUB/log.txt"
HDR="# checkout worktree branch unit owner alive started mem hold state merged pr"
OLD="$(date -d '-20 hours' +%Y-%m-%dT%H:%M)"; YOUNG="$(date -d '-1 hour' +%Y-%m-%dT%H:%M)"
reap() {  # rest = flags -> the reaper's output; actions land in $STUB_LOG
  HOME="$H" CLAUDE_CONFIG_DIR="" MM_WT="$STUB/wt" MM_REAPER_NO_NOTIFY=1 bash "$REAPER" "$@" 2>&1
}
lanes() { printf '%s\n' "$HDR" "$@" > "$STUB_LIST"; : > "$STUB_LOG"; }

lanes "app lane1 lane1 wt-app-lane1.service beta yes $OLD 100M - clean no none"
OUT="$(reap)"; RC=$?
assert_rc "a run with one action exits 0" 0 "$RC"
assert_has "a unit older than reaperMaxHours is stopped" "app stop lane1" "$(cat "$STUB_LOG")"
lanes "app lane1 lane1 wt-app-lane1.service beta yes $OLD 100M $(date -d '+2 hours' +%Y-%m-%dT%H:%M) clean no none"
OUT="$(reap)"
assert_empty "a valid hold blocks the expiry" "" "$(cat "$STUB_LOG")"
assert_has "the held lane is listed as held" "| held |" "$(cat "$H/.claude/state/wt/reaper-latest.md")"
lanes "app lane1 lane1 wt-app-lane1.service beta no $YOUNG 100M - clean no none"
OUT="$(reap)"
assert_empty "a gone owner is not acted on at the FIRST sighting" "" "$(cat "$STUB_LOG")"
: > "$STUB_LOG"
OUT="$(reap --now +1h)"
assert_has "a gone owner is acted on at the second sighting" "app stop lane1" "$(cat "$STUB_LOG")"
lanes "app lane1 lane1 wt-app-lane1.service - - $YOUNG 100M - clean no none"
OUT="$(reap --now +1h)"
assert_empty "an unknown owner is never treated as gone" "" "$(cat "$STUB_LOG")"
lanes "app lane1 lane1 - beta yes - - - clean yes MERGED"
OUT="$(reap)"
assert_has "a merged, clean, unit-less lane is removed" "app done lane1" "$(cat "$STUB_LOG")"
assert_has "the tip SHA from wt is carried into the listing" "tip was abc1234" "$OUT"
lanes "app lane1 lane1 - beta yes - - - clean no MERGED"
OUT="$(reap)"
assert_has "a squash-merged lane is removed on the pr column alone" "app done lane1" "$(cat "$STUB_LOG")"
lanes "app lane1 lane1 - beta yes - - - dirty yes MERGED"
OUT="$(reap)"
assert_empty "a dirty tree is never removed, however merged" "" "$(cat "$STUB_LOG")"
assert_has "the dirty lane is listed with its reason" "tree is dirty" "$OUT"
lanes "app lane1 lane1 - beta yes - - - unpushed no OPEN"
OUT="$(reap)"
assert_empty "unpushed commits are never removed" "" "$(cat "$STUB_LOG")"
lanes "app lane1 lane1 - beta yes - - - clean no OPEN"
OUT="$(reap)"
assert_empty "an open pull request is only listed" "" "$(cat "$STUB_LOG")"
# a lane straight out of `wt new` reads exactly this row — it must survive
lanes "app fresh fresh - - - - - - clean no none"
OUT="$(reap)"; RC=$?
assert_rc "a fresh lane run exits 0" 0 "$RC"
assert_empty "a lane that has produced nothing is never removed" "" "$(cat "$STUB_LOG")"
# the gh-less half of the merged rule: the local verdict alone is enough
lanes "app lane1 lane1 - beta yes - - - clean yes none"
OUT="$(reap)"
assert_has "merged yes with no pull request at all -> removed" "app done lane1" "$(cat "$STUB_LOG")"
lanes "app lane1 lane1 - beta yes - - - clean no error"
OUT="$(reap)"; RC=$?
assert_rc "an unreadable pr state alarms" 1 "$RC"
assert_empty "an unreadable pr state acts on nothing" "" "$(cat "$STUB_LOG")"
assert_has "the unreadable pr state says so" "UNKNOWN" "$OUT"
# a worktree somebody is working in: wt refuses with 3, which is a state, not an alarm
lanes "app lane1 lane1 - beta yes - - - clean yes MERGED"
export STUB_ACT_RC=3
OUT="$(reap)"; RC=$?
unset STUB_ACT_RC
assert_rc "a refused removal does not alarm" 0 "$RC"
assert_has "the refused lane is listed as busy" "still works inside app-lane1" "$OUT"
assert_has "the busy row names the pid" "pid 4242" "$OUT"
lanes "app lane1 lane1 - beta yes - - - clean yes MERGED" "app lane2 lane2 - beta yes - - - clean yes MERGED"
OUT="$(reap --only lane2)"
assert_lacks "--only keeps the other lane untouched" "app done lane1" "$(cat "$STUB_LOG")"
assert_has "--only acts on the named lane" "app done lane2" "$(cat "$STUB_LOG")"
lanes "app lane1 lane1 - beta yes - - - clean yes MERGED"
OUT="$(reap --dry-run)"
assert_empty "--dry-run changes nothing" "" "$(cat "$STUB_LOG")"
assert_has "--dry-run says what it would do" "merged: app-lane1" "$OUT"
[ -f "$H/.claude/state/wt/reaper-latest.md" ] && ok "the listing file is written" || bad "the listing file is written"
mkdir -p "$H/.claude/state/wt"; printf 'beta' > "$H/.claude/state/wt/owner-app-gone"
lanes "app lane1 lane1 - beta yes - - - clean no OPEN"
OUT="$(reap)"
[ -f "$H/.claude/state/wt/owner-app-gone" ] && bad "the marker of a vanished lane is deleted" || ok "the marker of a vanished lane is deleted"
# one send a day even when nothing changed: a dead timer must not look like a quiet machine
lanes "app lane1 lane1 - beta yes - - - clean no OPEN"
OUT="$(reap)"
OUT="$(reap)"
assert_has "a second run with nothing new sends nothing" "no change, nothing sent" "$OUT"
OUT="$(reap --now +24h)"
assert_has "the first run of a new day sends a digest anyway" "daily digest" "$OUT"
lanes "app lane1 lane1 - beta yes - clean"
OUT="$(reap)"; RC=$?
assert_rc "a row with the wrong column count -> loud failure" 1 "$RC"
assert_has "the failure refuses to guess" "refusing to guess" "$OUT"
unset STUB_LIST STUB_LOG

say "== lane reaper against the real wt: a fresh lane survives a full run =="
H="$(new_home)"
W2="$(mktemp -d -p "$TMPBASE")"
git -C "$W2" init -qb main src >/dev/null 2>&1
git -C "$W2/src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git clone -q "$W2/src" "$W2/app" 2>/dev/null
printf '{"protectedCheckouts":[{"name":"app","root":"%s/app","base":"origin/main"}]}' "$W2" \
  > "$H/.claude/middle-management.json"
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$WT" app new fresh >/dev/null 2>&1
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_REAPER_NO_NOTIFY=1 bash "$REAPER" 2>&1)"; RC=$?
assert_rc "a real run over a fresh lane exits 0" 0 "$RC"
[ -d "$W2/.worktrees-app/fresh" ] && ok "the fresh worktree is still there" || bad "the fresh worktree is still there" "$OUT"
git -C "$W2/app" rev-parse --verify --quiet refs/heads/fresh >/dev/null \
  && ok "the fresh branch is still there" || bad "the fresh branch is still there" "$OUT"

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
