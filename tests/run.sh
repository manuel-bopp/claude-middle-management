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
printf '{"protectedCheckouts":[{"name":"two words","root":"/tmp","base":"main"}]}' > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-alpha")"
assert_has "a checkout name with whitespace -> invalid (it is a wt list column)" "is invalid" "$OUT"
printf '{"reaperDigestHour":24,"protectedCheckouts":[{"name":"x","root":"/tmp","base":"main"}]}' > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-alpha")"
assert_has "reaperDigestHour 24 (out of 0-23) -> invalid" "is invalid" "$OUT"
printf '{"reaperDigestHour":3.5,"protectedCheckouts":[{"name":"x","root":"/tmp","base":"main"}]}' > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-alpha")"
assert_has "reaperDigestHour 3.5 (not an integer) -> invalid" "is invalid" "$OUT"
printf '{"reaperDigestHour":0,"protectedCheckouts":[{"name":"x","root":"/tmp","base":"main"}]}' > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-alpha")"
assert_lacks "reaperDigestHour 0 (in range) -> valid" "is invalid" "$OUT"
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
# The banner asks for the closed-marker line only where a session log exists or a path was chosen
# for one (its own section below) — so this home gets one, like the machine the regime came from.
mkdir -p "$H/logs"; : > "$H/logs/session-log.md"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "claim succeeds" 0 "$RC"
OUT="$(role "$H" "sess-alpha")"
assert_has "claimer sees ORCHESTRATOR" "ORCHESTRATOR" "$OUT"
assert_has "orchestrator banner: sub-agents return ten lines" "at most ten lines" "$OUT"
assert_has "orchestrator banner: model choice announced" "whether the strongest model was" "$OUT"
assert_has "orchestrator banner: one lane one session" "One lane = one session" "$OUT"
assert_has "orchestrator banner: wrapped tabs are read off disk, not asked" 'scripts/peer-state.py" --wrapped' "$OUT"
# The printed command has to be runnable as printed: a plugin root with a space in it used to
# produce a command line that breaks at the space.
assert_has "orchestrator banner: the reader path is quoted" 'python3 "' "$OUT"
# ...and never narrowed by --cwd: a lane worktree is a SIBLING of the checkout, so filtering by
# the repo root hides exactly the workers the list exists for.
assert_lacks "orchestrator banner: the tab list is not narrowed by --cwd" "--cwd" "$OUT"
assert_has "orchestrator banner: a wrapped session is never peer-messaged" "NEVER peer-message a session" "$OUT"
assert_has "orchestrator banner: waiting items carry their link" "in the SAME" "$OUT"
assert_has "orchestrator banner: housekeeping vs destruction" "housekeeping, not" "$OUT"
# a coordinator wraps like anyone else, and its wake is the most expensive one there is
assert_has "orchestrator banner: the wrap entry carries the closed marker too" \
  "- Session: closed · sess-alpha" "$OUT"
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
# the wrap declares the session finished by sessionId — the next coordinator looks that up
# instead of inferring it from the transcript
assert_has "worker banner: the wrap entry carries the closed marker, keyed by this sessionId" \
  "- Session: closed · sess-beta" "$OUT"
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

say "== the session log: path resolution (config-check.sh session-log) =="
# One rule, three steps, and scripts/peer-state.py implements the same one in python. The exit
# code is the second fact the hook needs: was this path CHOSEN, or is it just the default?
CC="$P/scripts/config-check.sh"
H="$(new_home)"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" bash "$CC" session-log)"; RC=$?
assert_has "no env, no key -> the documented default" "$H/logs/session-log.md" "$OUT"
assert_rc "a defaulted path says so" 1 "$RC"
printf '{"sessionLog":"~/notes/log.md"}' > "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" bash "$CC" session-log)"; RC=$?
assert_has "the config key wins over the default, with ~ expanded" "$H/notes/log.md" "$OUT"
assert_rc "a chosen path says so" 0 "$RC"
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$CC" validate; RC=$?
assert_rc "a string sessionLog passes the shape filter" 0 "$RC"
printf '{"sessionLog":5}' > "$H/.claude/middle-management.json"
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$CC" validate; RC=$?
assert_rc "a sessionLog that is not a string is invalid config" 1 "$RC"
# ...and it must not become a PATH either: peer-state.py takes the default for a non-string, and
# a refusal naming a file the reader never read is worse than no detail at all.
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" bash "$CC" session-log)"; RC=$?
assert_has "a non-string sessionLog resolves to the default, like the python side" "$H/logs/session-log.md" "$OUT"
assert_rc "...and reports itself as defaulted" 1 "$RC"
# A RELATIVE value is the same class and the worse one: it would resolve against whatever
# directory the caller happens to run in — the seat sits in the checkout root, a worker in its
# lane worktree, the wrap somewhere else — so the two signals the seat needs come out of
# different files. Invalid config (loud), and it names no file: the default answers.
printf '{"sessionLog":"logs/session-log.md"}' > "$H/.claude/middle-management.json"
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$CC" validate; RC=$?
assert_rc "a relative sessionLog is invalid config" 1 "$RC"
OUT="$(cd /tmp && HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" bash "$CC" session-log)"; RC=$?
assert_has "a relative sessionLog resolves to the default, never the caller's cwd" "$H/logs/session-log.md" "$OUT"
assert_rc "...and reports itself as defaulted too" 1 "$RC"
printf '{"sessionLog":"%s/from-config.md"}' "$H" > "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="$H/from-env.md" bash "$CC" session-log)"; RC=$?
assert_has "MM_SESSION_LOG wins over the config key" "$H/from-env.md" "$OUT"
assert_rc "an env-chosen path says so too" 0 "$RC"
rm -f "$H/.claude/middle-management.json"

say "== the banner asks for the closed-marker line only where it can be filed =="
# It fires in EVERY session on EVERY message, for both roles. With no log and no path for one it
# named a file the user did not have and no way to get it — permanent, unactionable noise.
H="$(new_home)"; PEER="$(add_peer "$H")"
HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim >/dev/null 2>&1
OUT="$(role "$H" "sess-alpha")"
assert_has "no log, no key -> one hint line instead" "No session log yet" "$OUT"
assert_has "the hint names the path it would be created at" "$H/logs/session-log.md" "$OUT"
assert_has "the hint names what creates it" "middle-management:wrap" "$OUT"
assert_has "the hint names the config key for another path" "sessionLog" "$OUT"
assert_lacks "no log, no key -> no unfileable closed-marker line" "Session: closed" "$OUT"
mkdir -p "$H/logs"; : > "$H/logs/session-log.md"
OUT="$(role "$H" "sess-alpha")"
assert_has "a log at the default path -> the closed-marker line is back" "- Session: closed · sess-alpha" "$OUT"
assert_has "...followed by how a wrap ends" "name yourself, your topic" "$OUT"
assert_lacks "...and no hint line" "No session log yet" "$OUT"
OUT="$(role "$H" "sess-beta")"
assert_has "the worker gets the same instruction, keyed by its own id" "- Session: closed · sess-beta" "$OUT"
assert_has "the worker is pointed at the same skill" "(middle-management:wrap)" "$OUT"
rm -f "$H/logs/session-log.md"
printf '{"sessionLog":"%s/elsewhere/log.md"}' "$H" > "$H/.claude/middle-management.json"
OUT="$(role "$H" "sess-alpha")"
assert_has "a configured path that does not exist yet still gets the instruction" "- Session: closed · sess-alpha" "$OUT"
assert_lacks "a chosen path is never reported as missing" "No session log yet" "$OUT"
assert_lacks "sessionLog does not make the config invalid" "is invalid" "$OUT"
rm -f "$H/.claude/middle-management.json"
kill "$PEER" 2>/dev/null

say "== stale seat: claim over a holder that WRAPPED but left its tab open =="
# Everything the route needs is on disk — a registry entry (add_peer), a transcript, and that
# transcript's mtime as the idle age. The holder is never messaged, so no peer is started here.
H="$(new_home)"; PEER="$(add_peer "$H" beta)"
mkdir -p "$H/.claude/projects/-tmp-x"
TR="$H/.claude/projects/-tmp-x/sess-beta.jsonl"
holder_wrote() {  # $1 = the holder's last line, $2 = minutes since it wrote it,
                  # $3 = the Status: of its last session-log entry (default completed, "none" = no entry)
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}],"usage":{"input_tokens":7,"cache_read_input_tokens":123000}}}\n' \
    "$1" > "$TR"
  touch -d "$2 minutes ago" "$TR"
  mkdir -p "$H/logs"                       # peer-state.py reads ~/logs/session-log.md — the fake HOME's
  case "${3:-completed}" in
    none) : > "$H/logs/session-log.md" ;;
    *)    printf '### 09:10 – [beta / Opus 5, KOORDINATOR] – Lane W1\n- Status: %s\n' "${3:-completed}" \
            > "$H/logs/session-log.md" ;;
  esac
  printf 'sess-beta\n' > "$H/.claude/state/orchestrator"
}
claim_alpha() { HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1; }
held() { head -1 "$H/.claude/state/orchestrator"; }
holder_wrote 'Lane W1 gelandet — you can close this tab.' 90
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "wrapped holder, idle past the threshold -> the seat is taken" 0 "$RC"
assert_has "the takeover names itself" "STALE SEAT" "$OUT"
assert_has "the evidence names holder and idle age" '"beta" (sess-beta), idle 1h30m' "$OUT"
assert_has "the evidence carries the price of the wake it avoided" "ctx 123007 tokens" "$OUT"
assert_has "the evidence names the signal that decided it" 'closing phrase "close this tab"' "$OUT"
assert_has "the evidence quotes the holder's own last line" "Lane W1 gelandet" "$OUT"
assert_has "the evidence says the holder was not woken" "NOT messaged" "$OUT"
[ "$(head -1 "$H/.claude/state/orchestrator")" = "sess-alpha" ] \
  && ok "the marker now points at the claimer" || bad "the marker now points at the claimer"
holder_wrote 'Fertig — you can close this tab.' 5
OUT="$(claim_alpha)"; RC=$?
assert_rc "wrapped but idle UNDER the threshold -> still refused" 1 "$RC"
assert_has "the refusal names the idle age it measured" "idle only 5m" "$OUT"
assert_has "the refusal says the appeal is the cheap move right now" "cache is probably still warm" "$OUT"

# The seat needs TWO agreeing signals, the tab list only one. The single session most likely to
# write a closing line is a WORKING coordinator — about somebody else's tab, after every wrap.
# Same transcript, same idle age, only the session log differs, so nothing but the log can be
# what decides these three.
STILL_WORKING='Lane W1 ist gelandet — der Worker hat gewrapped. Den Tab kannst du schließen. Als Nächstes: HYP-231?'
holder_wrote "$STILL_WORKING" 95 in-progress
OUT="$(claim_alpha)"; RC=$?
assert_rc "closing line but the session log says in-progress -> refused" 1 "$RC"
# The reader settles this one itself (a contradicted closing line is "no", not "yes"), so the
# refusal arrives as "still working". The seat's own second gate — a reader that DOES say yes
# while the log says otherwise — is pinned against a stub further down, where log_completed is
# the only field that moves.
assert_has "the refusal says the holder is still working" "still working" "$OUT"
[ "$(held)" = "sess-beta" ] && ok "the working coordinator keeps its seat" || bad "the working coordinator keeps its seat"
holder_wrote "$STILL_WORKING" 95 none
OUT="$(claim_alpha)"; RC=$?
assert_rc "closing line but no session log entry at all -> refused" 1 "$RC"
assert_has "the refusal says there is no entry under its name" "no session log entry under its name" "$OUT"
[ "$(held)" = "sess-beta" ] && ok "no log entry -> the seat stays put" || bad "no log entry -> the seat stays put"
holder_wrote "$STILL_WORKING" 95 completed
OUT="$(claim_alpha)"; RC=$?
assert_rc "the same line and idle age with the log completed -> the seat IS taken" 0 "$RC"
assert_has "the takeover says both signals agreed" "closing line AND session log agree" "$OUT"

# "No entry under its name" and "no session log on this machine at all" read identically inside
# the reader — log_completed is null for both — and are different problems: the first waits for
# that session's next wrap, the second cannot be solved by the holder at all. A stranger with no
# log was told to look for an entry in a file that does not exist, and the takeover the README
# describes could never fire on their machine. The pair below is that fix, both halves.
holder_wrote 'Lane W1 gelandet — you can close this tab.' 90 completed
rm -f "$H/logs/session-log.md"
OUT="$(claim_alpha)"; RC=$?
assert_rc "no session log file at all -> the seat is still NOT taken" 1 "$RC"
assert_has "the refusal says the log itself is missing" "no session log at all" "$OUT"
assert_lacks "...and does not blame a missing entry under its name" "no session log entry under its name" "$OUT"
assert_has "the refusal names the resolved path" "$H/logs/session-log.md" "$OUT"
assert_has "the refusal names what writes the entry" "middle-management:wrap" "$OUT"
assert_has "the refusal names release <id> for a session that is gone" "release sess-beta" "$OUT"
[ "$(held)" = "sess-beta" ] && ok "no log -> the seat stays put" || bad "no log -> the seat stays put"
# ...and the same holder, same transcript, after ONE wrap in the documented shape: day heading,
# entry header, Status, closed marker. (The marker line is inert in this fixture — CLOSED_MARK
# wants a hex sessionId and these fakes are "sess-beta" — so what decides here is the pair the
# seat actually needs: the holder's closing line and its entry reading completed.)
printf '## %s\n\n### %s – [beta / Opus 5, KOORDINATOR] – Lane W1\n- Status: completed\n- Session: closed · sess-beta — wrapped, the tab can be closed\n' \
  "$(date -d '90 minutes ago' +%F)" "$(date -d '90 minutes ago' +%H:%M)" > "$H/logs/session-log.md"
OUT="$(claim_alpha)"; RC=$?
assert_rc "one wrap entry in the documented format -> the seat IS taken" 0 "$RC"
assert_has "the takeover names the two signals it read" "closing line AND session log agree" "$OUT"
[ "$(held)" = "sess-alpha" ] && ok "after the wrap the seat moves" || bad "after the wrap the seat moves"

holder_wrote 'Fertig — you can close this tab.' 5
# Same wrapped, 5-minutes-idle holder: a threshold that silently evaluated to 0 would take it.
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_STALE_SEAT_MIN=abc bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "a non-numeric MM_STALE_SEAT_MIN -> aborted, not a takeover at threshold 0" 1 "$RC"
assert_has "the abort names the variable" "MM_STALE_SEAT_MIN" "$OUT"
[ "$(held)" = "sess-beta" ] \
  && ok "the holder keeps its seat through the aborted claim" || bad "the holder keeps its seat through the aborted claim"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_STALE_SEAT_MIN=0 bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "MM_STALE_SEAT_MIN=0 (every seat is stale) -> refused" 1 "$RC"
# A huge value is someone switching the route OFF. STALE_MIN*60 is int64: past ~1.5e17 it wrapped
# NEGATIVE, every idle age cleared the threshold, and the seat was taken from a holder idle 5m.
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_STALE_SEAT_MIN=999999999999999999999 bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "an MM_STALE_SEAT_MIN that overflows int64 -> refused, not an instant takeover" 1 "$RC"
assert_has "the refusal names the range it wants" "525600" "$OUT"
[ "$(held)" = "sess-beta" ] && ok "the overflow value leaves the seat alone" || bad "the overflow value leaves the seat alone"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_STALE_SEAT_MIN=153722867280912931 bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "the exact int64 wrap point -> refused too" 1 "$RC"
# Emergency paths must not care what that variable contains (it is only used by claim).
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_STALE_SEAT_MIN=abc bash "$ORCH" status 2>&1)"; RC=$?
assert_rc "status works whatever MM_STALE_SEAT_MIN contains" 0 "$RC"
assert_has "status still names the holder" "beta" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_STALE_SEAT_MIN=abc bash "$ORCH" release 2>&1)"; RC=$?
assert_lacks "release is never blocked by MM_STALE_SEAT_MIN" "MM_STALE_SEAT_MIN" "$OUT"
assert_has "release gives its own refusal instead" "REFUSED" "$OUT"
holder_wrote 'Lane W1 gelandet — you can close this tab.' 90
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_STALE_SEAT_MIN=1 bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "MM_STALE_SEAT_MIN lowers the threshold -> the same seat is taken" 0 "$RC"
assert_has "the takeover names the threshold it applied" "Threshold: 1 min" "$OUT"
# 08 is eight minutes to a human and octal to bash: $((08*60)) aborted the whole script with a
# raw "value too great for base", no refusal and no explanation.
holder_wrote 'Lane W1 gelandet — you can close this tab.' 90
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_STALE_SEAT_MIN=08 bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "a leading-zero MM_STALE_SEAT_MIN -> read as decimal, not octal" 0 "$RC"
assert_has "the leading zero is gone from the threshold it reports" "Threshold: 8 min" "$OUT"
assert_lacks "no raw bash arithmetic error reaches the user" "value too great for base" "$OUT"
holder_wrote 'Der Render läuft noch, ich melde mich mit den Zahlen.' 90 in-progress
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "a holder that has NOT wrapped -> refused however long it has been idle" 1 "$RC"
assert_has "the refusal says it is alive and working" "still working" "$OUT"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" status 2>&1)"; RC=$?
assert_rc "status with a live foreign holder still exits 0" 0 "$RC"
assert_has "status answers appeal-or-take without a second command" "idle 1h30m, wrapped no" "$OUT"

say "== stale seat: fail closed when the reader cannot be trusted =="
# A copy of the scripts dir so the reader can be removed/broken without touching the real one.
# Two coordinators at once is a worse failure than one expensive wake: no answer -> no takeover.
COPY="$(mktemp -d -p "$TMPBASE")"; cp -r "$P/scripts" "$COPY/scripts"
stub_reader() { cat > "$COPY/scripts/peer-state.py"; }   # body on stdin
copy_claim() { HOME="$H" CLAUDE_CONFIG_DIR="" bash "$COPY/scripts/orchestrator.sh" claim 2>&1; }
holder_wrote 'Alles erledigt — you can close this tab.' 90
rm -f "$COPY/scripts/peer-state.py"
OUT="$(copy_claim)"; RC=$?
assert_rc "reader missing -> refused even over a wrapped, long-idle holder" 1 "$RC"
assert_has "the refusal admits it could not judge" "no usable answer" "$OUT"
stub_reader <<'PY'
import sys
sys.exit(3)
PY
OUT="$(copy_claim)"; RC=$?
assert_rc "reader exits non-zero -> refused" 1 "$RC"
stub_reader <<'PY'
print("this is not json")
PY
OUT="$(copy_claim)"; RC=$?
assert_rc "reader prints unparseable output -> refused" 1 "$RC"
stub_reader <<'PY'
print('[{"wrapped": "unknown", "idle_seconds": null, "evidence": ["no transcript on disk"]}]')
PY
OUT="$(copy_claim)"; RC=$?
assert_rc "reader gives no idle age at all -> refused" 1 "$RC"
# ...and the same verdict WITH a usable idle age: without this the jq select rejects the row on
# idle_seconds and .wrapped is never read, so the case above proves nothing about "unknown".
stub_reader <<'PY'
print('[{"wrapped": "unknown", "log_completed": true, "idle_seconds": 99999, "idle": "27h",'
      ' "ctx": 200000, "evidence": ["no assistant text read"], "last": "-"}]')
PY
OUT="$(copy_claim)"; RC=$?
assert_rc "reader says wrapped=unknown past the threshold -> refused" 1 "$RC"
assert_has "unknown counts as working" "counts as working" "$OUT"
# The seat's second signal, straight from the reader's answer: everything else agrees and says
# take it, and log_completed alone holds it back.
stub_reader <<'PY'
print('[{"wrapped": "yes", "log_completed": false, "idle_seconds": 99999, "idle": "27h",'
      ' "ctx": 200000, "evidence": ["closing phrase; session log says in-progress"],'
      ' "last": "Den Tab kannst du schließen."}]')
PY
OUT="$(copy_claim)"; RC=$?
assert_rc "reader says wrapped=yes but log_completed=false -> refused however long it is idle" 1 "$RC"
assert_has "the refusal names the log signal" "session log entry is not completed" "$OUT"
stub_reader <<'PY'
print('[{"wrapped": "yes", "log_completed": true, "idle_seconds": 99999, "idle": "27h",'
      ' "ctx": 200000, "evidence": ["closing phrase; session log says completed"],'
      ' "last": "Den Tab kannst du schließen."}]')
PY
OUT="$(copy_claim)"; RC=$?
assert_rc "same row with log_completed=true -> the seat IS taken (so the refusal was that key)" 0 "$RC"
assert_has "the takeover quotes the reader's evidence" "session log says completed" "$OUT"
# Read-check-write is not one operation: three concurrent claims over the same stale holder each
# announced the takeover and each declared itself the coordinator. The reader is made slow here so
# another session can win the marker inside that gap — the claim must notice and step back.
stub_reader <<'PY'
import time
time.sleep(1)
print('[{"wrapped": "yes", "log_completed": true, "idle_seconds": 99999, "idle": "27h",'
      ' "ctx": 200000, "evidence": ["closing phrase"], "last": "-"}]')
PY
holder_wrote 'Alles erledigt — you can close this tab.' 90
( sleep 0.3; printf 'sess-gamma\n' > "$H/.claude/state/orchestrator" ) & RACER=$!
OUT="$(copy_claim)"; RC=$?
wait "$RACER" 2>/dev/null
assert_rc "another session wins the marker mid-claim -> refused, not a second coordinator" 1 "$RC"
assert_has "the loser says plainly that it is not the coordinator" "NOT the coordinator" "$OUT"
[ "$(held)" = "sess-gamma" ] && ok "the winner's marker is left alone" || bad "the winner's marker is left alone" "$(held)"

holder_wrote 'Alles erledigt — you can close this tab.' 90      # marker back to the holder
cp "$P/scripts/peer-state.py" "$COPY/scripts/peer-state.py"
OUT="$(copy_claim)"; RC=$?
assert_rc "the real reader back in the same copy -> the seat IS taken (the refusals were the stub)" 0 "$RC"
# The holder's process is GONE: that is the old route and the reader must not get in its way.
printf '{"pid":999998,"name":"ghost2","sessionId":"sess-ghost2","kind":"interactive"}\n' > "$H/.claude/sessions/999998.json"
cp "$TR" "$H/.claude/projects/-tmp-x/sess-ghost2.jsonl"
printf 'sess-ghost2\n' > "$H/.claude/state/orchestrator"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "holder process gone -> the old take-over path, unchanged" 0 "$RC"
assert_has "the dead-holder note is what fires" "taken over" "$OUT"
assert_lacks "a dead holder is not routed through the stale-seat evidence" "STALE SEAT" "$OUT"
kill "$PEER" 2>/dev/null

say "== claim: a marker write that fails is not a claim =="
# Announcing a successful claim after a failed write leaves a session believing it holds a seat it
# does not — the same two-coordinator state, reached from the other end.
H2="$(new_home)"
rm -f "$H2/.claude/state/orchestrator"; mkdir -p "$H2/.claude/state/orchestrator"
OUT="$(HOME="$H2" CLAUDE_CONFIG_DIR="" bash "$ORCH" claim 2>&1)"; RC=$?
assert_rc "the marker path is a directory -> claim fails" 1 "$RC"
assert_has "the failed write says this session is NOT the coordinator" "NOT the coordinator" "$OUT"
assert_lacks "a failed write is never reported as a successful claim" "coordinator from now on" "$OUT"

say "== --cwd, when used deliberately, matches by path prefix =="
# A lane's worktree is a SIBLING of the checkout (<parent>/.worktrees-<name>/<topic>, elsewhere a
# cache dir), so an exact --cwd match returned an empty tab list for exactly the sessions the list
# exists for. That is why the banner and the skill instruct --wrapped UNFILTERED (asserted above);
# the flag itself stays, and it has to match by prefix when someone does narrow on purpose.
H3="$(new_home)"
mkdir -p "$H3/.claude/projects/-tmp-x" "$H3/app" "$H3/.worktrees-app/T3"
printf '{"pid":999997,"name":"lane-t3","sessionId":"sess-lane","cwd":"%s/.worktrees-app/T3","kind":"interactive","updatedAt":5}\n' \
  "$H3" > "$H3/.claude/sessions/999997.json"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Lane T3 gelandet. You can close this tab."}]}}\n' \
  > "$H3/.claude/projects/-tmp-x/sess-lane.jsonl"
OUT="$(HOME="$H3" CLAUDE_CONFIG_DIR="" python3 "$P/scripts/peer-state.py" --wrapped --cwd "$H3" 2>&1)"
assert_has "--cwd matches by prefix, so a lane worktree beside the checkout is listed" "lane-t3" "$OUT"

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
# command position only: the phrase denies when it IS the command, not when it is an argument
OUT="$(bash_json 'echo \"git add -A is blocked\"' | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GITADD" 2>&1)"
assert_empty "the phrase inside a quoted string -> allow" "" "$OUT"
OUT="$(bash_json 'cd src && git add -A' | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GITADD" 2>&1)"
assert_has "blanket staging after && -> deny" '"deny"' "$OUT"
# `<<<word` is a herestring, not a heredoc: it must not turn heredoc mode on and swallow every
# following line of a multi-line command — while a genuine heredoc body still has to stay data.
OUT="$(bash_json 'cat <<<EOF\ngit add -A' | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GITADD" 2>&1)"
assert_has "a herestring does not hide the next line -> deny" '"deny"' "$OUT"
OUT="$(bash_json 'cat <<EOF\ngit add -A\nEOF' | HOME="$H" CLAUDE_CONFIG_DIR="" bash "$GITADD" 2>&1)"
assert_empty "the same phrase inside a real heredoc body -> allow" "" "$OUT"
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
# The stripper IS awk: without it the whole pipeline yields an empty command and the guard would
# allow everything, silently. It has to fall into the no-jq branch (match anywhere) instead.
AWKLESS="$(mktemp -d -p "$TMPBASE")"; ln -s /usr/bin/* /bin/* "$AWKLESS"/ 2>/dev/null; rm -f "$AWKLESS/awk"
OUT="$(bash_json 'git add -A' | HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$AWKLESS" bash "$GITADD" 2>&1)"
assert_has "blanket staging without awk -> still deny" '"deny"' "$OUT"
OUT="$(bash_json 'echo \"git add -A is blocked\"' | HOME="$H" CLAUDE_CONFIG_DIR="" PATH="$AWKLESS" bash "$GITADD" 2>&1)"
assert_has "...and it is the match-anywhere branch, as without jq" '"deny"' "$OUT"

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
assert_has "a refused removal gets its own row key, not the running-unit key" "busy-cwd:app-lane1" "$(cat "$H/.claude/state/wt/reaper-latest.md")"
assert_lacks "the refused-removal row key is not the plain busy key" "busy:app-lane1 " "$(cat "$H/.claude/state/wt/reaper-latest.md")"
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
say "== peer-state (tests/peer-state.sh) =="
PS_OUT="$(bash "$ROOT/tests/peer-state.sh" 2>&1)"; PS_RC=$?
printf '%s\n' "$PS_OUT" | grep -E '^\s+(FAIL|skip)' || true
PS_LINE="$(printf '%s\n' "$PS_OUT" | grep -E '^RESULT:' | tail -1)"
say "  ${PS_LINE:-peer-state matrix did not report}"
[ "$PS_RC" -eq 0 ] || FAIL=$((FAIL+1))

say ""
say "== heartbeat (tests/heartbeat.sh) =="
HB_OUT="$(bash "$ROOT/tests/heartbeat.sh" 2>&1)"; HB_RC=$?
printf '%s\n' "$HB_OUT" | grep -E '^\s+(FAIL|skip)' || true
HB_LINE="$(printf '%s\n' "$HB_OUT" | grep -E '^[0-9]+ passed' | tail -1)"
say "  ${HB_LINE:-heartbeat matrix did not report}"
[ "$HB_RC" -eq 0 ] || FAIL=$((FAIL+1))

say ""
say "RESULT: $PASS passed, $FAIL failed (plus peer-state: ${PS_LINE:-FAILED TO RUN}; heartbeat: ${HB_LINE:-FAILED TO RUN})"
[ "$FAIL" -eq 0 ]
