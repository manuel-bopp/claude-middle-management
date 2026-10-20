#!/usr/bin/env bash
# middle-management plugin: topics.py (follow-through, plan D7) against inline fixtures in a fake HOME.
# Consumers: tests/run.sh (to be folded into the main matrix); run by hand: bash tests/topics.sh
# Covers entry (log + state, key derivation, coordinator, --new, persistent waits and case, scopes),
# render (own topics file, removal rule), tick (cadence, window, ledger, inline vs page, daily digest),
# answer (--topic, --file), lint, stats and the migrate dry-run. Never touches the real log, board or state.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="$ROOT/plugins/middle-management/scripts/topics.py"
PASS=0; FAIL=0
TMPBASE="$(mktemp -d -t mm-topics.XXXXXX)"
trap 'case "$TMPBASE" in /tmp/*|/var/tmp/*) rm -rf "$TMPBASE" ;; esac' EXIT

say() { printf '%s\n' "$*"; }
ok()  { PASS=$((PASS+1)); say "  ok  - $1"; }
bad() { FAIL=$((FAIL+1)); say "  FAIL- $1"; [ -n "${2:-}" ] && say "        got: $2"; }
assert_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$3" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) bad "$1" "$3" ;; *) ok "$1" ;; esac; }
assert_rc()    { [ "$3" -eq "$2" ] && ok "$1" || bad "$1" "rc=$3 (want $2)"; }

H="$(mktemp -d -p "$TMPBASE")"; [ "$H" = "$HOME" ] && { echo "refusing: real HOME"; exit 2; }
C="$H/.claude"; LOG="$H/logs/log.md"; B="$H/board.md"; TF="$H/board.topics.md"; N="$H/notified"
mkdir -p "$C/sessions" "$H/logs" "$H/.cache/claude/wt/alpha" "$H/t3/proj/lane-beta/sub" "$H/repo" "$H/plain" "$H/ff"
git -C "$H/repo" init -q -b lane/gamma 2>/dev/null || { git -C "$H/repo" init -q && git -C "$H/repo" checkout -q -b lane/gamma; }
printf '# board\n\nsome prose\n' > "$B"
SID=aaaaaaaa-1111-4000-8000-000000000001     # a worker
CSID=cccccccc-3333-4000-8000-000000000003    # the coordinator seat holder
mkdir -p "$C/state"; printf '%s\n' "$CSID" > "$C/state/orchestrator"
T0="$(date -d "today 10:00" +%s)"
cfg() {  # $1 = extra JSON members
  printf '{"board":"%s","sessionLog":"%s","userName":"Manu","notifyCommand":"printf \\"%%s\\\\n---\\\\n\\" \\"$1\\" >> %s"%s}' \
    "$B" "$LOG" "$N" "${1:-}" > "$C/middle-management.json"
}
cfg
# tp <dir> <sid> <epoch> args...
tp() { local d="$1" s="$2" t="$3"; shift 3; (cd "$d" && HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" T3CODE_HOME="" \
  CLAUDE_CODE_SESSION_ID="$s" MM_TOPICS_NOW="$t" python3 "$TP" "$@" 2>&1); }
st() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["topics"].get(sys.argv[2],{}); print(json.dumps(d,sort_keys=True,ensure_ascii=False))' "$C/state/topics/${3:-default}.json" "$1"; }

say "== entry: log + state =="
OUT="$(tp "$H/.cache/claude/wt/alpha" "$SID" "$T0" entry --status in-progress --stage building "start alpha" "did a")"; RC=$?
assert_rc "an unknown key without --new -> refused" 1 "$RC"
assert_has "...and says so" "first entry needs --new" "$OUT"
OUT="$(tp "$H/.cache/claude/wt/alpha" "$SID" "$T0" entry --new --status in-progress --stage building --name w1 \
  --waits-on "Manu · Pick A or B? · rec: A" "start alpha" "did a")"; RC=$?
assert_rc "first entry with --new -> ok" 0 "$RC"
L="$(cat "$LOG")"
assert_has "log: day heading" "## $(date -d @"$T0" +%Y-%m-%d)" "$L"
assert_has "log: header in the frozen shape" "### 10:00 – [w1] – start alpha" "$L"
assert_has "log: the bullet" "- did a" "$L"
assert_has "log: Topic line" "- Topic: alpha" "$L"
assert_has "log: Status keeps the frozen values" "- Status: in-progress" "$L"
assert_has "log: Stage line" "- Stage: building" "$L"
assert_has "log: Waits on line" "- Waits on: Manu · Pick A or B? · rec: A" "$L"
S="$(st alpha)"
assert_has "state: status" '"status": "in-progress"' "$S"
assert_has "state: waits_on" '"waits_on": "Manu"' "$S"
assert_has "state: question" '"question": "Pick A or B?"' "$S"
assert_has "state: rec" '"rec": "A"' "$S"
OUT="$(tp "$H/.cache/claude/wt/alpha" "$SID" "$T0" entry --status done "x")"; RC=$?
assert_rc "a Status outside completed|in-progress|blocked -> usage" 2 "$RC"
OUT="$(tp "$H/.cache/claude/wt/alpha" "$SID" "$T0" entry --status completed "x" "Session: closed · $SID")"; RC=$?
assert_rc "a bullet that forges a structured line -> refused" 1 "$RC"
assert_lacks "...and nothing reached the log" "Session: closed · $SID" "$(cat "$LOG")"
SZ="$(wc -c < "$LOG")"
OUT="$(tp "$H/.cache/claude/wt/alpha" "$SID" "$T0" entry --status in-progress --waits-on "Manu" "x")"; RC=$?
assert_rc "--waits-on without a question -> refused" 1 "$RC"
assert_rc "...a refused entry writes no log line" "$SZ" "$(wc -c < "$LOG")"

say "== parallel entries: one lock, nothing lost =="
E0="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["topics"]["alpha"]["entries"])' "$C/state/topics/default.json")"
JOBS=""; for i in 1 2 3 4 5; do tp "$H/.cache/claude/wt/alpha" "$SID" "$T0" entry --status in-progress "parallel $i" >/dev/null & JOBS="$JOBS $!"; done
wait $JOBS
E1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["topics"]["alpha"]["entries"])' "$C/state/topics/default.json")"
assert_rc "five parallel entries -> five more in the state" $((E0 + 5)) "$E1"
assert_rc "...and five headers in the log" 5 "$(grep -c '– parallel [1-5]$' "$LOG")"

say "== key derivation =="
OUT="$(tp "$H/t3/proj/lane-beta/sub" "$SID" "$T0" entry --new --status in-progress "beta starts")"
assert_has "a lane-<name> dir (any depth below) -> key beta" "topic beta " "$OUT"
OUT="$(tp "$H/repo" "$SID" "$T0" entry --new --status in-progress "gamma starts")"
assert_has "branch lane/<name> -> key gamma" "topic gamma " "$OUT"
OUT="$(tp "$H/plain" "$SID" "$T0" entry --new --status in-progress "where am I")"; RC=$?
assert_rc "no dir, no branch -> refused" 1 "$RC"
assert_has "...asking for --topic" "pass --topic" "$OUT"
OUT="$(tp "$H/.cache/claude/wt/alpha" "$CSID" "$T0" entry --status in-progress "coordinator note")"; RC=$?
assert_rc "the seat holder without --topic -> refused, even inside a lane dir" 1 "$RC"
assert_has "...and says why" "seat holder passes --topic" "$OUT"
# a sub-agent of the coordinator runs with the parent's sessionId: the same refusal covers it
OUT="$(tp "$H/plain" "$CSID" "$T0" entry --topic beta --status in-progress "coordinator note on beta")"; RC=$?
assert_rc "the seat holder with --topic -> ok" 0 "$RC"
OUT="$(tp "$H/plain" "$CSID" "$T0" entry --topic "Bad Key" --new --status in-progress "x")"; RC=$?
assert_rc "a malformed key -> refused" 1 "$RC"
OUT="$(tp "$H/plain" "$CSID" "$T0" entry --topic betta --status in-progress "typo")"; RC=$?
assert_rc "a typo of a known key -> refused (needs --new)" 1 "$RC"
assert_has "...naming the known keys" "known: alpha, beta, gamma" "$OUT"

say "== persistent waits and case =="
tp "$H/.cache/claude/wt/alpha" "$SID" "$T0" entry --status in-progress --stage ready "round 2 ready" >/dev/null
assert_has "a later entry without --waits-on keeps the wait" '"waits_on": "Manu"' "$(st alpha)"
assert_has "...status from the latest entry" '"stage": "ready"' "$(st alpha)"
tp "$H/plain" "$CSID" "$T0" entry --topic alpha --status in-progress --answered "A, go" "Manu answered" >/dev/null
S="$(st alpha)"
assert_lacks "--answered clears the wait" '"waits_on"' "$S"
assert_has "...and keeps the answer" '"answered": "A, go"' "$S"
tp "$H/.cache/claude/wt/alpha" "$SID" "$T0" entry --status blocked --waits-on "Zoki · send the key" "blocked on Zoki" >/dev/null
tp "$H/.cache/claude/wt/alpha" "$SID" "$T0" entry --status blocked --waits-on "Manu · ask Zoki again? · rec: yes" "still blocked" >/dev/null
assert_has "a new --waits-on replaces the old one" '"question": "ask Zoki again?"' "$(st alpha)"
tp "$H/repo" "$SID" "$T0" entry --status in-progress --case BUG-7 "bug lane" >/dev/null
tp "$H/repo" "$SID" "$T0" entry --status in-progress "more work" >/dev/null
assert_has "the case stays across entries" '"case": "BUG-7"' "$(st gamma)"
OUT="$(tp "$H/repo" "$SID" "$T0" entry --status completed --case-closed "BUG-8 · x" "wrong ref")"; RC=$?
assert_rc "--case-closed with another REF -> refused" 1 "$RC"
tp "$H/repo" "$SID" "$T0" entry --status completed --case-closed "BUG-7 · fixed in abc123, live" "case closed" >/dev/null
S="$(st gamma)"
assert_lacks "--case-closed with the REF clears the case" '"case": ' "$S"
assert_has "...and keeps the evidence" '"case_closed": "BUG-7 · fixed in abc123, live"' "$S"

say "== scopes: own state, own topics file =="
printf -- '- other\n' > "$H/ff-board.md"
cfg ',"scopes":[{"name":"ff","root":"'"$H"'/ff","board":"'"$H"'/ff-board.md"}]'
OUT="$(tp "$H/ff" "$SID" "$T0" entry --topic ff-thing --new --status in-progress "an ff topic")"
assert_has "an entry from the ff root lands in scope ff" "scope ff" "$OUT"
assert_has "...its log line names the scope" "- Topic: ff/ff-thing" "$(cat "$LOG")"
[ -f "$C/state/topics/ff.json" ] && ok "...and its own state file" || bad "ff state file"
SUM="$(sha256sum "$B")"
tp "$H/plain" "$SID" "$T0" render >/dev/null
assert_lacks "the default topics file never shows an ff topic" "ff-thing" "$(cat "$TF")"
tp "$H/plain" "$SID" "$T0" render --scope ff >/dev/null
assert_has "render --scope ff writes next to the ff board" "ff-thing" "$(cat "$H/ff-board.topics.md")"
[ "$SUM" = "$(sha256sum "$B")" ] && ok "render never writes the board itself" || bad "board changed"
OUT="$(tp "$H/plain" "$SID" "$T0" render --scope nope)"; RC=$?
assert_rc "an unknown --scope -> refused" 1 "$RC"
cfg

say "== render: table and removal rule =="
T="$(cat "$TF")"
assert_has "header row" "| topic | thread | status/stage | waits on | since | next |" "$T"
assert_has "alpha row with its wait and rec" "| alpha | - | blocked/ready | Manu: ask Zoki again? (rec: yes) |" "$T"
OUT="$(tp "$H/t3/proj/lane-beta" "$SID" "$T0" entry --status completed --stage done --next "Manu's OK" "beta done")"
assert_has "done without review stays" "| beta |" "$(tp "$H/plain" "$SID" "$T0" render >/dev/null; cat "$TF")"
tp "$H/t3/proj/lane-beta" "$SID" "$T0" entry --status completed --stage done --review "1 round, clean" "beta reviewed" >/dev/null
tp "$H/plain" "$SID" "$T0" render >/dev/null
assert_has "done + review, no OK -> waits on the okBy (default: userName)" "| beta | - | completed/done | Manu (OK; review 1 round, clean) |" "$(cat "$TF")"
tp "$H/plain" "$CSID" "$T0" entry --topic gamma --status completed --stage done --review "1 round, clean" --ok "Manu 10:00" --case BUG-9 "gamma ok but new case" >/dev/null
tp "$H/plain" "$SID" "$T0" render >/dev/null
assert_has "done + review + OK with an open case stays" "| gamma |" "$(cat "$TF")"
tp "$H/plain" "$CSID" "$T0" entry --topic gamma --status completed --case-closed "BUG-9 · gone" "case closed" >/dev/null
tp "$H/plain" "$SID" "$T0" render >/dev/null
assert_lacks "done + review + OK + case closed -> removed" "| gamma |" "$(cat "$TF")"
tp "$H/plain" "$CSID" "$T0" entry --topic gamma --status in-progress --stage building "re-opened" >/dev/null
tp "$H/plain" "$SID" "$T0" render >/dev/null
assert_has "a new entry with stage building brings it back" "| gamma |" "$(cat "$TF")"
assert_lacks "...and clears the old OK" '"ok"' "$(st gamma)"

say "== tick: cadence, window, ledger =="
rm -f "$N"
OUT="$(tp "$H/plain" "$SID" $((T0 + 3600)) tick)"
[ -f "$N" ] && bad "nothing due after 1 h" "$(cat "$N")" || ok "nothing due after 1 h (threshold 2 h)"
OUT="$(tp "$H/plain" "$SID" $((T0 + 7260)) tick)"; RC=$?
assert_rc "a tick after 2 h exits 0" 0 "$RC"
M="$(cat "$N" 2>/dev/null)"
assert_has "one digest went out" "Waiting on you: 2" "$M"
assert_has "...the question inline" "alpha · ask Zoki again?" "$M"
assert_has "...its recommendation on its own line" "rec: yes" "$M"
assert_has "...the OK wait as a question" "beta · OK to close beta? Review: 1 round, clean" "$M"
if printf '%s\n' "$M" | grep -qE '^\[[0-9]{2}:[0-9]{2}\]'; then bad "no [HH:MM] prefix" "$M"; else ok "no [HH:MM] prefix"; fi
D="$(cat "$C/state/morning-ritual/delivered")"
assert_has "the delivered keys go into the ritual's ledger" "topic:default:alpha" "$D"
rm -f "$N"
tp "$H/plain" "$SID" $((T0 + 7260 + 600)) tick >/dev/null
[ -f "$N" ] && bad "the next tick 10 min later sends nothing" "$(cat "$N")" || ok "the next tick 10 min later sends nothing"
tp "$H/plain" "$SID" $((T0 + 4 * 3600 + 120)) tick >/dev/null
assert_has "the next digest after another 2 h carries the open ones again" "Waiting on you: 2" "$(cat "$N" 2>/dev/null)"
rm -f "$N"
OUT="$(tp "$H/plain" "$SID" "$(date -d "today 23:00" +%s)" tick)"
assert_has "outside the window: render only" "outside remindWindow" "$OUT"
[ -f "$N" ] && bad "...nothing sent at 23:00" || ok "...nothing sent at 23:00"
# open items: only stamped user items, older than the threshold, not delivered by the ritual
mkdir -p "$C/open-items"
printf '# w · %s · %s/plain\n- W1 · owner: user · stamped old · added: %s\n- W2 · owner: user · unstamped\n- W3 · owner: user · stamped, ritual delivered · added: %s\n- W4 · owner: lane · not yours · added: %s\n' \
  "$SID" "$H" "$(date -d @$((T0 - 3600)) '+%Y-%m-%d %H:%M')" "$(date -d @$((T0 - 3600)) '+%Y-%m-%d %H:%M')" \
  "$(date -d @$((T0 - 3600)) '+%Y-%m-%d %H:%M')" > "$C/open-items/aaaaaaaa-session-notes.md"
printf 'aaaaaaaa-W3\t%s\n' "$(date -d @$((T0 + 5 * 3600)) '+%Y-%m-%d %H:%M')" >> "$C/state/morning-ritual/delivered"
tp "$H/plain" "$SID" $((T0 + 6 * 3600 + 300)) tick >/dev/null
M="$(cat "$N" 2>/dev/null)"
assert_has "a stamped user item past the threshold is reminded" "aaaaaaaa-W1 · stamped old" "$M"
assert_lacks "an unstamped one never counts" "aaaaaaaa-W2" "$M"
assert_lacks "one the ritual delivered less than 2 h ago is not repeated" "aaaaaaaa-W3" "$M"
assert_lacks "a lane item is not the user's" "aaaaaaaa-W4" "$M"
assert_has "...and the item key goes into the same ledger" "aaaaaaaa-W1" "$(cat "$C/state/morning-ritual/delivered")"
rm -f "$N"
cfg ',"notifyCommand":"exit 1"'
OUT="$(tp "$H/plain" "$SID" $((T0 + 9 * 3600)) tick)"; RC=$?
assert_rc "a failing notifyCommand -> exit 1 (the unit alarm sees it)" 1 "$RC"
L1="$(grep -c 'topic:default:alpha' "$C/state/morning-ritual/delivered")"
cfg
tp "$H/plain" "$SID" $((T0 + 9 * 3600 + 60)) tick >/dev/null
assert_has "...nothing was recorded, so the next tick sends it" "Waiting on you" "$(cat "$N" 2>/dev/null)"

say "== more than 3: one page, answers booked back =="
for k in p1 p2 p3; do
  tp "$H/plain" "$CSID" "$T0" entry --topic "$k" --new --status blocked --waits-on "Manu · decide $k? · rec: yes" "ask $k" >/dev/null
done
rm -f "$N"
cfg ',"remindWindow":"00:00-23:59","pageCommand":"cp \"$1\" '"$H"'/page.json && echo https://example.test/page/"'
TK=$((T0 + 12 * 3600))
tp "$H/plain" "$SID" "$TK" tick >/dev/null
M="$(cat "$N" 2>/dev/null)"
assert_has ">3 due -> one message with the page link" "One page with all of them: https://example.test/page/" "$M"
assert_lacks "...not the questions inline" "decide p1?" "$M"
CARDS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(t["ticket"] for t in d["tickets"])); print(d["tickets"][0]["questions"][0]["id"])' "$H/page.json")"
assert_has "the page carries one card per topic, card id = topic key" "p1" "$CARDS"
assert_has "...the open item as a card too" "aaaaaaaa-W1" "$CARDS"
printf '{"generated":"x","items":[{"ticket":"p1","answers":[{"id":"p1-q1","choice_key":"a","choice_label":"yes","comment":"go ahead"}]},{"ticket":"p2","answers":[{"id":"p2-q1","choice_key":null,"choice_label":"","comment":""}]},{"ticket":"beta","answers":[{"id":"beta-ok","choice_key":"a","choice_label":"OK","comment":""}]},{"ticket":"aaaaaaaa-W1","answers":[{"id":"x","choice_key":"a","choice_label":"Done","comment":""}]}]}' > "$H/answers.json"
OUT="$(tp "$H/plain" "" "$TK" answer --file "$H/answers.json")"
assert_has "answer --file books the chosen option and the comment" "booked p1: yes · go ahead" "$OUT"
assert_lacks "p1's wait is gone" '"waits_on"' "$(st p1)"
assert_has "a skipped card keeps its wait" '"waits_on": "Manu"' "$(st p2)"
assert_has "an OK card books the OK" '"ok": "Manu ' "$(st beta)"
assert_has "a non-topic card is named for booking by hand" "book by hand, e.g. open items): aaaaaaaa-W1" "$OUT"
assert_has "the answer is in the log too" "- Answered: yes · go ahead" "$(cat "$LOG")"
tp "$H/plain" "$SID" "$TK" render >/dev/null
assert_lacks "beta (done + review + OK) left the table" "| beta |" "$(cat "$TF")"
OUT="$(tp "$H/plain" "" "$TK" answer --topic p2 "no")"
assert_lacks "answer --topic clears the wait" '"waits_on"' "$(st p2)"
rm -f "$N"
cfg ',"remindWindow":"00:00-23:59","pageCommand":"exit 3"'
for k in p4 p5 p6; do
  tp "$H/plain" "$CSID" "$TK" entry --topic "$k" --new --status blocked --waits-on "user · decide $k? · rec: no" "ask $k" >/dev/null
done
OUT="$(tp "$H/plain" "$SID" $((TK + 3 * 3600)) tick)"
assert_has "a failing pageCommand -> one inline digest" "inline digest instead" "$OUT"
assert_has "...with the questions inline" "p4 · decide p4?" "$(cat "$N" 2>/dev/null)"
cfg

say "== daily digest: stale and done without OK =="
D2="$(date -d "09:00 2 days" +%s)"
tp "$H/plain" "$CSID" $((D2 - 26 * 3600)) entry --topic old --new --status blocked --waits-on "Zoki · reply in Slack" "waits on Zoki" >/dev/null
tp "$H/plain" "$CSID" $((D2 - 26 * 3600)) entry --topic shipped --new --status completed --stage done "shipped, no review yet" >/dev/null
rm -f "$N"
tp "$H/plain" "$SID" "$D2" tick >/dev/null
M="$(cat "$N" 2>/dev/null)"
assert_has "a topic without an entry for 24 h, not on the user -> daily digest" "stale old · waits on Zoki" "$M"
assert_has "done without OK -> daily digest" "done without OK shipped · no review" "$M"
assert_has "...with the D3 line" "re-opened after wrap:" "$M"
rm -f "$N"
tp "$H/plain" "$SID" $((D2 + 600)) tick >/dev/null
assert_lacks "the daily digest goes out once a day" "Topics digest" "$(cat "$N" 2>/dev/null)"

say "== lint =="
OUT="$(tp "$H/plain" "$SID" "$T0" lint)"
assert_has "nothing untemplated so far" "0 entries without a Topic: line" "$OUT"
printf '\n### 11:11 – [w1] – hand-written entry\n- Status: completed\n\n### 11:12 – [w1] – Session started: something\n- Status: in-progress\n\n### 11:13 – [stranger] – never used topics\n- Status: completed\n' >> "$LOG"
OUT="$(tp "$H/plain" "$SID" "$T0" lint)"
assert_has "an entry of a topic writer without Topic: is listed" "[w1] hand-written entry" "$OUT"
assert_lacks "a Session started entry is exempt" "Session started" "$OUT"
assert_lacks "a session that never wrote a topic is not linted" "stranger" "$OUT"
assert_has "...counted" "1 entry without a Topic: line" "$OUT"
OUT="$(tp "$H/plain" "$SID" "$T0" lint)"
assert_has "the next lint starts after the last one" "0 entries without" "$OUT"

say "== stats (D3) and the closed marker =="
tp "$H/t3/proj/lane-beta" "$SID" "$T0" entry --status completed --closed "beta wrapped" >/dev/null
assert_has "--closed writes the frozen marker with the sessionId" "- Session: closed · $SID" "$(cat "$LOG")"
tp "$H/repo" "$SID" "$T0" entry --status completed --closed "gamma wrapped" >/dev/null
tp "$H/repo" "$SID" "$T0" entry --status in-progress "gamma again after the wrap" >/dev/null
tp "$H/repo" "$SID" "$T0" entry --status in-progress "and once more" >/dev/null
OUT="$(tp "$H/plain" "$SID" "$T0" stats)"
assert_has "per topic: entries after its wrap" "gamma: 2 entries after its wrap" "$OUT"
assert_has "re-opened after wrap: n of m" "re-opened after wrap: 1 of 2 topics (median 2 entries" "$OUT"
OUT="$(HOME="$H" MM_SESSION_LOG="$LOG" python3 "$ROOT/plugins/middle-management/scripts/peer-state.py" --all --json 2>&1)"; RC=$?
assert_rc "peer-state.py still parses the log" 0 "$RC"

say "== migrate: dry-run on a fixture board =="
H="$(mktemp -d -p "$TMPBASE")"; C="$H/.claude"; LOG="$H/logs/log.md"; B="$H/board.md"; N="$H/notified"
mkdir -p "$C/sessions" "$C/open-items" "$H/logs" "$H/plain"
cfg
cat > "$B" <<'EOF'
# Coordinator queue

Created: x

## TOPIC TABLE (open topics, inserted by hand)

| # | topic | lane / T3 thread | status | waits on | since | next step |
|---|---|---|---|---|---|---|
| 1 | mobile-wizard round 2 (split) | lane/mobile-wizard-2 · 86900e54 | building | nothing (Manu: Android check) | 10-20 09:32 | plan review |
| 2 | mobile-wizard round 1 | 86900e54 | LIVE+proof 6b3d | Manu (real Android check, card A5) | 10-20 09:28 | round 2 = row 1 |
| 3 | pod-limits (1 pod per customer) | 6d2b5360 | LIVE+proof 323e | nothing | 10-19 22:08 | watch the next render (dddddddd-W1) |
| 4 | Meta campaign objective Traffic | Slack thread 1792 | blocked | Zoki | 10-17 19:07 | check Zoki's reply |
| 5 | Funkelfreund lanes | FF coordinator | READY / LIVE | Manu (FF fee) | 10-19 | FF coordinator |

## 15:12 a later section
- eeeeeeee-W2 · owner: user · filed elsewhere
EOF
printf '# w · dddddddd-4444-4000-8000-000000000004 · %s/plain\n- W1 · owner: lane · watch the render\n' "$H" > "$C/open-items/dddddddd-session-notes.md"
SUM="$(sha256sum "$B")"
OUT="$(tp "$H/plain" "" "$(date -d "today 10:30" +%s)" migrate --board "$B" --skip 5)"; RC=$?
assert_rc "migrate exits 0" 0 "$RC"
assert_has "a lane row keys by its branch" "row  1 -> mobile-wizard-2" "$OUT"
assert_has "a row sharing that thread gets the same key" "row  2 -> mobile-wizard-2" "$OUT"
assert_has "a row with a hyphenated head word keys by it" "row  3 -> pod-limits" "$OUT"
assert_has "a prose row keys by its first words" "row  4 -> meta-campaign-objective" "$OUT"
assert_lacks "--skip leaves a row out" "row  5" "$OUT"
S="$(st mobile-wizard-2)"
assert_has "the older row's wait survives the newer row (persistent waits)" '"waits_on": "Manu"' "$S"
assert_has "...its since is the row's since" '"since": "'"$(date +%Y)"'-10-20 09:28"' "$S"
assert_has "...the thread is kept" '"thread": "86900e54"' "$S"
assert_has "the topics file is rendered" "| mobile-wizard-2 | 86900e54 |" "$(cat "$H/board.topics.md")"
assert_has "the board edit is printed as a diff" "-## TOPIC TABLE" "$OUT"
assert_has "...with the one link line" "+Topics: $H/board.topics.md" "$OUT"
[ "$SUM" = "$(sha256sum "$B")" ] && ok "the board itself is NOT changed" || bad "board changed by migrate"
assert_has "the check names a key that occurs only inside the table" "only inside the table: dddddddd-W1 (carried over" "$OUT"
assert_has "...and the link line carries it over" "carried over from it: dddddddd-W1" "$OUT"
assert_has "open-items list before: filed" "list before: 0 unfiled in 0 files" "$OUT"
assert_has "...after the edit: still filed" "list after: 0 unfiled in 0 files" "$OUT"
assert_has "a migrated wait drops the repeated who from the question" '"question": "real Android check, card A5"' "$S"
L="$(cat "$LOG")"
assert_has "the log carries ONE summary entry" "– [topics-migrate] – migrated 3 topics from the board table" "$L"
assert_has "...naming the keys" "- Keys: meta-campaign-objective, mobile-wizard-2, pod-limits" "$L"
assert_has "...with the frozen Status line" "- Status: completed" "$L"
[ "$(grep -c '^### ' "$LOG")" = 1 ] && ok "...and no entry per row" || bad "...and no entry per row" "$(grep -c '^### ' "$LOG") entries"
assert_has "the per-row headline still reaches the state" "migrated from the board TOPIC TABLE row 4" "$(st meta-campaign-objective)"
OUT="$(tp "$H/plain" "" "$(date -d "today 10:40" +%s)" lint)"
assert_has "lint does not list the summary entry" "0 entries without a Topic: line" "$OUT"

say ""
say "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
