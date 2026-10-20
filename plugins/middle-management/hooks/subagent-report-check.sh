#!/usr/bin/env bash
# middle-management plugin: SubagentStop hook, ON unless the config says "workPackagesGate": false.
# Consumers: hooks/hooks.json, tests/work-packages.sh.
#
# If the sub-agent's prompt named a `Report file:` that is missing or did not change during this
# run, stop the sub-agent ONCE and tell it to write the report now, or to say in the first line of
# its final answer that it has none. No SubagentStop output reaches the parent (CLI 2.1.300: exit 2,
# decision:block and additionalContext all go to the sub-agent), so the sub-agent's own answer is
# the only way the parent hears it. The prompt is not in the hook input: it is the first line of the
# agent transcript; "this run" starts at its last non-injected user entry (a resume).
# Fails open: no jq, no transcript, no Report file line, `none`, or stop_hook_active -> silent.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
command -v jq >/dev/null 2>&1 || exit 0
CFG="$(bash "$PLUGIN_ROOT/scripts/config-check.sh" file)"
[ "$(jq -r '.workPackagesGate' "$CFG" 2>/dev/null)" = false ] && exit 0

INPUT=$(cat)
j() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }
[ "$(j '.stop_hook_active // false')" = true ] && exit 0
AID=$(j '.agent_id // ""')
TR=$(j '.agent_transcript_path // ""')
if [ -z "$TR" ]; then   # empty in one CLI mode: the layout on disk is <session dir>/subagents/agent-<id>.jsonl
  P=$(j '.transcript_path // ""'); S=$(j '.session_id // ""')
  [ -n "$P" ] && [ -n "$S" ] && [ -n "$AID" ] && TR="$(dirname "$P")/$S/subagents/agent-$AID.jsonl"
fi
[ -n "$TR" ] && [ -f "$TR" ] || exit 0

# the prompts of this agent: user entries that are not injected (isMeta: skills, notifications, peer
# messages) and carry no tool_result part
USER=$(jq -cR 'fromjson? | select(.type == "user" and (.isMeta // false) != true) | .message.content as $c
  | select(([$c[]? | objects | select(.type == "tool_result")] | length) == 0)
  | (if ($c | type) == "string" then $c else ([$c[]? | select(.type == "text") | .text] | join("\n")) end) as $t
  | select($t != "") | {t: $t, ts: (.timestamp // "")}' "$TR" 2>/dev/null)
VAL=$(printf '%s\n' "$USER" | head -1 | jq -r '.t' 2>/dev/null \
  | sed -n 's/^[[:space:]>*`-]*Report file:[*`[:space:]]*//p' | head -1 | sed 's/[*`[:space:]]*$//')
case "$VAL" in /*) ;; *) exit 0 ;; esac   # no line, `none`, or not a path: nothing to check

START=$(printf '%s\n' "$USER" | tail -1 | jq -r '.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null)
if [ ! -f "$VAL" ]; then WHAT="does not exist"
elif [ -n "$START" ] && [ "$(stat -c %Y "$VAL")" -lt "${START%.*}" ]; then WHAT="did not change during this run"
else exit 0; fi

jq -n --arg f "$VAL" --arg w "$WHAT" --arg id "$AID" '{decision:"block",reason:("Work-packages check: your report file " + $f + " " + $w + ". Write it now: `## Packages` with your package list, then `## Package N: done · <result, paths>` for every package you finished, then end with your final answer (at most 10 lines plus the path). If you cannot write it, make the first line of your final answer exactly: sub-agent ended without its report: resume it with SendMessage to its id " + $id + ", do not start a new one.")}'
exit 0
