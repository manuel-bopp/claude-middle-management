---
name: morning-ritual
description: The coordinator's morning ritual — messages delta, repo state, wrap audit of yesterday's sessions, open-items sweep into the board, machine cleanup (stale dev servers, merged worktrees, dead watchers), day plan for your user. Use when the user says "morning ritual" / "Morgenroutine" / "start my day", opens the day with a status ask, or a fresh coordinator session starts its first morning. Coordinator sessions only — run this ONLY when the middle-management role hook says ORCHESTRATOR; in a worker session, point the user at the coordinator instead.
---

# Coordinator morning ritual

The first thing a coordinator session does each day. Run the six steps in order;
steps 1–3 are independent — run their commands in parallel. Everything here is
coordinator work: read, reconcile, route. Product/repo work stays delegated to
worker sessions.

Some steps touch things this plugin does not ship (your chat tool, your wrap
convention). Those carry a **CUSTOMIZE** marker: fill them with your team's actual
stack the first time you run this, and keep your concretization in your own notes
or a fork of this file.

## 1. Messages delta — CUSTOMIZE

Window: since the last ritual run (default: yesterday evening).

Read the delta from wherever your team talks — Slack/Teams/Discord channels, direct
messages to the coordinator, watched threads. Gotchas that generalize: channel
history usually does NOT include thread replies (fetch replies for every thread that
mattered), and an empty watcher log means UNANSWERED, not "no thread". If your team runs an
inbound path for the user's off-keyboard replies — the plugin ships none — read that inbox
too: a poke into a session is a hand-over, not a delivery, so the inbox is the only proof a
reply arrived. Never print tokens/secrets into output — load them into shell vars from your
secret store.

Done when every new message is routed: into the day plan, to a lane/worker, or
explicitly irrelevant.

## 2. Repo state

For every entry in `protectedCheckouts` (config: run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh" file` and read it):

- `git -C <root> fetch origin`.
- Open PRs with review state (`gh pr list --json number,title,reviewDecision,updatedAt`)
  and new comments on watched issues, where `gh` is available. A PR missing from the
  open list has MOVED — verify merged/closed before reporting it.
- Standing promotion check — CUSTOMIZE with your branch pair: if fixes ride an
  integration branch (say `dev`) that deploys later than production (`main`), check
  `git merge-base --is-ancestor <integration-head> origin/<production>`. An
  unpromoted security fix means the hole is LIVE in prod; that finding leads the
  day plan.

Done when every WAITS-ON item on the board has a fresh verdict: moved or unchanged.

## 3. Wrap audit (yesterday's sessions)

Reconcile three sources by sessionId — never by peer name (client reconnects
re-register sessions under NEW names; map names via the session registry,
`<config-dir>/sessions/*.json`):

- Registry + PID liveness (`kill -0 <pid>` per registry entry) — entries with
  `kind != "interactive"` (bg/daemon) are not sessions your user sits in front of; skip them.
- Yesterday's block in your team's session log, if you keep one — CUSTOMIZE: this
  plugin ships the roles, your team ships the wrap convention; if you have none,
  skip the audit or start keeping one. The entries and `- Session: closed · <sessionId>`
  markers this audit reads are what the shipped `middle-management:wrap` skill writes, so a
  team without its own convention gets one by pointing every session at that skill.
- Transcripts: `ls -t ~/.claude/projects/<project-slug>/*.jsonl` — anything modified
  yesterday needs an explanation.

Verdict per transcript: wrapped ✓ (log entry exists) · still-active (live PID) ·
test/probe artifact (nothing owed) · **dead without closing its books → headless
backfill**: `claude --resume <sessionId> -p "<your wrap command> — backfill
(coordinator, date): …"`, sequential, in the background. The backfill prompt names:
why (session died), what is already recorded on the board (so work is NOT
repeated), the owed artifacts, and the guard rails: commit only that session's own
files, board file explicitly forbidden (the coordinator is its only writer), no
pushes, no outward sends. Below 75% certainty whose a dirty file is: verify (mtime,
transcript grep) or leave it uncommitted and flag it — never guess ownership.

Done when every yesterday-transcript carries one of the four verdicts.

## 4. Open-items sweep → board

Fold overnight movement into the board (config `.board`; the coordinator is its only
writer): externally resolved items (merged PRs, answered threads, arrived reports),
the wrap-audit result, new sessions your user started this morning. Dated morning
block; if the board lives in a git repo, commit surgically — the board file plus
coordinator-owned docs only.

## 5. Machine cleanup

Free what yesterday left behind, before the day plan — so the plan reports what was
freed. Gather in one read-only pass, then act through ONE sub-agent with explicit PIDs:

- **Lanes:** with the lane reaper installed (setup step 6), read its listing
  `<config dir>/state/wt/reaper-latest.md` instead of sweeping yourself — on its own 30-minute
  cycle it already stopped the lane units nobody was using and removed the worktrees of merged
  lanes. What is left for you are its **list only** rows: a dirty tree, unpushed commits, a
  pull request that is open, closed or absent, an unknown owner, a process sitting inside a
  worktree. Decide each by verified PID lineage (parent first, cwd inside the worktree), never
  by pattern. A dirty merged tree goes to your user — what is the dirty file? — never discarded
  blind. Without the reaper the same sweep by hand: `/wt list`, then `/wt <name> done <topic>`
  for every lane that reads `clean` and `merged yes`.
- **Branch deletion:** branches of merged or closed pull requests go without asking, with
  `git update-ref -d refs/heads/<branch>` after recording the tip SHA and checking that no
  worktree still has the branch checked out (`git branch -D` is deny-listed in careful setups,
  and `branch -d` refuses a squash-merged branch). `/wt <name> done` already does it this way.
- **Dev servers outside a lane:** `ss -ltnp` over your dev-port range (CUSTOMIZE — Linux only;
  on macOS `lsof -iTCP -sTCP:LISTEN -n -P`) plus `pgrep -af` for your dev-server commands
  (CUSTOMIZE — on macOS `pgrep -fl`). A server whose lane is closed on the board is stale;
  the shared ones (the main checkout's server, shared backends) always stay. Kill by verified
  PID lineage, never by pattern.
- **Watchers:** long-running pollers your team runs (`pgrep -af <watcher>` — CUSTOMIZE)
  whose thread is answered or whose ask is moot (PR merged, decision taken) are killed by
  PID; the board names the live ones.
- **Memory:** `free -m` before and after — CUSTOMIZE, Linux only; on macOS `vm_stat` (pages, so
  multiply by the page size) or `top -l 1 -s 0 | head -12`. Both numbers go into the day plan.

Done when no listening port, worktree or watcher on the machine lacks a live owner on the
board. Ownership below 75% certain → leave it, list it under "unclear" in the day plan.

## 6. Day plan to your user

One message, in the language you talk to your user in, timestamped, links clickable,
every topic spelled out (no bare codenames): (a) what moved overnight, (b) the TOP
priority with a recommendation, (c) decisions pending on the user — each one line
with what unblocks it, (d) ready lanes they could open worker sessions for. Lead
with the delta; reference docs by path instead of retelling them.
