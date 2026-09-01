#!/usr/bin/env bash
# team-sessions plugin — PreToolUse guard, matcher Edit|Write|MultiEdit|NotebookEdit.
# Consumers: hooks/hooks.json.
#
# Keeps the configured main checkouts clean: implementation happens in a
# per-topic worktree (scripts/wt), so parallel sessions cannot mix changes in
# one shared checkout and the checkout stays usable as reference and for its own
# dev server. Edits under an entry's worktree directory always pass — including
# a worktree directory that lies inside the root.
#
# Silent and inactive while <config dir>/state/allow-main-checkout-edits exists
# (the deliberate exception marker), and on any unusable config: a guard that
# half-arms on a broken config can lock a session out of both the checkout and
# wt at once. hooks/session-role.sh announces both states on every message.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CHECK="$PLUGIN_ROOT/scripts/config-check.sh"

CFG_DIR="$(bash "$CHECK" dir)"
[ -e "$CFG_DIR/state/allow-main-checkout-edits" ] && exit 0
bash "$CHECK" validate || exit 0

FILE="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)"
[ -n "$FILE" ] || exit 0

ENTRIES="$(jq -r '(.protectedCheckouts // [])[] | [.name, .root, (.worktreeDir // "")] | @tsv' "$(bash "$CHECK" file)" 2>/dev/null)"
[ -n "$ENTRIES" ] || exit 0

# Pass 1: a worktree directory wins, even when it sits inside a protected root.
while IFS=$'\t' read -r NAME ROOT WTDIR; do
  [ -n "$ROOT" ] || continue
  [ -n "$WTDIR" ] || WTDIR="$(dirname "${ROOT%/}")/.worktrees-$NAME"
  case "$FILE" in "${WTDIR%/}"/*) exit 0 ;; esac
done <<< "$ENTRIES"

# Pass 2: deny inside a protected root.
while IFS=$'\t' read -r NAME ROOT WTDIR; do
  ROOT="${ROOT%/}"
  [ -n "$ROOT" ] || continue
  case "$FILE" in "$ROOT"/*)
    REASON="Direct edits in the protected checkout '$NAME' ($ROOT) are blocked: implementation happens in a per-topic worktree, so parallel sessions cannot mix changes in the shared checkout. Create one and edit there: bash \"$PLUGIN_ROOT/scripts/wt\" $NAME new <topic> — it prints the worktree path, branches off the configured base and installs dependencies. If this session cannot edit outside its working directory, add the worktree with /add-dir or start a session there. ONLY if your user explicitly allowed a direct edit in this session: mkdir -p \"$CFG_DIR/state\" && touch \"$CFG_DIR/state/allow-main-checkout-edits\", redo the edit, then delete the marker."
    jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
    ;;
  esac
done <<< "$ENTRIES"

exit 0
