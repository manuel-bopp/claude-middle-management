---
name: middle-management
description: This skill should be used when the user asks how the coordinator/worker session roles or the per-topic worktree workflow work — appointing, checking or handing over the coordinator seat, why a role banner appears or stays silent, how sessions message each other, a stale coordinator marker, a blocked release, or the /orchestrator, /wt and /middle-management-setup commands of the middle-management plugin.
version: 0.1.0
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

**Surface every waiting session to your user, one line each.** Your user does not look
into the other tabs. Whenever a worker waits for their go (a finished concept, a
question), your next message carries one line per waiting session: which session, what
it waits for, your default, "your go here is enough". A collective "open with you" list
is not enough — a finished concept once sat unnoticed for 40 minutes in a worker tab.
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

## Gotchas

- **An editor tab title is not the peer name.** Renaming a tab changes only the display;
  the session keeps its registry name. Reliable naming happens only at start via
  `claude -n <name>`. That is exactly why appointment uses a marker file.
- **Keep one conversation open in ONE place only.** A `claude --resume` over SSH onto a
  session that is already open in an editor puts two processes on the same transcript;
  the windows drift apart and the conversation ends up with two peer addresses — the
  coordinator may then send work to the window nobody is watching. Close the other side
  before continuing.
- **`orchestrator.sh` identifies its own session by walking up the process tree** until
  it finds the registry file named after a parent pid. A bash that runs detached from the
  session's process tree (sandboxes do this) cannot be identified; the script says so
  instead of guessing.

## Handing over to a fresh session

The user starts the new session themselves and tells the coordinator "take the newest
session". The coordinator finds it through the session registry instead of by name:

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

## The other half of the plugin

`/middle-management-setup` shows and edits the configuration (board path, protected
checkouts, staging guard). `/wt <name> new|list|done` creates and cleans up per-topic
worktrees, and a hook keeps edits out of the protected main checkouts. Roles work with no
configuration at all; the worktree part needs one entry per repo.

Pair this with your own team conventions — boards, handoff-doc naming, wrap rituals. The
plugin ships the mechanism, not your process.
