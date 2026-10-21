---
description: Show and edit the middle-management config — protected checkouts, staging protection, board path, the off-keyboard channel to the user and its fallback; optionally install the stuck-coordinator heartbeat, the lane reaper, the headless morning ritual or the T3 morning coordinator, the T3 Code watcher, the guard canary and the PR review runner
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
  "notifyFallbackCommand": "",
  "sessionLog": "/abs/path/to/logs/session-log.md",
  "longRunningAsUnit": false,
  "reviewLoopGate": false,
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
  ],
  "scopes": [
    { "name": "ff", "root": "/abs/path/project", "board": "/abs/path/ff-board.md" }
  ],
  "scopeMode": "per-root",
  "t3TokenFile": "~/.config/t3-threads/token",
  "t3Url": "http://127.0.0.1:8470",
  "onLimitCommand": "",
  "userName": "user",
  "okBy": "user",
  "remindAfterHours": 2,
  "remindWindow": "08:00-22:00",
  "pageCommand": "",
  "workPackagesGate": true,
  "morningTakeover": { "allowed": false, "okBy": "" },
  "morningTaskUrlFile": "~/.config/t3-threads/morning-task-url",
  "morningWaitUntil": "09:30",
  "morningRoot": "/abs/path/project",
  "replyTimestamp": false,
  "intentCheck": false,
  "intentCheckVerbs": "",
  "prReview": { "repos": ["owner/repo"], "authors": ["login"], "model": "opus",
                "securityModel": "fable", "approve": false, "reviewerName": "Mike", "maxRounds": 4 }
}
```

`name`, `root` and `base` are required per entry; `install`, `serve` and
`worktreeDir` are optional. `name`, `root`, `board` are required per scope entry.
In `prReview`, `repos` and `authors` are required for the runner to do anything (an empty
list = it reviews nothing); the other keys default as shown. Every top-level key except `protectedCheckouts` is
optional and has the default shown above; write only the ones the user decides
on, and leave the rest out.

## Step 1 — show the current state first

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG="$(bash "$CHECK" file)"; echo "config file: $CFG"
bash "$CHECK" validate; echo "validate status: $?"
[ -f "$CFG" ] && cat "$CFG"
LOG="$(bash "$CHECK" session-log)"; CHOSEN=$?
echo "session log: $LOG ($([ "$CHOSEN" -eq 0 ] && echo configured || echo default), $([ -f "$LOG" ] && echo exists || echo "does not exist yet"))"
CFG_DIR="$(bash "$CHECK" dir)"
jq -r '.scopes[]? | [.name, .root, .board] | @tsv' "$CFG" 2>/dev/null | while IFS=$'\t' read -r n r b; do
  m="$CFG_DIR/state/scopes/$n/orchestrator"
  echo "scope $n: root $r ($([ -d "$r" ] && echo exists || echo MISSING)), board $b ($([ -f "$b" ] && echo exists || echo "does not exist yet")), seat $m ($([ -s "$m" ] && echo "held by $(head -1 "$m")" || echo free))"
done
```

Status codes: `0` valid · `1` invalid (unparseable or wrong shape) · `2` no
config file yet · `3` jq is not installed.

On status `3`, stop here: tell the user the plugin needs `jq` and that setup
cannot validate anything without it.

Otherwise report to the user, in plain text: the config path, the status, and —
for each configured checkout — name, root, base, install command, and the
effective worktree directory (the configured `worktreeDir`, or the sibling
default `<parent of root>/.worktrees-<name>`). Also report the board path,
whether `surgicalStaging` is on, and the session-log line the block printed —
its path, whether it was configured or defaulted, and whether the file is
there. Per scope (README, "Scopes"): its name, root (exists?), board (exists?),
seat marker and current holder, as the `scope` lines print them (`/orchestrator
status` only covers the caller's own scope). With no config yet, say "none yet"
instead of inventing defaults.

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

9b. **Fallback alarm route.** Ask for a second command that reaches the user when the first one
    fails (another bot, a mail, a second chat), same contract. It becomes `notifyFallbackCommand`;
    `unit-failure-alarm.sh` runs it only when `notifyCommand` is missing or fails. Ask this BEFORE
    steps 5-10: each of them rewrites the alarm unit, and an alarm that fires before the key exists
    has no second route. Omit the key when there is none.

10. **Session log.** Show the path step 1 resolved and ask only whether the user
    wants a different one — Enter keeps it. Every session's wrap appends its
    entry there, and the coordinator's tab list plus the stale-seat takeover
    read it back (README, "The session log"). Write `sessionLog` **only when the
    user names a different path**: an unchanged answer must leave the config
    byte-identical, because the default is what every machine without the key
    already uses. `~` is allowed in the value; the path must be absolute — a
    relative one is rejected as invalid config, since it names a different file
    from every directory.

11. **Long-runners as units** (Linux with systemd only). Ask whether hand-started
    dev servers and heavy builds should be rewritten into `wt run` / `wt cap`
    automatically. Yes means `longRunningAsUnit: true`; the default is `false` and
    the hook then exits without doing anything. Explain what it costs: a matched
    command is rewritten in place, and a dev server inside a compound command
    (`cd x && npm run dev`) is refused with the replacement line to copy.

12. **Review gate.** Ask whether plans and handoff docs should be held back until
    the `review-loop` skill ran on them in the same session. Yes means
    `reviewLoopGate: true`; the default is `false` and the hook then exits without
    doing anything. Explain what it costs: ExitPlanMode with a plan of 900+
    characters and a Write to any `<YYYY-MM-DD>_handoff-*.md` file are denied
    until the skill's marker is under an hour old, so a session drafts in its
    scratch dir, runs the loop, then writes the file.

13. **Scopes (optional).** Ask whether a project on this machine needs its own,
    independent coordinator (own seat, own board); most machines need none. Per
    scope: `root` = the project directory, canonical via `cd "<path>" && pwd -P`,
    must exist, must differ from every other root (nesting is fine, the longest
    root wins); `name` = basename of the root unless the user picks one (letters,
    digits, `-`, `_`; not `default`; unique); `board` = absolute path, required;
    offer to create a missing board file with a title line. Where the headless ritual
    is installed, re-run step 7 afterwards so its copy gets `scope.py`. Explain the rule in
    two sentences: a session belongs to the scope of the directory it was started
    in (a linked worktree counts as the same subpath of its main checkout), every
    other session to the scope `default`; a scope gets a coordinator only when one
    of its sessions runs `/orchestrator claim`.
    Before adding, editing, nesting, removing or renaming any scope, list every
    held seat (default and named, from step 1) whose holder's start dir would
    resolve to a DIFFERENT scope after the change, and every seat of a scope being
    removed or renamed; tell the user to release those seats first
    (`/orchestrator release` in the holder). If they do not, the change still
    works (the old scope's sessions may `claim` the seat or `release <id>` it),
    but the holder keeps believing it coordinates until its next message. A
    removed or renamed scope leaves `<config dir>/state/scopes/<old>/` behind:
    inert once its seat is released; an alarmed heartbeat episode in it never
    gets its closing alarm; the user may delete the directory then (re-adding the
    old name would otherwise revive it).

14. **Scope mode (optional).** `scopeMode: "per-root"` makes every project root its own
    scope (own seat, sidecar, topics file and watcher pass) and drops the catch-all
    `default`: a session outside every claimed root runs standalone. Explicit `scopes`
    roots still win. Switching it on moves the default seat of a root that is not listed
    to `<config dir>/state/scopes/<basename>-<6 hex>/`, so list the held seats first (as
    in item 13) and offer to keep a root's seat where it is by adding it to `scopes`.

15. **Follow-through** (README, "Follow-through"). Ask for `userName` (the name the user
    appears under in "waits on", e.g. their first name; without it only "user" counts),
    `okBy` (who gives the final OK, default the user), `remindAfterHours` (2) and
    `remindWindow` ("08:00-22:00"), and `pageCommand`: a command that gets a
    pathfinder-schema `questions.json` path as `$1` and prints the page link as its last
    line (without it, more than three due questions go out as one inline digest).

16. **T3 Code** (only where sessions run in T3 Code threads). `t3Url`, the T3 server the
    watcher and `t3-token.sh` talk to: write `http://127.0.0.1:<port>` with the port of this
    box's T3 server (`$T3CODE_PORT` inside a T3 thread; unset = `8470`), or the URL the user
    names when the server listens elsewhere (unset key = that loopback default). `t3TokenFile`
    (default `~/.config/t3-threads/token`, mode 600) and `onLimitCommand` (optional, run once
    per usage-limit episode with the limited thread ids as arguments; output is dropped).
    Then offer step 8.

16b. **Morning coordinator in T3 Code** (README, "Morning coordinator in T3 Code"; only with T3
    Code). Ask whether a fresh coordinator thread should take over each weekday morning. Yes means:
    `morningTakeover: {"allowed": true, "okBy": "<the user's name, today's date>"}`, written ONLY
    when the user says so in this conversation, in their words: this key IS their standing word that
    the morning thread may take the seat of an asleep coordinator without asking. Then
    `morningWaitUntil` (latest time the trigger waits out a usage limit, default `09:30`),
    `morningTaskUrlFile` (only for another path than the default) and, with `scopes` or
    `scopeMode`, `morningRoot` = the folder of the T3 project the morning task runs in (required
    with `per-root`). Then offer step 7b instead of step 7.

17. **Work-packages gate.** `workPackagesGate` (default `true`): a sub-agent prompt
    without a `Report file:` line is refused (README, "Sub-agents"). `false` switches the
    gate and the sub-agent report check off.

18. **Optional prompt hooks** (README, "Optional prompt hooks"), both off by default.
    `replyTimestamp: true` hands every session the literal `[HH:MM]` prefix for its reply (useful
    with many parallel sessions; a house rule of the user then says "start every reply with it").
    `intentCheck: true` puts an intent reminder in front of prompts that read like a work order;
    `intentCheckVerbs` (a case-insensitive extended regex) replaces the built-in English and German
    verb list. Before switching either on, ask whether the same hook is already wired in the user's
    `settings.json`: then it would fire twice, so that entry goes first.

19. **Morning ritual fill file** (README, "Morning ritual: the local fill file"). Offer to create
    `<config dir>/morning-ritual.local.md` with the user's answers for the ritual's CUSTOMIZE steps
    (where the team talks, which repos and branch pairs, board block sections, how the day plan
    reaches the phone). Names and paths of secret files only, never their values.

20. **PR review runner** (README "Contributing and releases"; only on the one machine that reviews
    and merges the pull requests of an infra repo). `prReview.repos`: the `owner/name` repos it
    watches. `prReview.authors`: the GitHub logins whose pull requests it reviews and may merge
    (the allowlist, required: a fork or anyone else gets one "not reviewed" notice and nothing
    more). `model` (`opus`) and `securityModel` (`fable`, used when the diff touches
    `plugins/*/hooks/**` or a path with `guard` in it), `reviewerName` (`Mike`), `maxRounds` (4,
    then the PR waits for `userName`). `approve` stays `false` while the runner's `gh` login is the
    PR authors' own account (GitHub refuses to approve your own PR; the verdict is then a review
    comment); `true` once it has its own account. Then offer step 10.

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
# With scopes: every root must exist and resolve to its own scope (validate cannot stat paths).
scopes_ok() {
  jq -r '.scopes[]? | [.name, .root] | @tsv' "$CFG" | while IFS=$'\t' read -r n r; do
    [ -d "$r" ] && [ "$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/scope.py" of "$r" | cut -f1)" = "$n" ] \
      || { echo "scope $n: FAILED (root missing, or it resolves to another scope)"; exit 1; }
  done
}
if bash "$CHECK" validate && scopes_ok; then
  rm -f "$CFG.bak"; echo "written and valid: $CFG"
elif [ -f "$CFG.bak" ]; then
  mv "$CFG.bak" "$CFG"; echo "invalid — previous config restored, nothing changed"
else
  rm -f "$CFG"; echo "invalid — no config written"
fi
```

If validation failed, show the user the JSON you tried to write and what the
schema requires, then correct it and run the block again.

A `scope <name>: FAILED` line means a scope root is missing or resolves to another
scope (a longer root shadows it); the block then restores the backup exactly as for
an invalid config. Fix the root and run the block again.

## Step 4 — summarise

Tell the user what is protected now: per checkout the name, root, base and
effective worktree directory; whether blanket staging is blocked; the board
path; per scope its root, board and seat marker
(`<config dir>/state/scopes/<name>/orchestrator`), and that 0.10.0 sessions pick
a new scope up on their next message, older-version sessions only after a
restart. Add the two operational facts: implementation work goes into a worktree
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
silently — then arms the timer. `scripts/copy-set.sh` copies the set named in
`scripts/copy-sets.json` (the one list of what each copy dir holds; the poke
prompt only when it is absent):

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG_DIR="$(bash "$CHECK" dir)"; HB="$CFG_DIR/middle-management-heartbeat"; UNITS="$HOME/.config/systemd/user"
mkdir -p "$UNITS"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/copy-set.sh" middle-management-heartbeat || exit 1
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
CUSTOMIZE marks; this copy survives plugin updates); the scripts are refreshed
by the plugin itself at the first session start after an update (README
"Contributing and releases"), so this step is re-run only when the CHANGELOG
says so; and
`cat "$(bash "$CHECK" dir)/state/orch-heartbeat/last-tick"` answers "is it
still armed" — older than 15 minutes means it is not running. Offer a test
alarm and run it ONLY when the user says yes, because it reaches their phone:

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"; CFG="$(bash "$CHECK" file)"
MSG="middle-management heartbeat: test alarm"
printf '%s\n' "$MSG" | sh -c "$(jq -r .notifyCommand "$CFG")" notify "$MSG"
```

**Keep-warm rides on the same timer.** Every tick also looks at ALL live sessions
(`peer-state.py`, copied above): one that has not wrapped, has been idle 45 to 55
minutes and either ends on an open question or carries a hold file
`<config dir>/state/keep-warm/<sessionId>` gets one peer message from `keepwarm`
that reads `KEEPWARM PING (automatic, not from your user, not an answer). Do
nothing. Reply with exactly: ok`. That turn reads the prompt cache for a tenth of
its price and keeps it warm for another hour, so the answer, when it comes, does
not cost the session its whole context again. At most 3 pings per wait phase
(about 2.5 h), then it goes cold; the count starts over once the session moves.
Never a session parked on a permission prompt. Tell the user the two switches:
`touch <config dir>/state/keep-warm/<sessionId>` holds a session warm that has no
detected question, and `touch <config dir>/state/keep-warm/off` turns keep-warm
off on this machine. The units run the copies, so a plugin update reaches
keep-warm with the refresh at the next session start.

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
mkdir -p "$UNITS"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/copy-set.sh" middle-management-reaper || exit 1
# The unit inherits no shell environment: the config dir and a PATH that finds git, jq and gh
# have to be written into it.
for u in lane-reaper.service lane-reaper.timer; do
  sed "s|__REAPER_DIR__|$RP|g; s|__CONFIG_DIR__|$CFG_DIR|g; s|__PATH__|$PATH|g" \
    "${CLAUDE_PLUGIN_ROOT}/templates/systemd/$u" > "$UNITS/$u"
done
# the reaper's OnFailure= points at the same alarm unit step 5 installs (its copy is in the set)
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
gets `/wt <name> hold <topic> <hours>`; and the units run the copies, not the plugin,
which the plugin refreshes at the first session start after an update (re-run this step
only when the CHANGELOG says so). Thresholds are the config
keys `reaperMaxHours`, `reaperOwnerlessMinutes` and `reaperDigestHour`.

Disarm with `systemctl --user disable --now lane-reaper.timer`; never run that here
unasked.

## Step 7 — headless morning ritual (optional, Linux only)

A systemd **user** timer (weekdays 07:30) runs `scripts/morning-headless.sh`: when nothing moved
since the last delivered ritual it sends one "no progress since <date>" line and starts no model
at all; otherwise it probes the login in 25 seconds, falls back to a second credential on 429/401
or no answer, runs the `morning-ritual` skill under a budget and a hard timeout, and sends the day
plan (your user's to-do list included) through `notifyCommand`. A failure sends one headline, the
cause and the fix command instead of journal lines. Offer it only when the user wants the ritual
waiting on their phone before they sit down; otherwise skip this step and say so.

Preconditions — the same four as step 5 plus `claude` and `timeout` on this PATH. Without a
`notifyCommand` it refuses to run at all (nothing could reach anyone), so stop there.

Ask two things: whether the account may fall back to a second credential when its own login is
rate-limited — if yes, the PATH of a mode-600 file holding `ANTHROPIC_API_KEY=…` or
`CLAUDE_CODE_OAUTH_TOKEN=…` (the user fills it themselves; never read it, never print it); and
whether the run may use tools without asking (`MM_MORNING_PERMISSION_MODE`, README "Headless
morning ritual"). The day plan itself needs none (it is the run's final message), but the ritual's
reads (git, gh, open-items.py) are refused unattended unless the user's settings allow them.

Install — copies the runner and its helpers OUT of the plugin, for the same reason as step 5:

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG_DIR="$(bash "$CHECK" dir)"; MR="$CFG_DIR/middle-management-morning"; UNITS="$HOME/.config/systemd/user"
FB=""   # the fallback file path the user named, or empty
mkdir -p "$UNITS"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/copy-set.sh" middle-management-morning || exit 1
for u in orch-morning-ritual.service orch-morning-ritual.timer; do
  sed "s|__MORNING_DIR__|$MR|g; s|__CONFIG_DIR__|$CFG_DIR|g; s|__PATH__|$PATH|g; s|__FALLBACK_ENV__|$FB|g" \
    "${CLAUDE_PLUGIN_ROOT}/templates/systemd/$u" > "$UNITS/$u"
done
sed "s|__HEARTBEAT_DIR__|$MR|g; s|__CONFIG_DIR__|$CFG_DIR|g" \
  "${CLAUDE_PLUGIN_ROOT}/templates/systemd/unit-failure-alarm@.service" > "$UNITS/unit-failure-alarm@.service"
systemctl --user daemon-reload && systemctl --user enable --now orch-morning-ritual.timer
systemctl --user list-timers orch-morning-ritual.timer --no-pager
```

Then tell the user, in plain text: budget, timeout, model and permission mode are
`Environment=MM_MORNING_*` lines in `~/.config/systemd/user/orch-morning-ritual.service` (names in
the header of the runner); a test run is `systemctl --user start orch-morning-ritual.service` and
reaches their phone; the copy is refreshed at the first session start after a plugin update
(re-run this step only when the CHANGELOG says so). Disarm with
`systemctl --user disable --now orch-morning-ritual.timer`; never run that here unasked.

## Step 7b — morning coordinator in T3 Code (optional, Linux only, only with T3 Code)

Instead of step 7, never both: the headless ritual and the morning thread would act at the same
time (disable the other's timer in the same step). Needs `morningTakeover` from step 2, item 16b,
and the T3 watcher (step 8), which keeps the night coordinator asleep while the claim is pending.

Preconditions: the four of step 5, plus `curl`, `claude` and `timeout` on this PATH.

**1. The webhook task** — only a T3 thread can create it, so do it in THIS session when it runs in
T3 (`T3CODE_HOME` set), else ask the user to paste the call into a T3 thread of the project the
morning thread should run in. `schedule_task` with:

- `schedule`: `{"type": "webhook", "maxDeliveryAgeMinutes": 120}` (a request the relay held longer,
  e.g. overnight while T3 was offline, starts nothing);
- `bindToCurrentThread`: `false` (each request = a fresh top-level thread; `true` would post every
  morning into the thread that created the task);
- `title`: `Morning coordinator`;
- `prompt`, exactly this, with no `{{…}}` placeholder so the URL can start nothing else:

  ```text
  Morning coordinator run, started by the middle-management morning trigger. Load the
  middle-management:morning-ritual skill and follow its section "The morning thread": claim the
  seat with the morning route (t3_thread_list for your currentThreadId, then /orchestrator claim
  --thread <currentThreadId> --morning), create your report task and run t3-bind, settle the
  predecessor the claim names (delete its report task; never t3_thread_send it), run the ritual's
  steps 1-7, then stop and wait for the user in this thread. If the claim is refused, say what it
  printed and wait for the user.
  ```

The answer carries `webhookUrl`. Store it without printing it or putting it in argv (the same rule as
the report URL): the user pastes it, or you write it from the tool result straight into the file:

```bash
F="$HOME/.config/t3-threads/morning-task-url"   # or the morningTaskUrlFile the user chose
mkdir -p "$(dirname "$F")" && ( umask 077; cat > "$F" ) && chmod 600 "$F"   # URL on stdin
```

Model and runtime of the morning thread are inherited from the thread that created the task; to
change them later: `update_scheduled_task`.

**2. Units** — copies the trigger and its helpers OUT of the plugin, for the same reason as step 5.
Ask for the trigger time (default `Mon..Fri 07:30`) and the watchdog time (default
`Mon..Fri 08:15`, after the ritual would be done; systemd `OnCalendar=` syntax):

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG_DIR="$(bash "$CHECK" dir)"; MR="$CFG_DIR/middle-management-morning"; UNITS="$HOME/.config/systemd/user"
AT="Mon..Fri 07:30"; CHK="Mon..Fri 08:15"   # what the user chose
mkdir -p "$UNITS"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/copy-set.sh" middle-management-morning || exit 1
for u in orch-morning-t3.service orch-morning-t3.timer orch-morning-watchdog.service orch-morning-watchdog.timer; do
  sed "s|__MORNING_DIR__|$MR|g; s|__CONFIG_DIR__|$CFG_DIR|g; s|__PATH__|$PATH|g; s|__MORNING_TIME__|$AT|g; s|__CHECK_TIME__|$CHK|g" \
    "${CLAUDE_PLUGIN_ROOT}/templates/systemd/$u" > "$UNITS/$u"
done
sed "s|__HEARTBEAT_DIR__|$MR|g; s|__CONFIG_DIR__|$CFG_DIR|g" \
  "${CLAUDE_PLUGIN_ROOT}/templates/systemd/unit-failure-alarm@.service" > "$UNITS/unit-failure-alarm@.service"
systemctl --user daemon-reload
systemctl --user disable --now orch-morning-ritual.timer 2>/dev/null   # the headless ritual, if it was armed
systemctl --user enable --now orch-morning-t3.timer orch-morning-watchdog.timer
systemctl --user list-timers 'orch-morning-*' --no-pager
```

A `morningWaitUntil` later than two hours after the trigger time needs a longer
`TimeoutStartSec=` in `orch-morning-t3.service`. Then tell the user, in plain text: a test is
`systemctl --user start orch-morning-t3.service` and opens a real morning thread in T3 (offer it,
run it only on their yes); holidays are not skipped (disarm with
`systemctl --user disable --now orch-morning-t3.timer orch-morning-watchdog.timer`, never run that
here unasked); the copy is refreshed at the first session start after a plugin update (re-run
this step only when the CHANGELOG says so).

## Step 8: T3 Code watcher (optional, Linux only, only with T3 Code)

`scripts/t3-watch.py` is a systemd **user** timer (every 10 minutes, no model): it reads T3's
thread list and notifies on usage limits, clicks pending >10 min, stuck runs, lost reports, an
open handover and a folder without coordinator, retries a limited coordinator with `Keepalive`,
and runs the topics tick (table, reminders, daily digest). Offer it when sessions run in T3 Code
threads or the follow-through reminders are wanted; otherwise skip this step and say so.

Preconditions: the four of step 5, plus `curl`, and `claude` on this PATH (the limit probe).

Token: keep or mint the bearer token the watcher reads (`t3TokenFile`), checked against the
server in `t3Url` (step 16). It never prints the token; re-run it after every `t3 update`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/t3-token.sh"
```

Install: copies the scripts OUT of the plugin, for the same reason as step 5:

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG_DIR="$(bash "$CHECK" dir)"; TW="$CFG_DIR/middle-management-t3watch"; UNITS="$HOME/.config/systemd/user"
mkdir -p "$UNITS"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/copy-set.sh" middle-management-t3watch || exit 1
for u in t3-watch.service t3-watch.timer; do
  sed "s|__T3WATCH_DIR__|$TW|g; s|__CONFIG_DIR__|$CFG_DIR|g; s|__PATH__|$PATH|g" \
    "${CLAUDE_PLUGIN_ROOT}/templates/systemd/$u" > "$UNITS/$u"
done
sed "s|__HEARTBEAT_DIR__|$TW|g; s|__CONFIG_DIR__|$CFG_DIR|g" \
  "${CLAUDE_PLUGIN_ROOT}/templates/systemd/unit-failure-alarm@.service" > "$UNITS/unit-failure-alarm@.service"
systemctl --user daemon-reload && systemctl --user enable --now t3-watch.timer
systemctl --user list-timers t3-watch.timer --no-pager
python3 "$TW/t3-watch.py" --dry-run
```

The dry run prints what a tick would send and sends nothing. Tell the user, in plain text: post
counts per thread and day are `t3-watch.py --stats`; the copy is refreshed at the first session
start after a plugin update (re-run this step only when the CHANGELOG says so). Disarm with
`systemctl --user disable --now t3-watch.timer`; never run that here unasked.

## Step 9 — guard canary (optional, Linux only)

`scripts/guard-canary.sh` is a systemd **user** timer (hourly, no model): it alarms when the
plugin's guards are no longer live (config missing or invalid, plugin disabled, hooks not
registered, the same hooks wired twice in `settings.json`, a direct deny probe that does not deny),
and once a day, from 09:00, it runs an end-to-end probe: a headless `claude -p` (haiku, then once
on sonnet when haiku made no call) must try a blocked edit and a blocked blanket staging and get
the plugin's own deny text back. Offer it on machines where the guards matter (several sessions,
protected checkouts); otherwise skip this step and say so.

Preconditions: the four of step 5, plus `git`, `timeout` and `claude` on this PATH. The end-to-end
probe costs two small model calls a day and runs with `--permission-mode bypassPermissions` and
one tool, in the first protected checkout and in a throwaway repo under the canary's state dir.

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG_DIR="$(bash "$CHECK" dir)"; GC="$CFG_DIR/middle-management-canary"; UNITS="$HOME/.config/systemd/user"
mkdir -p "$UNITS"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/copy-set.sh" middle-management-canary || exit 1
for u in mm-guard-canary.service mm-guard-canary.timer; do
  sed "s|__CANARY_DIR__|$GC|g; s|__CONFIG_DIR__|$CFG_DIR|g; s|__PATH__|$PATH|g" \
    "${CLAUDE_PLUGIN_ROOT}/templates/systemd/$u" > "$UNITS/$u"
done
sed "s|__HEARTBEAT_DIR__|$GC|g; s|__CONFIG_DIR__|$CFG_DIR|g" \
  "${CLAUDE_PLUGIN_ROOT}/templates/systemd/unit-failure-alarm@.service" > "$UNITS/unit-failure-alarm@.service"
systemctl --user daemon-reload && systemctl --user enable --now mm-guard-canary.timer
MM_CANARY_NO_E2E=1 bash "$GC/guard-canary.sh"
```

The last line runs the static checks once, without the model probe. Tell the user: a failure
reaches them through the alarm (with its fallback route); `<config dir>/state/guard-canary/` keeps
the end-to-end streams for a week; the copy is refreshed at the first session start after a plugin
update (re-run this step only when the CHANGELOG says so). Disarm with
`systemctl --user disable --now mm-guard-canary.timer`; never run that here unasked.

## Step 10 — PR review runner (optional, Linux only)

`scripts/pr-review-watch.sh` is a systemd **user** timer (every 15 minutes): for every open pull
request of an allowlisted author in `prReview.repos` with a head it has not reviewed yet, it checks
the version gate (a touched `plugins/<p>/` needs a higher `plugin.json` version than the base
branch), runs `tests/run.sh`, runs a headless review with read-only tools, posts one review, and
merges the PR when the verdict is `CLEAN`, the tests are green and the gate holds. Every merge, every
round with findings and every error reaches the user through `notifyCommand`. Offer it only on the
one machine that reviews an infra repo (README "Contributing and releases"); otherwise skip this
step and say so.

Preconditions: the four of step 5, plus `gh`, `git`, `claude`, `timeout` and `flock` on this PATH,
`prReview.repos` and `prReview.authors` from step 2 item 20, and a `gh` login that can review and
merge in those repos (the unit runs as this user and uses that login):

```bash
for c in gh git claude timeout flock; do command -v "$c" >/dev/null && echo "$c: ok" || echo "NO $c on PATH"; done
gh auth status 2>&1 | head -3
```

Tell the user before installing: the first tick reviews every open pull request of an allowlisted
author, and merges the clean ones. Then:

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG_DIR="$(bash "$CHECK" dir)"; PR="$CFG_DIR/middle-management-prreview"; UNITS="$HOME/.config/systemd/user"
mkdir -p "$UNITS"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/copy-set.sh" middle-management-prreview || exit 1
for u in mm-pr-review.service mm-pr-review.timer; do
  sed "s|__PRREVIEW_DIR__|$PR|g; s|__CONFIG_DIR__|$CFG_DIR|g; s|__PATH__|$PATH|g" \
    "${CLAUDE_PLUGIN_ROOT}/templates/systemd/$u" > "$UNITS/$u"
done
sed "s|__HEARTBEAT_DIR__|$PR|g; s|__CONFIG_DIR__|$CFG_DIR|g" \
  "${CLAUDE_PLUGIN_ROOT}/templates/systemd/unit-failure-alarm@.service" > "$UNITS/unit-failure-alarm@.service"
systemctl --user daemon-reload && systemctl --user enable --now mm-pr-review.timer
systemctl --user list-timers mm-pr-review.timer --no-pager
```

Then tell the user, in plain text: state per pull request lives in
`<config dir>/state/pr-review/<owner>_<repo>/<number>.json`; a pull request that reached
`maxRounds` with findings is not reviewed again until that file is removed (`rm` it once the
findings are dealt with, and the next tick starts over at round 1); test and review time limits are
`Environment=MM_PR_REVIEW_TESTS_MIN=` / `MM_PR_REVIEW_TIMEOUT_MIN=` lines in
`~/.config/systemd/user/mm-pr-review.service` (defaults 15 / 20 minutes); the copy is refreshed at
the first session start after a plugin update (re-run this step only when the CHANGELOG says so).
Disarm with `systemctl --user disable --now mm-pr-review.timer`; never run that here unasked.
