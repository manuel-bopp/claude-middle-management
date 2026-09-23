#!/usr/bin/env bash
# middle-management plugin — peer-state.py against inline fixtures (fake HOME, never a live session).
# Consumers: run by hand or from CI: bash tests/peer-state.sh  (sibling of tests/run.sh; add a
#   line there to fold it into the main matrix).
# Everything lives under mktemp: no real registry, no real transcript, nothing messaged.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PS="$ROOT/plugins/middle-management/scripts/peer-state.py"
PASS=0; FAIL=0
TMPBASE="$(mktemp -d -t mm-peer-state.XXXXXX)"
trap 'case "$TMPBASE" in /tmp/*|/var/tmp/*) rm -rf "$TMPBASE" ;; esac' EXIT

say() { printf '%s\n' "$*"; }
ok()  { PASS=$((PASS+1)); say "  ok  - $1"; }
bad() { FAIL=$((FAIL+1)); say "  FAIL- $1"; [ -n "${2:-}" ] && say "        got: $2"; }
assert_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$3" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) bad "$1" "$3" ;; *) ok "$1" ;; esac; }
assert_rc()    { [ "$3" -eq "$2" ] && ok "$1" || bad "$1" "rc=$3 (want $2)"; }

H="$(mktemp -d -p "$TMPBASE")"; [ "$H" = "$HOME" ] && { echo "refusing: real HOME"; exit 2; }
mkdir -p "$H/.claude/sessions" "$H/.claude/projects/-tmp-x"
REG="$H/.claude/sessions"; T="$H/.claude/projects/-tmp-x"
: > "$H/log.md"
ps_() { HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="$H/log.md" python3 "$PS" "$@" 2>&1; }
entry() {  # entry <file> <pid> <sid> <name> <updatedAt> [procStart]
  printf '{"pid":%s,"sessionId":"%s","cwd":"/tmp/x","name":"%s","kind":"interactive","status":"busy","updatedAt":%s%s}\n' \
    "$2" "$3" "$4" "$5" "${6:+,\"procStart\":\"$6\"}" > "$REG/$1.json"
}
text() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}],"usage":{"input_tokens":1,"cache_read_input_tokens":123000}}}\n' "$1"; }

say "== wrap detection =="
entry 11 999901 aaaaaaaa-1 done-de 5
{ text 'Bericht steht.'; text 'Lane B1 ist abgeschlossen — diesen Tab kannst du schließen.'; } > "$T/aaaaaaaa-1.jsonl"
entry 12 999902 bbbbbbbb-1 done-en 5
text 'All landed. This session is finished, you can close this tab.' > "$T/bbbbbbbb-1.jsonl"
# The false positive the CLOSING_WINDOW exists for: a session WRITING about the phrase while it
# is still working. Measured on real transcripts: a genuine closing line sits 24-59 characters
# from the end of its block, a quoted one sat 684. The quote below is ~330 characters deep.
entry 13 999903 cccccccc-1 quoter 5
text 'The test asserts the banner contains \"close this tab\". That assertion now has to point at the new wording, so I am rewriting it and will report once the suite is green again. The rewrite touches three files, and the third one still needs the fixture that the assertion reads, so the suite cannot go green before that fixture exists. I will send the diff to the coordinator before I touch the wiring, and the lane stays open until then.' > "$T/cccccccc-1.jsonl"
entry 14 999904 dddddddd-1 silent 5
printf '{"type":"user","message":{"content":"hi"}}\n' > "$T/dddddddd-1.jsonl"
# sidechain text is a sub-agent, not the tab: it must not decide anything
entry 15 999905 eeeeeeee-1 subagent 5
{ text 'Working on it, the render is still running.'
  printf '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"Done — diesen Tab kannst du schließen."}]}}\n'; } > "$T/eeeeeeee-1.jsonl"
# Per session, not by counting lines around a grep hit: the row grows whenever a field is added.
assert_has "german closing line -> wrapped"  "wrapped : yes" "$(ps_ --name done-de)"
assert_has "english closing line -> wrapped" "wrapped : yes" "$(ps_ --name done-en)"
OUT="$(ps_ --name quoter)"
assert_has "the phrase quoted mid-text -> NOT wrapped" "wrapped : no" "$OUT"
OUT="$(ps_ --name silent)"
assert_has "no assistant text -> unknown"          "wrapped : unknown" "$OUT"
assert_has "unknown says it never counts as finished" "never counts as finished" "$OUT"
OUT="$(ps_ --name subagent)"
assert_has "a sub-agent's closing line -> NOT wrapped" "wrapped : no" "$OUT"
OUT="$(ps_ --wrapped)"
assert_has "the wrapped list is the tab list" "close these tabs instead of messaging them" "$OUT"
assert_lacks "the quoter is not on the tab list" "quoter" "$OUT"
assert_has "the price tag is on the tab list" "ctx 123k" "$OUT"

say "== the session log: corroboration and visible disagreement =="
printf '### 13:00 – [done-de / Opus 5, Worker] – Lane B1 gelandet\n- Status: completed\n' > "$H/log.md"
printf '### 13:10 – [silent / Opus 5, Worker] – Lane B2 rechnet\n- Status: completed\n' >> "$H/log.md"
OUT="$(ps_ --name done-de)"
assert_has "log completed corroborates the closing line" "session log says completed" "$OUT"
assert_lacks "two agreeing signals do not shout" "DISAGREE" "$OUT"
entry 16 999906 ffffffff-1 working 5
text 'Der Render läuft, ich melde mich mit den Zahlen.' > "$T/ffffffff-1.jsonl"
printf '### 13:20 – [working / Opus 5, Worker] – Lane B3\n- Status: completed\n' >> "$H/log.md"
OUT="$(ps_ --name working)"
assert_has "log completed WITHOUT a closing line -> the interesting case is marked" "DISAGREE" "$OUT"
assert_has "the disagreement does not flip the verdict" "wrapped : no" "$OUT"
assert_has "the log topic is used as the topic" "Lane B3" "$OUT"
: > "$H/log.md"
OUT="$(ps_ --name working)"
assert_has "no session log -> no log signal, no crash" "wrapped : no" "$OUT"
assert_lacks "no session log -> no log evidence" "session log says" "$OUT"

say "== registry: dedupe, liveness, damage =="
entry 17 999907 99999999-1 old-name 1
entry 18 999908 99999999-1 new-name 99
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"still here"}]}}\n' > "$T/99999999-1.jsonl"
OUT="$(ps_ --name new-name)"; assert_rc "the resumed name (newest updatedAt) wins" 0 $?
OUT="$(ps_ --name old-name)"; assert_rc "the stale duplicate is gone" 1 $?
assert_has "a missing name is reported on stderr" "no session" "$OUT"
entry 19 "$$" 77777777-1 me-wrong-start 5 4242424242
text 'hello' > "$T/77777777-1.jsonl"
OUT="$(ps_ --name me-wrong-start)"
assert_has "a live pid whose procStart does not match -> not live (pid reuse)" "live    : False" "$OUT"
entry 20 "$$" 88888888-1 me-real 5 "$(awk '{print $20}' <<<"$(sed 's/.*) //' /proc/$$/stat)")"
text 'hello' > "$T/88888888-1.jsonl"
OUT="$(ps_ --name me-real)"
assert_has "the real procStart of a live pid -> live" "live    : True" "$OUT"
printf '{oops' > "$REG/90.json"
printf 'NOT JSON AT ALL {{\n' >> "$T/aaaaaaaa-1.jsonl"
OUT="$(ps_ --all)"; RC=$?
assert_rc "a broken registry file and a broken JSONL line -> still exits 0" 0 "$RC"
assert_lacks "no traceback reaches the user" "Traceback" "$OUT"
assert_has "the intact sessions are still listed" "done-de" "$OUT"

say "== --session-id, including a session whose registry entry is already gone =="
OUT="$(ps_ --session-id aaaaaaaa-1)"; assert_rc "--session-id by full id" 0 $?
OUT="$(ps_ --session-id 99999999)"
assert_has "--session-id by prefix resolves to the deduped entry" "new-name" "$OUT"
rm -f "$REG"/11.json                       # the tab closed: entry gone, transcript still there
OUT="$(ps_ --session-id aaaaaaaa-1)"; RC=$?
assert_rc "an id with no registry entry is still answered from the transcript" 0 "$RC"
assert_has "the missing registry entry is marked" "NO REGISTRY ENTRY" "$OUT"
assert_has "the transcript alone still yields the verdict" "wrapped : yes" "$OUT"
OUT="$(ps_ --session-id aaaaaaaa-1 --json)"
assert_has "--session-id works with --json" '"registry": false' "$OUT"
OUT="$(ps_ --session-id 00000000-0)"; RC=$?
assert_rc "an id that is nowhere -> rc 1" 1 "$RC"

say "== closing-phrase recall: the wordings people actually write =="
# One fixture per wording the detector has to see. A MISS is the expensive direction here: a
# finished session that is not on the tab list gets messaged and pays its whole context
# (145k-726k tokens measured). The last line is the precision control - it must stay "no".
: > "$H/log.md"                                # no log entry: the phrase stands on its own
CN=0
closer() {   # closer <yes|no> <name> <text>
  CN=$((CN+1))
  entry "3$CN" "99930$CN" "c00000$CN-1" "$2" 5
  text "$3" > "$T/c00000$CN-1.jsonl"
  assert_has "-> $1: $3" "wrapped : $1" "$(ps_ --name "$2")"
}
closer yes cl-plural   'Beide Lanes sind durch — die Tabs kannst du schließen.'
closer yes cl-zumachen 'Alles erledigt. Du kannst den Tab jetzt zumachen.'
closer yes cl-kannzu   'Noch offen: HYP-231. Nebenbei: der alte Worker-Tab kann zu.'
closer yes cl-window   'All done — feel free to close this window.'
closer yes cl-closeit  'Everything is merged and pushed. You can close it now.'
closer yes cl-canbe    'Report written — this tab can be closed.'
# The wording SKILL.md §Recovery and the CHANGELOG tell a session to write. Without it, a
# session that follows the docs literally reads as unfinished forever.
closer yes cl-cancl    'Seat released, board updated — this tab can close.'
closer no  cl-open     'Der Tab bleibt offen, die Lane ist noch nicht abgeschlossen.'
# A session that announces ITSELF closed and never mentions a tab. The line below is verbatim
# from a live 401k-token session that read "no" and would have been messaged for it. Note the
# handover sentence after the phrase: 202 characters, i.e. just past CLOSING_WINDOW - which is
# why these are matched in the block's LAST LINE instead of in the character window.
closer yes cl-self74   '**Diese Session ist zu.** Sitz frei, `main` bei `ce1d9418`, Linear 12 Slots. Der Prompt für den Fable-Koordinator steht im Recap oben — Startpunkt bleibt `orchestrator.sh claim` ohne Weckruf, dann je eine Zeile an 98 und b4.'
closer yes cl-selfde   'Alles verbucht. Session ist zu.'
closer yes cl-selfen   'Handover written. This session is closed.'
closer yes cl-selfen2  'Nothing left to run — this session is done.'
# ...and the precision side of that widening: the noun has to be the session itself.
closer no  cl-lane     'Die Lane ist zu. Ich fange jetzt mit dem A/B an.'
closer no  cl-ticket   'Das Ticket ist done, der Rest des Pakets läuft weiter.'
# A self-closer that is NOT the last line is somebody thinking out loud, not signing off.
closer no  cl-notlast  'Diese Session ist zu, dachte ich — aber\nder Render läuft noch, ich melde mich mit den Zahlen.'

say "== a closing line the session log contradicts is NOT a wrap =="
# The session most likely to write "den Tab kannst du schließen" is a LIVE coordinator writing
# about a WORKER's tab - the role hook tells it to, after every wrap. Its own log entry still
# says in-progress, and that is the signal that settles whose tab is meant.
entry 41 999941 40000000-1 coord 5
text 'Lane W1 ist gelandet — der Worker hat gewrapped. Den Tab kannst du schließen. Als Nächstes: HYP-231?' > "$T/40000000-1.jsonl"
printf '### 09:10 – [coord / Fable, KOORDINATOR] – Lane W1 Review läuft\n- Status: in-progress\n' > "$H/log.md"
OUT="$(ps_ --name coord)"
assert_has "closing line + log in-progress -> NOT wrapped" "wrapped : no" "$OUT"
assert_has "the disagreement stays visible - it is the interesting case" "DISAGREE" "$OUT"
assert_lacks "a contradicted closer is not on the tab list" "coord" "$(ps_ --wrapped)"
assert_has "log_completed is false when the entry is not completed" '"log_completed": false' "$(ps_ --session-id 40000000-1 --json)"
printf '### 09:20 – [coord / Fable, KOORDINATOR] – Lane W1\n- Status: completed\n' > "$H/log.md"
assert_has "the same text with a completed entry -> wrapped" "wrapped : yes" "$(ps_ --name coord)"
assert_has "log_completed is true then" '"log_completed": true' "$(ps_ --session-id 40000000-1 --json)"
: > "$H/log.md"
assert_has "no entry for that name -> nothing to contradict -> wrapped" "wrapped : yes" "$(ps_ --name coord)"
assert_has "log_completed is null ONLY when there is no usable entry" '"log_completed": null' "$(ps_ --session-id 40000000-1 --json)"

say "== an entry from ANOTHER CALENDAR DAY is absent, not a contradiction =="
# Same session, same transcript, same closing line: ONLY the "## YYYY-MM-DD" heading above the
# entry differs. An entry filed yesterday cannot describe a turn written today. The day comes
# from the log's own structure, so there is no duration for anyone to tune later.
TODAY="$(date +%F)"; YDAY="$(date -d yesterday +%F)"
ENTRY_LINE='### 09:10 – [coord / Fable, KOORDINATOR] – Lane W1 Review läuft\n- Status: in-progress\n'
printf "## %s\n$ENTRY_LINE" "$TODAY" > "$H/log.md"
OUT="$(ps_ --name coord)"
assert_has "TODAY's entry -> the contradiction stands, the F1 defect stays fixed" "wrapped : no" "$OUT"
assert_has "...and is still visible as a disagreement" "DISAGREE" "$OUT"
assert_has "...log_completed false, so nothing about the seat changed" '"log_completed": false' "$(ps_ --session-id 40000000-1 --json)"
assert_lacks "...and a live coordinator is still off the tab list" "coord" "$(ps_ --wrapped)"
printf "## %s\n$ENTRY_LINE" "$YDAY" > "$H/log.md"
OUT="$(ps_ --name coord)"
assert_has "YESTERDAY's entry -> absent, the closing line stands alone" "wrapped : yes" "$OUT"
assert_lacks "...nothing left to disagree with" "DISAGREE" "$OUT"
assert_has "...the entry is named as disregarded, with its date" "from $YDAY was found and disregarded" "$OUT"
# null, not false: the tab list gets the session back while a seat takeover still refuses.
assert_has "...log_completed null (absent), which keeps the seat safe" '"log_completed": null' "$(ps_ --session-id 40000000-1 --json)"
# Not a one-way door: a stale COMPLETED entry stops corroborating just the same.
printf '## %s\n### 09:10 – [coord / Fable, KOORDINATOR] – Lane W1\n- Status: completed\n' "$YDAY" > "$H/log.md"
assert_has "a stale completed entry does not corroborate either" '"log_completed": null' "$(ps_ --session-id 40000000-1 --json)"
# A log with no day headings at all keeps the old behaviour - nothing to compare against.
printf "$ENTRY_LINE" > "$H/log.md"
assert_has "no day headings in the log -> the entry counts as before" "wrapped : no" "$(ps_ --name coord)"
: > "$H/log.md"

say "== damage that used to raise: non-object registry files, mixed updatedAt, nameless header =="
# `[]`, `null`, `5`, `"x"` are all valid JSON. `.get` on them raised AttributeError and killed
# the run for EVERY session - and the one caller hides stderr, so the feature would just stop.
CN=0
for body in '[]' 'null' '5' '"x"' '[{"sessionId":"q"}]' '{"sessionId":[1,2]}'; do
  CN=$((CN+1)); printf '%s' "$body" > "$REG/9$CN.json"
done
# ...and two entries for one sessionId whose updatedAt is str in one, int in the other.
entry 97 999997 70000000-1 mixed-upd 5
printf '{"pid":999998,"sessionId":"70000000-1","cwd":"/tmp/x","name":"mixed-upd-b","kind":"interactive","updatedAt":"2026-09-21T10:00:00Z"}\n' > "$REG/98.json"
text 'hello' > "$T/70000000-1.jsonl"
# ...and a hand-edited session-log header that names nobody. It sits AFTER a real entry, so a
# fix that merely stops the IndexError but keeps the previous name would hand done-en the
# "completed" below and flip its verdict from no to yes.
printf '### 13:05 – [done-en] – Lane B1 läuft noch\n- Status: in-progress\n### 13:00 – [ ] – a header naming nobody\n- Status: completed\n' > "$H/log.md"
OUT="$(ps_ --all)"; RC=$?
assert_rc "non-object registry files + mixed updatedAt + nameless log header -> still rc 0" 0 "$RC"
assert_lacks "no traceback reaches the user" "Traceback" "$OUT"
assert_has "the intact sessions are still listed" "done-en" "$OUT"
assert_has "the whitespace-only bracket keeps its status to itself" "wrapped : no" "$(ps_ --name done-en)"
rm -f "$REG"/9?.json; : > "$H/log.md"

say "== a session that renamed itself: its log entry is filed under the OTHER name =="
# Shape 1 — two registry entries, ONE sessionId, two names (a resumed session keeps its id but
# gets a new pid and a new derived name). The stale entry under the OLD name says in-progress,
# today's entry under the NEW one says completed. Keying the log by the winning entry's name
# alone read the stale one, called it a contradiction, and dropped the most expensive session on
# the machine (740,729 tokens, measured) off the tab list.
entry 60 999960 60000000-1 old-9b 5
entry 61 999961 60000000-1 new-0b 99
text 'Sitz freigegeben. Diese Session ist beendet, diesen Tab kannst du schließen.' > "$T/60000000-1.jsonl"
printf '### 18:52 – [old-9b / Fable, KOORDINATOR] – Abend-Lanes zugewiesen\n- Status: in-progress\n### 13:13 – [new-0b / Fable, KOORDINATOR] – Sitz freigegeben\n- Status: completed — Tab kann zu\n' > "$H/log.md"
OUT="$(ps_ --name new-0b)"
assert_has "the newest entry across BOTH names of one sessionId decides" "wrapped : yes" "$OUT"
assert_has "...and it is the completed one, not the stale in-progress one" "session log says completed" "$OUT"
# Newest, NOT "any completed wins": the same two entries, opposite order in the file.
printf '### 13:13 – [new-0b / Fable, KOORDINATOR] – Sitz freigegeben\n- Status: completed\n### 18:52 – [old-9b / Fable, KOORDINATOR] – doch noch was\n- Status: in-progress\n' > "$H/log.md"
assert_has "the LAST entry in file order wins, not the friendliest one" "wrapped : no" "$(ps_ --name new-0b)"
assert_has "the alias the verdict turned on is named, or the audit trail lies" 'filed under "old-9b"' "$(ps_ --name new-0b)"
assert_has "every name of the sessionId is exposed to the caller" '"old-9b"' "$(ps_ --session-id 60000000-1 --json)"
# The OTHER rename shape — declared in the log bracket alone, "[new (vormals old) / ...]" — is
# deliberately NOT followed, and this fixture is why. `bc` was worn by two different sessions on
# the real machine: one kept it, the other renamed bc -> ac -> 05. Following the bracket drags
# the first session onto the second's later, unfinished entry. Measured: four correctly-wrapped
# sessions turned into "no". The log's names are a human convention; identity is the sessionId.
entry 62 999962 62000000-1 keeper-bc 5
text 'Lane X1 ist abgeschlossen — diesen Tab kannst du schließen.' > "$T/62000000-1.jsonl"
printf '### 15:50 – [keeper-bc / Fable, Worker X1] – Lane X1 ABGESCHLOSSEN\n- Status: completed\n### 20:11 – [other-05 (ex keeper-bc) / Fable, Worker S1] – nach dem Freeze wieder da\n- Status: waiting\n' > "$H/log.md"
OUT="$(ps_ --name keeper-bc)"
assert_has "a bracket rename by a DIFFERENT session does not steal this one's verdict" "wrapped : yes" "$OUT"
assert_has "...its own completed entry is the one that counts" "session log says completed" "$OUT"
assert_lacks "...and no alias is claimed" "filed under" "$OUT"
: > "$H/log.md"

say "== the wrap's own \"Session: closed\" marker: declared, not inferred =="
# The authoritative record the wrap files: "- Session: closed · <sessionId>" inside its entry.
# It is keyed by sessionId, so the entry below is deliberately filed under a name this session
# never carried AND says in-progress - the marker has to beat both, and no closing phrase exists.
TODAY="$(date +%F)"; YDAY="$(date -d yesterday +%F)"; NOWHM="$(date +%H:%M)"
entry 70 999970 7a000000-1 mk-plain 5
text 'Der Render läuft, ich melde mich mit den Zahlen.' > "$T/7a000000-1.jsonl"
printf '## %s\n### %s – [a-name-it-never-had / Opus 5, Worker] – Lane W1\n- Status: in-progress\n- Session: closed · 7a000000-1 — Tab kann zu\n' "$TODAY" "$NOWHM" > "$H/log.md"
OUT="$(ps_ --name mk-plain)"
assert_has "a marker wraps the session with no closing phrase anywhere" "wrapped : yes" "$OUT"
assert_has "...naming the marker and its own timestamp" "closed at $NOWHM on $TODAY" "$OUT"
assert_has "...and it outranks a Status: in-progress filed under another name" "authoritative" "$OUT"
assert_has "...the JSON carries it, so a consumer sees DECLARED, not inferred" '"id": "7a000000-1"' "$(ps_ --session-id 7a000000-1 --json)"
# A prefix is what a human pastes; >=8 characters, resolved against the ids actually present.
entry 71 999971 7b000000-1 mk-prefix 5
text 'Noch am Rechnen.' > "$T/7b000000-1.jsonl"
printf '## %s\n### %s – [mk-prefix / Opus 5, Worker] – Lane W2\n- Session: closed · 7b000000\n' "$TODAY" "$NOWHM" > "$H/log.md"
assert_has "an 8-character prefix resolves to the session" "wrapped : yes" "$(ps_ --name mk-prefix)"
# ...but only while it names exactly one. Picking one of two would close the wrong tab silently.
entry 72 999972 abcd0000-1 mk-ambig1 5
entry 73 999973 abcd0000-2 mk-ambig2 5
text 'Läuft noch.'      > "$T/abcd0000-1.jsonl"
text 'Läuft auch noch.' > "$T/abcd0000-2.jsonl"
printf '## %s\n### %s – [mk-ambig1 / Opus 5, Worker] – Lane W3\n- Session: closed · abcd0000\n' "$TODAY" "$NOWHM" > "$H/log.md"
OUT="$(ps_ --name mk-ambig1)"
assert_has "a prefix matching two sessionIds resolves to NEITHER" "wrapped : no" "$OUT"
assert_has "...and says why, rather than dropping it silently" "matches 2 sessionIds" "$OUT"
assert_has "...the second one is not closed by it either" "wrapped : no" "$(ps_ --name mk-ambig2)"
assert_has "...and nothing is declared in the JSON" '"closed_marker": null' "$(ps_ --session-id abcd0000-1 --json)"
# THE staleness guard: a session RESUMED after its wrap leaves the marker behind while it works
# again. A stale yes here would let `orchestrator.sh claim` take a live coordinator's seat.
entry 74 999974 7c000000-1 mk-stale 5
text 'Ich bin wieder dran, die Lane läuft weiter.' > "$T/7c000000-1.jsonl"
printf '## %s\n### %s – [mk-stale / Fable, KOORDINATOR] – Wrap\n- Session: closed · 7c000000-1\n' \
  "$(date -d '-2 hours' +%F)" "$(date -d '-2 hours' +%H:%M)" > "$H/log.md"
OUT="$(ps_ --name mk-stale)"
assert_has "a marker the transcript kept working 2h past is ignored" "wrapped : no" "$OUT"
assert_has "...named as stale, with the gap, so the fallback is auditable" "later - STALE" "$OUT"
assert_has "...and nothing is declared in the JSON" '"closed_marker": null' "$(ps_ --session-id 7c000000-1 --json)"
printf '## %s\n### %s – [mk-stale / Fable, KOORDINATOR] – Wrap\n- Session: closed · 7c000000-1\n' \
  "$(date -d '-10 minutes' +%F)" "$(date -d '-10 minutes' +%H:%M)" > "$H/log.md"
assert_has "...10 minutes later is just the wrap finishing: NOT stale" "wrapped : yes" "$(ps_ --name mk-stale)"
# Yesterday's entries rotate out of the live log into archive/<day>.md. A session that wrapped
# yesterday and never came back must still read as closed today.
mkdir -p "$H/archive"
entry 75 999975 7d000000-1 mk-archived 5
text 'Bericht steht.' > "$T/7d000000-1.jsonl"
touch -d "$YDAY 15:10" "$T/7d000000-1.jsonl"
printf '## %s\n### 15:05 – [gone-name / Fable, Worker] – Lane W9\n- Status: in-progress\n- Session: closed · 7d000000-1 — Tab zu\n' "$YDAY" > "$H/archive/$YDAY.md"
: > "$H/log.md"
OUT="$(ps_ --name mk-archived)"
assert_has "a marker in a rotated archive file counts too" "wrapped : yes" "$OUT"
assert_has "...with that archived entry's own date, not today's" "closed at 15:05 on $YDAY" "$OUT"
# The conclusion this marker exists BECAUSE of, pinned: `Status:` describes the ENTRY'S WORK, not
# the session's life - hyperreel-5c filed completed and kept working for hours. Same session as
# the first fixture, same transcript, marker removed: back to "no".
printf '## %s\n### %s – [mk-plain / Opus 5, Worker] – Lane W1\n- Status: completed\n' "$TODAY" "$NOWHM" > "$H/log.md"
OUT="$(ps_ --name mk-plain)"
assert_has "Status: completed ALONE is still not a positive" "wrapped : no" "$OUT"
assert_has "...it stays mere corroboration, and the disagreement stays visible" "DISAGREE" "$OUT"
assert_has "...and declares nothing" '"closed_marker": null' "$(ps_ --session-id 7a000000-1 --json)"
# A marker under no headings at all cannot be dated, so the staleness guard cannot run on it -
# it is refused rather than trusted, and says so instead of vanishing.
printf -- '- Session: closed · 7a000000-1\n' > "$H/log.md"
OUT="$(ps_ --name mk-plain)"
assert_has "an undatable marker does not count" "wrapped : no" "$OUT"
assert_has "...and is named as refused, with the reason" "cannot be checked for staleness" "$OUT"
: > "$H/log.md"                                # the archive fixture stays: later sections scan it

say "== last vs topic, the two ages, --cwd prefix, the JSON contract =="
entry 50 999950 50000000-1 reporter 5
{ text 'Lane B7 — Bildpipeline, ich fange an.'
  text '## Zusammenfassung W1\nViele Zeilen Bericht ...\nFertig — you can close this tab.'; } > "$T/50000000-1.jsonl"
OUT="$(ps_ --name reporter)"
assert_has "last is the LAST line of the last block (the text at the bottom of the tab)" "last    : Fertig — you can close this tab." "$OUT"
assert_has "topic is the FIRST assistant line, so the two columns differ" "topic   : Lane B7" "$OUT"
# A RESUMED session: the process started 57 minutes ago, the conversation nine hours ago. Only
# the second number says what waking it would cost - `ListAgents` shows only the first.
NOW=$(date +%s)
printf '{"pid":999951,"sessionId":"51000000-1","cwd":"/tmp/x","name":"resumed","kind":"interactive","updatedAt":5,"startedAt":%s000}\n' "$((NOW-3420))" > "$REG/51.json"
{ printf '{"type":"user","timestamp":"%s","message":{"content":"hi"}}\n' "$(date -u -d "@$((NOW-32400))" +%Y-%m-%dT%H:%M:%S.000Z)"
  text 'Ganz anderes Thema, seit heute früh.'; } > "$T/51000000-1.jsonl"
OUT="$(ps_ --name resumed)"
assert_has "the process age is the young, misleading one" "process 57m" "$OUT"
assert_has "the conversation age is the true one" "conversation 9h00m" "$OUT"
assert_has "the gap between them is called out by name" "RESUMED" "$OUT"
# A lane worker sits in a worktree, not in the checkout root: exact --cwd listed nobody.
printf '{"pid":999952,"sessionId":"52000000-1","cwd":"/tmp/Repo/.worktrees-app/T3","name":"in-worktree","kind":"interactive","updatedAt":5}\n' > "$REG/52.json"
text 'Lane T3 läuft.' > "$T/52000000-1.jsonl"
printf '{"pid":999953,"sessionId":"53000000-1","cwd":"/tmp/RepoOther","name":"next-door","kind":"interactive","updatedAt":5}\n' > "$REG/53.json"
text 'Anderes Repo.' > "$T/53000000-1.jsonl"
OUT="$(ps_ --all --cwd /tmp/Repo)"
assert_has "--cwd matches a directory BELOW it (the lane worktree)" "in-worktree" "$OUT"
assert_lacks "--cwd stops at a path segment: /tmp/Repo is not /tmp/RepoOther" "next-door" "$OUT"
assert_has "--cwd still matches the directory itself" "in-worktree" "$(ps_ --all --cwd /tmp/Repo/.worktrees-app/T3)"

say "== which session log gets read: env, config key, default =="
# Three steps, and scripts/config-check.sh answers the same for shell callers. Every ps_ above
# pins MM_SESSION_LOG, so the config route needs its own calls with that variable empty.
entry 80 999980 80000000-1 log-route 5
text 'Lane R1 fertig, den Tab kannst du schließen.' > "$T/80000000-1.jsonl"
log_at() { printf '### 13:00 – [log-route / Opus 5, Worker] – Lane R1\n- Status: completed\n' > "$1"; }
log_at "$H/from-config.md"
printf '{"sessionLog":"%s/from-config.md"}' "$H" > "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" python3 "$PS" --name log-route 2>&1)"
assert_has "the sessionLog config key is read when the env var is empty" "session log says completed" "$OUT"
printf '{"sessionLog":"~/from-tilde.md"}' > "$H/.claude/middle-management.json"
log_at "$H/from-tilde.md"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" python3 "$PS" --name log-route 2>&1)"
assert_has "a ~ in the config key is expanded" "session log says completed" "$OUT"
: > "$H/empty.md"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="$H/empty.md" python3 "$PS" --name log-route 2>&1)"
assert_lacks "MM_SESSION_LOG wins over the config key" "session log says" "$OUT"
mkdir -p "$H/logs"; log_at "$H/logs/session-log.md"      # the built-in default, ~/logs/session-log.md
rm -f "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" python3 "$PS" --name log-route 2>&1)"
assert_has "no env, no config -> ~/logs/session-log.md" "session log says completed" "$OUT"
printf '{"sessionLog":5}' > "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" python3 "$PS" --name log-route 2>&1)"; RC=$?
assert_rc "a sessionLog that is not a string -> exit 0, no traceback" 0 "$RC"
assert_has "...and the built-in default answers instead" "session log says completed" "$OUT"
assert_lacks "no traceback from a broken config" "Traceback" "$OUT"
printf 'not json at all' > "$H/.claude/middle-management.json"
OUT="$(HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" python3 "$PS" --name log-route 2>&1)"; RC=$?
assert_rc "an unparseable config -> exit 0" 0 "$RC"
assert_has "...and the built-in default answers there too" "session log says completed" "$OUT"
# A RELATIVE value must never bind to this process's cwd — config-check.sh refuses it too, and a
# machine where the two name different files has no reliable second signal for the seat. The bait:
# $H/from-config.md holds the completed entry AND is the cwd, so a cwd-bound resolver reads it.
printf '{"sessionLog":"from-config.md"}' > "$H/.claude/middle-management.json"
rm -f "$H/logs/session-log.md"
OUT="$(cd "$H" && HOME="$H" CLAUDE_CONFIG_DIR="" MM_SESSION_LOG="" python3 "$PS" --name log-route 2>&1)"; RC=$?
assert_rc "a relative sessionLog -> exit 0" 0 "$RC"
assert_lacks "a relative sessionLog never binds to the caller's cwd" "session log says" "$OUT"
assert_has "...and one stderr line names the rule" "not an absolute path" "$OUT"
rm -f "$H/.claude/middle-management.json" "$H/logs/session-log.md"

say "== waiting on its user: a permission prompt or a question, read from the tail =="
# Alive but stuck until its user acts in THAT tab. Only a live process can be parked, so these
# fixtures use this shell's own pid with its real procStart (the "me-real" pattern above).
ME_START="$(awk '{print $20}' <<<"$(sed 's/.*) //' /proc/$$/stat)")"
WN=0
waiter() {   # waiter <name> <live|dead> <minutes idle>  < <(jsonl body)  - not a pipe: WN must count
  WN=$((WN+1))
  if [ "$2" = live ]; then entry "w$WN" "$$" "c1000$WN-1" "$1" 5 "$ME_START"
  else entry "w$WN" "99920$WN" "c1000$WN-1" "$1" 5; fi
  cat > "$T/c1000$WN-1.jsonl"
  touch -d "-$3 minutes" "$T/c1000$WN-1.jsonl"
}
tool() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"%s","input":{}}]}}\n' "$1"; }
result() { printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}\n'; }
waiter wt-perm live 10 < <(text 'Ich pushe jetzt den Branch.'; tool Bash)
waiter wt-running live 0 < <(text 'Ich starte den Build.'; tool Bash)
waiter wt-askq live 0 < <(text 'Zwei Wege offen.'; tool AskUserQuestion)
waiter wt-qmark live 2 < <(text 'Konzept steht unter /var/tmp/x/konzept.md. Passt die Reihenfolge so?')
waiter wt-phrase live 2 < <(text 'Soll ich das jetzt mergen, oder erst den Review abwarten.')
waiter wt-busy live 20 < <(text 'Der Render läuft, ich melde mich mit den Zahlen.')
waiter wt-answered live 10 < <(text 'Ich pushe jetzt.'; tool Bash; result)
waiter wt-dead dead 30 < <(text 'Passt die Reihenfolge so?')
waiter wt-wrapped live 30 < <(text 'Alles gelandet. Soll ich noch etwas tun? Sonst: diesen Tab kannst du schließen.')
waiter wt-sidechain live 10 < <(text 'Ich warte auf den Sub-Agenten.'
  printf '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"s1","name":"Bash","input":{}}]}}\n')
waiter wt-agent live 10 < <(text 'Ich lasse das reviewen.'; tool Agent)
waiter wt-kw live 50 < <(text 'Konzept steht. Passt die Reihenfolge so?'
  printf '{"type":"user","message":{"content":"<cross-session-message from-name=keepwarm> KEEPWARM PING (automatic, not from your user, not an answer). Do nothing. Reply with exactly: ok </cross-session-message>"}}\n'
  text 'ok')
waiter wt-kwdone live 5 < <(text 'Passt die Reihenfolge so?'
  printf '{"type":"user","message":{"content":"KEEPWARM PING (automatic, not from your user, not an answer). Do nothing. Reply with exactly: ok"}}\n'
  text 'ok'; printf '{"type":"user","message":{"content":"ja, passt"}}\n'; text 'Dann baue ich jetzt.')
assert_lacks "a pending sub-agent (Agent) call is work, not a dialog" "waiting :" "$(ps_ --name wt-agent)"
assert_has "a keep-warm ping and its ok do not hide the question" "waiting : question" "$(ps_ --name wt-kw)"
assert_lacks "an answer after the ping ends the wait" "waiting :" "$(ps_ --name wt-kwdone)"
assert_has "a tool call with no result, quiet 10 minutes -> permission" "waiting : permission" "$(ps_ --name wt-perm)"
assert_lacks "the same call written just now is a tool still running" "waiting :" "$(ps_ --name wt-running)"
assert_has "an open AskUserQuestion -> question at once" "waiting : question" "$(ps_ --name wt-askq)"
assert_has "a last text ending in a question mark -> question" "waiting : question" "$(ps_ --name wt-qmark)"
assert_has "a last text that asks in so many words -> question" "waiting : question" "$(ps_ --name wt-phrase)"
assert_lacks "a statement is not a question" "waiting :" "$(ps_ --name wt-busy)"
assert_lacks "a tool call that got its result is not parked" "waiting :" "$(ps_ --name wt-answered)"
assert_lacks "a dead process waits on nobody" "waiting :" "$(ps_ --name wt-dead)"
OUT="$(ps_ --name wt-wrapped)"
assert_has "a wrapped session that asked on the way out..." "wrapped : yes" "$OUT"
assert_lacks "...is finished, not waiting" "waiting :" "$OUT"
assert_lacks "a sub-agent's open tool call is not the tab's" "waiting :" "$(ps_ --name wt-sidechain)"
assert_has "the detail line hedges permission" "MAY be a permission prompt, or a tool still running" "$(ps_ --name wt-perm)"
assert_has "the detail line says what a question means" "will not move until its user acts" "$(ps_ --name wt-qmark)"
OUT="$(ps_ --waiting)"
assert_has "--waiting lists the permission prompt" "wt-perm" "$OUT"
assert_has "--waiting lists the question" "wt-qmark" "$OUT"
assert_lacks "--waiting leaves out the working session" "wt-busy" "$OUT"
assert_has "the table carries a WAITING column" "WAITING" "$OUT"
assert_has "the JSON carries the state" '"waiting": "permission"' "$(ps_ --name wt-perm --json)"

# The keys orchestrator.sh and the tab list read. Renaming one silently breaks a sibling script.
CONTRACT="$(ps_ --all --json | python3 -c '
import json, sys
want = {"wrapped": str, "wrapped_evidence": str, "log_completed": bool, "idle_seconds": (int, float),
        "ctx_tokens": (int, float), "last": str, "topic": str, "closed_marker": dict,
        "process_age_seconds": (int, float), "conversation_age_seconds": (int, float),
        "waiting": str}
bad = []
for r in json.load(sys.stdin):
    n = r.get("name")
    for k, t in want.items():
        if k not in r:
            bad.append("%s: %s missing" % (n, k))
        elif r[k] is not None and not isinstance(r[k], t):
            bad.append("%s: %s is %s" % (n, k, type(r[k]).__name__))
    if r.get("wrapped") not in ("yes", "no", "unknown"):
        bad.append("%s: wrapped=%r" % (n, r.get("wrapped")))
print("CONTRACT OK" if not bad else "CONTRACT BROKEN: " + "; ".join(bad[:6]))')"
assert_has "every row carries the documented keys, with the documented types" "CONTRACT OK" "$CONTRACT"
ps_ --all --json | python3 -m json.tool > /dev/null 2>&1
assert_rc "--json round-trips through a strict parser" 0 $?

say ""
say "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
