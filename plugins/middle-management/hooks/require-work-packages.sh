#!/usr/bin/env bash
# middle-management plugin: PreToolUse hook (matcher Agent), ON unless the config says
# "workPackagesGate": false. Consumers: hooks/hooks.json, tests/work-packages.sh.
#
# Every sub-agent prompt must carry a `Report file: <absolute path>` line (the work-packages
# scheme), so a sub-agent that dies on a limit or a server error leaves its work on disk.
# Allowed without a path: `Report file: none` (quick read-only lookups) and subagent_type Explore.
# The deny reason carries the template block, read from skills/work-packages/SKILL.md (one source).
# Fails open: no jq -> one warning line, the call goes through.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"systemMessage":"middle-management: jq not installed, the work-packages gate is off"}'
  exit 0
fi
CFG="$(bash "$PLUGIN_ROOT/scripts/config-check.sh" file)"
[ "$(jq -r '.workPackagesGate' "$CFG" 2>/dev/null)" = false ] && exit 0

INPUT=$(cat)
[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" = Agent ] || exit 0
[ "$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)" = Explore ] && exit 0
# the value of the first `Report file:` line, trimmed; empty = no line
VAL=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null \
  | sed -n 's/^[[:space:]>*`-]*Report file:[*`[:space:]]*//p' | head -1 | sed 's/[*`[:space:]]*$//')
case "$VAL" in
  [Nn][Oo][Nn][Ee]|[Nn][Oo][Nn][Ee][[:space:]]*|/*) exit 0 ;;
  "") WHY="This Agent prompt has no \`Report file:\` line." ;;
  *)  WHY="The \`Report file:\` line must name an absolute path (or \`none\`), got: $VAL" ;;
esac

BLOCK=$(awk '/^```/{n++; next} n==1' "$PLUGIN_ROOT/skills/work-packages/SKILL.md" 2>/dev/null)
[ -n "$BLOCK" ] || BLOCK="Report file: <absolute path>  (see skill middle-management:work-packages)"
jq -n --arg why "$WHY" --arg block "$BLOCK" '{hookSpecificOutput:{hookEventName:"PreToolUse",
  permissionDecision:"deny",permissionDecisionReason:($why + " Work-packages gate: a sub-agent that dies on a limit or a server error must leave its work on disk. Add this block to the prompt (absolute path the agent can write) and call Agent again. Quick read-only lookups under 5 minutes: `Report file: none`. Skill: middle-management:work-packages.\n\n" + $block)}}'
exit 0
