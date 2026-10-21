#!/usr/bin/env bash
# middle-management plugin: OPTIONAL UserPromptSubmit hook, OFF unless the config says
# "replyTimestamp": true. Consumers: hooks/hooks.json, tests/prompt-hooks.sh.
#
# A user with many parallel sessions needs to see on every reply when it was written and how long
# something has been lying around. This hands the session the finished prefix to copy, so nothing is
# computed or estimated: a model that adds minutes to a remembered time is wrong by the hour. The
# date comes along for the wrap recap (middle-management:wrap), which starts with the full stamp.
# Runs on every user message, no filter. Prints nothing when the key is off or jq is missing.
set -u
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
command -v jq >/dev/null 2>&1 || exit 0
[ "$(jq -r '.replyTimestamp // false' "$(bash "$PLUGIN_ROOT/scripts/config-check.sh" file)" 2>/dev/null)" = true ] || exit 0
cat >/dev/null   # the hook input is not needed
printf 'Your reply starts literally with: [%s]  (copy it, never compute or estimate it; local time of this message: %s; a wrap recap starts with [%s])\n' \
  "$(date '+%H:%M')" "$(date '+%d.%m.%Y %H:%M %Z')" "$(date '+%d.%m.%Y %H:%M')"
exit 0
