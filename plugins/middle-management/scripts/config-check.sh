#!/usr/bin/env bash
# middle-management plugin — config path resolver + THE shape filter (single owner).
# Consumers: hooks/session-role.sh, hooks/protect-main-checkouts.sh,
#   hooks/block-blanket-git-add.sh, hooks/long-running-as-unit.sh, hooks/require-review-loop.sh,
#   commands/middle-management-setup.md (via Bash),
#   scripts/wt, scripts/orchestrator.sh, scripts/morning-headless.sh, scripts/t3-wake.sh,
#   scripts/t3-token.sh, hooks/t3-report.sh, hooks/require-work-packages.sh,
#   hooks/subagent-report-check.sh, hooks/reply-timestamp.sh, hooks/intent-check.sh,
#   scripts/morning-t3.sh, scripts/copy-set.sh, scripts/pr-review-watch.sh, hooks/refresh-copies.sh,
#   tests/run.sh, tests/t3-seat.sh, tests/morning-t3.sh, tests/pr-review-watch.sh.
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
  case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#\~/}" ;; esac
  # Anything still not absolute — empty, relative, or a `~user/` form neither side expands — would
  # bind to the CALLER's cwd, and the seat, the wrap and the reader run from three different ones.
  # So it names no file: the shape filter calls it invalid (loudly) and the default answers here,
  # exactly as peer-state.py does. A relative path is the one way the two could name DIFFERENT
  # files on the same machine — which is how two sessions end up holding the seat at once.
  case "$p" in /*) ;; *) p="$HOME/logs/session-log.md"; chosen=1 ;; esac
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
    and ((.sessionLog // "/") | (type == "string" and (startswith("/") or startswith("~"))))
    and ((.unitMemoryMax // "") | type == "string")
    and ((.capMemoryMax // "") | type == "string")
    and ((.maxUnits // 0) | type == "number")
    and ((.longRunningAsUnit // false) | type == "boolean")
    and ((.reviewLoopGate // false) | type == "boolean")
    and ((.reaperMaxHours // 0) | type == "number")
    and ((.reaperOwnerlessMinutes // 0) | type == "number")
    and ((.reaperDigestHour // 7) | (type == "number" and . == (. | floor) and . >= 0 and . <= 23))
    # 0.11.0 (README "T3 Code", "Follow-through", "Sub-agents"): the readers fall back to their default
    # on a wrong shape too, but a typo should fail here, loudly.
    and ([.t3TokenFile, .onLimitCommand, .pageCommand, .userName, .okBy] | all(. == null or type == "string"))
    and ((.remindAfterHours // 2) | (type == "number" and . > 0))
    and ((.remindWindow // "08:00-22:00") | (type == "string" and test("\\A\\d{1,2}:\\d{2}-\\d{1,2}:\\d{2}\\z")))
    and ((.workPackagesGate // true) | type == "boolean")
    # 0.11.1 (README "Morning coordinator in T3 Code", "Alarm fallback"): the morning chain and the
    # second alarm route. morningTakeover carries the standing word of the user: allowed + who said it.
    and ([.notifyFallbackCommand, .morningTaskUrlFile] | all(. == null or type == "string"))
    # optional prompt hooks (README "Optional prompt hooks"), both default false
    and ((.replyTimestamp // false) | type == "boolean")
    and ((.intentCheck // false) | type == "boolean")
    and ((.intentCheckVerbs // "x") | (type == "string" and length > 0))
    and ((.morningRoot // "/") | (type == "string" and startswith("/")))
    and ((.morningWaitUntil // "09:30") | (type == "string" and test("\\A([01]?\\d|2[0-3]):[0-5]\\d\\z")))
    and ((.morningTakeover // {"allowed": false}) | (type == "object")
          and (.allowed | type == "boolean")
          and ((.okBy // "") | type == "string")
          and (if .allowed then ((.okBy // "") | test("\\S")) else true end))
    # 0.12.0 (README "Contributing and releases"): the PR review runner. repos are "owner/name" (a
    # state directory name), authors the allowlist, maxRounds a whole number of rounds.
    and ((.prReview // {}) | (type == "object")
          and ((.repos // []) | type == "array" and all(type == "string" and test("\\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\z")))
          and ((.authors // []) | type == "array" and all(type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9-]*\\z")))
          and ([.model, .securityModel, .reviewerName, .placementGuide] | all(. == null or (type == "string" and test("\\S"))))
          and ((.base // "main") | type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9._/-]*\\z") and (startswith("refs/") | not))
          and ((.approve // false) | type == "boolean")
          and ((.maxRounds // 4) | (type == "number" and . >= 1 and . == floor)))
    # t3Url: the base URL of the T3 server (watcher, t3-token.sh); a plain http(s) URL, nothing else.
    and ((.t3Url // "http://x") | (type == "string" and test("\\Ahttps?://[^\\s\"]+\\z")))
    and ((.protectedCheckouts // []) | (type == "array") and all(
          (type == "object")
          and (.name | (type == "string") and (test("^[^[:space:]]+$")))  # a column of `wt list`
          and (.root | type == "string")
          and (.base | type == "string")
          and ((.install // "") | type == "string")
          and ((.serve // "") | type == "string")
          and ((.worktreeDir // "") | type == "string")
        ))
    # Scopes (README "Scopes"): the name becomes a directory under state/scopes/, a root of / would
    # swallow every session; scripts/scope.py refuses both on its own as well.
    # scopeMode (README "Scopes", D7): "per-root" = every project root is its own scope, no catch-all.
    and ((.scopeMode // "per-root") | . == "per-root")
    and ((.scopes // []) | (type == "array")
          and all((type == "object")
            and (.name | type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9_-]*\\z") and . != "default" and . != "none")
            and (.root | type == "string" and startswith("/") and (sub("/+$"; "") | length) > 0)
            and (.board | type == "string" and startswith("/")))
          and ((map(.name) | unique | length) == length)
          and ((map(.root | sub("/+$"; "")) | unique | length) == length))
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
