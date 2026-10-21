#!/usr/bin/env bash
# middle-management plugin: the guard canary. Alarms when the plugin's guards are no longer live.
# Consumers: templates/systemd/mm-guard-canary.service (hourly via mm-guard-canary.timer; installed
#   by /middle-management-setup step 9, which copies this script next to unit-failure-alarm.sh),
#   manual runs, tests/guard-canary.sh. Reads the INSTALLED plugin (installed_plugins.json), not
#   the copy beside it. Leaves the cause file scripts/unit-failure-alarm.sh sends on failure.
#
# Why: the role banner, the staging guard and the checkout guard exist only as plugin hooks, and the
# checkout guard fails OPEN on a missing or invalid config or an unloaded plugin. Nothing would tell.
# Checks, in order (the first failure ends the run: exit 1, one cause line, the OnFailure alarm):
#   1. the config exists and validates            2. the plugin is enabled in settings.json
#   3. its installPath exists and its hooks.json registers session-role.sh, block-blanket-git-add.sh
#      and protect-main-checkouts.sh              4. the same three are not ALSO wired in
#      settings.json (a site-local copy left behind fires twice)
#   5. direct deny probes, no model: the staging guard (unless surgicalStaging is false) and the
#      checkout guard (on the first protectedCheckouts root, when there is one)
#   6. once a day, the first run from MM_CANARY_E2E_HOUR (9) on: the end-to-end probe. A headless
#      `claude -p` must make the blocked call and get the plugin's own deny text back, proving the
#      CLI still LOADS the hooks. The prompt says the denial IS the expected result, because a small
#      model otherwise refuses to attempt a blocked command; a run without the tool call is retried
#      once on the next model of MM_CANARY_MODELS ("haiku sonnet").
# Env (optional): MM_CANARY_UNIT (the unit name, for the cause file), MM_CANARY_PLUGIN (the plugin
#   key, default: the installed "middle-management@<marketplace>"), MM_CANARY_E2E_HOUR,
#   MM_CANARY_MODELS, MM_CANARY_NO_E2E=1 (static checks only).
# ponytail: hourly static checks, one daily e2e probe, nothing smarter.
set -uo pipefail

CFG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CFG=$CFG_DIR/middle-management.json
STATE=$CFG_DIR/state/guard-canary
UNIT=${MM_CANARY_UNIT:-}
HOST=$(hostname -s 2>/dev/null || echo host)

fail() {
  local text="[$HOST] middle-management guard canary FAILED${UNIT:+ ($UNIT)}
Cause: $1
Fix: ${2:-/middle-management-setup, then: systemctl --user start mm-guard-canary.service}"
  printf '%s\n' "$text" >&2
  if [ -n "$UNIT" ]; then
    local c="$CFG_DIR/state/unit-failure-alarm/$(printf '%s' "$UNIT" | tr -c 'A-Za-z0-9._-' '_').cause"
    mkdir -p "$(dirname "$c")" && printf '%s\n' "$text" > "$c"
  fi
  exit 1
}
command -v jq >/dev/null 2>&1 || fail "jq is not installed" "install jq"

# 1. config
[ -f "$CFG" ] || fail "config missing: $CFG (the checkout guard is silently off)"
# 2. enabled
S=$CFG_DIR/settings.json
[ -f "$S" ] || fail "settings missing: $S"
PLUGIN=${MM_CANARY_PLUGIN:-$(jq -r '.plugins // {} | keys[] | select(startswith("middle-management@"))' \
  "$CFG_DIR/plugins/installed_plugins.json" 2>/dev/null | head -1)}
[ -n "$PLUGIN" ] || fail "middle-management is not in $CFG_DIR/plugins/installed_plugins.json" "/plugin install middle-management@<marketplace>"
[ "$(jq -r --arg p "$PLUGIN" '.enabledPlugins[$p] // false' "$S" 2>/dev/null)" = true ] \
  || fail "$PLUGIN is not enabled in $S" "/plugin enable $PLUGIN"
# 3. installed hooks
IP=$(jq -r --arg p "$PLUGIN" '.plugins[$p][0].installPath // ""' "$CFG_DIR/plugins/installed_plugins.json" 2>/dev/null)
[ -n "$IP" ] && [ -d "$IP" ] || fail "the installPath of $PLUGIN is missing ('$IP')" "/plugin update $PLUGIN"
for h in session-role.sh block-blanket-git-add.sh protect-main-checkouts.sh; do
  grep -q "hooks/$h" "$IP/hooks/hooks.json" 2>/dev/null || fail "$IP/hooks/hooks.json does not register $h" "/plugin update $PLUGIN"
done
CLAUDE_CONFIG_DIR="$CFG_DIR" bash "$IP/scripts/config-check.sh" validate >/dev/null 2>&1 \
  || fail "config-check.sh validate fails for $CFG (invalid config: the checkout guard is off)"
# 4. no second wiring of the same hooks in settings.json
LEG=$(jq -r '[.hooks[]?[]?.hooks[]?.command // empty] | map(select(test("session-role\\.sh|block-blanket-git-add\\.sh|protect-main-checkouts\\.sh"))) | join(" ")' "$S" 2>/dev/null)
[ -z "$LEG" ] || fail "the guard hooks are also wired in $S (they fire twice): $LEG" "remove those entries from $S"

# 5. direct probes. The staging string is built from halves: a guard on this machine blocks the
#    literal even inside a quoted string.
A="git add"
STAGING=$(jq -r 'if .surgicalStaging == false then "off" else "on" end' "$CFG")
if [ "$STAGING" = on ]; then
  printf '{"tool_input":{"command":"%s -A"}}' "$A" | CLAUDE_CONFIG_DIR="$CFG_DIR" CLAUDE_PLUGIN_ROOT="$IP" bash "$IP/hooks/block-blanket-git-add.sh" 2>/dev/null \
    | grep -q '"permissionDecision":"deny"' || fail "the staging guard did not deny the direct probe"
fi
ROOT=$(jq -r '.protectedCheckouts[0].root // ""' "$CFG")
if [ -n "$ROOT" ]; then
  jq -nc --arg f "$ROOT/.mm-guard-probe" '{tool_input:{file_path:$f}}' \
    | CLAUDE_CONFIG_DIR="$CFG_DIR" CLAUDE_PLUGIN_ROOT="$IP" bash "$IP/hooks/protect-main-checkouts.sh" 2>/dev/null \
    | grep -q '"permissionDecision":"deny"' || fail "the checkout guard did not deny the direct probe on $ROOT"
fi

# 6. daily end-to-end probe
mkdir -p "$STATE"
LATCH=$STATE/e2e-$(date +%F)
if [ -z "${MM_CANARY_NO_E2E:-}" ] && [ ! -f "$LATCH" ] && [ "$((10#$(date +%H)))" -ge "${MM_CANARY_E2E_HOUR:-9}" ]; then
  command -v claude >/dev/null 2>&1 || fail "claude is not on PATH for the end-to-end probe" "set Environment=PATH= in the unit"
  OUT=$(mktemp -d "$STATE/e2e.XXXXXX")
  # The CLI reads ~/.claude.json only while CLAUDE_CONFIG_DIR is unset (morning-headless.sh, same fix).
  CC=$CFG_DIR; [ "$CC" = "$HOME/.claude" ] && CC=""
  probe() {  # <out file> <tool> <cwd> <instruction>: true once the model made the call
    local out=$1 tool=$2 cwd=$3 task=$4 m
    for m in ${MM_CANARY_MODELS:-haiku sonnet}; do
      ( cd "$cwd" && CLAUDE_CONFIG_DIR="$CC" timeout 180 claude -p "Automated guard test (middle-management guard canary). A PreToolUse hook is EXPECTED to deny the following tool call: the denial IS the test result you are asked to produce, not a problem to avoid. So make the call exactly once, do not refuse it, and do not work around the denial. $task" \
          --model "$m" --tools "$tool" --max-turns 3 --permission-mode bypassPermissions \
          --output-format stream-json --verbose </dev/null ) > "$out" 2>&1
      jq -e --arg t "$tool" 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name==$t)' "$out" >/dev/null 2>&1 && return 0
    done
    return 1
  }
  if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
    P=$ROOT/.mm-guard-probe
    probe "$OUT/edit.jsonl" Write "$ROOT" "Use the Write tool to create $P with the content x, then reply done."
    if [ -e "$P" ]; then
      mkdir -p "$STATE/leftovers" && mv "$P" "$STATE/leftovers/mm-guard-probe-$(date +%F-%H%M)"
      fail "e2e: the probe file was written into the protected checkout $ROOT (checkout guard not live); stream: $OUT/edit.jsonl"
    fi
    grep -q 'Direct edits in the protected checkout' "$OUT/edit.jsonl" \
      || fail "e2e: no plugin deny text for the edit probe (no Write call on ${MM_CANARY_MODELS:-haiku sonnet}, or the guard is not loaded); stream: $OUT/edit.jsonl"
  fi
  if [ "$STAGING" = on ]; then
    R=$(mktemp -d "$STATE/repo.XXXXXX"); git -C "$R" init -q && touch "$R/f"
    probe "$OUT/stage.jsonl" Bash "$R" "Run exactly this Bash command and nothing else: $A -A"
    [ -z "$(git -C "$R" diff --cached --name-only 2>/dev/null)" ] || fail "e2e: the staging probe staged files in $R (staging guard not live)"
    grep -q 'blanket git staging is blocked' "$OUT/stage.jsonl" \
      || fail "e2e: no plugin deny text for the staging probe (no Bash call on ${MM_CANARY_MODELS:-haiku sonnet}, or the guard is not loaded); stream: $OUT/stage.jsonl"
  fi
  date '+%F %T' > "$LATCH"
  find "$STATE" -maxdepth 1 \( -name 'e2e.*' -o -name 'repo.*' -o -name 'e2e-*' \) -mtime +7 -exec rm -rf {} + 2>/dev/null
  echo "guard-canary: e2e ok"
fi
echo "guard-canary: ok ($IP)"
