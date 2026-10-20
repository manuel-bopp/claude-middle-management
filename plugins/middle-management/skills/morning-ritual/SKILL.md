---
name: morning-ritual
description: The coordinator's morning ritual — messages delta, repo state, wrap audit of yesterday's sessions, open-items sweep into the board, machine cleanup (stale dev servers, merged worktrees, dead watchers), your user's open to-do list, day plan for your user. Use when the user says "morning ritual" / "Morgenroutine" / "start my day", opens the day with a status ask, or a fresh coordinator session starts its first morning. Step 6 alone (the user's to-do list, delta since the last delivery) when the user asks "todo list", "my open to-dos", "meine offenen To-Dos" or "Was sind meine offenen To-Dos", and as part of a seat takeover when no headless ritual delivered it this morning. Coordinator sessions only — run this ONLY when the middle-management role hook says ORCHESTRATOR; in a worker session, point the user at the coordinator instead (exception: the unattended run started by the plugin's scripts/morning-headless.sh, whose prompt says so; it reads and reports only).
---

# Coordinator morning ritual

The first thing a coordinator session does each day. Run the seven steps in order;
steps 1–3 are independent — run their commands in parallel. Step 6 also runs on its own
(see there). Run headless by `scripts/morning-headless.sh` (a systemd timer, README "Headless
morning ritual"), the same steps apply read-only: no file written, no action taken, steps 3-5
become report lines for the coordinator, and the final message is the day plan. Everything here is
coordinator work: read, reconcile, route. Product/repo work stays delegated to
worker sessions.

Some steps touch things this plugin does not ship (your chat tool, your wrap
convention). Those carry a **CUSTOMIZE** marker: fill them with your team's actual
stack the first time you run this, and keep your concretization in your own notes
or a fork of this file.

With scopes (a `scopes` key in the config; middle-management skill, "Scopes"), every step is
your scope's: sessions from `peer-state.py --all --scope <yours>`, your scope's board (the one
your banner names) in step 4, and in step 5 only resources owned by your scope's sessions.
Another scope's lanes, servers and worktrees are never yours to clean, even when your board does
not name them; cross-scope findings go to that scope's coordinator. Step 6 (`open-items.py todo`)
already reads your scope's board and drop files. Your window file is your scope's:
`<config dir>/state/scopes/<name>/morning-ritual/window` for a named scope (the default scope keeps
`<config dir>/state/morning-ritual/window`); stamp that one in step 7. The headless runner serves
the default scope only, so a named scope's coordinator runs this ritual itself.

## 1. Messages delta — CUSTOMIZE

Window: since the last ritual run, the epoch in `<state dir>/morning-ritual/window` (`<state dir>` =
`<config dir>/state`, or with scopes your scope's: `scope.py of "$PWD" | cut -f2` prints it)
(`date -d @$(cat …)`; macOS `date -r $(cat …)`), written at the end of step 7 and by the headless runner; no file → yesterday
evening.

Read the delta from wherever your team talks — Slack/Teams/Discord channels, direct
messages to the coordinator, watched threads. Gotchas that generalize: channel
history usually does NOT include thread replies (fetch replies for every thread that
mattered), and an empty watcher log means UNANSWERED, not "no thread". If your team runs an
inbound path for the user's off-keyboard replies — the plugin ships none — read that inbox
too: a poke into a session is a hand-over, not a delivery, so the inbox is the only proof a
reply arrived. Never print tokens/secrets into output — load them into shell vars from your
secret store.

Then walk the question ledger (one row per open question: who was asked, where, when sent,
what waits on it, the default; see the middle-management skill): a row answered overnight is
acted on and deleted, a row past its time gets its default and says so in the day plan.

Done when every new message is routed: into the day plan, to a lane/worker, or
explicitly irrelevant, and every ledger row is answered, defaulted or still open on purpose.

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
**asleep in a T3 thread** (process gone, no closed marker, but T3 names the session:
`peer-state.py` LIVE "asleep (T3)", `open-items.py list` "asleep in T3 thread <id>") → it
is NOT dead and gets NO backfill and never `claude --resume` (T3 owns that session; a
headless run would be a second writer to its transcript and wrap it behind its back): wake
it with `t3_thread_send <id>` when its lane needs to move, else leave it for the day plan ·
test/probe artifact (nothing owed) · **dead without closing its books → headless
backfill** (never for a T3 session, see above): `claude --resume <sessionId> -p "<your wrap command> — backfill
(coordinator, date): …"`, sequential, in the background. The backfill prompt names:
why (session died), what is already recorded on the board (so work is NOT
repeated), the owed artifacts, its open-items drop file (`open-items.py list` marks
it "died unwrapped"; the wrap adds what is missing there and ends it with `--wrapped`),
and the guard rails: commit only that session's own files, board file explicitly
forbidden (the coordinator is its only writer), no pushes, no outward sends. Below
75% certainty whose a dirty file is: verify (mtime, transcript grep) or leave it
uncommitted and flag it — never guess ownership.

**T3 Code threads: settle, never archive.** A thread whose session-log entry carries
`Session: closed · <sessionId>` but which is still unsettled (`t3_thread_list`; `peer-state.py`
names the thread) gets settled, together with its sub-agent children, after a check for loose
ends per thread: last run state, a pending request, open items in its drop file, a dirty
worktree. Unpin pinned children first (a pinned thread never auto-settles). Never in bulk
without the list shown first; a thread with a loose end stays and goes to the day plan.

Done when every yesterday-transcript carries one of the five verdicts.

## 4. Open-items sweep → board

Start with `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/open-items.py" list`: every item a session
wrote to its drop file that is not on the board yet. File each by putting its key `<sid8>-W<n>`
in a board line, then `open-items.py done <file>` for every file it marks "all filed, session
gone" (rules: middle-management skill, "Open items"). A file marked "asleep in T3 thread <id>"
is woken with `t3_thread_send <id>`, never backfilled or resumed headless.

Then fold overnight movement into the board (config `.board`, or with scopes your scope's board, which the banner names; the coordinator is its only
writer): externally resolved items (merged PRs, answered threads, arrived reports),
the wrap-audit result, new sessions your user started this morning. Dated morning
block; if the board lives in a git repo, commit surgically — the board file plus
coordinator-owned docs only.

Close the step with the wave-end check from the middle-management skill, as if last night's
landings were a wave: re-read the lane rules and the head of the latest handover, count the
active lanes against your cap, re-scan the queue for packages the overnight landings unblocked,
and put base-moved notes on the board (overnight, every lane session is idle past the hour, so
none of them gets a message).

**Topics.** Read `<board dir>/<board name>.topics.md` (rendered by `topics.py` on every watcher
tick) and run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/topics.py" lint`: a listed log entry
without `Topic:` gets its topic booked with `topics.py entry --topic <key>`. Book your user's
answers and OKs from overnight with `topics.py answer --topic <key> "<text>"` and
`topics.py entry --topic <key> --status completed --stage done --ok "<who time>" "<headline>"`.
A topic leaves the table only with stage done, a review and an OK (and its case closed).

## 5. Machine cleanup

Free what yesterday left behind, before the day plan — so the plan reports what was
freed. Gather in one read-only pass, then act through ONE sub-agent with explicit PIDs (its
prompt carries `Report file: <absolute path>`, the middle-management:work-packages block; the
gate refuses it otherwise):

- **Lanes:** with the lane reaper installed (setup step 6), read its listing
  `<config dir>/state/wt/reaper-latest.md` instead of sweeping yourself — on its own 30-minute
  cycle it already stopped the lane units nobody was using and removed the worktrees of merged
  lanes. What is left for you are its **list only** rows: a dirty tree, unpushed commits, a
  pull request that is open, closed or absent, an unknown owner, a process sitting inside a
  worktree. Decide each by verified PID lineage (parent first, cwd inside the worktree), never
  by pattern. A dirty merged tree goes to your user — what is the dirty file? — never discarded
  blind. Without the reaper the same sweep by hand: `/wt list`, then `/wt <name> done <topic>`
  for every lane that reads `clean` and `merged yes`.
- **T3 worktrees** (`~/.t3/worktrees/`, never touched by `/wt` or the reaper): remove one only
  when its branch is merged into main AND its thread is settled (`t3_worktree_list` +
  `t3_thread_list settled=true`), with `git worktree remove`, never `--force` on a dirty tree.
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

## 6. Your user's to-do list

Also on its own: "todo list", "my open to-dos", "meine offenen To-Dos", "Was sind meine offenen
To-Dos" — run this step alone and answer with its result. A coordinator that takes the seat in the
morning runs it too when the headless ritual did not deliver today (no `window` file from today, or
your user says nothing arrived).

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/open-items.py" todo          # new since the last delivery
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/open-items.py" todo --all    # every open one, on request
```

It lists every open item whose owner is `user` (also `user+lane…`) from the board and the
open-items drops, not yet delivered: a board line `- <key> · owner: user · …` wins over the drop
file's line; `add --done` in the drop, or `<key> done` (also closed / answered / decided /
resolved / erledigt) on the board, closes one. Board items your
user owns must therefore sit on the board in that drop-line shape — that is what filing them with
the line `list` printed gives you.

Write it for your user, grouped by what they have to do, in this order, empty groups left out:
**decide** (a choice or a go only they can give) · **click** (open a link, approve, sign in) ·
**run** (a command or a session on their side) · **read** (a report or a doc to take in). One line
per item: what it is in one line of context, then the link or command **on the same line**, then
the key — delivery is recorded by the keys the message carries. No item without its link or
command when the line it came from has one. Too many for one message → the rest as one line
`+N more: open-items.py todo --all`, so they stay undelivered. Nothing new → one line saying so,
with the total still open.

Delivered = your user has the list in the chat or the channel. Then, and only then, run the
`todo --delivered <keys>` line the command printed (the exact keys it listed), so the next ritual
does not repeat them. A key that is still open stays in `todo --all`.

## 7. Day plan to your user

One message, in the language you talk to your user in, timestamped, links clickable,
every topic spelled out (no bare codenames): (a) what moved overnight, (b) the TOP
priority with a recommendation, (c) decisions pending on the user — each one line
with what unblocks it, (d) ready lanes they could open worker sessions for, (e) step 6's
to-do list. Lead with the delta; reference docs by path instead of retelling them.

Once it is out, stamp the window for the next ritual:
`mkdir -p "<state dir>/morning-ritual" && date +%s > "<state dir>/morning-ritual/window"` (step 1 names `<state dir>`).
