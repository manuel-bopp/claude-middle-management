#!/usr/bin/env bash
# middle-management plugin: Stop hook, a session's report into its T3 coordinator (plan 1.3, D0).
# Consumers: hooks/hooks.json (Stop registration), tests/t3-report.sh. Calls scripts/t3-wake.sh (the
#   one sender), scripts/config-check.sh and, with scopes or scopeMode per-root, scripts/scope.py.
#
# Every session that is not the CURRENT coordinator (a worker, or a former coordinator after a
# takeover) sends the last text of each turn to the coordinator of its scope. Nothing happens unless:
# T3CODE_HOME is set (a T3 Code thread) · the scope has a sidecar <marker dir>/orchestrator.t3.json ·
# this session is not sidecar.sessionId · the text is not empty and not exactly "OK" (the answer to a
# Keepalive) · no sub-agent of this session is still running (the turn after the last one sends) ·
# the text differs from the last one sent (sha256 in <cfg>/state/t3-report/<sessionId>).
# No stop_hook_active skip (review r1 F4): a turn continued after another Stop hook's block carries
# the real answer. A report that is not delivered is never silent: t3-wake.sh logs it to
# failures.log (the watcher notifies), and this hook blocks ONCE per text, never on a continuation,
# telling the session to send it itself. The reportUrl is never read or printed here.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
S="$PLUGIN_ROOT/scripts"
[ -n "${T3CODE_HOME:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || { echo '{"systemMessage":"middle-management: jq is not installed, the T3 report hook cannot deliver this report"}'; exit 0; }

IN=$(cat)
SID=$(jq -r '.session_id // empty' <<<"$IN")
[ -n "$SID" ] || exit 0
CFG_DIR="$(bash "$S/config-check.sh" dir)"
CFG_FILE="$(bash "$S/config-check.sh" file)"

# The scope comes from the directory the session was STARTED in (its registry cwd), like the role
# banner; the hook input's cwd only when the registry has no entry.
START=$(cat "$CFG_DIR"/sessions/*.json 2>/dev/null \
  | jq -r --arg id "$SID" 'select(.sessionId == $id) | .cwd | strings' 2>/dev/null | head -1)
[ -n "$START" ] || START=$(jq -r '.cwd // empty' <<<"$IN")
SDIR="$CFG_DIR/state"
if jq -e '([.scopes | arrays | .[]] | length > 0) or (.scopeMode == "per-root")' "$CFG_FILE" >/dev/null 2>&1; then
  # ponytail: an unresolvable scope (git failed) sends nothing; t3-wake.sh fails closed the same way.
  L=$(python3 "$S/scope.py" of "$START" 2>/dev/null) || exit 0
  IFS=$'\t' read -r _ SDIR _ <<<"$L"
fi
SIDE="$SDIR/orchestrator.t3.json"
[ -f "$SIDE" ] || exit 0
COORD=$(jq -r '.sessionId // empty' "$SIDE" 2>/dev/null)
[ -n "$COORD" ] && [ "$COORD" != "$SID" ] || exit 0

# Interim turn: one of this session's sub-agents is still running (F14).
jq -e '[.background_tasks // [] | .[]? | select(type == "object" and .type == "subagent"
        and ((.status // "running") | test("^(completed|failed|killed|stopped|cancelled|canceled|done|error)$") | not))]
       | length > 0' <<<"$IN" >/dev/null 2>&1 && exit 0

TEXT=$(jq -r '.last_assistant_message // empty | strings' <<<"$IN")
if [ -z "$TEXT" ]; then   # fallback: the text blocks of the last assistant entry in the transcript
  TR=$(jq -r '.transcript_path // empty' <<<"$IN")
  [ -f "$TR" ] && TEXT=$(tail -n 400 "$TR" | jq -rs '[.[] | select(.type == "assistant")
      | [.message.content[]? | select(.type == "text") | .text] | select(length > 0) | join("\n")] | last // empty' 2>/dev/null)
fi
TRIM=$(printf '%s' "$TEXT" | tr -d '[:space:]')
[ -n "$TRIM" ] && [ "$TRIM" != OK ] || exit 0

RDIR="$CFG_DIR/state/t3-report"; mkdir -p "$RDIR" 2>/dev/null
SUM=$(printf '%s' "$TEXT" | sha256sum | cut -d' ' -f1)
[ "$(cat "$RDIR/$SID" 2>/dev/null)" = "$SUM" ] && exit 0

FROM=$(cat "$CFG_DIR"/sessions/*.json 2>/dev/null \
  | jq -r --arg id "$SID" 'select(.sessionId == $id) | .name | strings' 2>/dev/null | head -1)
TMP=$(umask 077; mktemp) || exit 0
printf '%s' "$TEXT" > "$TMP"
MM_SESSION_ID="$SID" MM_SCOPE_CWD="$START" bash "$S/t3-wake.sh" "${FROM:-session ${SID:0:8}}" "$TMP" >/dev/null 2>&1; RC=$?
rm -f "$TMP"
case "$RC" in
  0) printf '%s\n' "$SUM" > "$RDIR/$SID"; exit 0 ;;
  3) exit 0 ;;    # the sidecar went away meanwhile (release): no coordinator to report to
esac
# Not delivered. Block once per text, never on a continuation (no loop).
[ "$(jq -r '.stop_hook_active // false' <<<"$IN")" = true ] && exit 0
[ "$(cat "$RDIR/$SID.blocked" 2>/dev/null)" = "$SUM" ] && exit 0
printf '%s\n' "$SUM" > "$RDIR/$SID.blocked"
jq -cn --arg t "$(jq -r '.threadId // "?"' "$SIDE" 2>/dev/null)" \
  '{decision: "block", reason: "report NOT delivered to the coordinator: send it yourself with t3_thread_send \($t)"}'
exit 0
