# middle-management — a Claude Code plugin for many parallel sessions on one machine

*It doesn't do the work. It makes sure the work gets done.*

Run several Claude Code sessions side by side without them stepping on each other:
exactly **one coordinator** session plans and routes, every other session works and
reports back; implementation happens in **per-topic git worktrees** instead of a shared
checkout; and **blanket git staging** (`git add -A`) is blocked so sessions cannot
commit each other's work. The regime was extracted from a production multi-session
setup; this plugin packages it so installing it is two commands and requires **no
edits to your `settings.json` or `CLAUDE.md`**.

## The picture

![One boss, one middle manager, many workers: you appoint one tab and plan with it; it hands out one task sheet per job; workers do the job in their own copy of the code, report back, and never talk sideways; you can still step in on any worker directly; a hook reminds every tab of its role on every message](docs/overview.svg)

The picture says *middle manager*; the commands say `orchestrator` (`/orchestrator claim`).
Same tab. How the plugin knows who is who (marker file, session registry, hand-over) is
drawn in detail under [How the roles work](#how-the-roles-work).

## Your day with it

![A day with the coordinator, in two lanes: you open one session and appoint today's coordinator, it reports once what today looks like and which sessions it needs, you open those tabs, and your next move only comes when it reports back. The top lane is empty in the second column — between step two and step four there is nothing for you to do.](docs/journey.svg)

*solid grey = you act · solid blue = the coordinator reports to you · dashed outline = nothing for you to do*

1. You open one session and say: "You are today's coordinator. Run the morning ritual."
2. It reports **once**: what today looks like, what it wants to run, and which sessions it needs you to open.
3. You open those tabs — one lane per session. From there it runs by itself: workers build in their own worktrees, review themselves, and report to the coordinator, not to you.
4. Your next move only comes when it reports back: which tabs to close, whether it needs another session, and the one or two things only you can decide.

The empty cell in the top lane is the point: the coordinator cannot open a tab, and that is
the only thing it needs you for.

**Not every job needs a worker tab.** The coordinator can also run work through its own
sub-agents (the Agent tool), and you can tell it to: "do that with sub-agents, no new session".
Interactive worker sessions are for the bigger jobs, where you want to talk to the session
directly while it works, or where the job is large enough that the session should call its
own sub-agents for plan, build, review and report and keep its context for reading their
results. Small, well-specified tasks stay with the coordinator and its sub-agents; a tab is
what you open when a lane is worth a conversation of its own.

## Install

```
/plugin marketplace add manuel-bopp/claude-middle-management
/plugin install middle-management@dr-bopp
```

Then start a new session (or run `/reload-plugins`) so the hooks arm, and run
`/middle-management-setup` once to configure the optional worktree part.

**Installed from `bopp-plugins` before?** The marketplace is now called `dr-bopp`, and a
rename migrates nothing — re-register it once:

```
/plugin uninstall middle-management@bopp-plugins
/plugin marketplace remove bopp-plugins
/plugin marketplace add manuel-bopp/claude-middle-management
/plugin install middle-management@dr-bopp
```

**After every plugin update, re-run `/middle-management-setup` step 5 and step 6** if you
installed the heartbeat or the lane reaper — their units run a copy of the scripts, because the
plugin's own cache path is versioned and goes stale with each update.

### First five minutes

1. Open two Claude Code tabs.
2. First tab: `/orchestrator claim` — it answers `OK: this session (…) is the coordinator`.
3. Second tab: send any message. It now starts with `Session role: WORKER` and the contract
   that goes with it; the first tab's next message starts with `Session role: ORCHESTRATOR`.
4. `/orchestrator status` in either tab names the holder and this session's own id.
5. `/orchestrator release` in the first tab ends the regime — after it both tabs are silent again.

No banner in step 3? The role hook is never silent about a problem (missing `jq`, no session
registry) — if it says nothing at all, the hooks are not armed yet: restart the tab.

## What you get

| Piece | Kind | What it does |
|---|---|---|
| Session roles | UserPromptSubmit hook | Tells every session, on every message, whether it is the ORCHESTRATOR or a WORKER — including the operative rules for that role. Silent when no coordinator exists. |
| `/orchestrator claim\|release\|status` | command | Appoints this session as coordinator (marker file), hands the seat back, or shows who holds it. |
| Worktree guard | PreToolUse hook | Denies direct edits inside configured main checkouts and points to the worktree workflow instead. Dormant until you configure repos. |
| `/wt <name> new\|list\|run\|stop\|hold\|done` | command | Creates/lists/removes per-topic worktrees with the branch based on your configured base branch, deps installed. `done` refuses while the worktree is dirty, unpushed or any live process sits inside it, and deletes the branch (via `update-ref`, recording the tip) once it is merged into the base — a squash-merged branch is kept, since it is no ancestor of the base. |
| `/wt <name> run\|stop <topic>`, `/wt cap` | command (Linux) | Starts the lane's dev server as a memory-capped systemd user unit `wt-<name>-<topic>` and stops it again, waiting for the cgroup to be empty rather than believing "inactive"; `cap` caps one heavy build or test run in the foreground. At most `maxUnits` lane units at a time. |
| `/wt <name> hold\|chown <topic>`, `/wt list` | command | `hold` keeps the reaper off a lane that has to stay up; `chown` hands a lane to another session so it does not go ownerless. `list` is the one view: one parseable row per lane with its unit, owner, uptime, memory, hold, git state and pull-request state. |
| Long-runners as units | PreToolUse hook (optional, Linux) | Rewrites a hand-started `next dev`, `vite`, `<pm> run dev` into `wt run`, and `bun test`, `next build`, `playwright test`, `<pm> run build` into `wt cap`; refuses a dev server inside a compound command with the line to copy. Off unless `longRunningAsUnit: true`. |
| Lane reaper | systemd user timer (optional, Linux) | Every 30 minutes: stops lane units past `reaperMaxHours` or whose owning session is gone, removes the worktree of a merged, clean, pushed lane, and lists everything else with its reason — never killing a process by pid, and never touching a lane that has produced nothing yet. Alarms go through your `notifyCommand`, plus one digest a day so silence cannot mean a dead timer. Installed by setup step 6. |
| Staging guard | PreToolUse hook | Blocks `git add -A` / `git add .` / `git commit -a` so parallel sessions stage only their own files. Off-switch for solo users: `surgicalStaging: false`. |
| `/middle-management-setup` | command | Shows the current config, then interviews you and writes/edits it — with validation. |
| `middle-management` skill | skill | Extended reference: appointment, handover between sessions, troubleshooting. |
| `wrap` skill | skill | The end-of-session routine: touched docs, the session-log entry with its `Session: closed · <id>` marker, open items, the closing lines. The tab list and the stale-seat takeover both read what it writes — see [The session log](#the-session-log). Addressed `/middle-management:wrap`; a personal `~/.claude/skills/wrap` wins the bare `/wrap`. |
| `morning-ritual` skill | skill | The coordinator’s day-opener: messages delta, repo state, wrap audit, board sweep, machine cleanup, day plan. Coordinator sessions only; carries CUSTOMIZE markers for your team’s stack. |
| Heartbeat | systemd user timer (optional, Linux) | Watches the coordinator session: a turn with no answer for 45 minutes → one alarm through your `notifyCommand` and a poke written into the session's own socket (no model call), hourly, giving up after 24 h. Installed by setup step 5. |

## How the roles work

![The session-role flow: one orchestrator claims a marker, the human starts workers manually, work routes through the middle lane, a worker runs its lane through sub-agents and then wraps itself — the wrap writes a three-line closing block and a `- Session: closed · <sessionId>` line into the session log, which peer-state.py --wrapped reads back as the coordinator's tab list; four hooks announce each session's role, and the seat is handed over or released](docs/flow.svg)

<details>
<summary>Key to the numbered badges 1–15 in the picture</summary>

*solid grey = an action · dashed blue = a file read or written · fine dashes = read-only ·
thick = you, by hand · gold = what a finishing session writes down · orange = the seat
changing hands · red = never.*

1. You tell one session it is the coordinator.
2. `claim` writes that session's id into the marker.
3. Four hooks announce the role in every session, on every message — or say nothing when no seat is taken.
4. You start every worker session yourself, by hand. One lane = one session; a new lane gets a fresh session with the model named.
5. The coordinator plans with you and writes a handoff doc.
6. It sends the worker the doc's *path*, never the content — and only to live sessions: a session idle for an hour re-pays its whole context when you wake it.
7. The worker reads the doc off disk.
8. Workers never message each other; anything Worker B needs arrives via the middle lane.
9. The worker reports done or blocked, unprompted — its lane runs through its own sub-agents (plan, build, review, report) and it reads their reports, not their diffs.
10. The coordinator is the sole writer of the board; workers read it.
11. The lane ends with its unit stopped and its worktree gone, and the session wraps itself.
12. The seat is handed over to a fresh tab, or `release`d — best at wrap time, while still warm. An empty marker is a good state.
13. The wrap ends on three lines and nothing after them: the session's name, its topic (both in the chat's language), and the literal `Close this tab.` alone on the last line in every language — never a translation, never both languages, never a near-variant.
14. The same wrap appends `- Session: closed · <sessionId>` to its session-log entry — keyed by id, because session names get recycled.
15. The coordinator runs `peer-state.py --wrapped` and gets the tab list, each row carrying that session's own last line so you find the tab by what is on screen in it. Nobody is woken. The same JSON is what lets `claim` take a stale seat off disk (wrapped **and** the log says completed **and** idle past `MM_STALE_SEAT_MIN`).

</details>

1. Your user tells one session "you are the coordinator"; that session runs
   `/orchestrator claim`, which records its session id in
   `<config-dir>/state/orchestrator`.
2. On every user message, the role hook reads that marker plus Claude Code's live
   session registry and announces the session's role with its contract. Workers talk
   ONLY to the coordinator; the coordinator plans, routes, and does not build.
3. `release` (in the coordinating session) turns the regime off; with no living
   coordinator the hook is silent and every session works standalone. When the
   coordinating session is gone, any session clears the orphaned marker with
   `release <id>` (the id from `status`) — never without it.
4. Terminal fallback without the marker: start a session named `orchestrator`
   (`claude -n orchestrator`) — a living session whose name starts with `orch` counts.
5. Finishing is written down, not asked about: each session's wrap ends on a three-line
   closing block and appends `- Session: closed · <sessionId>` to the session log,
   and the coordinator reads both back with `scripts/peer-state.py --wrapped` to tell you
   which tabs to close — nobody is messaged, and those same two signals are what let
   `claim` take over a seat whose holder wrapped last night. The plugin ships that wrap as
   the `middle-management:wrap` skill; a personal `~/.claude/skills/wrap` still wins on `/wrap`.
6. Waiting is read off disk the same way: `scripts/peer-state.py --waiting` lists the live
   sessions parked on a permission prompt or ending on a question. They are alive but will not
   move until you act in that tab, so the coordinator tells you which tab instead of messaging it.

Solo user with a single session? You do not need `claim` at all — install, configure
the worktree part if you like it, and ignore the roles.

## Configuration

One user-global file, `<config-dir>/middle-management.json` (config dir =
`$CLAUDE_CONFIG_DIR` or `~/.claude`), written for you by `/middle-management-setup`:

```json
{
  "board": "/abs/path/to/your-status-board.md",
  "surgicalStaging": true,
  "notifyCommand": ". ~/.claude/secrets/telegram.env && curl -sS -m 15 -X POST \"https://api.telegram.org/bot$BOT_TOKEN/sendMessage\" --data-urlencode \"chat_id=$CHAT_ID\" --data-urlencode \"text=$1\"",
  "sessionLog": "/home/you/logs/session-log.md",
  "longRunningAsUnit": false,
  "unitMemoryMax": "3G",
  "capMemoryMax": "5G",
  "maxUnits": 2,
  "reaperMaxHours": 10,
  "reaperOwnerlessMinutes": 30,
  "reaperDigestHour": 7,
  "protectedCheckouts": [
    { "name": "app",
      "root": "/home/you/code/app",
      "base": "origin/dev",
      "install": "npm install",
      "serve": "npm run dev",
      "worktreeDir": "/home/you/code/.worktrees-app" }
  ]
}
```

- `board` (optional): a status/waiting board only the coordinator writes; workers read.
- `notifyCommand` (optional): a shell command that reaches you when you are away from the
  keyboard — the ONE sender on the machine. The heartbeat, the unit-failure alarm and the
  coordinator itself run it with the message as `$1` and on stdin. Callers always pass plain
  text; any decoration (a bold first line, a parse mode, the fallback to plain when the rich
  form is rejected) lives inside this one command, so an alarm never dies of formatting. Keep
  tokens in a mode-600 env file the command sources — setup prints this file back to you.
- `sessionLog` (optional, default `~/logs/session-log.md`): the machine's session log — see
  [The session log](#the-session-log). Must be absolute (`~` is expanded); a relative path makes
  the config invalid, because it would name a different file per caller. `$MM_SESSION_LOG`
  overrides it.
- `longRunningAsUnit` (optional, default `false`): arms the hook that rewrites hand-started
  dev servers and heavy builds into `wt run` / `wt cap`.
- `unitMemoryMax` / `capMemoryMax` / `maxUnits` (optional, defaults `3G` / `5G` / `2`): the
  memory ceiling of a lane unit, of a `wt cap` command, and how many lane units may run at once.
- `reaperMaxHours` / `reaperOwnerlessMinutes` / `reaperDigestHour` (optional, defaults `10` /
  `30` / `7`): when the lane reaper calls a unit expired, how long an owning session must be
  gone before its lane counts as ownerless (confirmed on a second sighting), and the hour from
  which its once-a-day digest goes out.
- `protectedCheckouts` (optional): repos whose main checkout is edit-protected;
  work happens in worktrees under `worktreeDir`. `base` is the branch new worktree
  branches start from — setup always writes it explicitly, and `serve` is the dev-server
  command `/wt <name> run <topic>` starts when the caller passes none.
- No config file = roles **plus the staging guard**: blanket staging is blocked out of the box,
  because sessions share a checkout long before anyone configures one. The worktree part is what
  stays completely silent. Working solo? `surgicalStaging: false` turns the guard off.
- User-global on purpose: the coordinator seat is per machine, and protected checkouts
  are absolute paths independent of any one project. One board per machine for now.

## The session log

One markdown file per machine in which **every session writes what it did** when it finishes.
It is not decoration: the coordinator's tab list and the stale-seat takeover are read out of it.

**Where it is** — resolved in three steps, by `scripts/peer-state.py` and by
`scripts/config-check.sh session-log` (the hook and `/orchestrator` use the latter), in this
order:

1. `$MM_SESSION_LOG`
2. `"sessionLog"` in `<config-dir>/middle-management.json` (`~` is expanded)
3. `~/logs/session-log.md` — the default, when neither is set, and when the value is not
   absolute: a relative path would resolve against whatever directory the reader happens to run
   in, so both resolvers refuse it (and the config counts as invalid)

Rotated days may sit beside it as `<log dir>/archive/YYYY-MM-DD.md`; those are read too, for
closed markers only.

**Who writes it** — every session, at the end of its own work: the shipped `middle-management:wrap`
skill, or your own wrap routine as long as it produces the shape below. Nothing writes this file
behind your back.

**Who reads it** — `scripts/peer-state.py`, for two things: the coordinator's tab list
(`peer-state.py --wrapped`, which sessions are finished and can be closed instead of messaged),
and `/orchestrator claim` over a seat whose holder wrapped last night — that takeover needs the
holder's own closing line **and** its log entry reading `completed`, so with no log there is no
takeover, and `claim` says so and names this path.

**The format is frozen** — the reader matches it literally. En dash `–` between the parts of the
entry header, middle dot `·` in the closed line:

```markdown
## 2026-01-15

### 09:12 – [session-name] – Topic in a handful of words
- What was done, one bullet per step
- Files modified: `path/to/file`
- Status: completed
- Session: closed · 0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9
```

- `## YYYY-MM-DD` — a day heading, and nothing else on that line. Entries under no day heading
  still count as entries, but a closed marker under none is ignored: its age cannot be checked.
- `### HH:MM – [name] – topic` — the session's **display name** in brackets (anything after a
  `/` inside them, `[name / Opus 5, WORKER]`, is free text), then the topic. `-`, `–` and `—` all
  parse.
- `- Status: completed` — `completed`, `in-progress`, `blocked`, whatever you use; only
  `completed` corroborates a wrap. It describes **the entry's work**, not the session's life.
- `- Session: closed · <sessionId>` — written only by the entry that ends the session, keyed by
  the **sessionId** (`/orchestrator status` prints it), because display names are recycled and
  change across a resume. Free text may follow the id. This line is what makes a session
  *declared* finished rather than inferred.

Entries are appended, so the last entry naming a session is the one that counts; an entry whose
day heading is not the day of that session's last turn is disregarded rather than believed.
Nothing here is validated on write — a wrong shape parses as "no entry", which is
indistinguishable from an absent file, which is why it is written out here.

Until a log exists the role hook says so on every message instead of asking for the closed line,
and `plugins/middle-management/templates/session-log.md` is a skeleton to start one from — copy
it to the resolved path. One file per machine, never one per repository.

## Starting a project from the templates

`plugins/middle-management/templates/docs/` holds the minimum a project needs before its first
wrap: a `CLAUDE.md` and a `docs/` skeleton (`architecture.md`, `lessons.md`, README conventions
for `runbooks/` and `handoffs/`). Copy what you want into a new repository and fill it in —
nothing reads these as templates at runtime, they are a starting point, not a framework. The
session log is the one file that is NOT per project: its skeleton sits beside them as
`templates/session-log.md` and belongs at the machine-wide path above.

## Failure policy (loud, not silent)

If `jq` is missing, the session registry is absent, the config file is invalid, or an
override marker was left behind, the role hook says so **on every message** — the
plugin never degrades silently. While the config is invalid, the worktree guard and
`/wt` are disarmed (announced) and the staging guard is forced ON.

## Honesty notes

- The worktree guard is a **guardrail, not a security boundary**: it intercepts the
  Edit/Write tools, not Bash-side writes (`sed -i`, redirects, `git checkout`).
- The staging guard's escape hatch: only when your user explicitly allows a direct
  main-checkout edit in the session, the deny message names an override marker;
  delete the marker right after — the role hook nags while it exists.
- Hooks **auto-update** with the marketplace by default. After an update, restart open
  sessions. If a broken update worries you, disable auto-update for this marketplace.
- Command names `/wt`, `/orchestrator` are short and generic; collision behavior with
  same-named commands from other plugins is untested.
- Uninstall (`/plugin uninstall middle-management`) removes the plugin but NOT your data:
  `<config-dir>/middle-management.json` and `<config-dir>/state/{orchestrator,allow-main-checkout-edits}`
  stay; delete them by hand if you want a clean slate. The heartbeat, if installed, keeps
  running from its copy — disarm and uninstall it per the skill.
- The heartbeat's units point at a COPY under `<config-dir>/middle-management-heartbeat/`
  (the plugin cache path is versioned and would go stale on the next update): **after a
  plugin update, re-run setup step 5** to refresh that copy. `last-tick` under
  `<config-dir>/state/orch-heartbeat/` older than 15 minutes means the timer is not running.
- The lane reaper decides from `wt list` alone. The `pr` column reads `-` whenever there is no
  pull-request information to be had (no `gh`, no GitHub remote, `gh` never logged in), and
  only a gh that was supposed to answer and failed reads `error`, which alarms. Without that
  column only lanes whose branch is an ancestor of the base are cleaned up, and squash-merged
  ones are listed instead — the safe half of that trade. Such a branch then keeps its ref for
  good: once the worktree is gone the lane is never listed again, so delete it yourself with
  the `update-ref` line `/wt … done` printed. The reaper never kills a process by pid, and its
  units point at a COPY under `<config-dir>/middle-management-reaper/`, so re-run setup step 6
  after a plugin update.
- **There is no idle rule.** Deciding that a lane is idle means reading request lines out of
  its server's log, and the plugin cannot know what those look like; a unit nobody uses is
  caught by `reaperMaxHours` instead — later, but without guessing.
- No lock around `wt`'s own verbs and no free-memory check before starting a unit (the master
  this was extracted from has both): two `run` calls racing each other can exceed `maxUnits`,
  which `MemoryMax` per unit bounds anyway. The unit count is machine-wide — every
  `wt-*.service` on the user's systemd counts, including ones another tool started.
- The long-runner hook is a stripper, not a shell parser. It matches in command position only
  (so `echo "bun test"` is left alone) and its blind spots are listed in its own header; a dev
  server started outside any lane is not rewritten, because there is no lane to name the unit
  after.
- The heartbeat's alarm is the proven half; the poke is a cheap bet — a socket write is
  known to re-trigger an idle session, not yet known to revive one whose turn died.

## Requirements

- Claude Code recent enough to have the session registry (`<config-dir>/sessions/`)
  and cross-session peer messaging — the substrate the roles ride on.
- `jq`, `bash`, `python3`, GNU `date` (`date -d`), POSIX `ps`/`kill`. Linux tested; macOS
  expected-compatible but untested; Windows via WSL. `python3` is not heartbeat-only: it runs
  `peer-state.py`, which the coordinator is pointed at on every message and which
  `/orchestrator claim` needs to judge a stale seat. GNU `date` is what `/wt <name> hold
  <topic> <hours>` and the lane reaper do their timestamp and age math with — they refuse
  rather than answer wrongly where `date` is not GNU (macOS: `brew install coreutils`, then
  `gdate` on `PATH` as `date`); `/wt list` degrades its date columns to `-` instead, and
  clearing a hold (`hold <topic> 0`) formats nothing and works either way. `/wt run`,
  `/wt stop`, `/wt cap`, the long-runner hook and the
  reaper need a systemd user manager and refuse where there is none; `gh` is optional and only
  fills the `pr` column of `/wt list`.
- For the heartbeat additionally: Linux with a systemd user manager
  (`loginctl enable-linger`). macOS launchd is not supported.
- For a private marketplace repo: working git credentials for the host on every
  installing machine (`/plugin marketplace add` clones over git).

## Recommended settings (your user-scope `settings.json` — the plugin never writes it)

- `"env": { "CLAUDE_CODE_RETRY_WATCHDOG": "1" }` — long-running coordinator and worker
  sessions keep retrying on API overload (429/529) instead of giving up after ten
  attempts. Sessions started before the change keep the old behaviour until restarted.
- `"remoteControlAtStartup": false` — with many sessions on one machine, only the
  coordinator should be reachable remotely; `claim` reminds it to turn Remote Control on
  in its tab, and a fresh coordinator starts as `claude --rc -n orchestrator`.

## Why this exists

Many parallel sessions on one machine kept messaging each other crosswise, turning
the human into a context courier, committing each other's files, and editing a shared
checkout underneath a running dev server. The fix that stuck: one coordinator session
with the only pen for the board, per-topic worktrees with one branch and one small PR
per lane, and surgical staging. This plugin is that setup, made portable.

## License

Public domain ([Unlicense](https://unlicense.org)) — do whatever you want with it.
