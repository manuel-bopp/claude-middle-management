#!/usr/bin/env bash
# middle-management plugin — PreToolUse guard, matcher Bash.
# Consumers: hooks/hooks.json.
#
# Blocks blanket git staging so parallel sessions cannot commit each other's
# work: git add -A / --all / -u / . and git commit -a / -am. Sessions stage the
# explicit paths they changed.
#
# Off-switch for solo users: "surgicalStaging": false in the plugin config. An
# unusable config (unparseable, wrong shape, or jq missing) keeps the guard ON
# and switches the deny reason to the config-invalid branch — failing strict
# here only annoys, while the config may well already carry the off-switch.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CHECK="$PLUGIN_ROOT/scripts/config-check.sh"

REASON="middle-management plugin: blanket git staging is blocked so parallel sessions cannot commit each other's work. Stage explicit paths: git add <file> ... — working solo? set surgicalStaging to false via /middle-management-setup."

RC=0; bash "$CHECK" validate || RC=$?
case "$RC" in
  0) jq -e '.surgicalStaging == false' "$(bash "$CHECK" file)" >/dev/null 2>&1 && exit 0 ;;
  1|3) REASON="middle-management plugin: blanket git staging is blocked (your middle-management config is invalid, so protection is forced ON — fix it with /middle-management-setup). Stage explicit paths: git add <file> ..." ;;
esac

INPUT="$(cat)"
if command -v jq >/dev/null 2>&1; then
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)"
else
  # No jq: match the raw payload rather than going dark. Quotes and commas
  # become spaces so the regex still sees command words at a word boundary.
  CMD="$(printf '%s' "$INPUT" | tr '",' '  ')"
fi

if printf '%s' "$CMD" | grep -qE 'git([^|;&]*[[:space:]])?add([[:space:]]+[^|;&]*)?[[:space:]](-A|--all|-u)([[:space:]]|$)|git([^|;&]*[[:space:]])?add[[:space:]]+\.([[:space:]]|$|;)|git([^|;&]*[[:space:]])?commit[[:space:]]+-[a-zA-Z]*a'; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$REASON"
fi
exit 0
