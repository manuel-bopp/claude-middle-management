#!/usr/bin/env bash
# middle-management plugin: OPTIONAL UserPromptSubmit hook, OFF unless the config says
# "intentCheck": true. Consumers: hooks/hooks.json, tests/prompt-hooks.sh.
#
# Intent capture: a user who dictates by voice, or writes in a hurry, undershoots the goal with the
# literal words ("switch writing to the new service" means reading too). On a prompt that reads like
# a work order, this puts the intent question in front of the work. Short prompts and injected
# system turns pass untouched. The work-order verbs are a case-insensitive extended regex: the
# config key "intentCheckVerbs" replaces the default list below (English and German).
set -u
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MIN_CHARS=25
DEFAULT_VERBS='umstell|\bstell|umzieh|\bzieh|umbau|einbau|ausbau|migrier|implementier|baue?[ns]?\b|bau |ändern|änder|wechsel|entfern|lösch|ersetz|refactor|(^|[[:space:]])fix|migrate|implement|switch|move|\bport\b|portier|rewrite|replace|(^|[[:space:]])add |build |wire |hook up|integrier|anbind|abschalt|\bschalt|aktivier'

command -v jq >/dev/null 2>&1 || exit 0
CFG="$(bash "$PLUGIN_ROOT/scripts/config-check.sh" file)"
[ "$(jq -r '.intentCheck // false' "$CFG" 2>/dev/null)" = true ] || exit 0
VERBS="$(jq -r '(.intentCheckVerbs | strings) // ""' "$CFG" 2>/dev/null)"; [ -n "$VERBS" ] || VERBS="$DEFAULT_VERBS"
PROMPT=$(jq -r '.prompt // ""')
# System-injected turns (background task notifications, hook output) are not work orders.
printf '%s' "$PROMPT" | grep -qE 'SYSTEM NOTIFICATION|task-notification|system-reminder' && exit 0
[ "${#PROMPT}" -lt "$MIN_CHARS" ] && exit 0
printf '%s' "$PROMPT" | grep -qiE -- "$VERBS" 2>/dev/null || exit 0

cat <<'REMINDER'
Intent check before you start:
1. State in one sentence what your user wants to ACHIEVE: the goal behind the wording.
2. Name the operations the goal implies that the words left out: read next to write, delete next
   to create, list, live updates, migration of what already exists, the other environment.
3. Wording and goal diverge: ask one question first, then work.
REMINDER
exit 0
