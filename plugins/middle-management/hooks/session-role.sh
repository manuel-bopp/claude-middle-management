#!/usr/bin/env bash
# middle-management plugin — UserPromptSubmit hook.
# Consumers: hooks/hooks.json (UserPromptSubmit registration). Reads the coordinator
# marker written by scripts/orchestrator.sh; resolves every path through
# scripts/config-check.sh.
#
# Exactly ONE session coordinates, every other session is a worker. Two sources for
# "who coordinates", in this order:
#   1. The marker file <config dir>/state/orchestrator (a sessionId), written by
#      scripts/orchestrator.sh claim. The route for editor sessions, whose tab title
#      never reaches the session registry.
#   2. Fallback: a living session whose peer name starts with "orch"
#      (started as `claude -n orchestrator`). The route for terminal sessions.
# If neither finds a living coordinator, this hook stays SILENT — the regime is off and
# every session works standalone. The role messages below ARE the behavioral contract;
# the skill "middle-management" is the extended reference.
# Alive = a registry entry with kind "interactive" whose pid answers kill -0. On the marker
# route the sessionId is the identity and .name is display only; scripts/orchestrator.sh
# follows the same rule (liveness rule F1).
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CHECK="$PLUGIN_ROOT/scripts/config-check.sh"

CFG_DIR="$(bash "$CHECK" dir)"
CFG_FILE="$(bash "$CHECK" file)"
REG="$CFG_DIR/sessions"
MARKER="$CFG_DIR/state/orchestrator"
OVERRIDE="$CFG_DIR/state/allow-main-checkout-edits"

# The override nag comes first and needs no jq: a forgotten marker silently disarms the
# checkout guard for every session on this machine. -e, not -f — the guard
# (hooks/protect-main-checkouts.sh) tests -e, so a marker created as a directory disarms it too.
[ -e "$OVERRIDE" ] && printf 'middle-management: override marker active — main-checkout guard is OFF; delete %s when the exception is done\n' "$OVERRIDE"

command -v jq >/dev/null 2>&1 || {
  echo "middle-management: jq not installed — plugin inactive (install jq)"; exit 0; }

[ -d "$REG" ] || {
  echo "middle-management: session registry not found — role detection inactive (requires a recent Claude Code)"
  exit 0; }

# --- preconditions: warn loudly, then carry on with the role logic ---------------
bash "$CHECK" validate; CFG_STATE=$?
# Initialised BEFORE the branches: a roles-only install has no config file (CFG_STATE 2) and
# this hook runs under `set -u` — an unset variable below would abort every message.
BOARD=""
NOTIFY=""
if [ "$CFG_STATE" -eq 1 ]; then
  printf 'middle-management: %s is invalid — worktree guard and wt are DISARMED and blanket-staging protection is forced ON until fixed (run /middle-management-setup)\n' "$CFG_FILE"
elif [ "$CFG_STATE" -eq 0 ]; then
  BOARD=$(jq -r '.board // ""' "$CFG_FILE" 2>/dev/null)
  NOTIFY=$(jq -r '.notifyCommand // ""' "$CFG_FILE" 2>/dev/null)
  jq -r '.protectedCheckouts[]? | [.name, .root] | @tsv' "$CFG_FILE" 2>/dev/null \
    | while IFS=$'\t' read -r pc_name pc_root; do
        [ -d "$pc_root" ] || printf 'middle-management: protected checkout "%s" points at %s, which is not a directory — that entry is inert (run /middle-management-setup)\n' "$pc_name" "$pc_root"
      done
fi
# --- role detection ---------------------------------------------------------------
MY_ID=$(jq -r '.session_id // ""')

# name<TAB>sessionId of every living interactive session. The (possibly empty) name comes LAST
# in the jq array: `read` with a tab IFS collapses empty fields, so a nameless session would
# otherwise get its sessionId in the name column and no id at all (found 04.09.2026, case F1).
LIVE=$(cat "$REG"/*.json 2>/dev/null \
  | jq -r 'select(.pid and .sessionId and .kind == "interactive") | [.pid, .sessionId, .name // ""] | @tsv' 2>/dev/null \
  | while IFS=$'\t' read -r pid sid name; do
      kill -0 "$pid" 2>/dev/null && printf '%s\t%s\n' "$name" "$sid"
    done)
[ -z "$LIVE" ] && exit 0

name_of() { printf '%s\n' "$LIVE" | awk -F'\t' -v id="$1" '$2==id{print $1; exit}'; }

ORCH=""; ORCH_ID=""; ORCH_SRC=""; STALE=""
if [ -f "$MARKER" ]; then
  MID=$(head -1 "$MARKER" | tr -d '[:space:]')
  if [ -n "$MID" ]; then
    # alive = the id is in LIVE (not: it has a name) — a nameless coordinator is still one
    if printf '%s\n' "$LIVE" | cut -f2 | grep -qxF "$MID"; then
      ORCH_ID="$MID"; ORCH="$(name_of "$MID")"; ORCH_SRC="marker"
    else STALE=1; fi
  fi
fi

NAMED=$(printf '%s\n' "$LIVE" | cut -f1 | grep -i '^orch' | sort -u)
NAMED_COUNT=$(printf '%s' "$NAMED" | grep -c .)

if [ -z "$ORCH_SRC" ]; then
  if [ "$NAMED_COUNT" -eq 0 ]; then
    # Both exits, with a human gate: this hint fires in EVERY living session.
    [ -n "$STALE" ] && printf 'middle-management: the coordinator marker points at a session that is not visibly alive (%s) — until someone acts there is no coordinator. Workers keep working their lane, hold every outward coordination the regime routes through the coordinator (posts, tickets, pull requests, asks to the user), close their books when done or blocked, and report to whoever claims next. ONLY if your user wants THIS session to coordinate:\n  take over:   bash %s/scripts/orchestrator.sh claim\n  regime OFF:  bash %s/scripts/orchestrator.sh release %s   (the id is also printed by status)\nOtherwise ignore this.\n' "$MID" "$PLUGIN_ROOT" "$PLUGIN_ROOT" "$MID"
    exit 0
  fi
  if [ "$NAMED_COUNT" -gt 1 ]; then
    printf 'SESSION ROLES BROKEN: %s sessions are named "orch*" (%s) and there is no coordinator marker.\n' \
      "$NAMED_COUNT" "$(printf '%s' "$NAMED" | tr '\n' ' ')"
    printf 'Tell your user before you send anything to another session.\n'; exit 0
  fi
  ORCH="$NAMED"; ORCH_SRC="name"
elif [ "$NAMED_COUNT" -ge 1 ] && ! printf '%s\n' "$NAMED" | grep -qxF "$ORCH"; then
  printf 'WARNING: the marker says the coordinator is "%s", but "%s" is also running under an orch* name.\n' \
    "${ORCH:-unnamed}" "$(printf '%s' "$NAMED" | tr '\n' ' ')"
  printf 'The marker wins. Tell your user that two coordinators are in the race.\n'
fi

MY_NAME=$(name_of "$MY_ID")

# Marker route: identity by sessionId. Name route: by name, but never an empty one.
if { [ "$ORCH_SRC" = marker ] && [ "$MY_ID" = "$ORCH_ID" ]; } \
   || { [ "$ORCH_SRC" = name ] && [ -n "$MY_NAME" ] && [ "$MY_NAME" = "$ORCH" ]; }; then
  printf 'Session role: ORCHESTRATOR ("%s", by %s). You plan with your user and route the work —\n' \
    "${MY_NAME:-unnamed}" "$([ "$ORCH_SRC" = marker ] && echo marker || echo name)"
  printf 'you do NOT build yourself. Directly allowed: planning/decision docs, chat/GitHub coordination,\n'
  printf 'tasking workers and sub-agents. NOT yourself: product/repo code, repo git surgery, builds/tests —\n'
  printf 'delegate those. Small clear jobs (one-file fix, research, mechanical sweep) go to a sub-agent in\n'
  printf 'THIS session; larger packages go to interactive worker sessions your user starts. Fallback: a\n'
  printf 'package that is clear AND uncritical and only waits for the user to start a session — do not\n'
  printf 'wait for hours; run it via sub-agent with the recommended option and record the decision.\n'
  printf 'You are the only session that connects workers — what worker A finds and worker B needs\n'
  printf 'flows through you — and you track who works on what.\n'
  printf 'Resource hygiene is YOUR job: orphaned dev servers, worktrees of merged branches and stale\n'
  printf 'watchers go as soon as their reason is gone (sub-agent, by verified PID lineage, never by\n'
  printf 'pattern) — not when memory runs out. Morning ritual, step 5.\n'
  printf 'One lane = one session: a new lane gets a FRESH session — ask your user to open one and name\n'
  printf 'the model; never stack a second lane into a running session (exception: after ~30 minutes of\n'
  printf 'silence from your user, and only for safe, reversible work). A wrapped session is closed for\n'
  printf 'good. After every wrap, tell your user unprompted which tabs to close AND send each of those\n'
  printf 'sessions its own peer message, so it answers in its own tab with "close this tab" — your user\n'
  printf 'cannot map peer names to editor tabs. Never send that message to a session you cannot identify.\n'
  printf 'Every waiting item you put in front of your user carries its link or command line in the SAME\n'
  printf 'line, at every repetition — a reminder they have to scroll for is worthless.\n'
  printf 'After a re-wake or a resume: work the RE-WAKE checklist (top of the board, or the last checklist\n'
  printf 'in your own transcript) before any new task.\n'
  printf 'Sub-agents write long results to a FILE and return you at most ten lines; the file path goes\n'
  printf 'where you track lanes. Your context is for decisions and routing, not raw material — put that\n'
  printf 'instruction in every sub-agent prompt you write.\n'
  printf 'Every sub-agent you announce to your user names its model and whether the strongest model was\n'
  printf 'needed or a cheaper one suffices; briefs name model and effort per role. Cheapest plausible\n'
  printf 'model first, escalate after two failed attempts, never a third try on the same one.\n'
  [ -n "$NOTIFY" ] && printf 'Your off-keyboard channel to your user is configured (notifyCommand): use it for what must reach\nthem away from the desk — plain text, one topic, the fact first. The skill has the call.\n'
  [ -n "$BOARD" ] && printf 'You are the sole writer of the board %s; workers read it and report to you.\n' "$BOARD"
  printf 'Current workers: %s\n' "$(printf '%s\n' "$LIVE" | cut -f1 | grep -vxF "$ORCH" | tr '\n' ' ')"
else
  printf 'Session role: WORKER ("%s"). The coordinator is "%s".\n' "${MY_NAME:-unnamed}" "${ORCH:-unnamed}"
  printf 'Peer messages go ONLY to "%s" — never to other workers; anything another session needs\n' "${ORCH:-unnamed}"
  printf 'goes through the coordinator. When you finish or block, report there yourself.\n'
  printf 'You are the SUB-ORCHESTRATOR of your lane: plan review, build, diff review, screenshots and\n'
  printf 'report writing run in sub-agents with fresh context, each prompt naming its model and effort.\n'
  printf 'Every sub-agent writes long output to a FILE and returns you at most ten lines — up to twenty\n'
  printf 'when it carries a decision you must make. You read those reports, not whole files or diffs.\n'
  printf 'End every report to the coordinator with your rough context fill (1/4, 1/2, 3/4): a session\n'
  printf 'that reads everything itself is full within the hour and dies with its lane.\n'
  [ -n "$BOARD" ] && printf 'The board %s is read-only for you — the coordinator is its only writer.\n' "$BOARD"
fi
exit 0
