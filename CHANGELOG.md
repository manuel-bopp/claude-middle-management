# Changelog

## Unreleased

Synced from the master setup (2026-09-11, round 4): **a lane runs itself and ends clean**. The
WORKER banner and the skill now say that a worker is the **sub-orchestrator of its own lane** —
plan review, build, diff review, screenshots and report writing run in sub-agents with fresh
context, each prompt naming model and effort; every sub-agent writes long output to a file and
returns at most ten lines, twenty when the report carries a decision the worker must make; the
worker reads reports, not whole files or diffs; and every status to the coordinator ends with the
worker's rough context fill. The ten-line and model-choice rules were coordinator-only until now.
For the coordinator: **one lane = one session** (a new lane gets a fresh session, asked for with
the model named, never a second lane stacked silently into a running one — exception only after
around half an hour of user silence and only for safe, reversible work); **a wrapped session is
closed for good**, so after every wrap the coordinator says unprompted which tabs can go and
sends each of those sessions its own peer message so it answers in its own tab with "close this
tab" (users cannot map peer names to editor tabs and have closed the wrong ones); and every
**waiting item carries its link or command line in the SAME line, at every repetition**. The
skill's off-keyboard section gains the rule for teams whose channel has an inbound leg: an answer
arriving there is the user's word when it references the concrete question (reply-to, or the item
named), and a loose "yes" is not.

`poke-session.py` now declares the RECEIVER's permission mode in the envelope
(`from-mode`, mirrored from the target's `--permission-mode` or the config dir's
`permissions.defaultMode`; `POKE_FROM_MODE` overrides). Without it a session running in
bypassPermissions HOLDS every peer message that does not declare the same mode — parked for
approval, never queued, no log line anywhere — so heartbeat pokes and off-keyboard replies were
silently swallowed. The attribute order in the envelope is load-bearing.

`wt done` deletes the branch of work that is merged into the base instead of hinting at it,
using `git update-ref -d refs/heads/<branch> <tip>` after recording the tip SHA and checking no
other worktree still has the branch checked out (`git branch -D` is deny-listed in careful setups
and `branch -d` refuses squash-merged branches); an unmerged branch is kept with that same
update-ref line as the hint. `done` also refuses when the calling shell's cwd is inside the
worktree, and exits 0 with "already removed" when the worktree is gone, so cleanup routines can
call it blind. Seventeen new test cases (108 + 101).

**Resource management for lanes.** A lane is no longer only a directory: `wt <name> run <topic>
[-- <cmd>]` starts its dev server — the command passed in, or the checkout's new `serve` key — as
a memory-capped transient systemd user unit `wt-<name>-<topic>`, `stop` takes it down and waits
for the cgroup to be empty instead of believing systemd's "inactive", `hold <topic> <hours>` keeps
the reaper off a lane that must stay up, and `wt cap -- <cmd>` caps one heavy build or test run in
the foreground. At most `maxUnits` (default 2) lane units run at once. `wt list` becomes the one
view: a documented, whitespace-separated row per lane (checkout, worktree, branch, unit, owner,
alive, started, memory, hold, git state, merged, pull request) that a cleanup routine can parse.
`done` stops the lane's unit first and now refuses while ANY live process has its cwd inside the
worktree, not just the calling shell.

An OPTIONAL PreToolUse hook, off unless `longRunningAsUnit: true`, rewrites hand-started dev
servers and heavy one-shots into those capped units — in command position only, so prose about a
command is left alone — and refuses a dev server inside a compound command with the replacement
line to copy.

A lane that has produced nothing is never mistaken for a merged one: `wt new` branches off the
base and git sets the new branch's upstream to the base, so an untouched lane used to read
`merged yes` and could be removed — worktree, branch and everything gitignored inside it —
within half an hour of being created. `merged` now also requires that the lane tracks a branch
of its own and has moved since it was created. `wt list` also gained honest pull-request
semantics: `-` where there is no information to be had (no `gh`, no GitHub remote, `gh` never
logged in), `none` only for gh's own "no pull requests found", and `error` — which the reaper
alarms about — for everything else. `wt done` refuses with exit 3 while a live process sits in
the worktree, which the reaper reports as a busy lane with the pids instead of alarming every
half hour, and `wt chown <topic> <owner>` hands a lane over so it does not go ownerless when
the session that started it ends. `run` keeps the caller's cwd when it is inside the lane,
`stop` keeps a valid hold, and `list` fails loudly on a checkout whose root it cannot read.

An OPTIONAL lane reaper, installed like the heartbeat by the new setup step 6 into
`<config dir>/middle-management-reaper/`, runs every 30 minutes: it stops lane units that ran past
`reaperMaxHours` or whose owning session has been gone for `reaperOwnerlessMinutes` (confirmed on
a second sighting), removes the worktree of a merged, clean, pushed lane through `wt done`, and
lists everything else — dirty, unpushed, not merged, unknown owner — with its reason instead of
touching it. It never kills a process by pid and never deletes a ref. It reports through
`notifyCommand` when something happened, when the listed set changed, and once a day from
`reaperDigestHour` (default 7), so a dead timer cannot look like a quiet machine. It ships
without the master's idle rule — deciding a lane is idle means reading request lines out of its
server's log, which no plugin can know the shape of; `reaperMaxHours` catches those units
later instead. It also ships without the master's lock around `wt`'s verbs and without its
free-memory check: two racing `run` calls can exceed `maxUnits`, which `MemoryMax` per unit
bounds anyway.

Both role banners carry the rule this exists for: a lane ends with its unit stopped and its
worktree removed, proven by the `wt list` line in the wrap, and `wt hold` is how a slot stays.
Stopping a lane unit and removing a merged, clean, pushed worktree is housekeeping, done unasked;
anything dirty, unpushed or unmerged stays and goes to the user. Morning-ritual step 5 reads the
reaper's listing and works only its list-only rows, by verified PID lineage.

`wt done` took the branch name from `rev-parse --abbrev-ref HEAD`, which shortens to the shortest
UNAMBIGUOUS name: a tag sharing the branch name yielded `heads/<name>`, and the delete then
targeted `refs/heads/heads/<name>` and failed after the worktree was already gone. The tip SHA had
the mirror bug — resolved in the root checkout, where tags outrank heads and a detached worktree
reported the root's HEAD. Both now come from the worktree, from the full ref. Ninety new test
cases (198 + 110), including a real `wt new` followed by a real reaper run that has to leave
the lane standing.

The marketplace is renamed from `bopp-plugins` to `dr-bopp`. Nothing migrates automatically:
uninstall, `/plugin marketplace remove bopp-plugins`, re-add, install from `dr-bopp` — the README
carries the four commands.

## 0.4.0 — 2026-09-08

Synced from the master setup (2026-09-08, round 3): **what a coordinator does when nobody is
watching**. The `middle-management` skill gained four sections and the ORCHESTRATOR banner three
lines. *The autonomous loop (optional)*: merge into the integration branch on the coordinator's
own word when the pull request is green, carries the team's review artifact and a fresh-context
review sub-agent found no blocker; take the next items from a written queue of decision-free
packages, one lane per worktree; the gates that stay human (promotion to production, taste,
data-loss migrations, outward communication, secrets, deletions, anything a concept calls a
decision); and the reporting that makes the first three safe — plus the failure mode where a
pushing sub-agent stalls invisibly on a permission prompt. *Reaching your user off-keyboard*:
`notifyCommand` is now the ONE sender on the machine — the heartbeat, the unit-failure alarm and
the coordinator all call it, callers pass plain text, decoration and the plain fallback live
inside that one command, output is discarded because a failing command can echo a token, and a
non-zero rc means "not delivered, say so in the tab". README and `/middle-management-setup` say
the same; the plugin still ships the outbound leg only. *Fresh sessions*: an unbriefed living
session is free for the coordinator to take for a lane, a session that already ran one is not.
Sub-agents write long results to a FILE and return the coordinator at most ten lines; every
sub-agent the coordinator announces names its model and whether the strongest was needed, with
the escalation ladder (cheapest plausible first, escalate after two failed attempts). A review
sub-agent gets its OWN temporary worktree, never the worker's. Before an outbound draft, a cheap
sub-agent reads the channels one to two weeks back; before a question to the user, check what is
already decided. Gotcha: a peer message to a session that holds inbound for approval expires
after a few minutes. `poke exit 0` is a hand-over, not a delivery — persist first, then poke, and
`POKE_FROM_NAME` now names the sender the receiving session sees. The morning ritual reads the
off-keyboard inbox too, if the team runs one. Five new banner tests (91 + 101 cases).

Heartbeat note: an installed heartbeat runs a COPY of `poke-session.py` under
`<config-dir>/middle-management-heartbeat/` — re-run `/middle-management-setup` step 5 after this
update to refresh it.

## 0.3.0 — 2026-09-04

Synced from the master setup (2026-09-04, round 2): **the stuck-coordinator heartbeat** — a
systemd user timer (Linux) that alarms through the new config key `notifyCommand` when the
coordinator's last turn got no answer for 45 minutes and pokes the session over its own
socket (`scripts/orch-heartbeat.sh`, `poke-session.py`, `unit-failure-alarm.sh`, unit
templates, the poke prompt with CUSTOMIZE marks; setup step 5 installs a copy under
`<config-dir>/middle-management-heartbeat/`; 96 test cases in `tests/heartbeat.sh`). Liveness
is now decided by sessionId and `kind == "interactive"` in both the role hook and
`orchestrator.sh` (a nameless coordinator no longer reads as a stale marker); a nameless
session keeps its id (tab-IFS row shape); a non-holder clears an orphaned marker only with
`release <id>`; the stale-marker hint names both exits, the marker id and the worker conduct
while the coordinator is dead; the ORCHESTRATOR banner and the skill carry "RE-WAKE checklist
first"; the override-marker nag tests `-e` like the guard and fires before the jq check; the
morning ritual's wrap audit skips non-interactive registry entries; `tests/run.sh` mirrors the
master matrix's behaviour cases and cleans up its fake HOMEs. Skill: section "Recovery after
a kill".

Added the end-user overview picture (`docs/overview.svg`: boss, middle manager, workers,
the manager's duties) at the top of the README; the detailed flow diagram stays under
"How the roles work".

Synced from the master setup (2026-09-03): `wt done` names the real branch in its
delete hint (the topic may be the directory name); the ORCHESTRATOR banner carries the
explicit allowed/not-yourself split, the "user starts worker sessions" rule, the
proceed-with-the-default fallback and resource hygiene; `morning-ritual` gained step 5
"Machine cleanup"; the `middle-management` skill gained Remote Control for coordinators,
"surface every waiting session to your user, one line each", resource hygiene and the
wrap-in-one-motion rule; the checkout-guard deny text says "one lane = one branch = one
pull request"; the `claim` reminder names `claude --rc -n orchestrator`; README lists the
recommended `settings.json` entries (retry watchdog, Remote Control off by default).

## 0.2.0 — 2026-09-02

Added the `morning-ritual` skill (coordinator day-opener with CUSTOMIZE markers),
the conditional Remote Control reminder after `claim`, and the session-role flow
diagram (README + docs/flow.svg). License changed from MIT to the Unlicense
(public domain).

## 0.1.0 — 2026-09-01

Initial release: coordinator/worker session roles (UserPromptSubmit hook +
`/orchestrator`), per-topic worktree discipline (PreToolUse guard + `/wt` +
`/middle-management-setup`), surgical git staging guard, `middle-management` reference skill.
