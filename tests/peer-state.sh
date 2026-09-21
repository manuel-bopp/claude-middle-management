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
# The keys orchestrator.sh and the tab list read. Renaming one silently breaks a sibling script.
CONTRACT="$(ps_ --all --json | python3 -c '
import json, sys
want = {"wrapped": str, "wrapped_evidence": str, "log_completed": bool, "idle_seconds": (int, float),
        "ctx_tokens": (int, float), "last": str, "topic": str,
        "process_age_seconds": (int, float), "conversation_age_seconds": (int, float)}
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
