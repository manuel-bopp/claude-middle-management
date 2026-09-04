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
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CHECK="$PLUGIN_ROOT/scripts/config-check.sh"

command -v jq >/dev/null 2>&1 || {
  echo "middle-management: jq not installed — plugin inactive (install jq)"; exit 0; }

CFG_DIR="$(bash "$CHECK" dir)"
CFG_FILE="$(bash "$CHECK" file)"
REG="$CFG_DIR/sessions"
MARKER="$CFG_DIR/state/orchestrator"
OVERRIDE="$CFG_DIR/state/allow-main-checkout-edits"

[ -d "$REG" ] || {
  echo "middle-management: session registry not found — role detection inactive (requires a recent Claude Code)"
  exit 0; }

# --- preconditions: warn loudly, then carry on with the role logic ---------------
bash "$CHECK" validate; CFG_STATE=$?
BOARD=""
if [ "$CFG_STATE" -eq 1 ]; then
  printf 'middle-management: %s is invalid — worktree guard and wt are DISARMED and blanket-staging protection is forced ON until fixed (run /middle-management-setup)\n' "$CFG_FILE"
elif [ "$CFG_STATE" -eq 0 ]; then
  BOARD=$(jq -r '.board // ""' "$CFG_FILE" 2>/dev/null)
  jq -r '.protectedCheckouts[]? | [.name, .root] | @tsv' "$CFG_FILE" 2>/dev/null \
    | while IFS=$'\t' read -r pc_name pc_root; do
        [ -d "$pc_root" ] || printf 'middle-management: protected checkout "%s" points at %s, which is not a directory — that entry is inert (run /middle-management-setup)\n' "$pc_name" "$pc_root"
      done
fi
[ -f "$OVERRIDE" ] && printf 'middle-management: override marker active — main-checkout guard is OFF; delete %s when the exception is done\n' "$OVERRIDE"

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

ORCH=""; ORCH_SRC=""; STALE=""
if [ -f "$MARKER" ]; then
  MID=$(head -1 "$MARKER" | tr -d '[:space:]')
  if [ -n "$MID" ]; then
    MNAME=$(name_of "$MID")
    if [ -n "$MNAME" ]; then ORCH="$MNAME"; ORCH_SRC="marker"; else STALE=1; fi
  fi
fi

NAMED=$(printf '%s\n' "$LIVE" | cut -f1 | grep -i '^orch' | sort -u)
NAMED_COUNT=$(printf '%s' "$NAMED" | grep -c .)

if [ -z "$ORCH" ]; then
  if [ "$NAMED_COUNT" -eq 0 ]; then
    [ -n "$STALE" ] && printf 'middle-management: a previous coordinator session ended; the role regime is off until someone claims. Only if your user wants THIS session to coordinate, run: bash %s/scripts/orchestrator.sh claim — otherwise ignore this.\n' "$PLUGIN_ROOT"
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
    "$ORCH" "$(printf '%s' "$NAMED" | tr '\n' ' ')"
  printf 'The marker wins. Tell your user that two coordinators are in the race.\n'
fi

MY_NAME=$(name_of "$MY_ID")

if [ "$MY_NAME" = "$ORCH" ]; then
  printf 'Session role: ORCHESTRATOR ("%s", by %s). You plan with your user and route the work —\n' \
    "$MY_NAME" "$([ "$ORCH_SRC" = marker ] && echo marker || echo name)"
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
  [ -n "$BOARD" ] && printf 'You are the sole writer of the board %s; workers read it and report to you.\n' "$BOARD"
  printf 'Current workers: %s\n' "$(printf '%s\n' "$LIVE" | cut -f1 | grep -vxF "$ORCH" | tr '\n' ' ')"
else
  printf 'Session role: WORKER ("%s"). The coordinator is "%s".\n' "${MY_NAME:-unnamed}" "$ORCH"
  printf 'Peer messages go ONLY to "%s" — never to other workers; anything another session needs\n' "$ORCH"
  printf 'goes through the coordinator. When you finish or block, report there yourself.\n'
  [ -n "$BOARD" ] && printf 'The board %s is read-only for you — the coordinator is its only writer.\n' "$BOARD"
fi
exit 0
