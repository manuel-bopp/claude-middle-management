#!/usr/bin/env bash
# middle-management plugin — OPTIONAL PreToolUse hook (matcher Bash), OFF unless the config says
# "longRunningAsUnit": true. Consumers: hooks/hooks.json.
#
# Keeps hand-started dev servers and heavy one-shots inside the capped units `wt run` / `wt cap`,
# instead of escaping into the session's own process tree where nothing bounds their memory and
# no cleanup routine can see them.
#
# Matching happens in COMMAND POSITION only: the awk block drops heredoc bodies, quoted strings
# and comments, splits the rest at shell operators, strips harmless prefixes (VAR=, sudo, env,
# nohup, time, timeout 300, bunx, npx, a leading path) and only then anchors a verb at the start
# of a command. So `cat vite.config.ts`, `grep 'next dev' f` and `echo "bun test"` are NOT matched.
#
# What the tokenizer cannot see (deliberate; it is a stripper, not a shell parser):
#   - anything inside "double quotes", including "$(bun test)" — not matched;
#   - a `<<` inside a quoted string turns on heredoc mode and the rest of the input is dropped —
#     fail-open, i.e. not matched;
#   - one heredoc per line only;
#   - a verb inside a script, alias or function the hook cannot read;
#   - a long-runner started with an explicit `cd` into the lane (`cd <lane> && next dev`) — the
#     lane is read from the tool's cwd, and a compound command is refused anyway.
# Not covered by the verb list at all: `npm test`, and any dev server that is not next, vite or
# a `dev` script. ponytail: a stripper instead of a parser, and the list above is the price.
#
# Outcome:
#   long-runner, simple, cwd inside a lane -> REWRITE to `wt <name> run <lane> -- <cmd>`, allow
#   long-runner, compound, cwd in a lane   -> REFUSE with the full replacement line: starting a
#                                             server inside a pipe must not happen silently
#   long-runner, cwd outside every lane    -> left alone (there is no lane to name the unit after)
#   heavy one-shot, simple                 -> REWRITE to `wt cap -- <cmd>`
#   heavy one-shot, compound               -> REWRITE to `wt cap -- bash -lc '<original>'`
#                                             (keeps cwd, pipes and the exit status)
#
# Override for one deliberate hand-start: touch <config dir>/state/allow-hand-start — and delete
# it right after.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CHECK="$PLUGIN_ROOT/scripts/config-check.sh"
command -v jq >/dev/null 2>&1 || exit 0
bash "$CHECK" validate || exit 0              # invalid or absent config: stay out of the way
CFG_FILE="$(bash "$CHECK" file)"
CFG_DIR="$(bash "$CHECK" dir)"
[ "$(jq -r '.longRunningAsUnit // false' "$CFG_FILE" 2>/dev/null)" = true ] || exit 0
[ -e "$CFG_DIR/state/allow-hand-start" ] && exit 0

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)"
[ -z "$CMD" ] && exit 0

# -> "<group> <needs-shell 0|1> <hyphenated-verb>", or nothing when nothing matches.
VERDICT="$(printf '%s' "$CMD" | awk '
BEGIN {
  q    = sprintf("%c", 39)                       # single quote, unquotable inline
  HDRE = "<<-?[ \t]*[" q "\"A-Za-z_][" q "\"A-Za-z0-9_]*"
  LR   = "^(next[ \t]+dev|vite|(bun|npm|pnpm|yarn)([ \t]+run)?[ \t]+dev)([ \t]|$)"
  HV   = "^(bun[ \t]+test|next[ \t]+build|playwright[ \t]+test|(bun|npm|pnpm|yarn)([ \t]+run)?[ \t]+build)([ \t]|$)"
  ASG  = "^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]*"
  PBIN = "^(sudo|env|nohup|time|nice|bunx|npx)([ \t]+|$)"  # real binaries: survive wt cap
  TMO  = "^timeout([ \t]+-[^ \t]+)*[ \t]+[0-9.]+[smhd]?([ \t]+|$)"   # timeout 300 bun test
  PSH  = "^(exec|command|then|do|else|elif|if|while|until|!)([ \t]+|$)"  # shell-only: need bash -lc
  SKIP = "(^|/)(wt|systemd-run)$"
  st = 0                                         # quote state, carried ACROSS lines
}
{
  line = $0
  if (hd != "") {                                # inside a heredoc body: drop it
    t = line; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
    if (t == hd) hd = ""
    next
  }
  if (match(line, HDRE)) {                       # heredoc starts here
    d = substr(line, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", d); gsub("[" q "\"]", "", d)
    hd = d
  }
  out = ""                                       # st: 0 plain, 1 in q, 2 in " — a
                                                 # multi-line "…" (git commit -m) stays quoted
  for (i = 1; i <= length(line); i++) {
    c = substr(line, i, 1)
    if (st == 1) { if (c == q) st = 0; continue }
    if (st == 2) { if (c == "\\") { i++; continue } ; if (c == "\"") st = 0; continue }
    if (c == "\\") { i++; out = out " "; continue }
    if (c == q)    { st = 1; continue }
    if (c == "\"") { st = 2; continue }
    if (c == "#" && (out == "" || substr(out, length(out), 1) ~ /[ \t;&|(]/)) break
    out = out c
  }
  buf = buf out "\n"
}
END {
  txt = buf
  sub(/\n+$/, "", txt)
  gsub(/[0-9]*[<>]&[0-9-]*/, " ", txt)           # 2>&1 / >&2 are redirections, not operators
  gsub(/&>>?/, " ", txt)
  shell = (txt ~ /[;|&(){}`]/ || txt ~ /\n/) ? 1 : 0
  gsub(/[;|&(){}`]/, "\n", txt)
  n = split(txt, seg, "\n")
  for (i = 1; i <= n; i++) {
    s = seg[i]; sub(/^[ \t]+/, "", s); need = 0
    while (1) {
      if (s ~ ASG)  { sub(ASG, "", s); need = 1; continue }               # VAR=x cmd
      if (s ~ PSH)  { sub(/^[^ \t]+[ \t]*/, "", s); need = 1; continue }
      if (s ~ PBIN) { sub(/^[^ \t]+[ \t]*/, "", s); continue }
      if (s ~ TMO)  { sub(/^timeout([ \t]+-[^ \t]+)*[ \t]+[0-9.]+[smhd]?[ \t]*/, "", s); continue }
      if (s ~ /^[^ \t]*\//) { sub(/^[^ \t]*\//, "", s); continue }      # ~/.bun/bin/bun test
      break
    }
    fw = s; sub(/[ \t].*/, "", fw)
    if (fw ~ SKIP) continue                       # already routed through wt / systemd-run
    if (match(s, LR)) { grp = "run"; nm = substr(s, 1, RLENGTH); shell = shell || need; break }
    if (grp == "" && match(s, HV)) { grp = "cap"; nm = substr(s, 1, RLENGTH); shell = shell || need }
  }
  if (grp == "") exit
  sub(/[ \t]+$/, "", nm); gsub(/[ \t]+/, "-", nm)
  print grp " " shell " " tolower(nm)
}
' 2>/dev/null)"
[ -z "$VERDICT" ] && exit 0

set -- $VERDICT
GROUP="$1" SHELL_NEEDED="$2" VERB="${3//-/ }"
WT="bash \"$PLUGIN_ROOT/scripts/wt\""

if [ "$GROUP" = run ]; then
  # Which lane? The tool's cwd decides: a lane is a directory directly inside a checkout's
  # worktreeDir, and its name is what the unit is called after.
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)"; CWD="${CWD:-$PWD}"
  LANE=""
  while IFS=$'\t' read -r pc_name pc_root pc_wtdir; do
    [ -n "$pc_wtdir" ] || pc_wtdir="$(dirname "${pc_root%/}")/.worktrees-$pc_name"
    pc_wtdir="${pc_wtdir%/}"
    case "$CWD/" in
      "$pc_wtdir"/*) LANE="${CWD#"$pc_wtdir"/}"; LANE="${LANE%%/*}"
                     [ -n "$LANE" ] && { CHECKOUT="$pc_name"; break; } ;;
    esac
  done < <(jq -r '.protectedCheckouts[]? | [.name, .root, (.worktreeDir // "")] | @tsv' "$CFG_FILE" 2>/dev/null)
  [ -n "$LANE" ] || exit 0
  WTFORM="$WT $CHECKOUT run $LANE --"
else
  WTFORM="$WT cap --"
fi

if [ "$SHELL_NEEDED" = 1 ]; then
  INNER="$CMD"
  # A unit's main process must stay in the foreground: `nohup … &` returns at once, and systemd
  # then tears the cgroup down around the server that just detached into it.
  [ "$GROUP" = run ] && INNER="$(printf '%s' "$INNER" | sed -e 's/^[ \t]*nohup[ \t]\{1,\}//' -e 's/[ \t]*&[ \t]*$//')"
  # bash -lc '<original>' is a correct replacement for ANY command — pipes, cd, redirections,
  # env prefixes, several lines — and wt cap passes the exit status through.
  NEWCMD="$WTFORM bash -lc '$(printf '%s' "$INNER" | sed "s/'/'\\\\''/g")'"
else
  NEWCMD="$WTFORM $CMD"
fi

if [ "$GROUP" = run ] && [ "$SHELL_NEEDED" = 1 ]; then
  REASON="Long-runner ($VERB) inside a compound command — a server belongs in its lane's unit, not in this session's process tree.
Run this instead (copy as-is):
$NEWCMD"
  jq -n --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

REASON="Hand-started $VERB — rewritten to run memory-capped: $NEWCMD"
printf '%s' "$INPUT" | jq --arg r "$REASON" --arg cmd "$NEWCMD" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r,updatedInput:((.tool_input // {}) + {command:$cmd})}}'
exit 0
