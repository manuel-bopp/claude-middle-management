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

**After every plugin update, re-run `/middle-management-setup` steps 5, 6 and 7** for whichever of
the heartbeat, the lane reaper and the headless morning ritual you installed — their units run a
copy of the scripts, because the plugin's own cache path is versioned and goes stale with each
update.

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
| `review-loop` skill | skill | The loop every deliverable goes through before it is handed on as finished: a fresh-context reviewer checks it against its acceptance criteria and must prove each finding against the code or doc, the session fixes what was confirmed, a new reviewer runs again, until a round finds nothing. Hard cap 4 rounds, then the open findings are reported and nothing is called clean. Opus at xhigh by default, Fable for money, security, data and the customer path. |
| Review gate | PreToolUse hook (optional) | Holds ExitPlanMode on a real plan and a Write to any `<date>_handoff-*.md` until the review loop ran in this session within the hour. Off unless `reviewLoopGate: true`. |
| Open-items drop | script + banner line | Every session writes each "for later" item the moment it appears, with `scripts/open-items.py add`, to its own file under `<config-dir>/open-items/`; the coordinator's banner counts what is not on the board yet, `list` shows it, and `done` deletes a file only once every key is on the board and the session is gone. A to-do no longer dies with a session that never wrapped, or with a coordinator hand-over. |
| `morning-ritual` skill | skill | The coordinator’s day-opener: messages delta, repo state, wrap audit, board sweep, machine cleanup, your user’s to-do list, day plan. The to-do list also runs alone ("todo list", "meine offenen To-Dos"): every open `owner: user` item from the board and the drops, grouped decide / click / run / read, only what was not delivered yet (`open-items.py todo`). Coordinator sessions only; carries CUSTOMIZE markers for your team’s stack. |
| Headless morning ritual | systemd user timer (optional, Linux) | Weekdays 07:30: nothing moved since the last delivered ritual → one "no progress since <date>" line, no model run. Otherwise a 25-second login probe (429/401/no answer → a second credential from a file the unit names), the `morning-ritual` skill under `--max-budget-usd` and a hard timeout, and the day plan through your `notifyCommand`. A failure arrives as headline + cause + fix command, not journal lines. Installed by setup step 7; see [Headless morning ritual](#headless-morning-ritual). |
| T3 report hook | Stop hook (T3 Code only) | In a T3 Code thread whose scope's coordinator is bound to a thread: sends the last text of each worker turn to the coordinator's report task, which wakes it, also when it is asleep. Skips interim turns while its own sub-agents run, repeats and a bare `OK`; a failed send is told to the session once. See [T3 Code](#t3-code). |
| T3 watcher | systemd user timer (optional, Linux) | Every 10 minutes, no model: usage limits (with a retry), clicks pending, stuck runs, lost reports, an open handover, a folder without coordinator, and the topics tick. Installed by setup step 8. |
| Follow-through | script + timer tick | `scripts/topics.py` is the one writer of a topic's state: it appends the session-log entry and keeps a table `<board>.topics.md`, a reminder digest and a daily digest, so no topic drops out of sight before it is done, reviewed and OK'd. See [Follow-through](#follow-through). |
| `work-packages` skill + two hooks | skill, PreToolUse + SubagentStop hooks | Every sub-agent writes its package list into a report file first and appends each result at once, so a sub-agent that dies at 99 % leaves its work behind. A prompt without a `Report file:` line is refused; a sub-agent that ends without touching its report is held once. See [Sub-agents](#sub-agents). |
| Heartbeat | systemd user timer (optional, Linux) | Watches the coordinator session: a turn with no answer for 45 minutes → one alarm through your `notifyCommand` and a poke written into the session's own socket (no model call), hourly, giving up after 24 h. The same tick keeps waiting sessions warm: a live, unwrapped session idle 45 to 55 minutes on an open question (or a hold file) gets one "reply ok" ping, at most 3 per wait phase, so the answer does not cost it its whole context again. Installed by setup step 5. |

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
15. The coordinator runs `peer-state.py --wrapped` and gets the tab list, each row carrying that session's own last line so you find the tab by what is on screen in it. Nobody is woken. The same JSON is what lets `claim` take a stale seat off disk (wrapped **and** the log says completed **and** idle past `MM_STALE_SEAT_MIN`), or an expired one (nothing of the holder moved for `MM_EXPIRED_SEAT_MIN`, default 6 h: its wrap entry is backfilled for it).

</details>

1. Your user tells one session "you are the coordinator"; that session runs
   `/orchestrator claim`, which records its session id in
   `<config-dir>/state/orchestrator` (one marker per scope, see [Scopes](#scopes)).
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
   `claim` take over a seat whose holder wrapped last night. A holder quiet past
   `MM_EXPIRED_SEAT_MIN` (default 360 minutes; transcript and session folder both still) has an
   expired seat even without its closing line: `claim` takes it, prints what it read, and
   appends the holder's wrap entry with its closed marker ("backfilled by …"), never messaging it. The plugin ships that wrap as
   the `middle-management:wrap` skill; a personal `~/.claude/skills/wrap` still wins on `/wrap`.
6. Waiting is read off disk the same way: `scripts/peer-state.py --waiting` lists the live
   sessions that MAY be parked on a permission prompt (a long-running tool reads the same; a
   pending sub-agent call never counts) or that end on a question. Such a session is alive but
   will not move until someone acts in that tab, so the coordinator checks the tab's last line
   and tells you which tab, instead of messaging it.
7. Open items go to disk, not into prose: every session appends them with
   `scripts/open-items.py add` to `<config-dir>/open-items/<sid8>-session-notes.md`, each under a
   key `<sid8>-W<n>`. The coordinator files a key by writing it anywhere on the board; its banner
   says how many are still unfiled and stays silent at zero. `open-items.py todo` is the user's
   side of the same records: every open `owner: user` item, new since the last delivery
   (morning ritual, step 6). Details: the middle-management skill, section "Open items".

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
  "userName": "Alex",
  "pageCommand": "/home/you/bin/questions-page.sh",
  "workPackagesGate": true,
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

- `board` (optional): a status/waiting board only the coordinator writes; workers read. Open
  items count as filed once their key is in it, so without it the open-items inbox never empties.
  A symlink works (it is followed), which keeps the path stable while the board itself rotates;
  carry the keys of still-open items over to the new board, or the inbox lists them again. Keys go
  on the board in full (`b42d7700-W2`), never as ranges (`-W1..W3`).
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
- `scopes` (optional): a second, independent coordinator regime per project root, with its own
  seat and board. `scopeMode: "per-root"` (optional) makes every project root its own scope. See [Scopes](#scopes).
- `t3TokenFile` (optional, default `~/.config/t3-threads/token`, mode 600) and `onLimitCommand`
  (optional, run once per usage-limit episode with the limited thread ids as arguments): the T3
  watcher. See [T3 Code](#t3-code).
- `userName`, `okBy`, `remindAfterHours`, `remindWindow`, `pageCommand` (optional, defaults
  `user` / the user / `2` / `08:00-22:00` / none): follow-through. See [Follow-through](#follow-through).
- `workPackagesGate` (optional, default `true`): the sub-agent report gate. See [Sub-agents](#sub-agents).
- No config file = roles **plus the staging guard**: blanket staging is blocked out of the box,
  because sessions share a checkout long before anyone configures one. The worktree part is what
  stays completely silent. Working solo? `surgicalStaging: false` turns the guard off.
- User-global on purpose: protected checkouts are absolute paths independent of any one
  project, and one seat and one board per scope; without `scopes`, that is one per machine.

## Scopes

One config dir normally means one coordinator for every session on the machine. When two
projects on the same machine need independent coordinators (own seat, own board, own workers),
list the second project's root under `scopes`:

```json
{
  "board": "/home/you/handoffs/main-board.md",
  "scopes": [
    { "name": "ff", "root": "/home/you/ff-static-ads", "board": "/home/you/handoffs/ff-board.md" }
  ]
}
```

- `name`: letters, digits, `-` and `_`, not `default`, unique (it becomes a directory name).
  `root`: absolute, not `/`, unique; nesting is allowed. `board`: absolute, required.
- **Which scope a session belongs to:** the scope of the directory it was STARTED in (its entry
  in `<config-dir>/sessions/`), never where it later `cd`s. The longest root that is that
  directory or one of its parents wins, on whole path segments. A session started in a linked
  git worktree that matches no root counts as the same subpath of its main checkout, so a lane
  worktree of `ff` belongs to `ff`, but only while that worktree exists: once it is removed, a
  session still running from it and the drop file it wrote (its header names the worktree path)
  fall back to scope `default`. Everything else is the implicit scope `default`, which keeps
  today's top-level keys and today's paths.
- A scope has no coordinator until one of its sessions runs `/orchestrator claim`; until then its
  sessions get no banner, exactly like a machine without a seat.

| Per scope | Machine-wide (unchanged) |
|---|---|
| the seat marker: `default` = `<config-dir>/state/orchestrator`, a named scope = `<config-dir>/state/scopes/<name>/orchestrator` | the session registry and the session log (one log for all scopes; no per-scope `sessionLog` in 0.10.0) |
| the board (`default` = the top-level `board`) | the open-items drop dir (each file belongs to the scope of the cwd in its header line) |
| the role banners, the coordinator's worker list and the `orch*` name route | `notifyCommand`, `surgicalStaging`, `protectedCheckouts`, `/wt` and the lane reaper |
| the tab list: `peer-state.py --wrapped --scope <name>` (also `--waiting`, `--all`) | the long-runner hook, the review gate, keep-warm |
| the open-items inbox and `done` | the heartbeat timer and its installed copy |
| the heartbeat's watch of the seat (state under `<scope dir>/orch-heartbeat/`, alarms tagged `scope <name>`) and its poke's roster | override markers in `<config-dir>/state/` |

- **Messaging across scopes:** a worker messages only its own scope's coordinator; the
  coordinators of two scopes may message each other directly about anything that crosses
  scopes; nobody messages another scope's workers, stops its servers or removes its worktrees.
- **Open items:** a drop file belongs to the scope of the cwd in its header line (the writing
  session's start dir). Only that scope's coordinator counts, lists, files and deletes it, against
  its own board; a key written on another scope's board is not filed. Unreadable or headerless
  files fall to the default scope's coordinator. Adding or moving a root re-homes existing drop
  files with it, so a new scope's board must carry over the keys already filed elsewhere, as for
  a rotated board.
- **Changing scopes while seats are held:** a seat whose holder's start dir now resolves to
  another scope no longer counts as held: the old scope's sessions see it as not visibly alive
  and may `claim` it or `release <id>` it. So release the seats a change would move before you
  add, nest, remove or rename a scope (`/middle-management-setup` lists them). A removed or
  renamed scope leaves `<config-dir>/state/scopes/<old>/` behind; once its seat is released you
  may delete it (re-adding the old name would otherwise revive it).
- **Morning ritual:** the interactive ritual is per scope (its sessions, board, cleanup and
  `open-items.py todo` are the caller's scope's; its `window` file lives under the scope's state
  dir, so `claim`'s "no morning ritual was delivered today" line is per scope too). The headless
  runner and its timer serve the **default scope only**: they run in no session, so `todo`
  resolves to the default board. A named scope's coordinator runs the ritual itself. The
  delivered-keys file stays machine-wide (keys are unique per session).
- **Expired seats:** `claim`'s stale and expired takeover (and its wrap backfill) only ever look
  at the holder of the caller's own scope's marker. A holder alive in another scope is not
  expired, it simply no longer holds the seat, so it is never backfilled.
- **`scopeMode: "per-root"`** (0.11.0): every project root is its own scope, with no catch-all
  `default`. A path under a listed `scopes` root keeps that scope; any other path belongs to the
  main checkout of its git repo (for a T3 worktree under `~/.t3/worktrees/` that is the T3
  project's `workspaceRoot`). Its name is `<basename>-<6 hex of the root>`, its state dir
  `<config-dir>/state/scopes/<name>/`, created by its first claim, and it has no board (give a
  root that needs one an explicit `scopes` entry). A path in no git repo is scope `none`: a
  standalone session, no seat, no banner, no reports. `none` is reserved like `default`.
  Switching it on moves the seat of a root that is not listed out of `state/orchestrator`, so
  list that root under `scopes` to keep its seat where it is, or re-claim.
- **Requirements:** `python3` resolves scopes once a `scopes` key exists (the role hook,
  `/orchestrator` including `status` and `release`, the heartbeat); git 2.31 or newer for the
  worktree mapping (older git maps no worktree, never a wrong one). Without the key nothing of
  this runs and every file, banner and marker path stays as before.
- **Upgrade:** the default scope is untouched (no migration, the current coordinator keeps its
  seat). Sessions pick up a new scope with their next message once they run 0.10.0 hooks; older
  sessions only after a restart. Where the heartbeat or the headless ritual is installed, re-run
  step 5 or step 7 of `/middle-management-setup` so the copy gets `scope.py`; an older headless
  copy is scope-blind (its `todo` lists and marks every scope's items).

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
takeover, and `claim` says so and names this path. The one write by someone else: a seat that
expired (nothing of the holder moved for `MM_EXPIRED_SEAT_MIN`) gets the holder's wrap entry
appended by the session that took it, in the shape below, marked "backfilled by <name> at <time>".

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
  `/` inside them, `[name / Opus 5.5, WORKER]`, is free text), then the topic. `-`, `–` and `—` all
  parse.
- `- Status: completed` — `completed`, `in-progress`, `blocked`, whatever you use; only
  `completed` corroborates a wrap. It describes **the entry's work**, not the session's life.
- `- Session: closed · <sessionId>` — written only by the entry that ends the session, keyed by
  the **sessionId** (`/orchestrator status` prints it), because display names are recycled and
  change across a resume. Free text may follow the id. This line is what makes a session
  *declared* finished rather than inferred.
- Optional lines (0.11.0, written by `scripts/topics.py entry`, see [Follow-through](#follow-through)):
  `- Topic: <key>`, `- Stage: building|ready|reviewed|live|done`, `- Waits on: <who> · <question> · rec: <r>`,
  `- Answered: <text>`, `- Case: <ref>`, `- Case closed: <ref> · <evidence>`, `- Review: <rounds, verdict>`,
  `- OK: <who time>`, `- Next: <step>`. The `Status:` values stay as they are; `peer-state.py`
  ignores the new lines.

Entries are appended, so the last entry naming a session is the one that counts; an entry whose
day heading is not the day of that session's last turn is disregarded rather than believed.
Nothing here is validated on write — a wrong shape parses as "no entry", which is
indistinguishable from an absent file, which is why it is written out here.

Until a log exists the role hook says so on every message instead of asking for the closed line,
and `plugins/middle-management/templates/session-log.md` is a skeleton to start one from — copy
it to the resolved path. One file per machine, never one per repository.

## T3 Code

T3 Code runs each Claude session as a thread and ends a thread's process after
30 minutes idle. A peer message cannot reach such a thread, and a sleeping coordinator does not
count as alive, so 0.11.0 adds a T3 mode. It is active when `T3CODE_HOME` is set (T3 sets it for
every thread, hooks included).

- **Sidecar.** On `/orchestrator claim` the coordinator creates a report task (a T3 webhook
  scheduled task bound to its own thread, prompt `{{body.prompt}}`) and runs `orchestrator.sh t3-bind`
  with the task's URL on stdin. That writes `<marker dir>/orchestrator.t3.json`, mode 0600:
  `{sessionId, threadId, title, model, reportTaskId, reportUrl}`, plus `previous` and `handover`
  during a handover. The URL is a capability into a full-access thread: never printed, logged or
  put in argv; only `scripts/t3-wake.sh` reads it.
- **Wake paths.** (1) Every session that is not the current coordinator: its Stop hook
  (`hooks/t3-report.sh`) sends the last text of each turn through `t3-wake.sh`, which counts it as
  delivered only on HTTP 202. A failure blocks the session once with "report NOT delivered ... send
  it yourself with t3_thread_send <thread>" and lands in `<config-dir>/state/t3-report/failures.log`.
  (2) The watcher, only on an anomaly. (3) The coordinator tasks a worker with `t3_thread_send`,
  which wakes it, also after settle. A pure retry or liveness ping is the single word `Keepalive`,
  never wrapped in other text; the answer is exactly `OK`.
- **Asleep is not gone.** A holder whose process ended but whose sidecar names it is "asleep in T3":
  the banner says so instead of "stale", `peer-state.py` shows `asleep (T3)` and a thread column,
  and `claim` / `release <id>` refuse with "wake it: t3_thread_send <id>". `--t3-asleep-ok`
  overrides, only on the user's word.
- **Handover.** The outgoing coordinator launches the successor's thread and runs
  `orchestrator.sh t3-handover --to-thread <id> --to-title <title>`, keeping seat and report task.
  The successor's `claim --thread <id>` takes the seat even from the living holder; its `t3-bind`
  wakes the old holder once ("seat taken over by ..."). From then on the old holder reports like
  a worker, forwards late reports, and deletes its old report task as its last wrap step.
- **Watcher.** `scripts/t3-watch.py` (user timer every 10 min, setup step 8; stdlib, read-only
  `GET /api/orchestration/shell` with the header `x-t3-orchestration-protocol: 2` and the bearer
  token from `t3TokenFile`, kept or minted by `scripts/t3-token.sh`). Per scope it watches the
  unsettled top-level threads of the scope's T3 projects: usage limit (notify once per episode,
  `onLimitCommand` once, every 30 min a `Keepalive` into a limited coordinator or a one-call model
  probe for limited workers, then one "limit over" wake), a click pending >10 min, a run stuck >3 h,
  other failures (one wake per run; the coordinator's own is notified), lost reports, a handover
  open >30 min, a folder without coordinator. API trouble is one notify per kind and day.
  `--dry-run` sends nothing, `--stats` counts posts per thread and day. State:
  `<config-dir>/state/t3-watch/`, `<config-dir>/state/t3-report/{failures.log,posts.tsv}`.
- **Settle, not archive.** A worker's wrap ends with `t3_thread_organize settle` for its own
  sub-agent threads, then for itself. The coordinator re-opens a settled worker with
  `t3_thread_send`. The morning ritual settles threads whose log entry is closed, after a
  loose-ends check, and removes a T3 worktree only when merged and settled. Nothing archives or
  deletes threads. The heartbeat skips a coordinator with a sidecar; poke and keep-warm do not
  apply in T3.

## Follow-through

`scripts/topics.py` keeps every topic in sight until it is really finished.

- **One writer.** `topics.py entry` is the only way a topic changes: under the log's lock it
  appends the session-log entry (frozen format plus the optional lines of
  [The session log](#the-session-log); `--closed` writes the closed marker), then updates
  `<config-dir>/state/topics/<scope>.json`. The wrap writes its closing entry this way after its
  review loop; workers report READY / LIVE / blocked / a question this way. Key: `--topic`, else
  the lane dir `lane-<name>` or `~/.cache/claude/wt/<name>`, else the branch `lane/<name>`; the
  coordinator always passes `--topic`, a new key needs `--new`. `answer` books an answer (also a
  pathfinder answers file), `lint` lists log entries without `Topic:`, `stats` counts topics
  re-opened after their wrap.
- **The table** `<board dir>/<board name>.topics.md` (topic, thread, status/stage, waits on, since,
  next), rendered on every watcher tick with or without T3. It is its own file, linked from the
  board's head, because a key anywhere in the board counts as filed for the open-items inbox.
- **Reminders.** Inside `remindWindow`, one digest per `remindAfterHours` with every topic waiting
  on the user (`user` or `userName`) longer than that: up to three inline through `notifyCommand`,
  more as one page built by `pageCommand` (a pathfinder-schema `questions.json` as `$1`, the link as
  its last stdout line). Delivered items go into the morning ritual's ledger
  (`state/morning-ritual/delivered`), so the to-do list and the reminders never repeat each other.
  New open items carry a ` · added: YYYY-MM-DD HH:MM` stamp and count from then.
- **Removal.** A topic leaves the table only with stage `done`, a review and an OK (`okBy`), and
  its case closed when it had one. Stale topics (24 h without an entry, not waiting on the user)
  and done-without-OK go into one daily digest.

## Sub-agents

- **The scheme** (`middle-management:work-packages` skill): every sub-agent prompt carries a
  `Report file: <absolute path>` line. The sub-agent writes its package list there first, appends
  each package's result the moment it is done, and returns at most ten lines plus the path. A
  resumed sub-agent reads its report first and goes on at the first open package.
- **The two hooks.** `hooks/require-work-packages.sh` (PreToolUse on `Agent`) refuses a prompt
  without that line and pastes the template; `Report file: none` and `Explore` agents pass.
  `hooks/subagent-report-check.sh` (SubagentStop) holds a sub-agent once when its report file is
  missing or unchanged since its run started. `workPackagesGate: false` turns both off.
- **Resume before respawn.** A dead or stopped sub-agent keeps its transcript: `SendMessage` to its
  id continues it with its whole context, which is cheaper than a fresh agent re-reading
  everything. Wait out a usage limit before either.

## Headless morning ritual

`scripts/morning-headless.sh` runs the coordinator's morning ritual with nobody at the keyboard,
from the timer `orch-morning-ritual.timer` (weekdays 07:30, no catch-up after a reboot) that setup
step 7 installs. Every path comes from the config (`sessionLog`, `board`,
`protectedCheckouts[].root`, `notifyCommand`); state lives in `<config-dir>/state/morning-ritual/`
(`window` = epoch of the last delivered ritual, `delivered` = to-do keys already sent, `runs/`).
With [scopes](#scopes) it serves the default scope only.

1. **Empty window.** No change in the session log, the board, the open-items drops, the commits of
   any protected checkout (after a best-effort fetch) or `MM_MORNING_WATCH` since `window` → one
   line `no progress since <date>`, no model run, the window keeps its date.
2. **Probe.** `claude -p OK --max-turns 1` under `timeout` (`MM_MORNING_PROBE_SEC`, 25). A 429, a
   401 or no answer — a rate-limited login retries with backoff and simply hangs — loads
   `ANTHROPIC_API_KEY` and/or `CLAUDE_CODE_OAUTH_TOKEN` from the file `MM_MORNING_FALLBACK_ENV`
   names and probes once more. The file is read only then, never executed, its values never
   printed; it is deliberately not an `EnvironmentFile=`, which would put the key in front of the
   primary login on every run.
3. **The ritual**, `middle-management:morning-ritual` with its to-do step, under
   `--max-budget-usd` (`MM_MORNING_MAX_BUDGET_USD`, 3) and `timeout` (`MM_MORNING_TIMEOUT_MIN`,
   20), as the coordinator's unattended stand-in that reads and reports only (no board write, no
   action: steps 3-5 become report lines). Its final message is the day plan; the runner checks it
   for secret-looking strings, sends it (cut on a line boundary past 3800 bytes), records as
   delivered only the to-do keys the sent text carries, and stamps the window. The probe uses the
   same model. Model and permission mode: `MM_MORNING_MODEL`, `MM_MORNING_PERMISSION_MODE` (unset =
   the CLI's defaults; the report needs no tool, the ritual's reads such as git and `open-items.py`
   need your settings' allow rules or a mode, since nothing can be approved unattended). A unit
   `CLAUDE_CONFIG_DIR` equal to `~/.claude` is not passed on to `claude`, which would otherwise read
   `~/.claude/.claude.json` instead of your `~/.claude.json`.
4. **Failure** → exit 1 with a cause file `<config-dir>/state/unit-failure-alarm/<unit>.cause`:
   one headline, the cause (`429`, `401`, `timeout`, `budget`, `other`) and the one fix command.
   The unit's `OnFailure=unit-failure-alarm@%n.service` sends that instead of the journal tail.

**Porting a site-local runner.** A machine that already runs its own headless ritual (a wrapper
around `claude -p` with hard-coded paths and its own sender) moves onto this one mechanically:

| What the old runner had | Where it goes |
|---|---|
| its board path, session log, the repos it fetched | config keys `board`, `sessionLog`, `protectedCheckouts[].root` |
| its own sender (a Telegram `curl`, a bot script) | config key `notifyCommand` (message as `$1` and on stdin); its token stays in the env file that command sources |
| an API key or a second account's token for bad mornings | a mode-600 file of `ANTHROPIC_API_KEY=…` / `CLAUDE_CODE_OAUTH_TOKEN=…` lines (`claude setup-token` of the second account), named by `Environment=MM_MORNING_FALLBACK_ENV=` in the unit |
| its budget, `--model`, `--permission-mode`, extra inputs, force/dry switch | `MM_MORNING_MAX_BUDGET_USD`, `MM_MORNING_MODEL`, `MM_MORNING_PERMISSION_MODE`, `MM_MORNING_WATCH`, `MM_MORNING_FORCE=1` |
| unit `ExecStart=<old script> …` | `ExecStart=<config-dir>/middle-management-morning/morning-headless.sh`, no arguments |
| unit `TimeoutStartSec=` sized for a hang | `MM_MORNING_TIMEOUT_MIN` + 10 minutes (the template's 30): the run stops itself first, with its cause; add 1 minute per protected checkout beyond a few (each fetch may take that long) |
| — | new: `Environment=MM_MORNING_UNIT=%n`, `Environment=CLAUDE_CONFIG_DIR=…`, an `Environment=PATH=` that finds `claude`, `git`, `jq`, `python3`, `timeout` |
| `OnFailure=` | `unit-failure-alarm@%n.service`, the plugin's alarm (switch to it if the old unit used a site alarm: only the plugin's reads the cause file) |
| the timer's `OnCalendar=` | unchanged |
| its pre-gather step, proxy wrap + seat release + poke of the old coordinator, a watchdog unit, a journal-dump alarm, a runs log | dropped: the skill gathers, `claim` takes an expired seat and backfills its wrap, the cause file replaces the dump |

Re-running setup step 7 writes exactly these unit lines; the old unit and its timer are disabled
by hand (`systemctl --user disable --now <old>.timer`) once the new one has delivered a morning.

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
  `/orchestrator claim` needs to judge a stale seat, and it resolves [scopes](#scopes) once a
  `scopes` key exists. GNU `date` is what `/wt <name> hold
  <topic> <hours>` and the lane reaper do their timestamp and age math with — they refuse
  rather than answer wrongly where `date` is not GNU (macOS: `brew install coreutils`, then
  `gdate` on `PATH` as `date`); `/wt list` degrades its date columns to `-` instead, and
  clearing a hold (`hold <topic> 0`) formats nothing and works either way. `/wt run`,
  `/wt stop`, `/wt cap`, the long-runner hook and the
  reaper need a systemd user manager and refuse where there is none; `gh` is optional and only
  fills the `pr` column of `/wt list`.
- For the heartbeat additionally: Linux with a systemd user manager
  (`loginctl enable-linger`). macOS launchd is not supported.
- For the T3 mode additionally: T3 Code 0.1.0 or newer (the protocol-2 read and the provider-log
  names the thread lookup uses are T3 internals; both fail soft after a T3 update: thread
  `unknown`, one "T3 API changed" notify), `curl`, and for the watcher a systemd user manager.
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
