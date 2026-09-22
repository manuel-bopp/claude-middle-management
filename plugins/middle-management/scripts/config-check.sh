#!/usr/bin/env bash
# middle-management plugin — config path resolver + THE shape filter (single owner).
# Consumers: hooks/session-role.sh, hooks/protect-main-checkouts.sh,
#   hooks/block-blanket-git-add.sh, commands/middle-management-setup.md (via Bash),
#   scripts/wt, tests/run.sh.
#
# Usage:
#   config-check.sh dir        print the resolved Claude config dir
#   config-check.sh file       print the resolved middle-management config file path
#   config-check.sh validate   validate the config file; exit codes:
#                                0 = valid config
#                                1 = invalid (unparseable JSON or wrong shape)
#                                2 = no config file (plugin dormant for worktree part)
#                                3 = jq not installed
#   config-check.sh session-log  print the resolved session-log path; exit codes:
#                                0 = the user chose it ($MM_SESSION_LOG or the sessionLog key)
#                                1 = nobody chose it, this is the built-in default
#
# The config dir honors CLAUDE_CONFIG_DIR (empty value = unset, matching Claude
# Code's own handling); default is ~/.claude.
set -u

cfg_dir() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s' "$CLAUDE_CONFIG_DIR"
  else
    printf '%s' "$HOME/.claude"
  fi
}

cfg_file() { printf '%s/middle-management.json' "$(cfg_dir)"; }

# The session log both the role hook and the coordinator seat have to be able to NAME, even on a
# machine that has none yet: $MM_SESSION_LOG > the config key sessionLog > ~/logs/session-log.md.
# scripts/peer-state.py resolves the same three, in the same order, without this script (it is a
# standalone reader). The exit code carries the second fact its callers need — whether the path
# was CHOSEN or merely defaulted — so neither has to read the config a second time.
session_log() {
  local p="${MM_SESSION_LOG:-}" chosen=0
  # `strings` drops a non-string value, so a broken config falls back to the default here exactly
  # as it does in peer-state.py — the two must never name different files. No jq: empty, default.
  [ -n "$p" ] || p="$(jq -r '(.sessionLog | strings) // ""' "$(cfg_file)" 2>/dev/null)"
  [ -n "$p" ] || { p="$HOME/logs/session-log.md"; chosen=1; }
  case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#\~/}" ;; esac
  printf '%s\n' "$p"
  return "$chosen"
}

validate() {
  command -v jq >/dev/null 2>&1 || return 3
  local f
  f="$(cfg_file)"
  [ -f "$f" ] || return 2
  jq -e '
    (type == "object")
    and ((.board // "") | type == "string")
    and ((.surgicalStaging // true) | type == "boolean")
    and ((.notifyCommand // "") | type == "string")
    and ((.sessionLog // "") | type == "string")
    and ((.unitMemoryMax // "") | type == "string")
    and ((.capMemoryMax // "") | type == "string")
    and ((.maxUnits // 0) | type == "number")
    and ((.longRunningAsUnit // false) | type == "boolean")
    and ((.reaperMaxHours // 0) | type == "number")
    and ((.reaperOwnerlessMinutes // 0) | type == "number")
    and ((.reaperDigestHour // 7) | (type == "number" and . == (. | floor) and . >= 0 and . <= 23))
    and ((.protectedCheckouts // []) | (type == "array") and all(
          (type == "object")
          and (.name | (type == "string") and (test("^[^[:space:]]+$")))  # a column of `wt list`
          and (.root | type == "string")
          and (.base | type == "string")
          and ((.install // "") | type == "string")
          and ((.serve // "") | type == "string")
          and ((.worktreeDir // "") | type == "string")
        ))
  ' "$f" >/dev/null 2>&1 || return 1
  return 0
}

case "${1:-}" in
  dir)         cfg_dir; echo ;;
  file)        cfg_file; echo ;;
  validate)    validate ;;
  session-log) session_log ;;
  *) echo "usage: config-check.sh dir|file|validate|session-log" >&2; exit 64 ;;
esac
