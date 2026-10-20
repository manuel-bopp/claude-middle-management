#!/usr/bin/env bash
# middle-management plugin: the one sender into the current coordinator's T3 thread (plan 1.1, 1.3, 1.8).
# Consumers: hooks/t3-report.sh (a worker's turn end), scripts/t3-watch.py (the Keepalive retry and
#   the named action reports), pathfinder's serve.py submit push (outside the plugin),
#   tests/t3-watch.sh. Nothing else may POST to the coordinator's webhook.
#
# Usage: t3-wake.sh <from> <file-with-text>
#        t3-wake.sh <from> --keepalive        the report is exactly "Keepalive" (rule 1.4b)
# Env:   MM_SCOPE      the scope (name) whose coordinator is woken; wins over MM_SCOPE_CWD
#        MM_SCOPE_CWD  the directory whose scope's coordinator is woken (default: the cwd)
#        MM_SESSION_ID the caller's Claude session id (default: CLAUDE_CODE_SESSION_ID; set it to ""
#                      for a caller that is no session, like the watcher)
#
# Reads the scope's sidecar <marker dir>/orchestrator.t3.json (written 0600 by orchestrator.sh
# t3-bind), POSTs {from, session, thread, report, prompt} to its reportUrl and counts as delivered ONLY on
# HTTP 202. thread = the caller's own T3 thread, looked up in T3's provider logs by its session id
# (exactly one log names it, else "unknown").
# Exit: 0 delivered (202) · 3 no sidecar for this scope (or the scope is unknown) · 4 not delivered
#   (non-202, timeout, unusable sidecar): one line in <cfg>/state/t3-report/failures.log, which
#   t3-watch.py turns into a notify · 64 usage.
# The reportUrl is a capability into a full-access thread: it never reaches argv, stdout, stderr
# or a log line. curl reads it from stdin (-K -), and curl's own error text is dropped.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
FROM=${1:-}; ARG=${2:-}
[ -n "$FROM" ] && [ -n "$ARG" ] || { echo "usage: t3-wake.sh <from> <file-with-text>|--keepalive" >&2; exit 64; }
command -v jq >/dev/null 2>&1 || { echo "t3-wake: jq is not installed" >&2; exit 4; }

CFG_DIR="$(bash "$DIR/config-check.sh" dir)"
CFG_FILE="$(bash "$DIR/config-check.sh" file)"
RDIR="$CFG_DIR/state/t3-report"
SID=${MM_SESSION_ID-${CLAUDE_CODE_SESSION_ID:-}}

# The thread of the CALLER (F2): T3 names a thread's provider log events.<threadId, ':' as '-'>.log.
# The quoted key, not the bare id: a coordinator's id shows up in many foreign logs.
THREAD=unknown
if [ -n "$SID" ]; then
  M=$(grep -lF "\"session_id\":\"$SID\"" "${T3CODE_HOME:-$HOME/.t3}"/userdata/logs/provider/events.*.log 2>/dev/null)
  if [ -n "$M" ] && [ "$(printf '%s\n' "$M" | wc -l)" -eq 1 ]; then
    THREAD=${M##*/events.}; THREAD=${THREAD%.log}
    case $THREAD in mcp-*) THREAD=mcp:${THREAD#mcp-} ;; esac   # file name has ':' as '-'; t3_thread_send needs mcp:<uuid>
  fi
fi

fail() {  # $1 = reason (never the URL)
  mkdir -p "$RDIR" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$FROM" "${SID:--}" "$THREAD" "$1" >> "$RDIR/failures.log" 2>/dev/null
  echo "t3-wake: report NOT delivered ($1)" >&2
  exit 4
}

# The marker dir, resolved exactly as orchestrator.sh and session-role.sh resolve the marker.
SDIR="$CFG_DIR/state"
if jq -e '([.scopes | arrays | .[]] | length > 0) or (.scopeMode == "per-root")' "$CFG_FILE" >/dev/null 2>&1; then
  if [ -n "${MM_SCOPE:-}" ]; then   # by name (the watcher): "default" or a line of `scope.py list`
    S=""; [ "$MM_SCOPE" = default ] && S="default	$SDIR	"
    [ -n "$S" ] || S=$(python3 "$DIR/scope.py" list 2>/dev/null | awk -F '\t' -v n="$MM_SCOPE" '$1 == n' | head -1)
  else
    S=$(python3 "$DIR/scope.py" of "${MM_SCOPE_CWD:-$PWD}" 2>/dev/null) || S=""
  fi
  [ -n "$S" ] || { echo "t3-wake: the scope (${MM_SCOPE:-of ${MM_SCOPE_CWD:-$PWD}}) cannot be resolved (scope.py), nothing sent" >&2; exit 3; }
  IFS=$'\t' read -r _ SDIR _ <<<"$S"
fi
SIDE="$SDIR/orchestrator.t3.json"
[ -f "$SIDE" ] || { echo "t3-wake: no T3 coordinator in this scope (no $SIDE)" >&2; exit 3; }

# Trust boundary: a sidecar others can read has leaked the capability, one others can write could
# redirect every report. Either way it is not used.
case "$(stat -c %a "$SIDE" 2>/dev/null)" in 600|400) ;; *) fail "sidecar mode is not 0600" ;; esac
URL=$(jq -r '.reportUrl | strings' "$SIDE" 2>/dev/null)
# Only a plain http(s) URL: it goes into a curl config line, so a quote or a space must never get in.
printf '%s' "$URL" | grep -Eq '^https?://[^"\\[:space:]]+$' || fail "sidecar has no usable reportUrl"

# The text is read by jq itself (--rawfile): a long report never passes through argv.
if [ "$ARG" = --keepalive ]; then
  SRC=(--arg r Keepalive --argjson ka true)
else
  [ -r "$ARG" ] || { echo "t3-wake: cannot read $ARG" >&2; exit 64; }
  SRC=(--rawfile r "$ARG" --argjson ka false)
fi
BODY=$(jq -cn --arg from "$FROM" --arg session "$SID" --arg thread "$THREAD" "${SRC[@]}" \
  '{from: $from, session: $session, thread: $thread, report: ($r | rtrimstr("\n"))[:4000]}
   # prompt = what the report task templates ({{body.prompt}}): Keepalive is never wrapped (rule 1.4b).
   | .prompt = (if $ka then .report
                else "Report from \(.from) (thread \(.thread)): \(.report)" end)') \
  || fail "could not build the JSON body"

# Local before cloud: the relay URL https://relay.t3.codes/v1/hooks/<env>/<task>/<token> has the local twin
# http://127.0.0.1:<T3CODE_PORT>/api/hooks/<task>/<token> (proven 2026-10-20). Local first, the relay only as fallback.
LOCAL=""
case $URL in
  https://relay.t3.codes/v1/hooks/*/*/*) R=${URL#https://relay.t3.codes/v1/hooks/}; LOCAL="http://127.0.0.1:${T3CODE_PORT:-8470}/api/hooks/${R#*/}" ;;
esac
# Time budget: at most two POSTs of T3_WAKE_TIMEOUT (default 4 s) each, so the sender ends well inside
# the Stop hook's 20 s (hooks.json) and its failure line always gets written (t3-report.sh adds a guard).
post() {  # $1 = url; prints the HTTP code. The URL travels through a process substitution: printf is a builtin, so it is in no process's argv.
  curl -sS --connect-timeout 2 -m "${T3_WAKE_TIMEOUT:-4}" -o /dev/null -w '%{http_code}' -K <(printf 'url = "%s"\n' "$1") \
    -H 'content-type: application/json' --data-binary @- <<<"$BODY" 2>/dev/null
}
CODE=""
[ -n "$LOCAL" ] && [ -z "${T3_WAKE_NO_LOCAL:-}" ] && CODE=$(post "$LOCAL")
[ "$CODE" = 202 ] || CODE=$(post "$URL")
[ "$CODE" = 202 ] || fail "http ${CODE:-000}"
mkdir -p "$RDIR" 2>/dev/null
printf '%s\t%s\t%s\t%s\n' "$(date +%F)" "$FROM" "${SID:--}" "$THREAD" >> "$RDIR/posts.tsv" 2>/dev/null
exit 0
