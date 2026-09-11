---
description: Show and edit the middle-management config — protected checkouts, staging protection, board path, the off-keyboard channel to the user; optionally install the stuck-coordinator heartbeat and the lane reaper
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
---

# middle-management setup

Show the user their current configuration, interview them about the changes they
want, then write the file back and validate it. The config is one JSON file that
arms the worktree guard, the `/wt` helper, the blanket-staging guard and the
off-keyboard channel the heartbeat, the unit-failure alarm and the coordinator
all send through.

Schema (nothing else is valid):

```json
{
  "board": "/abs/path/to/board.md",
  "surgicalStaging": true,
  "notifyCommand": ". ~/.claude/secrets/telegram.env && curl -sS -m 15 -X POST \"https://api.telegram.org/bot$BOT_TOKEN/sendMessage\" --data-urlencode \"chat_id=$CHAT_ID\" --data-urlencode \"text=$1\"",
  "longRunningAsUnit": false,
  "unitMemoryMax": "3G",
  "capMemoryMax": "5G",
  "maxUnits": 2,
  "reaperMaxHours": 10,
  "reaperOwnerlessMinutes": 30,
  "reaperDigestHour": 7,
  "protectedCheckouts": [
    { "name": "app", "root": "/abs/path/repo", "base": "origin/main",
      "install": "npm install", "serve": "npm run dev",
      "worktreeDir": "/abs/path/.worktrees-app" }
  ]
}
```

`name`, `root` and `base` are required per entry; `install`, `serve` and
`worktreeDir` are optional. Every top-level key except `protectedCheckouts` is
optional and has the default shown above; write only the ones the user decides
on, and leave the rest out.

## Step 1 — show the current state first

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG="$(bash "$CHECK" file)"; echo "config file: $CFG"
bash "$CHECK" validate; echo "validate status: $?"
[ -f "$CFG" ] && cat "$CFG"
```

Status codes: `0` valid · `1` invalid (unparseable or wrong shape) · `2` no
config file yet · `3` jq is not installed.

On status `3`, stop here: tell the user the plugin needs `jq` and that setup
cannot validate anything without it.

Otherwise report to the user, in plain text: the config path, the status, and —
for each configured checkout — name, root, base, install command, and the
effective worktree directory (the configured `worktreeDir`, or the sibling
default `<parent of root>/.worktrees-<name>`). Also report the board path and
whether `surgicalStaging` is on. With no config yet, say "none yet" instead of
inventing defaults.

Done when the user has seen the current state. Never skip this: step 3 rewrites
the whole file, so entries you did not read here would be lost.

## Step 2 — interview

Ask short questions, one topic at a time. **Below ~75% confidence about what the
user wants, ask instead of assuming.** Never scan the filesystem for
repositories; the user names them.

1. **Which checkouts to protect.** Offer the current session's repository as a
   candidate:

   ```bash
   git rev-parse --show-toplevel 2>/dev/null
   ```

   Ask the user to name any further repository paths. Verify each named path and
   use the canonical root it prints:

   ```bash
   git -C "<path>" rev-parse --show-toplevel
   ```

   A path that fails this is not a git repository — say so and ask again.

2. **Name.** Derive it from the basename of the root; it is what the user types
   in `/wt <name> new <topic>` and what the guard's deny message prints. On a
   collision with another entry, append the parent directory's name or ask the
   user for a name.

3. **Base branch.** Detect a candidate, `origin/HEAD` first, current branch as
   the fallback:

   ```bash
   git -C "<root>" symbolic-ref --quiet --short refs/remotes/origin/HEAD
   git -C "<root>" rev-parse --abbrev-ref HEAD
   ```

   Show the candidate and have the user confirm it, because teams often branch
   off an integration branch that `origin/HEAD` does not point at. Write `base`
   explicitly for every entry — there is no default anywhere.

4. **Install command.** Ask for the command that installs dependencies in a
   fresh worktree (for example `npm install`). It runs as `sh -c "<command>"`
   inside the new worktree. Empty means the step is skipped.

5. **Serve command.** Ask for the command that starts that repo's dev server
   (for example `npm run dev`). `/wt <name> run <topic>` then starts it in the
   lane's worktree as a memory-capped systemd unit, which is what makes a lane's
   server visible to the cleanup routines. Omit the key when there is none — a
   caller can always pass a command after `--`.

6. **Worktree directory.** State the default — the sibling directory
   `<parent of root>/.worktrees-<name>` — and ask only whether the user wants a
   different one. Keep it outside the root so the checkout stays clean. Write
   the `worktreeDir` key only for a custom directory.

7. **Staging protection.** Ask: "Do you run several Claude Code sessions in
   parallel on this machine?" Yes means `surgicalStaging: true` (blanket
   `git add -A` and `git commit -a` are blocked so sessions cannot commit each
   other's work); no means `false`. Write the key explicitly.

8. **Board.** Ask for the path of the shared board document the coordinator
   maintains, if the user keeps one. Omit the key when there is none.

9. **Off-keyboard channel.** Ask for a shell command that reaches the user
   (phone, chat). It is the ONE sender on this machine: the heartbeat (step 5),
   the unit-failure alarm, the lane reaper (step 6) AND the coordinator itself run it with the message as
   `$1` and on stdin. Callers pass plain text, so any decoration (a bold first
   line, a parse mode, the fallback to plain when the rich form is rejected)
   belongs inside this command. Tokens belong in a mode-600 env file the command
   sources, never inline — this command shows the config back to the user in
   step 1. The schema block above carries a Telegram example. Omit the key only
   when the user wants neither the heartbeat alarm nor the coordinator's
   off-keyboard asks; step 5 then refuses to arm.

10. **Long-runners as units** (Linux with systemd only). Ask whether hand-started
    dev servers and heavy builds should be rewritten into `wt run` / `wt cap`
    automatically. Yes means `longRunningAsUnit: true`; the default is `false` and
    the hook then exits without doing anything. Explain what it costs: a matched
    command is rewritten in place, and a dev server inside a compound command
    (`cd x && npm run dev`) is refused with the replacement line to copy.

On a re-run, walk the existing entries with the user first: keep, edit or
remove each one, then ask about additions. An entry the user removes is dropped
from the file.

Done when every key you are about to write has either a confirmed value or a
deliberate omission.

## Step 3 — write and validate

`config-check.sh` validates the resolved config path, not an arbitrary file, so
back up, write, validate, and restore the backup if validation fails. Write the
complete file — every entry the user kept plus the new ones.

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG="$(bash "$CHECK" file)"
mkdir -p "$(dirname "$CFG")"
[ -f "$CFG" ] && cp "$CFG" "$CFG.bak"
cat > "$CFG" <<'JSON'
{
  "surgicalStaging": true,
  "protectedCheckouts": [
    { "name": "app", "root": "/abs/path/repo", "base": "origin/main", "install": "npm install" }
  ]
}
JSON
if bash "$CHECK" validate; then
  rm -f "$CFG.bak"; echo "written and valid: $CFG"
elif [ -f "$CFG.bak" ]; then
  mv "$CFG.bak" "$CFG"; echo "invalid — previous config restored, nothing changed"
else
  rm -f "$CFG"; echo "invalid — no config written"
fi
```

If validation failed, show the user the JSON you tried to write and what the
schema requires, then correct it and run the block again.

## Step 4 — summarise

Tell the user what is protected now: per checkout the name, root, base and
effective worktree directory; whether blanket staging is blocked; the board
path. Add the two operational facts: implementation work goes into a worktree
via `/wt <name> new <topic>`, and the config takes effect immediately — the
hooks read it on every run, so no restart is needed.

## Step 5 — heartbeat (optional, Linux only)

The stuck-coordinator heartbeat is a systemd **user** timer: every 10 minutes it
checks whether the coordinator session's last turn got an answer; after 45
minutes of silence it alarms once through `notifyCommand` and pokes the session
over its own socket. What it is a net for and what it cannot see: skill
`middle-management`, section "Recovery after a kill". Offer it only when the
user runs a coordinator session that sits unattended for hours; otherwise skip
this step and say so.

Preconditions — run all four and stop with one plain sentence at the first
that fails:

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"; CFG="$(bash "$CHECK" file)"
systemctl --user --version >/dev/null 2>&1 && echo "systemd user manager: ok" || echo "NO systemd user manager (macOS/launchd is not supported)"
command -v python3 >/dev/null && echo "python3: ok" || echo "NO python3 (the poke sender needs it)"
[ -n "$(jq -r '.notifyCommand // ""' "$CFG" 2>/dev/null)" ] && echo "notifyCommand: set" || echo "NO notifyCommand in $CFG (step 2, item 9)"
echo "linger: $(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)"
```

`linger: no` means the timer dies with the login session — the user runs
`loginctl enable-linger "$USER"` first (it may ask for their password).

Install — copies the heartbeat files OUT of the plugin, because the plugin
cache path changes with every update and a unit pointing there would die
silently — then arms the timer:

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG_DIR="$(bash "$CHECK" dir)"; HB="$CFG_DIR/middle-management-heartbeat"; UNITS="$HOME/.config/systemd/user"
mkdir -p "$HB" "$UNITS"
cp "${CLAUDE_PLUGIN_ROOT}"/scripts/{orch-heartbeat.sh,poke-session.py,unit-failure-alarm.sh} "$HB/"
[ -e "$HB/orch-heartbeat-poke.md" ] || cp "${CLAUDE_PLUGIN_ROOT}/scripts/orch-heartbeat-poke.md" "$HB/"
# The units carry the resolved config dir: the systemd user manager inherits no shell environment,
# so a CLAUDE_CONFIG_DIR set in the shell would otherwise never reach the tick.
for u in orch-heartbeat.timer orch-heartbeat.service unit-failure-alarm@.service; do
  sed "s|__HEARTBEAT_DIR__|$HB|g; s|__CONFIG_DIR__|$CFG_DIR|g" "${CLAUDE_PLUGIN_ROOT}/templates/systemd/$u" > "$UNITS/$u"
done
systemctl --user daemon-reload && systemctl --user enable --now orch-heartbeat.timer
systemctl --user list-timers orch-heartbeat.timer --no-pager
```

Then tell the user, in plain text: the poke prompt to customize is
`$HB/orch-heartbeat-poke.md` (board path, commit convention, alarm line — the
CUSTOMIZE marks; this copy survives plugin updates); **after every plugin update
re-run this step** so the scripts are refreshed; and
`cat "$(bash "$CHECK" dir)/state/orch-heartbeat/last-tick"` answers "is it
still armed" — older than 15 minutes means it is not running. Offer a test
alarm and run it ONLY when the user says yes, because it reaches their phone:

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"; CFG="$(bash "$CHECK" file)"
MSG="middle-management heartbeat: test alarm"
printf '%s\n' "$MSG" | sh -c "$(jq -r .notifyCommand "$CFG")" notify "$MSG"
```

Disarm and uninstall are in the skill; never run them here unasked.

## Step 6 — lane reaper (optional, Linux only)

The lane reaper is a systemd **user** timer: every 30 minutes it reads `wt list` and
stops lane units that have run past `reaperMaxHours` or whose owning session is gone,
removes the worktrees of merged lanes through `wt done`, and lists everything it must
not touch — dirty trees, unpushed commits, lanes whose pull request is not merged. It
never kills a process by pid and never deletes a ref. Offer it only when the user runs
several lanes in parallel; otherwise skip this step and say so.

Preconditions — the same four as step 5, plus `git`. Without a `notifyCommand` the
reaper still runs and still writes its listing; it just cannot tell anyone, so say that
before installing.

Install — copies the reaper, `wt` and `config-check.sh` OUT of the plugin for the same
reason as step 5, then arms the timer:

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG_DIR="$(bash "$CHECK" dir)"; RP="$CFG_DIR/middle-management-reaper"; UNITS="$HOME/.config/systemd/user"
mkdir -p "$RP" "$UNITS"
cp "${CLAUDE_PLUGIN_ROOT}"/scripts/{lane-reaper.sh,wt,config-check.sh} "$RP/"
# The unit inherits no shell environment: the config dir and a PATH that finds git, jq and gh
# have to be written into it.
for u in lane-reaper.service lane-reaper.timer; do
  sed "s|__REAPER_DIR__|$RP|g; s|__CONFIG_DIR__|$CFG_DIR|g; s|__PATH__|$PATH|g" \
    "${CLAUDE_PLUGIN_ROOT}/templates/systemd/$u" > "$UNITS/$u"
done
# the reaper's OnFailure= points at the same alarm unit step 5 installs — written every time,
# so re-running this step after a plugin update really refreshes every copy
cp "${CLAUDE_PLUGIN_ROOT}/scripts/unit-failure-alarm.sh" "$RP/"
sed "s|__HEARTBEAT_DIR__|$RP|g; s|__CONFIG_DIR__|$CFG_DIR|g" \
  "${CLAUDE_PLUGIN_ROOT}/templates/systemd/unit-failure-alarm@.service" > "$UNITS/unit-failure-alarm@.service"
systemctl --user daemon-reload && systemctl --user enable --now lane-reaper.timer
systemctl --user list-timers lane-reaper.timer --no-pager
```

Then show the user one dry run, which acts on nothing:

```bash
bash "$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh" dir)/middle-management-reaper/lane-reaper.sh" --dry-run
```

Tell them, in plain text: the listing lands in `<config dir>/state/wt/reaper-latest.md`
and is where the morning ritual reads what was cleaned up; a lane that must stay up
gets `/wt <name> hold <topic> <hours>`; and **after every plugin update re-run this
step**, because the units run the copies, not the plugin. Thresholds are the config
keys `reaperMaxHours`, `reaperOwnerlessMinutes` and `reaperDigestHour`.

Disarm with `systemctl --user disable --now lane-reaper.timer`; never run that here
unasked.
