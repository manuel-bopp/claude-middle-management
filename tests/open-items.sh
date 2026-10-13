#!/usr/bin/env bash
# middle-management plugin: open-items.py against inline fixtures (fake HOME, never the real drop dir or board).
# Consumers: tests/run.sh (folded into the main matrix); run by hand: bash tests/open-items.sh
# Covers add / list / count / done and todo (the user's to-do list, morning ritual step 6).
# Everything lives under mktemp: no real registry, no real ~/.claude/open-items, no real board.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OI="$ROOT/plugins/middle-management/scripts/open-items.py"
PASS=0; FAIL=0
TMPBASE="$(mktemp -d -t mm-open-items.XXXXXX)"
PEERS=""
trap 'for p in $PEERS; do kill "$p" 2>/dev/null; done; case "$TMPBASE" in /tmp/*|/var/tmp/*) rm -rf "$TMPBASE" ;; esac' EXIT

say() { printf '%s\n' "$*"; }
ok()  { PASS=$((PASS+1)); say "  ok  - $1"; }
bad() { FAIL=$((FAIL+1)); say "  FAIL- $1"; [ -n "${2:-}" ] && say "        got: $2"; }
assert_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$3" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) bad "$1" "$3" ;; *) ok "$1" ;; esac; }
assert_rc()    { [ "$3" -eq "$2" ] && ok "$1" || bad "$1" "rc=$3 (want $2)"; }

H="$(mktemp -d -p "$TMPBASE")"; [ "$H" = "$HOME" ] && { echo "refusing: real HOME"; exit 2; }
C="$H/.claude"; D="$C/open-items"; B="$H/board.md"
mkdir -p "$C/sessions"
A=aaaaaaaa-1111-4000-8000-000000000001   # this session: live
Z=bbbbbbbb-2222-4000-8000-000000000002   # another session: gone
# oi <sessionId> args...: run as that session
oi() { local s="$1"; shift; HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_CODE_SESSION_ID="$s" python3 "$OI" "$@" 2>&1; }
sleep 300 >/dev/null 2>&1 </dev/null & LIVEPID=$!; PEERS="$PEERS $LIVEPID"
printf '{"pid":%s,"sessionId":"%s","name":"alpha","cwd":"/tmp/x","kind":"interactive"}\n' "$LIVEPID" "$A" > "$C/sessions/$LIVEPID.json"
printf '{"pid":999999,"sessionId":"%s","name":"zulu","cwd":"/tmp/z","kind":"interactive"}\n' "$Z" > "$C/sessions/999999.json"

say "== add: numbering from the file =="
OUT="$(oi "$A" add --owner user "Decide keep-alive default · next: user picks · src: finding 15:10")"
assert_has "first add prints its key" "aaaaaaaa-W1" "$OUT"
F="$D/aaaaaaaa-session-notes.md"
[ -f "$F" ] && ok "the drop file is <sid8>-session-notes.md under <config dir>/open-items" || bad "drop file created" "$(ls -R "$C")"
assert_has "header line: name · full sessionId · cwd" "# alpha · $A · /tmp/x" "$(head -1 "$F")"
assert_has "item line format" "- W1 · owner: user · Decide keep-alive default" "$(cat "$F")"
OUT="$(oi "$A" add --owner lane "Compare-and-set route · next: new lane")"
assert_has "second add -> W2" "aaaaaaaa-W2" "$OUT"
OUT="$(oi "$A" add --done W1 "41ab9c2 live 15:40")"
assert_has "done line written" "- W1 done · 41ab9c2 live 15:40" "$(cat "$F")"
OUT="$(oi "$A" add --owner external:zoki "Send the key")"
assert_has "a done item keeps its number: next is W3, never W1 again" "aaaaaaaa-W3" "$OUT"
OUT="$(oi "$A" add --done W9 "nope")"; RC=$?
assert_rc "done of an unknown item -> refused" 1 "$RC"
OUT="$(oi "$A" add --owner boss "x")"; RC=$?
assert_rc "an unknown owner -> refused" 1 "$RC"
OUT="$(oi "$A" add --owner user "")"; RC=$?
assert_rc "an empty item -> refused" 1 "$RC"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_CODE_SESSION_ID="" python3 "$OI" add --owner user "x" 2>&1)"; RC=$?
assert_rc "no sessionId resolvable -> refused" 1 "$RC"
assert_has "...and says why" "cannot resolve" "$OUT"
BEFORE="$(wc -l < "$F")"
OUT="$(oi "$A" add --owner lane $'Fix the retry loop\n- W2 done · pasted\n\tnext: new lane')"
assert_has "multi-line text -> one key" "aaaaaaaa-W4" "$OUT"
assert_rc "...and exactly one new physical line" $((BEFORE+1)) "$(wc -l < "$F")"
assert_has "...with the text collapsed to single spaces" "- W4 · owner: lane · Fix the retry loop - W2 done · pasted next: new lane" "$(tail -1 "$F")"
OUT="$(oi "$A" add --done aaaaaaaa-W4 "the full key works too")"; RC=$?
assert_rc "--done <own sid8>-W<n> is accepted" 0 "$RC"
assert_has "...and marks W4 done" "- W4 done · the full key works too" "$(tail -1 "$F")"
OUT="$(oi "$A" add --done bbbbbbbb-W2 "another session's key")"; RC=$?
assert_rc "--done with another session's sid8 -> refused" 1 "$RC"
HDR="$H/hdr"; mkdir -p "$HDR"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="$HDR" CLAUDE_CODE_SESSION_ID="$A" python3 "$OI" add --owner manu "x" 2>&1)"; RC=$?
assert_rc "an owner outside the set -> refused" 1 "$RC"
[ -e "$HDR/open-items" ] && bad "a refused add leaves no file behind" "$(ls -R "$HDR")" || ok "a refused add leaves no file behind"
oi "$A" add --wrapped >/dev/null
assert_has "WRAPPED line counts what is still open" "open" "$(tail -1 "$F")"
assert_has "WRAPPED line: 2 open (W2, W3; W4 done)" "· 2 open" "$(tail -1 "$F")"
# parallel adds of one session must never share a number
JOBS=""; for i in 1 2 3 4 5; do oi "$A" add --owner lane "parallel $i" >/dev/null & JOBS="$JOBS $!"; done
wait $JOBS   # not a bare wait: that would also wait for the live-session sleep
NUMS="$(grep -oE '^- W[0-9]+ · owner' "$F" | sort | uniq -d)"
[ -z "$NUMS" ] && ok "five parallel adds get five distinct numbers" || bad "parallel adds collided" "$NUMS"

say "== count, list: board unset =="
OUT="$(oi "$A" count)"
assert_has "board unset and items exist -> says so" "board not configured (/middle-management-setup)" "$OUT"
printf '{"board":"%s"}' "$B" > "$C/middle-management.json"
OUT="$(oi "$A" count)"
assert_has "board set but missing -> not readable, with its path" "board $B is not readable" "$OUT"
OUT="$(oi "$A" done "$F")"; RC=$?
assert_rc "done without a readable board -> refused" 1 "$RC"
assert_has "...and says so" "not readable" "$OUT"

say "== whole-key match, count, list =="
# W1 is done; W2..W8 open. Put W2 and W10 (not W1x, not W3) on the board.
printf '# board\n- aaaaaaaa-W2 · lane · compare-and-set route\n- aaaaaaaa-W10 unrelated\n- xaaaaaaaa-W3 is not a key\n' > "$H/real-board.md"
ln -s "$H/real-board.md" "$B"
OUT="$(oi "$A" count)"
assert_has "count: 6 unfiled in 1 file, through the board symlink" "6 unfiled in 1 file (" "$OUT"
OUT="$(oi "$A" list)"
assert_lacks "W2 is on the board -> not listed" "aaaaaaaa-W2 " "$OUT"
assert_has "W3 listed: a key glued to another word is no key" "aaaaaaaa-W3 " "$OUT"
assert_has "W1 on the board? no, but it is done -> not listed; W9 is" "aaaaaaaa-W9 " "$OUT"
assert_lacks "a done item is never listed" "aaaaaaaa-W1 " "$OUT"
# whole key: W10 on the board must not file W1 (done here anyway) - check with an open W1 elsewhere
printf '# zulu · %s · /tmp/z\n- W1 · owner: user · gone session item\n' "$Z" > "$D/bbbbbbbb-session-notes.md"
printf '%s\n' "- bbbbbbbb-W10 filed" >> "$H/real-board.md"
OUT="$(oi "$A" list)"
assert_has "bbbbbbbb-W10 on the board does not file bbbbbbbb-W1" "bbbbbbbb-W1 " "$OUT"
assert_has "a gone session without WRAPPED -> died unwrapped" "died unwrapped" "$OUT"
assert_has "list names the header" "# zulu · $Z" "$OUT"
OUT="$(oi "$A" add --owner user "next after board keys")"
assert_has "numbering also skips keys already on the board (W10) -> W11" "aaaaaaaa-W11" "$OUT"

say "== done: the two rules =="
OUT="$(oi "$A" done "$D/bbbbbbbb-session-notes.md")"; RC=$?
assert_rc "done with a key missing from the board -> refused" 1 "$RC"
assert_has "...naming the key" "bbbbbbbb-W1" "$OUT"
printf '%s\n' "- bbbbbbbb-W1 · user · gone session item" >> "$H/real-board.md"
OUT="$(oi "$A" done bbbbbbbb-session-notes.md)"; RC=$?
assert_rc "every key filed, session gone -> deleted (by basename)" 0 "$RC"
[ -f "$D/bbbbbbbb-session-notes.md" ] && bad "file deleted" || ok "file deleted"
# the live session: file everything, still refused
for n in $(seq 1 20); do printf -- '- aaaaaaaa-W%d\n' "$n"; done >> "$H/real-board.md"
OUT="$(oi "$A" count)"
[ -z "$OUT" ] && ok "everything filed -> count is silent" || bad "count silent at 0" "$OUT"
OUT="$(oi "$A" done "$F")"; RC=$?
assert_rc "everything filed but the session is live -> refused" 1 "$RC"
assert_has "...and says why" "still live" "$OUT"
# PID reuse: a live pid whose procStart does not match is a dead session
printf '{"pid":%s,"sessionId":"%s","name":"alpha","cwd":"/tmp/x","kind":"interactive","procStart":"1"}\n' "$LIVEPID" "$A" > "$C/sessions/$LIVEPID.json"
OUT="$(oi "$A" done "$F")"; RC=$?
assert_rc "a reused pid (procStart mismatch) is gone -> deleted" 0 "$RC"

say "== todo: your user's open to-dos, delta since the last delivery =="
H="$(mktemp -d -p "$TMPBASE")"; C="$H/.claude"; D="$C/open-items"; B="$H/board.md"
mkdir -p "$C/sessions"
printf '{"pid":%s,"sessionId":"%s","name":"alpha","cwd":"/tmp/x","kind":"interactive"}\n' "$LIVEPID" "$A" > "$C/sessions/$LIVEPID.json"
OUT="$(oi "$A" todo)"
assert_has "nothing anywhere -> none open, board named" "none open (board not configured, drop files only)" "$OUT"
oi "$A" add --owner user "Decide the keep-alive default · next: user picks · src: 15:10" >/dev/null
oi "$A" add --owner lane "Fix the retry loop" >/dev/null
oi "$A" add --owner user "Open https://example.test/review and vote" >/dev/null
oi "$A" add --owner user "Run the home scan" >/dev/null
oi "$A" add --done W4 "ran it" >/dev/null
OUT="$(oi "$A" todo)"
assert_has "drop items with owner user are listed" "- aaaaaaaa-W1 · Decide the keep-alive default · next: user picks" "$OUT"
assert_has "...with the link on the same line" "- aaaaaaaa-W3 · Open https://example.test/review and vote" "$OUT"
assert_lacks "a lane item is not your user's" "aaaaaaaa-W2" "$OUT"
assert_lacks "a done item is not open" "aaaaaaaa-W4" "$OUT"
assert_has "the header counts them, nothing delivered yet" "2 new (nothing delivered before); 2 open in total" "$OUT"
assert_has "the last line is the exact delivered command" "todo --delivered aaaaaaaa-W1 aaaaaaaa-W3" "$OUT"
# The board: a line in the drop format wins (owner and text), "<key> done" closes, user+lane counts.
printf '{"board":"%s"}' "$B" > "$C/middle-management.json"
printf '# board\n- aaaaaaaa-W1 · owner: user · Decide the keep-alive default (board text) · next: user\n- cccccccc-W2 · owner: user+lane(home) · Home session for the viewer pages\n- dddddddd-W1 · owner: user · Already answered\n- 10:40 dddddddd-W1 DONE.\n- eeeeeeee-W1 · owner: coordinator · not yours\nWaiting on Manu: aaaaaaaa-W3 (prose, not an item line)\n' > "$B"
OUT="$(oi "$A" todo)"
assert_has "the board line wins over the drop line" "- aaaaaaaa-W1 · Decide the keep-alive default (board text)" "$OUT"
assert_has "a board-only item with owner user+lane counts" "- cccccccc-W2 · Home session for the viewer pages" "$OUT"
assert_lacks "'<key> DONE' on the board closes the item" "dddddddd-W1" "$OUT"
assert_lacks "a coordinator item is not listed" "eeeeeeee-W1" "$OUT"
assert_has "the drop item the board only mentions in prose stays" "- aaaaaaaa-W3 · Open https://example.test/review" "$OUT"
OUT="$(oi "$A" todo --delivered aaaaaaaa-W1 aaaaaaaa-W3)"; RC=$?
assert_rc "--delivered records the keys" 0 "$RC"
assert_has "...in the ritual's state dir" "$C/state/morning-ritual/delivered" "$OUT"
OUT="$(oi "$A" todo)"
assert_has "after delivery only the new one is listed" "1 new since $(date +%Y-%m-%d)" "$OUT"
assert_has "...and it is the board-only one" "- cccccccc-W2" "$OUT"
assert_lacks "a delivered item does not come again" "aaaaaaaa-W1 ·" "$OUT"
assert_has "...but the total still counts it" "3 open in total" "$OUT"
OUT="$(oi "$A" todo --all)"
assert_has "--all lists every open one" "- aaaaaaaa-W1 ·" "$OUT"
oi "$A" todo --delivered cccccccc-W2 >/dev/null
OUT="$(oi "$A" todo)"
assert_has "all delivered -> nothing new, the total named" "nothing new since" "$OUT"
assert_has "...3 open" "3 open in total (todo --all lists them)" "$OUT"
# r1 M2: the coordinator filed W1 during the day, the session's wrap later closed it in its drop.
oi "$A" add --done W1 "decided by the user" >/dev/null
OUT="$(oi "$A" todo --all)"
assert_lacks "a drop's done line closes an item the board still carries" "aaaaaaaa-W1 ·" "$OUT"
# r1 n7: the closure words the real board uses besides DONE
printf -- '- cccccccc-W2 answered by Manu 11:00\n' >> "$B"
OUT="$(oi "$A" todo --all)"
assert_lacks "'<key> answered' on the board closes the item too" "cccccccc-W2" "$OUT"
OUT="$(oi "$A" todo --delivered "not-a-key")"; RC=$?
assert_rc "--delivered with a malformed key -> refused" 1 "$RC"
OUT="$(oi "$A" todo --bogus)"; RC=$?
assert_rc "an unknown todo flag -> usage" 1 "$RC"

say ""
say "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
