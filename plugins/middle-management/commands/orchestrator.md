---
description: Claim, release, or show the coordinator seat for parallel Claude Code sessions (middle-management)
argument-hint: "[claim|release [<sessionId>]|status]"
allowed-tools: ["Bash"]
---

# Coordinator seat

Exactly one session coordinates; every other session is a worker. This command manages
the marker that decides which one.

## Your task

1. Run this command verbatim (no arguments = `status`):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator.sh" $ARGUMENTS
   ```

   If `$ARGUMENTS` reaches you unsubstituted, put the subcommand the user asked for
   there instead.

2. Relay the script's output to the user as it is — it is short and already plain text.
   Do not paraphrase it away, do not add invented detail.

3. Add one sentence of context only where it helps:
   - after a successful `claim`: the role banner switches with the next message in every
     session on this machine.
   - on `BUSY` / `REFUSED`: say which session holds the seat and that only that session
     (or the user) can hand it over. Do not retry, and never delete the marker by hand.
     A `REFUSED` that prints `release <id>` means the holder is not visibly alive: rerun
     with that id ONLY when the user confirms the coordinator session is gone.
   - when a `claim` takes the seat from a holder that is still running: the script found two
     signals agreeing that the holder finished — its own closing line AND its session-log entry
     reading completed — plus an idle age past `MM_STALE_SEAT_MIN` (default 60 minutes), and
     prints the evidence it read off disk. Relay that evidence. A `BUSY` here names the signal
     that was missing; one signal is never enough, because two coordinators at once is worse
     than one expensive wake. That second signal comes from the machine's session log
     (`$MM_SESSION_LOG`, else the `sessionLog` config key, else `~/logs/session-log.md`), so on a
     machine that has none yet the refusal says exactly that and names the path — one wrap
     (`/middle-management:wrap`) in the holder's session creates it; README, "The session log". Asking the holder to release the seat stays the route for one that
     is live and still working, and for one idle less than that: its prompt cache is warm, so the
     message costs it almost nothing.
   - on `RACE LOST` or `FAILED`: the seat was NOT taken — another session claimed it a moment
     earlier, or the marker could not be written. Do not act as coordinator; run `status` and
     tell the user what it says.
   - on the "no session registry entry" error: the script ran outside this session's
     process tree (a sandboxed bash does that) — rerun it as a normal Bash call in this
     session.

Only run `claim` when the user asked for THIS session to coordinate. A hook hint that a
previous coordinator ended is not that request.
