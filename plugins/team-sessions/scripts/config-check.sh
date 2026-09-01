#!/usr/bin/env bash
# team-sessions plugin — config path resolver + THE shape filter (single owner).
# Consumers: hooks/session-role.sh, hooks/protect-main-checkouts.sh,
#   hooks/block-blanket-git-add.sh, commands/team-sessions-setup.md (via Bash),
#   scripts/wt, tests/run.sh.
#
# Usage:
#   config-check.sh dir        print the resolved Claude config dir
#   config-check.sh file       print the resolved team-sessions config file path
#   config-check.sh validate   validate the config file; exit codes:
#                                0 = valid config
#                                1 = invalid (unparseable JSON or wrong shape)
#                                2 = no config file (plugin dormant for worktree part)
#                                3 = jq not installed
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

cfg_file() { printf '%s/team-sessions.json' "$(cfg_dir)"; }

validate() {
  command -v jq >/dev/null 2>&1 || return 3
  local f
  f="$(cfg_file)"
  [ -f "$f" ] || return 2
  jq -e '
    (type == "object")
    and ((.board // "") | type == "string")
    and ((.surgicalStaging // true) | type == "boolean")
    and ((.protectedCheckouts // []) | (type == "array") and all(
          (type == "object")
          and (.name | type == "string")
          and (.root | type == "string")
          and (.base | type == "string")
          and ((.install // "") | type == "string")
          and ((.worktreeDir // "") | type == "string")
        ))
  ' "$f" >/dev/null 2>&1 || return 1
  return 0
}

case "${1:-}" in
  dir)      cfg_dir; echo ;;
  file)     cfg_file; echo ;;
  validate) validate ;;
  *) echo "usage: config-check.sh dir|file|validate" >&2; exit 64 ;;
esac
