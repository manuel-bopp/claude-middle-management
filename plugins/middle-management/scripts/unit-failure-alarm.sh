#!/usr/bin/env bash
# middle-management plugin — the OnFailure= alarm for the heartbeat's systemd user units.
# Consumers: templates/systemd/unit-failure-alarm@.service (installed by /middle-management-setup
#   next to this script's copy); any further user unit may point OnFailure= at
#   unit-failure-alarm@%n.service. tests/heartbeat.sh, section D. Nothing else calls it.
#
# A unit failed, so say so through the configured notifyCommand (config key; the text arrives as
# $1 and on stdin) — an unattended failure must reach a human, never only a journal.
# Usage: unit-failure-alarm.sh <unit name>
# Ships the unit's last 8 journal lines: never point it at a unit whose journal can carry a
# credential. Never prints a secret itself.
#
# LATCHED: at most one alarm per unit per hour. A unit that fails on every start (a bad path, a
# permission, a persistent timeout) would otherwise send 144 messages a day.
set -uo pipefail

UNIT=${1:-unknown-unit}
CFG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CFG_FILE=${UFA_CONFIG:-$CFG_DIR/middle-management.json}
LATCHDIR=${UFA_LATCH_DIR:-$CFG_DIR/state/unit-failure-alarm}
LATCH=$LATCHDIR/$(printf '%s' "$UNIT" | tr -c 'A-Za-z0-9._-' '_')
mkdir -p "$LATCHDIR" 2>/dev/null || true
NOW=$(date +%s)
LAST=$(cat "$LATCH" 2>/dev/null || echo 0)
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
if [ $((NOW - LAST)) -lt "${UFA_THROTTLE_SEC:-3600}" ]; then
  echo "unit-failure-alarm: $UNIT alarmed $((NOW - LAST))s ago, throttled" >&2
  exit 0
fi
printf '%s\n' "$NOW" > "$LATCH" 2>/dev/null || true
RESULT=$(systemctl --user show "$UNIT" -p Result --value 2>/dev/null || echo unknown)
STATE=$(systemctl --user show "$UNIT" -p ActiveState --value 2>/dev/null || echo unknown)
LOG=$(journalctl --user -u "$UNIT" -n 8 --no-pager -o cat 2>/dev/null | tail -c 600)

TEXT="[$(hostname -s 2>/dev/null || echo host)] systemd user unit ${UNIT} FAILED (result: ${RESULT:-unknown}, state: ${STATE:-unknown}).

Check: journalctl --user -u ${UNIT} -n 50

Last lines:
${LOG:-<no journal available>}"

# ponytail: the same lines live in orch-heartbeat.sh on purpose (different contracts).
CMD=$(jq -r '.notifyCommand // ""' "$CFG_FILE" 2>/dev/null || true)
if [ -z "$CMD" ]; then
  echo "unit-failure-alarm: no notifyCommand in $CFG_FILE - alarm NOT delivered: $TEXT" >&2
  exit 1
fi
# Output discarded, not journaled: a failing command may echo a URL that carries a token.
if printf '%s\n' "$TEXT" | sh -c "$CMD" notify "$TEXT" >/dev/null 2>&1; then exit 0; fi
echo "unit-failure-alarm: notifyCommand failed for $UNIT" >&2
exit 1
