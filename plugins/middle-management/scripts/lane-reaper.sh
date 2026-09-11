#!/usr/bin/env bash
# middle-management plugin — OPTIONAL, Linux only. Stops lane units nobody is using any more and
# removes the worktrees of merged lanes; everything it must not touch it LISTS instead.
# Consumers: templates/systemd/lane-reaper.service (started every 30 minutes by
#   lane-reaper.timer); the coordinator by hand; the morning ritual, which reads the listing
#   instead of sweeping the machine itself. Installed by /middle-management-setup step 6 into
#   <config dir>/middle-management-reaper/, next to copies of `wt` and `config-check.sh`.
#
# `wt list` is the only thing it reads — one row per lane, the columns its header declares. For
# EVERY rule every condition must hold, and a valid `wt <name> hold <topic> <hours>` blocks all
# of them:
#   expired    the lane's unit has been up longer than reaperMaxHours (default 10)
#                                                        -> wt <name> stop <topic>
#   ownerless  the unit's owner session has been gone for longer than reaperOwnerlessMinutes
#              (default 30), seen TWICE — the first sighting only writes the stamp. An owner of
#              `-` or an unknown one is never treated as gone.
#                                                        -> wt <name> stop <topic>
#   merged     no unit running, the tree is clean, nothing is unpushed, and the branch is either
#              an ancestor of the base or its pull request is MERGED
#                                                        -> wt <name> done <topic>
#   list only  everything else: dirty trees, unpushed commits, open/closed/absent pull requests,
#              an unknown pr state — listed with the reason, never touched
#   markers    owner/hold/dead files of lanes that no longer exist are deleted
# There is deliberately NO idle rule: judging a lane idle means reading request lines out of its
# server's log, and no plugin can know what those look like. A unit nobody uses is caught by
# reaperMaxHours instead, later but without guessing.
# It never kills a process by pid and never deletes a ref; `wt done` deletes the branch of merged
# work itself, and the tip SHA it prints is carried into the listing.
#
# Squash merges: such a branch is no ancestor of its base, so without `gh` (pr column `-`) the
# lane is listed rather than removed. That is the safe half of the trade.
#
# Output: <config dir>/state/wt/reaper-latest.md, the run before it rotated to
# reaper-previous.md. The configured notifyCommand is called when something was done or when the
# set of listed rows changed — a quiet machine sends nothing. A failed action or a broken
# `wt list` exits non-zero, which the unit's OnFailure= turns into an alarm.
#
# Flags:
#   --dry-run       print what WOULD happen and change nothing: no action, no listing file, no
#                   marker, no dead-<owner> stamp. The second sighting the ownerless rule needs
#                   therefore always comes from a real run.
#   --now <ts|+Nh>  pretend it is that time — the age math only. Anything `date -d` understands,
#                   plus +Nh and +Nm.
#   --only <name>   perform ACTIONS only for that lane (its worktree name, or <checkout>-<lane>);
#                   the listing stays complete. The safety rail for tests.
# Env: MM_REAPER_NO_NOTIFY=1 suppresses the send and prints the message instead.
#      MM_WT points at the `wt` to use (tests); default is the copy beside this script.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WT="${MM_WT:-$HERE/wt}"
CHECK="$HERE/config-check.sh"

fail() { echo "lane-reaper: $*" >&2; exit 1; }
usage() { sed -n '/^# Flags:/,/^# *MM_WT/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
parse_now() {
  local v="$1" n
  case "$v" in
    +*h) n=${v#+}; echo $(( $(date +%s) + ${n%h}*3600 )) ;;
    +*m) n=${v#+}; echo $(( $(date +%s) + ${n%m}*60 )) ;;
    *)   date -d "$v" +%s 2>/dev/null || fail "cannot read --now '$v'" ;;
  esac
}

DRY=0; ONLY=""; NOW=$(date +%s)
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --now)  shift; NOW=$(parse_now "${1:-}") ;;
    --only) shift; ONLY="${1:-}"; [ -n "$ONLY" ] || fail "--only needs a name" ;;
    -h|--help) usage ;;
    *) fail "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

bash "$CHECK" validate || fail "the middle-management config is unusable — run /middle-management-setup"
CFG_FILE="$(bash "$CHECK" file)"
CFG_DIR="$(bash "$CHECK" dir)"
STATE="$CFG_DIR/state/wt"
LATEST="$STATE/reaper-latest.md"
PREV="$STATE/reaper-previous.md"
TTL_SEC=$(( $(jq -r '.reaperMaxHours // 10' "$CFG_FILE") * 3600 ))
DEAD_SEC=$(( $(jq -r '.reaperOwnerlessMinutes // 30' "$CFG_FILE") * 60 ))
NOTIFY="$(jq -r '.notifyCommand // ""' "$CFG_FILE")"
DIGEST_HOUR="$(jq -r '.reaperDigestHour // 7' "$CFG_FILE")"
mkdir -p "$STATE"

RC=0; ACTIONS=(); ROWS=(); KEYS=(); OWNERS_GONE=""
age() { local s=$(( NOW - $1 )); printf '%dh%02dm' $((s/3600)) $(( (s%3600)/60 )); }
epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }    # `-` and junk become 0 = "unknown"
row() { KEYS+=("$1"); shift; local c o=""           # a `|` in a field would break the table
  for c in "$@"; do o="$o| ${c//|//} "; done; ROWS+=("$o|"); }
only_match() { [ -z "$ONLY" ] && return 0; case "$ONLY" in "$1"|"$2") return 0 ;; esac; return 1; }
act() {  # act <lane> <key> <why> -- <cmd...>
  local lane="$1" key="$2" why="$3"; shift 3; [ "${1:-}" = "--" ] && shift
  if ! only_match "$lane" "$key"; then
    row "skip:$key" "skipped" "$key" "$why" "not matched by --only $ONLY"; return 0
  fi
  if [ "$DRY" = 1 ]; then ACTIONS+=("$why → ${*}"); return 0; fi
  local out st=0 tip
  out=$("$@" 2>&1) || st=$?
  case "$st" in
    0) ACTIONS+=("$why → ${*}")
       # once the branch is deleted, the tip SHA wt printed is the only record that the commits
       # can be restored
       tip=$(grep -m1 'tip was' <<<"$out" || true); [ -n "$tip" ] && ACTIONS+=("$tip") || true ;;
    3) # wt refuses to remove a worktree a live process sits in, and names the pids. That is a
       # state to report — with the pids, in the line that gets sent — not a failure to alarm
       # about again every 30 minutes.
       local pids
       pids=$(printf '%s' "$out" | grep -oE 'pid [0-9]+' | head -3 | tr '\n' ' ' || true)
       row "busy-cwd:$key" "listed" "$key" "refused, ${pids:-a process} still works inside $key" \
           "$why — the worktree stays; stop it by explicit pid, never by pattern" ;;
    *) RC=1; ACTIONS+=("FAILED on $key: ${*} → $(printf '%s' "$out" | tail -2 | tr '\n' ' ')") ;;
  esac
  return 0
}
dead_since() {  # owner -> seconds it has been seen gone (0 = first sighting)
  local f="$STATE/dead-$1" t d
  # The stamp carries the REAL time, never --now: a `--dry-run --now +11h` must not be able to
  # leave a future stamp behind, which would switch the rule off for that owner for good.
  if [ ! -f "$f" ]; then [ "$DRY" = 1 ] || date +%s > "$f"; echo 0; return; fi
  t=$(cat "$f" 2>/dev/null || echo "$NOW")
  case "$t" in ''|*[!0-9]*) t=$NOW ;; esac
  d=$(( NOW - t )); [ "$d" -lt 0 ] && d=0
  echo "$d"
}

LIST=$("$WT" list) || fail "'$WT list' failed — nothing can be decided without it"

while IFS= read -r line; do
  case "$line" in '#'*) continue ;; '') continue ;; esac
  # shellcheck disable=SC2086
  set -- $line
  [ $# -eq 12 ] || fail "unexpected row in wt list — refusing to guess its columns: $line"
  CO=$1 LANE=$2 BRANCH=$3 UNIT=$4 OWNER=$5 ALIVE=$6 STARTED=$7 HOLD=${9} STATE_C=${10} MERGED=${11} PR=${12}
  KEY="$CO-$LANE"; ST=$(epoch "$STARTED")
  [ "$ALIVE" = no ] && OWNERS_GONE="$OWNERS_GONE $OWNER"
  if [ "$HOLD" != "-" ] && [ "$(epoch "$HOLD")" -gt "$NOW" ]; then
    row "hold:$KEY" "held" "$KEY" "hold until $HOLD" "every rule waits while a hold is valid"
  elif [ "$UNIT" != "-" ]; then
    if [ "$ST" != 0 ] && [ $(( NOW - ST )) -gt "$TTL_SEC" ]; then
      act "$LANE" "$KEY" "expired: $UNIT up for $(age "$ST")" -- "$WT" "$CO" stop "$LANE"
    elif [ "$ALIVE" = no ] && [ "$(dead_since "$OWNER")" -gt "$DEAD_SEC" ]; then
      act "$LANE" "$KEY" "ownerless: $UNIT, owner $OWNER gone" -- "$WT" "$CO" stop "$LANE"
    else
      row "busy:$KEY" "running" "$KEY" "up $(age "$ST")" "owner $OWNER (alive $ALIVE), $UNIT"
    fi
  elif [ "$PR" = error ]; then
    RC=1; row "prerror:$KEY" "listed" "$KEY" "pull-request state UNKNOWN — gh failed" \
      "alarm raised; an unreadable state is never read as 'nothing merged'"
  elif [ "$STATE_C" != clean ]; then
    row "$STATE_C:$KEY" "listed" "$KEY" "tree is $STATE_C" "branch $BRANCH — nothing is removed while work can be lost"
  elif [ "$MERGED" = yes ] || [ "$PR" = MERGED ]; then
    act "$LANE" "$KEY" "merged: $KEY (branch $BRANCH)" -- "$WT" "$CO" done "$LANE"
  else
    row "keep:$KEY" "listed" "$KEY" "pr $PR, not merged into the base" "branch $BRANCH, owner $OWNER"
  fi
done <<<"$LIST"

# ─── markers of lanes that no longer exist ───────────────────────────────────────────────────
LANEKEYS=" $(printf '%s\n' "$LIST" | awk '!/^#/ && NF>=12 {print $1"-"$2}' | tr '\n' ' ')"
drop_marker() { only_match "$2" "$2" || return 0
  ACTIONS+=("marker cleanup: rm $(basename "$1")"); [ "$DRY" = 1 ] || rm -f "$1"; }
for f in "$STATE"/owner-* "$STATE"/hold-*; do
  [ -e "$f" ] || continue
  k=$(basename "$f"); k=${k#owner-}; k=${k#hold-}
  case "$LANEKEYS" in *" $k "*) continue ;; esac
  drop_marker "$f" "$k"
done
# dead-<owner> is keyed by OWNER, not by lane, and it is the memory of the two-sighting rule: it
# may only go once that owner holds no gone lane any more.
for f in "$STATE"/dead-*; do
  [ -e "$f" ] || continue
  o=$(basename "$f"); o=${o#dead-}
  case " $OWNERS_GONE " in *" $o "*) continue ;; esac
  drop_marker "$f" "$o"
done

# ─── listing, change detection, notification ────────────────────────────────────────────────
LISTING="$(
  echo "# lane-reaper — $(date -d "@$NOW" '+%Y-%m-%d %H:%M')$([ "$DRY" = 1 ] && echo ' (dry-run)')${ONLY:+ · actions restricted to --only }$ONLY"
  echo
  echo "## Actions taken"
  if [ ${#ACTIONS[@]} -eq 0 ]; then echo "none"; else printf -- '- %s\n' "${ACTIONS[@]}"; fi
  echo
  echo "## Listed, not touched"
  if [ ${#ROWS[@]} -eq 0 ]; then echo "none"; else
    echo "| kind | lane | why | detail |"; echo "|---|---|---|---|"; printf '%s\n' "${ROWS[@]}"
  fi
  echo
  echo "<!-- rowkeys: ${KEYS[*]:-} -->"
)"

OLDKEYS=$(sed -n 's/^<!-- rowkeys: \(.*\) -->$/\1/p' "$LATEST" 2>/dev/null || true)
[ -f "$LATEST" ] || OLDKEYS="__first_run__"
CHANGED=0; [ "$OLDKEYS" = "${KEYS[*]:-}" ] || CHANGED=1
# One send a day even when nothing changed: silence must not be the same signal as a dead timer.
# A once-a-day fact, not a minute match — the timer is Persistent=true, so a catch-up run after
# downtime fires late and would miss an exact time.
DAY=$(date -d "@$NOW" +%F); DIGEST=0
[ "$(( 10#$(date -d "@$NOW" +%H) ))" -ge "$DIGEST_HOUR" ] \
  && [ "$(cat "$STATE/digest-last" 2>/dev/null || true)" != "$DAY" ] && DIGEST=1

BODY=()
for a in ${ACTIONS[@]+"${ACTIONS[@]}"}; do BODY+=("$a"); done
BODY+=("listed untouched: ${#ROWS[@]}")
for r in ${ROWS[@]+"${ROWS[@]}"}; do
  BODY+=("· $(awk -F'|' '{gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); print $3" — "$4}' <<<"$r")")
done
MSG="lane reaper: $([ ${#ACTIONS[@]} -eq 0 ] && echo 'no action' || echo "${#ACTIONS[@]} action(s)")$([ "$DIGEST" = 1 ] && echo ' · daily digest')
$(printf '%s\n' "${BODY[@]}" | head -12)
full listing: $LATEST"

if [ "$DRY" = 1 ]; then
  printf '%s\n' "$LISTING"
  echo "--- would notify: $( { [ "${#ACTIONS[@]}" -gt 0 ] || [ "$CHANGED" = 1 ] || [ "$DIGEST" = 1 ]; } && echo yes || echo 'no, nothing changed') ---"
  printf '%s\n' "$MSG"
  exit "$RC"
fi

[ -f "$LATEST" ] && mv -f "$LATEST" "$PREV" || true
printf '%s\n' "$LISTING" > "$LATEST"
[ "$DIGEST" = 1 ] && echo "$DAY" > "$STATE/digest-last" || true
if [ ${#ACTIONS[@]} -gt 0 ] || [ "$CHANGED" = 1 ] || [ "$DIGEST" = 1 ]; then
  if [ "${MM_REAPER_NO_NOTIFY:-0}" = 1 ] || [ -z "$NOTIFY" ]; then
    echo "not sent (no notifyCommand, or suppressed); the message would have been:"; printf '%s\n' "$MSG"
  elif ! printf '%s\n' "$MSG" | sh -c "$NOTIFY" notify "$MSG" >/dev/null 2>&1; then
    echo "lane-reaper: notifyCommand failed" >&2; RC=1
  fi
else
  echo "no change, nothing sent"
fi
exit "$RC"
