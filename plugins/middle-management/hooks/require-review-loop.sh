#!/usr/bin/env bash
# middle-management plugin: OPTIONAL PreToolUse hook (matcher ExitPlanMode|Write), OFF unless the
# config says "reviewLoopGate": true. Consumers: hooks/hooks.json, tests/run.sh.
#
# A plan or a handoff doc reaches your user only after the review-loop skill ran in this session:
# ExitPlanMode with a plan of 900+ characters, or a Write to a file named <YYYY-MM-DD>_handoff-*.md
# in any directory (the name both wraps give a handoff), is denied until the skill's marker
# <config dir>/state/review-loop/<sessionId>.json exists and is under an hour old.
# Known limit: this gates the Write TOOL. A handoff written through a shell heredoc bypasses it;
# the gate raises the cost of skipping the review, it does not make skipping impossible.
# Ported from a gate that held plans back after one moved a system's writes and forgot its reads.
set -u
MAX_AGE=3600          # a marker counts as fresh for one hour
MINI_PLAN_CHARS=900   # below this a plan is a two-liner, not a concept

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CHECK="$PLUGIN_ROOT/scripts/config-check.sh"
command -v jq >/dev/null 2>&1 || exit 0
bash "$CHECK" validate || exit 0              # invalid or absent config: stay out of the way
[ "$(jq -r '.reviewLoopGate // false' "$(bash "$CHECK" file)" 2>/dev/null)" = true ] || exit 0

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // ""')
case "$TOOL" in
  ExitPlanMode)
    [ "$(printf '%s' "$INPUT" | jq -r '.tool_input.plan // "" | length')" -lt "$MINI_PLAN_CHARS" ] && exit 0 ;;
  Write)
    FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
    printf '%s' "${FILE##*/}" | grep -qiE '^[0-9]{4}-[0-9]{2}-[0-9]{2}_handoff-.*\.md$' || exit 0 ;;
  *) exit 0 ;;
esac

MARKER="$(bash "$CHECK" dir)/state/review-loop/${SESSION}.json"
if [ -n "$SESSION" ] && [ -f "$MARKER" ]; then
  [ $(( $(date +%s) - $(stat -c %Y "$MARKER") )) -lt "$MAX_AGE" ] && exit 0
fi

jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:
  "Review gate (reviewLoopGate): this plan or handoff has not been through the review-loop skill in this session within the last hour. Draft it somewhere else (your scratch dir), run the review-loop skill on the draft (a fresh-context reviewer, findings verified, fixed, re-reviewed, at most 4 rounds), and the skill writes the marker that opens this gate. Skill: middle-management:review-loop."}}'
exit 0
