#!/usr/bin/env bash
# middle-management plugin — PreToolUse guard, matcher Bash.
# Consumers: hooks/hooks.json.
#
# Blocks blanket git staging so parallel sessions cannot commit each other's
# work: git add -A / --all / -u / . and git commit -a / -am. Sessions stage the
# explicit paths they changed.
#
# Off-switch for solo users: "surgicalStaging": false in the plugin config. An
# unusable config (unparseable, wrong shape, or jq missing) keeps the guard ON
# and switches the deny reason to the config-invalid branch — failing strict
# here only annoys, while the config may well already carry the off-switch.
#
# Matching happens in COMMAND POSITION only, with the same stripper
# hooks/long-running-as-unit.sh uses: the awk block drops heredoc bodies, quoted
# strings and comments, splits the rest at shell operators and strips harmless
# prefixes (VAR=, sudo, env, nohup, then/do/else, a leading path), so `echo "git
# add -A"`, `grep 'git add -A' docs/` and a commit message that mentions it are
# not commands and are left alone — while `git add -A`, `cd x && git add .` and
# `git commit -am x` still deny.
# What the stripper cannot see (deliberate; it is a stripper, not a shell parser):
#   - anything inside quotes, so `bash -lc 'git add -A'` is NOT matched;
#   - a `<<` inside a quoted string turns on heredoc mode and the rest is dropped;
#   - a blanket stage inside a script, alias or function the hook cannot read.
# Without jq the command cannot be lifted out of the payload at all, so that path
# keeps the old match-anywhere behaviour rather than going dark — loud over silent.
# ponytail: a stripper instead of a parser, and the list above is the price.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CHECK="$PLUGIN_ROOT/scripts/config-check.sh"

REASON="middle-management plugin: blanket git staging is blocked so parallel sessions cannot commit each other's work. Stage explicit paths: git add <file> ... — working solo? set surgicalStaging to false via /middle-management-setup."

RC=0; bash "$CHECK" validate || RC=$?
case "$RC" in
  0) jq -e '.surgicalStaging == false' "$(bash "$CHECK" file)" >/dev/null 2>&1 && exit 0 ;;
  1|3) REASON="middle-management plugin: blanket git staging is blocked (your middle-management config is invalid, so protection is forced ON — fix it with /middle-management-setup). Stage explicit paths: git add <file> ..." ;;
esac

INPUT="$(cat)"
AT='^'                    # command position — one stripped command per line (see the header)
if command -v jq >/dev/null 2>&1; then
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null | awk '
BEGIN {
  q    = sprintf("%c", 39)                       # single quote, unquotable inline
  HDRE = "<<-?[ \t]*[" q "\"A-Za-z_][" q "\"A-Za-z0-9_]*"
  ASG  = "^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]*"
  PRE  = "^(sudo|env|nohup|time|nice|exec|command|then|do|else|elif|if|while|until|!)([ \t]+|$)"
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
  out = ""                                       # st: 0 plain, 1 in q, 2 in "
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
  gsub(/[0-9]*[<>]&[0-9-]*/, " ", txt)           # 2>&1 / >&2 are redirections, not operators
  gsub(/&>>?/, " ", txt)
  gsub(/[;|&(){}`]/, "\n", txt)                  # one command per line
  n = split(txt, seg, "\n")
  for (i = 1; i <= n; i++) {
    s = seg[i]; sub(/^[ \t]+/, "", s)
    while (1) {
      if (s ~ ASG) { sub(ASG, "", s); continue }                 # VAR=x git add -A
      if (s ~ PRE) { sub(/^[^ \t]+[ \t]*/, "", s); continue }    # sudo / then / do …
      if (s ~ /^[^ \t]*\//) { sub(/^[^ \t]*\//, "", s); continue }   # /usr/bin/git
      break
    }
    print s
  }
}
' 2>/dev/null)"
else
  # No jq: match the raw payload rather than going dark. Quotes and commas
  # become spaces so the regex still sees command words at a word boundary —
  # and without the command itself there is no command position to anchor to.
  CMD="$(printf '%s' "$INPUT" | tr '",' '  ')"
  AT=''
fi

if printf '%s' "$CMD" | grep -qE "${AT}git([^|;&]*[[:space:]])?add([[:space:]]+[^|;&]*)?[[:space:]](-A|--all|-u)([[:space:]]|$)|${AT}git([^|;&]*[[:space:]])?add[[:space:]]+\.([[:space:]]|$|;)|${AT}git([^|;&]*[[:space:]])?commit[[:space:]]+-[a-zA-Z]*a"; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$REASON"
fi
exit 0
