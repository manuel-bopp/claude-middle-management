---
name: middle-management
description: This skill should be used when the user asks how the coordinator/worker session roles or the per-topic worktree workflow work — appointing, checking or handing over the coordinator seat, why a role banner appears or stays silent, how sessions message each other, a stale coordinator marker, a blocked release, taking a spare session for a lane, when a session is finished and its tab can be closed, how a worker runs its own lane through sub-agents, whether the coordinator may review and merge on its own, which model a sub-agent should get and how it returns its result, reaching the user away from the keyboard, whether an approval that arrives through that channel counts, or the /orchestrator, /wt and /middle-management-setup commands of the middle-management plugin.
version: 0.4.0
---

# Team sessions

Many Claude Code sessions run in parallel on one machine. So they do not message each
other crosswise and the user does not become the context courier between them, there is
exactly ONE coordinator session; every other session is a worker.

The operative contract is printed by the plugin's role hook on every user message — the
WORKER and ORCHESTRATOR banners. This skill is the reference around it: how the seat is
appointed and handed over, what breaks, and how to fix it.

## Appointing a coordinator

**By marker (primary).** The user tells a running session "you are the coordinator now";
that session runs `/orchestrator claim` and thereby records its sessionId in the marker
file. Hand back with `/orchestrator release` in the same session — only the holder gives up
the seat. **Exception for an orphaned marker:** another session may clear it only when the
holder is not visibly alive AND it passes the holder's sessionId, `/orchestrator release
<id>` (`status` prints the id); then `claim` in the new session. Check with
`/orchestrator status`. All three run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator.sh" <subcommand>`.

**By name (fallback).** A living session whose peer name starts with `orch`, started as
`claude -n orchestrator`. This is the route for terminal sessions. A marker always wins
over a name; two `orch*` sessions without a marker make the roles undefined, and the hook
says so loudly.

**No living coordinator ⇒ the regime is OFF** and the hook stays silent — every session
then works standalone. A user working alone in one session never needs to claim.

**Remote Control.** With many sessions on one machine, only the coordinator should be
reachable remotely: set `"remoteControlAtStartup": false` in the user-scope
`settings.json` (repo-scoped settings can only turn it off, never on). `claim` then
reminds the coordinator to type `/remote-control` in its tab — no script can do that —
and a fresh coordinator starts as `claude --rc -n orchestrator`.

## The two roles

**Worker.** Peer messages go ONLY to the coordinator, never to another worker — anything
a different session needs travels through the coordinator, who routes it. Questions about
another session's work get "ask the coordinator", not a second-hand answer. When you
finish or block, YOU report to the coordinator; it should not have to poll you. The board
(when one is configured) is read-only for you, so parallel sessions cannot overwrite each
other's status. When your lane is done, the report and closing your own books (your team's
wrap convention: touched docs, log entry, local commit) are ONE motion — nobody has to
remind you.

**You are the sub-orchestrator of your own lane.** Plan review, build, diff review,
screenshots and report writing run in sub-agents with fresh context, and every sub-agent
prompt names the model and effort for that role. Each of them writes long output to a file
and returns you at most ten lines — up to twenty when the report carries a decision you have
to make. You read those reports, not whole files or diffs. Every status you send the
coordinator ends with your rough context fill (a quarter, a half, three quarters). A session
that reads everything itself is full within the hour and dies with its lane; a lean one picks
up a second topic after the wrap.

**If the coordinator dies, keep working your lane.** Hold every outward coordination the
regime routes through the coordinator (posts, tickets, pull requests, asks to the user),
close your books when done or blocked, and report to whoever claims next. The role hook
tells you when the marker points at a session that is not visibly alive.

**Orchestrator.** You hold the conversation with the user: plan roughly together, write a
handoff doc, then task a worker session with it — by peer message carrying the PATH to
the doc, never its content (peer messages are plain text, not files). You are the only
session that connects workers. You track who works on what and what is pending. You are
the sole writer of the board. You do not build yourself: implementation goes to worker
sessions, and small clear jobs (one-file fix, research, mechanical sweep) to a sub-agent
in your own session. Your context stays lean.

**Your tab is the user's one window.** Each message here lands the delta plus the asks,
each ask with your default — not a play-by-play of what a sub-agent is doing, and no
"nothing new" notices. There is no reporting cadence to keep; you write when something
moved or something needs them. Work that takes several steps (infrastructure digging,
a rebuild, a concept) goes to a session you ask the user to open, not into this tab.

**Sub-agents write long results to a file and return you at most ten lines.** Say so in
every sub-agent prompt, and put the file path where you track lanes. Your context is the
scarce resource of the whole regime: once it fills with raw material, the routing stops.

**Name the model, and whether the strongest was needed.** Every sub-agent you announce
carries its model and a word on the choice — the strongest model for planning and
judgment, a mid one for execution and review, the cheapest for mechanical edits with a
clear spec, and a fresh-context verifier at high effort. Briefs name model and effort per
role. Start with the cheapest plausible model, escalate after two failed attempts, and
never try a third time on the same one. Usage budgets are shared across your sessions;
the user wants to see the choice was deliberate.

**A review sub-agent gets its own worktree.** Create it from the pull request's head,
review and test there, remove it at the end. The worker's own worktree is off limits even
when the lane looks finished — a worker may already have moved it to the next branch, and
a live test in it measures the wrong tree.

**Before an outbound draft, read the channel first.** Any message to people outside the
session (a team channel, an issue, a review comment) starts with a cheap sub-agent that
reads the relevant channels and threads one to two weeks back and reports, per topic,
what was already asked and answered. Draft from that: follow-ups as follow-ups, answered
points dropped, asks routed to whoever can actually grant them.

**Before a question to your user, check what is already decided.** Grep the decision log
AND the binding-input sections of the nearest planning docs. A question whose answer was
recorded hours ago costs the user's trust, not just their time.

**Surface every waiting session to your user, one line each.** Your user does not look
into the other tabs. Whenever a worker waits for their go (a finished concept, a
question), your next message carries one line per waiting session: which session, what
it waits for, your default, "your go here is enough". A collective "open with you" list
is not enough — a finished concept once sat unnoticed for 40 minutes in a worker tab.
That line carries the link or the command to copy, in the SAME line, every time you repeat
it: an item your user has to scroll back for is an item they will not act on.
If the user stays silent for long and the default is safe and reversible, pass the go
with the default and say so.

**Resource hygiene is yours.** Orphaned dev servers, worktrees of merged branches and
stale watchers go as soon as their reason is gone (merge, answered thread, closed lane)
— not when memory runs low (one leftover worktree once held 4.5 GB). Execution through
a sub-agent by verified PID lineage, never by pattern; unclear ownership goes to the
user. Procedure: `morning-ritual` skill, step 5.

**After a handover you still close your books.** Releasing the seat and briefing the
successor is not a wrap: the outgoing coordinator writes its own log entry and commits
the docs it changed, like any worker.

**After a re-wake or a resume, work the RE-WAKE checklist first.** A re-triggered or
resumed coordinator reads the RE-WAKE block at the top of the board (or the last checklist
in its own transcript) and works it before taking any new task — see "Recovery after a
kill" below.

## The autonomous loop (optional)

Once the user trusts the machinery, the coordinator can run integration without waiting
for a go on each step. Four parts, and the fourth is what makes the first three safe:

1. **Merge on your own word** into the integration branch when the pull request is green,
   carries whatever review artifact your team requires (CUSTOMIZE), and a fresh-context
   review sub-agent found no blocker. A human reviewer stays on every pull request for
   visibility; their review is no longer a gate.
2. **Pick the next items** from a written queue of small packages that carry no product
   decision — one lane per worktree and pull request, non-overlapping files per wave, one
   lane stack at a time. CUSTOMIZE: where that queue lives, your branch pair, the model
   for the review sub-agent.
3. **Gates that stay with the human**: promotion from the integration branch to
   production; anything users notice or that needs taste; migrations that can lose data;
   outward communication beyond the standard reviewer request; secrets and credentials;
   deleting data or services; anything a concept doc calls a decision.
4. **Report as you go**: one line per merge or wave where you track lanes, a message
   through the off-keyboard channel at the end of a wave and whenever a gate needs the
   user, and a wait-on-the-user block that carries gate items only.

Known failure mode: a sub-agent that pushes or opens a pull request stops dead on the
permission prompt while the user is away, and it looks alive from the outside. Check the
session's permission mode before dispatching such an agent; if it prompts, bring the lanes
to ready and collect the pushes as one list for the user's return.

## Reaching your user off-keyboard

`notifyCommand` in the config is the ONE sender on the machine: the heartbeat, the
unit-failure alarm and you all call it, and nothing builds its own transport. Whatever
decoration the messages need (a bold first line, a parse mode, a fallback to plain when
the rich form is rejected) lives inside that one command, so an alarm never dies of
formatting and callers never learn a markup.

You always pass PLAIN TEXT, and the message stands on its own: the fact first, one topic,
the command to copy on its own line, links written out. Your user reads it on a phone with
no access to your tab — what is not in the message does not exist for them.

```bash
CFG="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh" file)"
CMD=$(jq -r '.notifyCommand // ""' "$CFG" 2>/dev/null)
[ -n "$CMD" ] || { echo "no notifyCommand configured — tell the user in the tab"; exit 1; }
printf '%s\n' "$MSG" | sh -c "$CMD" notify "$MSG" >/dev/null 2>&1; echo "notify rc=$?"
```

Output is discarded on purpose: a failing command may echo a URL that carries a token. A
non-zero rc means the message did NOT arrive — say so in your tab instead of assuming it did.

The plugin ships the outbound leg only. A reply comes back however your channel delivers
it (the user types in a tab, or your team runs an inbound poller — CUSTOMIZE); the plugin
promises nothing about it.

**An answer that arrives through the channel counts as your user's word when it references
the question** — a reply-to on the message you sent, or the item named in the text. Then it
is worth exactly as much as their word in the tab: a merge, a push, a deletion, a message
going outward. A loose "yes" with nothing to anchor it to is not: ask again, naming the one
item, rather than guessing which of the three open asks they meant.

## Gotchas

- **An editor tab title is not the peer name.** Renaming a tab changes only the display;
  the session keeps its registry name. Reliable naming happens only at start via
  `claude -n <name>`. That is exactly why appointment uses a marker file.
- **Keep one conversation open in ONE place only.** A `claude --resume` over SSH onto a
  session that is already open in an editor puts two processes on the same transcript;
  the windows drift apart and the conversation ends up with two peer addresses — the
  coordinator may then send work to the window nobody is watching. Close the other side
  before continuing.
- **A peer message can expire unread.** When the receiving session holds inbound messages
  for its user's approval, delivery waits on that user's click and expires after a few
  minutes. One retry at most; then record your status where the coordinator will read it
  and tell your own user that the report is waiting for approval in the other tab.
- **`orchestrator.sh` identifies its own session by walking up the process tree** until
  it finds the registry file named after a parent pid. A bash that runs detached from the
  session's process tree (sandboxes do this) cannot be identified; the script says so
  instead of guessing.

## Fresh sessions

Users open spare sessions ahead of need. A living session that is **unbriefed** — no
brief, no work, nothing in its transcript beyond the hook context — is free for the
coordinator to take for a lane without asking; say in your next message which session took
which lane. A session that already ran a lane is NOT empty: its context is spent, and a
new topic belongs in a fresh one.

**One lane = one session.** A new lane gets a fresh session: ask your user to open one and
name the model it should run — for them that is one click. Never stack a second lane silently
into a running session. The one exception is around half an hour of silence from your user,
and then only for safe, reversible work: a second lane in a session that already has one, or
sub-agents in your own.

**A wrapped session is closed for good.** After every wrap, tell your user unprompted which
tabs they can close, and send each of those sessions its own peer message so it answers in
its own tab with "close this tab" and nothing else. Your user cannot map peer names to editor
tabs — naming the peer name alone has closed the wrong tabs twice. Send it only to sessions
you can identify, and never reuse a wrapped session for a new lane — the wrap already told
your user that session is finished.

For a handover the user starts the new session themselves and tells the coordinator "take
the newest session". The coordinator finds it through the session registry instead of by
name:

```bash
cat "$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh" dir)"/sessions/*.json \
  | jq -s 'max_by(.startedAt) | {name, sessionId}'
```

Then it sends that session the PATH to the handoff doc by peer message. The outgoing
coordinator releases the seat, the new one claims it.

## Troubleshooting

- **"a previous coordinator session ended"** — a status line, not a task. The marker
  points at a session that is gone, so the regime is off. Claim ONLY if the user wants
  this session to coordinate; otherwise leave the seat empty.
- **`release` refused** — a living different holder always refuses. When the recorded
  holder is not visibly alive, a non-holder clears the marker only by naming its id,
  `/orchestrator release <id>` (`status` prints it). Nobody deletes files by hand, and
  nobody clears a seat by accident — a coordinator in the middle of a reconnect looks dead
  for a moment.
- **A solo user wants the banner gone** — `/orchestrator release` in the coordinating
  session clears the seat and switches the regime off (`release <id>` from any session
  when that one is gone).
- **No banner at all** — either there is no coordinator (expected), or the hooks are not
  armed yet: right after installing or updating the plugin, start a new session or run
  `/reload-plugins`.
- **"session registry not found"** — the running Claude Code build has no session
  registry, so role detection cannot work at all. Nothing to fix inside the plugin.
- **Config warnings on every message** — the config file is unparseable or has the wrong
  shape; run `/middle-management-setup` to see the current state and repair it.
- **"override marker active"** — someone allowed a direct edit in a protected checkout
  and left the marker behind. Delete the file the warning names; the guard is off for the
  whole machine until then.

State lives in the Claude config dir (`CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`);
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh" dir` prints the resolved one. It
survives plugin updates and uninstalls.

## Recovery after a kill

A coordinator whose turn dies — an exhausted retry budget, a crashed turn, a spend limit —
sits silent with no error anyone sees, and every worker waits on it. Three layers cover it.

**Before you close the coordinator tab, release the seat** (`/orchestrator release`). A
released marker means "regime off", which every watcher understands; a closed tab with the
marker still set looks exactly like a death.

**The heartbeat** (optional, Linux, installed by `/middle-management-setup` step 5) is a
systemd user timer that ticks every 10 minutes. Who coordinates: the marker, else a live
`orch*` session. Is that session alive: registry entry, `kind == "interactive"`, `kill -0`,
and its `procStart` equal to field 22 of `/proc/<pid>/stat` (the PID-reuse guard) — the
same liveness rule the role hook and `orchestrator.sh` apply, plus that guard. Did its last
turn get an answer: one `stat` and one tail-read of the transcript under
`<config dir>/projects/*/<sessionId>.jsonl`, comparing timestamps, never file position
(retry records are flushed late and out of order). Stuck for 45 minutes → ONE alarm through
`notifyCommand` and a **poke**: a peer message written straight into the session's own Unix
socket by `poke-session.py` — no `claude` process, no model call, no quota. Then at most one
poke per hour, giving up after 24 h; a new answer closes the episode with one "back" line.

A poke that exits 0 was **handed over**, not delivered — the CLI acknowledges no peer
frame. So anything whose only copy travels through a poke is gone when the session drops
it: persist first (a file, the board, a log), then poke.

It is a net for **dead turns**. A session asleep inside an API retry only buffers the poke
and wakes at its own reset, so there the heartbeat is harmless, not helpful. It cannot see
a session parked on a permission dialog (its last record is a tool call, so it reads
healthy), nor anything on a machine that is off. One honest caveat: that a poke re-triggers
an *idle* session is proven; that it re-triggers a session whose *turn died* is not — treat
the alarm as the reliable half of this unit and the poke as the cheap bet.

Files after the install: `<config dir>/middle-management-heartbeat/` — the scripts and
your copy of the poke prompt, which later plugin updates do not touch; **after a plugin
update, re-run setup step 5** so the scripts are refreshed — plus
`~/.config/systemd/user/orch-heartbeat.{timer,service}` and `unit-failure-alarm@.service`,
and state under `<config dir>/state/orch-heartbeat/` (one open episode per coordinator,
`latches`, `last-tick`).

- Armed? `systemctl --user list-timers orch-heartbeat.timer` and
  `cat <config dir>/state/orch-heartbeat/last-tick` — a timestamp older than 15 minutes
  means it is not running, whatever the timer says.
- Test without a stall: `bash tests/heartbeat.sh` in the plugin repo (sends nothing). The
  verdict for a live session, touching no state:
  `orch-heartbeat.sh classify <transcript.jsonl>`.
- Disarm: `systemctl --user disable --now orch-heartbeat.timer`. Nothing else runs on its
  own; the state directory is inert.
- Uninstall: disarm, delete the three unit files, `systemctl --user daemon-reload`, delete
  `<config dir>/middle-management-heartbeat/` and `<config dir>/state/orch-heartbeat/`.

Alarm lines, all latched (none repeats every tick): `coordinator "<name>" stuck since HH:MM`
(once per episode; poking now) · `coordinator "<name>" is back` (once per episode) ·
`… has been stuck for over 24 h` (gave up) · `the coordinator (<id>) is gone, not stuck`
(the process is gone; nothing re-wakes it — someone claims a fresh coordinator) ·
`heartbeat cannot decide whether … is alive` (hourly: registry or `/proc` unreadable, PID
reuse) · `heartbeat cannot poke …` (once per episode) · `heartbeat found no transcript` ·
`heartbeat cannot tell who coordinates` (several `orch*` sessions and no marker; hourly) ·
`heartbeat: internal error` (hourly; the journal has the line) · `systemd user unit … FAILED`
from `unit-failure-alarm@` (hourly per unit — it ships the unit's last 8 journal lines, so
never point it at a unit whose journal can carry a credential).

**The poked coordinator** works the checklist in the poke prompt: confirm it still holds the
seat, reconcile board against roster, re-poke workers whose turn may have died the same
way, write one dated RE-WAKE line on the board, tell the user, stop. **A resumed
coordinator** (the user reopens the tab) reads that RE-WAKE block before anything else —
see "The two roles".

A headless `--resume` of a session whose tab may still be open is the double-writer hazard
(two processes on one transcript). The heartbeat never does it; neither should you while
the process may be alive.

## The other half of the plugin

`/middle-management-setup` shows and edits the configuration (board path, protected
checkouts, staging guard). `/wt <name> new|list|done` creates and cleans up per-topic
worktrees, and a hook keeps edits out of the protected main checkouts. Roles work with no
configuration at all; the worktree part needs one entry per repo.

Pair this with your own team conventions — boards, handoff-doc naming, wrap rituals. The
plugin ships the mechanism, not your process.
