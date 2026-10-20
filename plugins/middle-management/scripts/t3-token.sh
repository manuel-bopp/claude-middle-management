#!/usr/bin/env bash
# middle-management plugin: keep or mint the T3 Code bearer token the watcher reads (t3TokenFile).
# Consumers: commands/middle-management-setup.md (step 8, and again after every `t3 update`).
#   Ported from the mint/keep part of the retired ~/.claude/skills/t3-threads/install.sh (2026-10-20).
#
# Usage: t3-token.sh [--check]
#   keeps the stored token while the server accepts it; mints a new one (ttl 365d, label t3-threads)
#   only when the file is missing or the server rejects it, then revokes older sessions with that
#   label (other labels are never touched). --check only tests, never mints.
# Env:   T3_BIN (default: t3 on PATH), T3T_URL (default 100.125.193.62:8470), CLAUDE_CONFIG_DIR.
# Exit:  0 accepted · 2 missing/rejected (--check) · 1 unreachable, or the new token not accepted.
# The token never appears in argv, output or xtrace: curl reads its header from a process
# substitution (printf is a builtin).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CFG_FILE="$(bash "$DIR/config-check.sh" file)"
TOKEN_FILE=$(jq -r '.t3TokenFile // empty' "$CFG_FILE" 2>/dev/null || true)
TOKEN_FILE=${TOKEN_FILE:-$HOME/.config/t3-threads/token}
TOKEN_FILE=${TOKEN_FILE/#\~/$HOME}
T3=${T3_BIN:-t3}
URL=${T3T_URL:-100.125.193.62:8470}; case $URL in http://*|https://*) ;; *) URL=http://$URL ;; esac

# 0 accepted, 2 missing/rejected, 1 anything else after ~60 s of retries (a T3 restart takes one)
check() {
  [ -s "$TOKEN_FILE" ] || return 2
  local code
  for _ in $(seq 12); do
    code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -H 'x-t3-orchestration-protocol: 2' \
      -K <(printf 'header = "authorization: Bearer %s"\n' "$(tr -d '[:space:]' < "$TOKEN_FILE")") \
      "${URL%/}/api/orchestration/shell" 2>/dev/null) || code=000
    case $code in 200) return 0 ;; 401|403) return 2 ;; esac
    sleep 5
  done
  echo "t3-token: server answered HTTP $code" >&2; return 1
}

rc=0; check || rc=$?
[ "${1:-}" = --check ] && { echo "token: $(case $rc in 0) echo accepted ;; 2) echo missing or rejected ;; *) echo unknown, server unreachable ;; esac)"; exit $rc; }
if [ $rc = 0 ]; then
  echo "token: stored token accepted"
elif [ $rc = 2 ]; then
  echo "token: missing or rejected, minting a new one (ttl 365d)"
  mkdir -p "$(dirname "$TOKEN_FILE")"; chmod 700 "$(dirname "$TOKEN_FILE")"
  ( umask 077; "$T3" auth session issue --label t3-threads --ttl 365d --token-only > "$TOKEN_FILE.new" )
  mv "$TOKEN_FILE.new" "$TOKEN_FILE"
  rc=0; check || rc=$?
  [ $rc = 0 ] || { echo "FAIL: freshly minted token not accepted (rc $rc)" >&2; exit 1; }
  "$T3" auth session list --json | TOKEN_FILE="$TOKEN_FILE" python3 -c '
import base64, json, os, sys
p = open(os.environ["TOKEN_FILE"]).read().strip().split(".")[0]
mine = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["sid"]
for s in json.load(sys.stdin):
    if (s.get("client") or {}).get("label") == "t3-threads" and s["sessionId"] != mine:
        print(s["sessionId"])' | while read -r sid; do
      "$T3" auth session revoke "$sid" >/dev/null && echo "token: revoked old t3-threads session $sid"
    done
  echo "token: minted and accepted"
else
  echo "FAIL: server unreachable; stored token left untouched" >&2; exit 1
fi
chmod 600 "$TOKEN_FILE"
