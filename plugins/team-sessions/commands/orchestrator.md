---
description: Claim, release, or show the coordinator seat for parallel Claude Code sessions (team-sessions)
argument-hint: "[claim|release|status]"
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
   - on the "no session registry entry" error: the script ran outside this session's
     process tree (a sandboxed bash does that) — rerun it as a normal Bash call in this
     session.

Only run `claim` when the user asked for THIS session to coordinate. A hook hint that a
previous coordinator ended is not that request.
