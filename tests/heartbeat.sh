#!/usr/bin/env bash
# middle-management plugin — heartbeat regression matrix (fake environment, sends nothing).
# Consumers: tests/run.sh (runs it last); by hand from the repo root: bash tests/heartbeat.sh
#
#   B  fixtures for the classifier (every record shape that must or must not count as a turn)
#   C  every transition, liveness outcome and latch, against a fake registry/marker/transcript
#   D  the configured notifyCommand and the unit-failure alarm
# The master setup this plugin derives from also re-runs the classifier against real stalled
# transcripts (its section A); those files are private and stay there.
# Alarms and pokes are redirected into files with OHB_ALARM_SINK / OHB_POKE_SINK; section D
# clears the sink and drives the real notifyCommand path against a throwaway config.
set -uo pipefail

HB=$(cd "$(dirname "$0")/.." && pwd)/plugins/middle-management/scripts
SCRIPT=$HB/orch-heartbeat.sh
UFA=$HB/unit-failure-alarm.sh
TMP=$(mktemp -d /tmp/orch-heartbeat-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s (%s)\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }   # is <name> <actual> <expected>
# near <name> <actual> <expected> [tolerance] - for epoch comparisons: the fixture's timestamp and
# the expectation are taken from two different `date` calls, so a second boundary between them
# must not turn a correct implementation red.
near() { local d=$(( $2 - $3 )); [ "$d" -lt 0 ] && d=$(( 0 - d ))
         [ "$d" -le "${4:-2}" ] && ok "$1" || bad "$1" "$3 (±${4:-2}s)" "$2"; }

verdict() { OHB_STATE_DIR=$TMP/never-written "$SCRIPT" classify "$1" | cut -f1; }
iso()  { date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
aged() { touch -d "@$(( $(date +%s) - ${2} * 60 ))" "$1"; }     # aged <file> <minutes>

# ------------------------------------------------------------------------- B. fixtures ------
echo "B. classifier fixtures"
u()     { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"do the thing"}}\n' "$(iso "$1")"; }
a()     { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"done"}]}}\n' "$(iso "$1")"; }
synth() { printf '{"type":"assistant","timestamp":"%s","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 529"}]}}\n' "$(iso "$1")"; }
scmd()  { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<%s>x</%s>"}}\n' "$(iso "$2")" "$1" "$1"; }
cmd()   { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"text","text":"<command-name>/model</command-name>"}]}}\n' "$(iso "$1")"; }
side()  { printf '{"type":"user","timestamp":"%s","isSidechain":true,"message":{"role":"user","content":"sub-agent turn"}}\n' "$(iso "$1")"; }
sidea() { printf '{"type":"assistant","timestamp":"%s","isSidechain":true,"message":{"model":"claude-opus-5","content":[]}}\n' "$(iso "$1")"; }
nots()  { printf '{"type":"%s"}\n' "$1"; }
limit() { printf '{"type":"system","subtype":"api_error","timestamp":"%s","error":{"status":429,"rateLimits":{"resetsAt":%s}}}\n' "$(iso "$1")" "$2"; }

fx() { f=$TMP/fx-$1.jsonl; shift; cat > "$f"; }   # usage: fx <name>  <<records

fx latch     < <( { a "62 min ago"; u "60 min ago"; nots atis-latch; nots bridge-session; } ); aged "$TMP/fx-latch.jsonl" 60
is "stall ending on atis-latch/bridge-session" "$(verdict "$TMP/fx-latch.jsonl")" STUCK

fx fresh     < <( { nots ai-title; printf '{"type":"system","subtype":"init","timestamp":"%s"}\n' "$(iso "60 min ago")"; } ); aged "$TMP/fx-fresh.jsonl" 60
is "fresh session, no user record" "$(verdict "$TMP/fx-fresh.jsonl")" HEALTHY

fx nots      < <( { nots atis-latch; nots ai-title; nots bridge-session; } ); aged "$TMP/fx-nots.jsonl" 60
is "records without timestamps only" "$(verdict "$TMP/fx-nots.jsonl")" HEALTHY

# "Must not be STUCK": with the echo / the sidechain excluded the newest own record is the
# assistant's answer, so the classifier says RECOVERED.
fx slash     < <( { u "70 min ago"; a "69 min ago"; cmd "60 min ago"; } ); aged "$TMP/fx-slash.jsonl" 60
[ "$(verdict "$TMP/fx-slash.jsonl")" != STUCK ] && ok "slash-command echo (array shape) is not STUCK" \
  || bad "slash-command echo (array shape)" "not STUCK" "STUCK"
# Every echo on disk is a STRING, and all three tags occur - this is the shape production sees.
for tag in local-command-caveat command-name local-command-stdout; do
  fx "slash-$tag" < <( { u "70 min ago"; a "69 min ago"; scmd "$tag" "60 min ago"; } )
  aged "$TMP/fx-slash-$tag.jsonl" 60
  [ "$(verdict "$TMP/fx-slash-$tag.jsonl")" != STUCK ] && ok "string echo <$tag> is not STUCK" \
    || bad "string echo <$tag>" "not STUCK" "STUCK"
done
# ... but a tool result that merely QUOTES such a tag is a real turn and must still count.
fx quoting   < <( { a "70 min ago"; printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"here is the record: <command-name>/model</command-name>"}}\n' "$(iso "60 min ago")"; } )
aged "$TMP/fx-quoting.jsonl" 60
is "a tool result quoting a tag still counts" "$(verdict "$TMP/fx-quoting.jsonl")" STUCK
# The sidechain fixture must END on a sidechain USER record with no later assistant: that is the
# only shape where dropping the isSidechain filter flips the verdict (it would read STUCK).
fx side      < <( { u "70 min ago"; a "69 min ago"; sidea "62 min ago"; side "60 min ago"; } ); aged "$TMP/fx-side.jsonl" 60
[ "$(verdict "$TMP/fx-side.jsonl")" != STUCK ] && ok "sidechain user record as newest is not STUCK" \
  || bad "sidechain user record as newest" "not STUCK" "STUCK"

fx rec       < <( { u "70 min ago"; limit "69 min ago" "$(( $(date +%s) - 3000 ))"; a "60 min ago"; } ); aged "$TMP/fx-rec.jsonl" 60
is "recovered with a limit block" "$(verdict "$TMP/fx-rec.jsonl")" RECOVERED
shuf "$TMP/fx-rec.jsonl" -o "$TMP/fx-shuf.jsonl"; aged "$TMP/fx-shuf.jsonl" 60
is "same file, lines shuffled (order must not matter)" "$(verdict "$TMP/fx-shuf.jsonl")" RECOVERED
fx recnl     < <( { u "70 min ago"; a "60 min ago"; } ); aged "$TMP/fx-recnl.jsonl" 60
is "recovered without a limit block" "$(verdict "$TMP/fx-recnl.jsonl")" RECOVERED

fx inflight  < <( { a "70 min ago"; u "2 min ago"; } ); aged "$TMP/fx-inflight.jsonl" 2
is "turn in progress (fresh mtime) is not stuck" "$(verdict "$TMP/fx-inflight.jsonl")" HEALTHY

fx deadturn  < <( { a "70 min ago"; u "60 min ago"; synth "59 min ago"; } ); aged "$TMP/fx-deadturn.jsonl" 59
is "terminal synthetic error record does not count as an answer" "$(verdict "$TMP/fx-deadturn.jsonl")" STUCK
# each exclusion alone must be enough - together they hide a broken one
fx synthonly < <( { a "70 min ago"; u "60 min ago"; printf '{"type":"assistant","timestamp":"%s","message":{"model":"<synthetic>","content":[]}}\n' "$(iso "59 min ago")"; } )
aged "$TMP/fx-synthonly.jsonl" 59
is "model <synthetic> alone is excluded" "$(verdict "$TMP/fx-synthonly.jsonl")" STUCK
fx erronly   < <( { a "70 min ago"; u "60 min ago"; printf '{"type":"assistant","timestamp":"%s","isApiErrorMessage":true,"message":{"model":"claude-opus-5","content":[]}}\n' "$(iso "59 min ago")"; } )
aged "$TMP/fx-erronly.jsonl" 59
is "isApiErrorMessage alone is excluded" "$(verdict "$TMP/fx-erronly.jsonl")" STUCK

# The tail window is a cost optimisation, not a guarantee: a burned
# retry budget flushes hundreds of records AFTER the prompt. Both directions must survive it.
{ u "60 min ago"; for i in $(seq 1 1200); do printf '{"type":"system","subtype":"api_error","timestamp":"%s","error":{"status":429}}\n' "$(iso "59 min ago")"; done
  synth "58 min ago"; } > "$TMP/fx-window.jsonl"; aged "$TMP/fx-window.jsonl" 58
is "dead turn behind 1200 flushed records is still STUCK" "$(verdict "$TMP/fx-window.jsonl")" STUCK
{ u "60 min ago"; for i in $(seq 1 1200); do nots bridge-session; done
  a "70 min ago"; } > "$TMP/fx-window2.jsonl"; aged "$TMP/fx-window2.jsonl" 58
is "an OLDER assistant flushed last is never a recovery" "$(verdict "$TMP/fx-window2.jsonl")" STUCK

is "classify writes no state at all" "$([ -e "$TMP/never-written" ] && echo yes || echo no)" no

# ----------------------------------------------------------------------- C. transitions -----
echo "C. transitions, liveness and latches against a fake environment"
SID=11111111-2222-3333-4444-555555555555
ENVDIR=$TMP/env
PROCSTART=$(rest=$(cat /proc/$$/stat); rest=${rest#*') '}; printf '%s' "$rest" | awk '{print $20}')

setup() { # fresh fake world; $1 = registry session name (default orchtest)
  rm -rf "$ENVDIR"
  mkdir -p "$ENVDIR"/{reg,state,projects/p,hb}
  printf '{"pid":%d,"sessionId":"%s","kind":"interactive","name":"%s","procStart":"%s","peerProtocol":1,"messagingSocketPath":"/dev/null"}\n' \
    "$$" "$SID" "${1:-orchtest}" "$PROCSTART" > "$ENVDIR/reg/$$.json"
  printf '%s\n' "$SID" > "$ENVDIR/state/orchestrator"
  echo "poke body" > "$ENVDIR/hb/orch-heartbeat-poke.md"
  : > "$ENVDIR/alarms"; : > "$ENVDIR/pokes"
}
transcript() { cat > "$ENVDIR/projects/p/$SID.jsonl"; aged "$ENVDIR/projects/p/$SID.jsonl" "$1"; }
tick() {
  OHB_REG=$ENVDIR/reg OHB_MARKER=$ENVDIR/state/orchestrator OHB_PROJECTS=$ENVDIR/projects \
  OHB_STATE_DIR=$ENVDIR/hbstate OHB_DIR=$ENVDIR/hb OHB_CONFIG=$ENVDIR/mm.json \
  OHB_ALARM_SINK=${ALARM_SINK_OVERRIDE-$ENVDIR/alarms} OHB_POKE_SINK=${POKE_SINK_OVERRIDE-$ENVDIR/pokes} \
  "$SCRIPT" tick >"$ENVDIR/journal" 2>&1
  echo $?
}
alarms() { awk 'END{print NR}' "$ENVDIR/alarms" 2>/dev/null; }
pokes()  { awk 'END{print NR}' "$ENVDIR/pokes"  2>/dev/null; }
epfield() { jq -r --arg k "$2" '(.[$k] // "") | tostring' "$ENVDIR/hbstate/$1.json" 2>/dev/null; }

# C1 healthy idle coordinator
setup; transcript 3 < <( { u "20 min ago"; a "3 min ago"; } )
is "C1 exit 0"                    "$(tick)" 0
is "C1 no alarm"                  "$(alarms)" 0
is "C1 no poke"                   "$(pokes)" 0
is "C1 no episode"                "$([ -e "$ENVDIR/hbstate/$SID.json" ] && echo yes || echo no)" no
is "C1 last-tick written"         "$([ -s "$ENVDIR/hbstate/last-tick" ] && echo yes || echo no)" yes

# C2 stuck below the alarm threshold
setup; transcript 20 < <( { a "21 min ago"; u "20 min ago"; } )
tick >/dev/null
is "C2 episode opened"            "$([ -e "$ENVDIR/hbstate/$SID.json" ] && echo yes || echo no)" yes
is "C2 no alarm yet"              "$(alarms)" 0
is "C2 no poke yet"               "$(pokes)" 0
near "C2 stuck_since is lastUser" "$(epfield "$SID" stuck_since)" "$(( $(date +%s) - 1200 ))"

# C3 stuck past the alarm threshold -> alarm #1 + poke #1
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
tick >/dev/null
is "C3 alarm #1"                  "$(alarms)" 1
is "C3 poke #1"                   "$(pokes)" 1
is "C3 episode alarmed"           "$(epfield "$SID" alarmed)" yes
is "C3 alarm names the session"   "$(grep -c 'coordinator "orchtest" stuck since' "$ENVDIR/alarms")" 1
# C4 next tick, nothing new
tick >/dev/null
is "C4 still one alarm"           "$(alarms)" 1
is "C4 still one poke"            "$(pokes)" 1
# C5 an hour later -> poke #2, still one alarm
jq --arg t "$(( $(date +%s) - 3700 ))" '.last_poke = $t' "$ENVDIR/hbstate/$SID.json" > "$TMP/e" && mv "$TMP/e" "$ENVDIR/hbstate/$SID.json"
tick >/dev/null
is "C5 poke #2 after POKE_EVERY"  "$(pokes)" 2
is "C5 no second alarm"           "$(alarms)" 1

# C6 recovery closes the episode and reports the cause
transcript 0 < <( { a "61 min ago"; u "60 min ago"; limit "59 min ago" "$(( $(date +%s) - 600 ))"; a "1 min ago"; } )
tick >/dev/null
is "C6 recovery alarm"            "$(alarms)" 2
is "C6 episode deleted"           "$([ -e "$ENVDIR/hbstate/$SID.json" ] && echo yes || echo no)" no
is "C6 cause quoted"              "$(grep -c 'usage limit, reset at' "$ENVDIR/alarms")" 1

# C7 HEALTHY (fresh mtime) must NOT be read as recovery
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
tick >/dev/null                                     # opens + alarms the episode
transcript 1 < <( { a "61 min ago"; u "60 min ago"; } )   # same records, fresh mtime
tick >/dev/null
is "C7 episode survives freshness" "$([ -e "$ENVDIR/hbstate/$SID.json" ] && echo yes || echo no)" yes
is "C7 no recovery alarm"          "$(alarms)" 1

# C8 give up after GIVE_UP_H
setup; transcript 1500 < <( { a "1501 min ago"; u "1500 min ago"; } )
tick >/dev/null
is "C8 final alarm"               "$(grep -c 'gives up' "$ENVDIR/alarms")" 1
is "C8 no poke"                   "$(pokes)" 0
is "C8 stopped"                   "$(epfield "$SID" stopped)" yes
tick >/dev/null
is "C8 stays silent afterwards"   "$(alarms)" 1

# C9 housekeeping: a foreign episode is closed, last-tick and the latch file survive
setup; transcript 3 < <( { u "20 min ago"; a "3 min ago"; } )
mkdir -p "$ENVDIR/hbstate"
echo '{"alarmed":"yes","stuck_since":"1"}' > "$ENVDIR/hbstate/99999999-dead-dead-dead-999999999999.json"
echo '{"kept":1}' > "$ENVDIR/hbstate/latches"; echo "old" > "$ENVDIR/hbstate/last-tick"
tick >/dev/null
is "C9 foreign episode removed"   "$(ls "$ENVDIR/hbstate"/*.json 2>/dev/null | wc -l)" 0
is "C9 closing line sent"         "$(grep -c 'closed without a recovery' "$ENVDIR/alarms")" 1
is "C9 latch file survives"       "$([ -e "$ENVDIR/hbstate/latches" ] && echo yes || echo no)" yes
is "C9 last-tick survives"        "$([ -e "$ENVDIR/hbstate/last-tick" ] && echo yes || echo no)" yes

# C10 no marker, but a live session named orch* -> still watched
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
rm -f "$ENVDIR/state/orchestrator"
tick >/dev/null
is "C10 name fallback watches"    "$(pokes)" 1

# C11 no marker and no orch* session -> regime off, open episode closed
setup buildos-xx; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
mkdir -p "$ENVDIR/hbstate"; echo '{"alarmed":"yes"}' > "$ENVDIR/hbstate/$SID.json"
rm -f "$ENVDIR/state/orchestrator"
tick >/dev/null
is "C11 episode closed"           "$(ls "$ENVDIR/hbstate"/*.json 2>/dev/null | wc -l)" 0
is "C11 one closing line"         "$(alarms)" 1
is "C11 no poke"                  "$(pokes)" 0

# C12 marker points at a session that is gone -> dead, latched once per sessionId
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
rm -f "$ENVDIR/reg/$$.json"
tick >/dev/null
is "C12 dead alarm"               "$(grep -c 'is gone, not stuck' "$ENVDIR/alarms")" 1
tick >/dev/null
is "C12 latched (no repeat)"      "$(alarms)" 1
is "C12 no poke"                  "$(pokes)" 0

# C13 PID reuse -> undecidable, hourly latch, exit 0 (never 1: OnFailure must not double-alarm)
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
jq '.procStart = "999999999"' "$ENVDIR/reg/$$.json" > "$TMP/e" && mv "$TMP/e" "$ENVDIR/reg/$$.json"
is "C13 exit 0"                   "$(tick)" 0
is "C13 undecidable alarm"        "$(grep -c 'cannot decide' "$ENVDIR/alarms")" 1
tick >/dev/null
is "C13 throttled to hourly"      "$(alarms)" 1

# C14 no transcript -> latched alarm, no crash
setup
tick >/dev/null
is "C14 missing transcript alarm" "$(grep -c 'found no transcript' "$ENVDIR/alarms")" 1
tick >/dev/null
is "C14 latched"                  "$(alarms)" 1

# C15 the sender fails -> one alarm per episode, never per tick
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
printf 'import sys\nsys.exit(2)\n' > "$ENVDIR/hb/poke-session.py"
POKE_SINK_OVERRIDE="" tick >/dev/null
is "C15 poke failure alarmed"     "$(grep -c 'no live session with id' "$ENVDIR/alarms")" 1
jq --arg t "$(( $(date +%s) - 3700 ))" '.last_poke = $t' "$ENVDIR/hbstate/$SID.json" > "$TMP/e" && mv "$TMP/e" "$ENVDIR/hbstate/$SID.json"
POKE_SINK_OVERRIDE="" tick >/dev/null
is "C15 not alarmed again"        "$(grep -c 'no live session with id' "$ENVDIR/alarms")" 1
is "C15 episode carries the flag" "$(epfield "$SID" poke_error)" yes

# C16 an alarm that cannot be delivered never gates the poke
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
ALARM_SINK_OVERRIDE=/proc/1/no-such-place tick >/dev/null
is "C16 poke sent anyway"         "$(pokes)" 1
is "C16 failure journaled"        "$(grep -c 'alarm sink unwritable' "$ENVDIR/journal")" 1

# C18 a NEW unanswered turn re-baselines a stale episode: otherwise a
# recovery no tick happened to observe swallows the next stall's alarm, and the 24 h cap later
# fires against the wrong clock and disarms the heartbeat for good.
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
tick >/dev/null
is "C18 first stall alarmed"      "$(alarms)" 1
transcript 50 < <( { a "61 min ago"; u "60 min ago"; a "55 min ago"; u "50 min ago"; } )
tick >/dev/null
is "C18 new turn re-alarms"       "$(alarms)" 2
near "C18 stuck_since moved"      "$(epfield "$SID" stuck_since)" "$(( $(date +%s) - 3000 ))"
is "C18 poke counter reset"       "$(epfield "$SID" pokes)" 1

# C19 corrupt state must not invert the latch into an alarm storm
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
mkdir -p "$ENVDIR/hbstate"; echo 'not json at all' > "$ENVDIR/hbstate/latches"
echo 'garbage {' > "$ENVDIR/hbstate/$SID.json"
tick >/dev/null; tick >/dev/null; tick >/dev/null
is "C19 three ticks, one stuck alarm" "$(grep -c 'stuck since' "$ENVDIR/alarms")" 1
# the latch file is only rewritten when a latched branch fires - drive one that does
setup; mkdir -p "$ENVDIR/hbstate"; echo 'not json at all' > "$ENVDIR/hbstate/latches"
tick >/dev/null; tick >/dev/null; tick >/dev/null      # no transcript: a "once" latch
is "C19 corrupt latch still latches" "$(grep -c 'found no transcript' "$ENVDIR/alarms")" 1
is "C19 latch file repaired"      "$(jq -r 'type' "$ENVDIR/hbstate/latches" 2>/dev/null)" object
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
mkdir -p "$ENVDIR/hbstate"; echo 'garbage {' > "$ENVDIR/hbstate/$SID.json"
tick >/dev/null; tick >/dev/null; tick >/dev/null
is "C19 episode repaired"         "$(epfield "$SID" alarmed)" yes
is "C19 no tmp files left"        "$(ls "$ENVDIR/hbstate"/*.tmp 2>/dev/null | wc -l)" 0

# C20 several live orch* sessions and no marker -> refuse to guess, alarm hourly
setup orchtest; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
sed 's/"orchtest"/"orch-two"/; s/"sessionId":"[^"]*"/"sessionId":"22222222-3333-4444-5555-666666666666"/' \
  "$ENVDIR/reg/$$.json" > "$ENVDIR/reg/second.json"
rm -f "$ENVDIR/state/orchestrator"
tick >/dev/null
is "C20 refuses to guess"         "$(grep -c 'cannot tell who coordinates' "$ENVDIR/alarms")" 1
is "C20 no poke"                  "$(pokes)" 0
tick >/dev/null
is "C20 throttled to hourly"      "$(alarms)" 1

# C17 an internal error alarms ONCE and exits 0 - a non-zero exit would make OnFailure= fire a
# second, unthrottled alarm every ten minutes (the double-alarm trap)
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
rm -f "$ENVDIR/hb/orch-heartbeat-poke.md"   # a file the poke path needs
is "C17 exit 0 despite the error" "$(POKE_SINK_OVERRIDE="" tick)" 0
is "C17 one internal-error alarm" "$(grep -c 'internal error' "$ENVDIR/alarms")" 1
is "C17 plus the legitimate one"  "$(alarms)" 2
POKE_SINK_OVERRIDE="" tick >/dev/null
is "C17 error alarm is latched"   "$(grep -c 'internal error' "$ENVDIR/alarms")" 1

# ----------------------------------------------------------------- D. notifyCommand ---------
echo "D. the configured notifyCommand and the unit-failure alarm"
notify_to_file() { jq -n --arg c "printf '%s\\n' \"\$1\" >> $ENVDIR/notified" '{notifyCommand:$c}' > "$ENVDIR/mm.json"; }
# D1 delivered through notifyCommand: the text arrives as $1; the poke is sent regardless
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } ); notify_to_file
is "D1 exit 0"                    "$(ALARM_SINK_OVERRIDE="" tick)" 0
is "D1 delivered via notifyCommand" "$(grep -c 'stuck since' "$ENVDIR/notified")" 1
is "D1 line carries the host tag" "$(grep -c '^\[' "$ENVDIR/notified")" 1
is "D1 poke sent"                 "$(pokes)" 1
# D2 no config file at all: journaled, poke still sent, exit 0
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } ); rm -f "$ENVDIR/mm.json"
is "D2 exit 0"                    "$(ALARM_SINK_OVERRIDE="" tick)" 0
is "D2 missing notifyCommand journaled" "$(grep -c 'no notifyCommand' "$ENVDIR/journal")" 1
is "D2 poke sent anyway"          "$(pokes)" 1
# D3 a failing notifyCommand never gates the poke
setup; transcript 60 < <( { a "61 min ago"; u "60 min ago"; } )
jq -n '{notifyCommand:"exit 7"}' > "$ENVDIR/mm.json"
is "D3 exit 0"                    "$(ALARM_SINK_OVERRIDE="" tick)" 0
is "D3 failure journaled with rc" "$(grep -c 'notifyCommand failed (exit 7)' "$ENVDIR/journal")" 1
is "D3 poke sent anyway"          "$(pokes)" 1
# D4 the unit-failure alarm delivers through the same key and throttles per unit
setup; notify_to_file
UFA_CONFIG=$ENVDIR/mm.json UFA_LATCH_DIR=$ENVDIR/ufa "$UFA" some.service >/dev/null 2>&1; RC=$?
is "D4 exit 0"                    "$RC" 0
is "D4 names the unit"            "$(grep -c 'some.service FAILED' "$ENVDIR/notified")" 1
UFA_CONFIG=$ENVDIR/mm.json UFA_LATCH_DIR=$ENVDIR/ufa "$UFA" some.service >/dev/null 2>&1
is "D4 second failure throttled"  "$(grep -c 'some.service FAILED' "$ENVDIR/notified")" 1
rm -f "$ENVDIR/mm.json"
UFA_CONFIG=$ENVDIR/mm.json UFA_LATCH_DIR=$ENVDIR/ufa2 "$UFA" other.service >/dev/null 2>&1; RC=$?
is "D4 no notifyCommand -> exit 1 (loud in the journal)" "$RC" 1
# D5 the unit templates: the install step's sed fills both placeholders, and the two service
# units carry the config dir — the systemd user manager inherits no shell environment
setup; TPL=$(cd "$HB/.." && pwd)/templates/systemd
for u in orch-heartbeat.timer orch-heartbeat.service unit-failure-alarm@.service; do
  sed "s|__HEARTBEAT_DIR__|/tmp/hb|g; s|__CONFIG_DIR__|/tmp/cfg|g" "$TPL/$u" > "$ENVDIR/$u"
done
is "D5 no placeholder left"                "$(cat "$ENVDIR"/orch-heartbeat.* "$ENVDIR/unit-failure-alarm@.service" | grep -c '__')" 0
is "D5 tick unit carries the config dir"   "$(grep -c '^Environment=CLAUDE_CONFIG_DIR=/tmp/cfg$' "$ENVDIR/orch-heartbeat.service")" 1
is "D5 alarm unit carries the config dir"  "$(grep -c '^Environment=CLAUDE_CONFIG_DIR=/tmp/cfg$' "$ENVDIR/unit-failure-alarm@.service")" 1
is "D5 tick unit runs the copied script"   "$(grep -c '^ExecStart=/tmp/hb/orch-heartbeat.sh$' "$ENVDIR/orch-heartbeat.service")" 1
is "D5 timer starts the tick unit"         "$(grep -c '^Unit=orch-heartbeat.service$' "$ENVDIR/orch-heartbeat.timer")" 1

echo
printf '%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$SKIP" = 0 ] || echo "  NOTE: a skip means a regression transcript is gone - the acceptance test did not run in full"
[ "$FAIL" = 0 ] && [ "$SKIP" = 0 ]
