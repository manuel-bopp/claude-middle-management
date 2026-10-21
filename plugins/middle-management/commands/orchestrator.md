---
description: Claim, release, or show the coordinator seat for parallel Claude Code sessions (middle-management)
argument-hint: "[claim [--thread <id>] [--morning]|release [<sessionId>]|status|t3-bind ...|t3-handover ...]"
allowed-tools: ["Bash", "mcp__t3-code__t3_thread_list", "mcp__t3-code__schedule_task", "mcp__t3-code__update_scheduled_task", "mcp__t3-code__delete_scheduled_task", "mcp__t3-code__t3_thread_send", "mcp__t3-code__t3_thread_launch"]
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
   Do not paraphrase it away, do not add invented detail. With scopes, the first line names
   the scope the command acted on; relay it.

3. Add one sentence of context only where it helps:
   - after a successful `claim`: the role banner switches with the next message in every
     session of its scope (with a `scopes` key; README, "Scopes"), otherwise in every session
     on this machine.
   - on `BUSY` / `REFUSED`: say which session holds the seat and that only that session
     (or the user) can hand it over. Do not retry, and never delete the marker by hand.
     A `REFUSED` that prints `release <id>` means the holder is not visibly alive, or alive in
     another scope (the script says so); then `claim` or `release <id>` work. Rerun with that id
     ONLY when the user confirms the coordinator session is gone or moved.
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
   - when `claim` prints "No morning ritual was delivered today": run the
     `middle-management:morning-ritual` skill now, step 6 (the user's to-do list) at least, before
     anything else — issue #2, the first coordinator of the day delivers what the headless run did not.
   - on `EXPIRED SEAT`: nothing of the holder moved for `MM_EXPIRED_SEAT_MIN` (default 360
     minutes), so the seat was taken without its closing line and the holder's wrap entry was
     backfilled into the session log (`BACKFILLED:` names the file) and its open-items drop got a
     `WRAPPED` line, so no ritual resumes it later. Relay the evidence; if the
     log line says `NOT completed`, tell the user the old coordinator's last work may be
     unfinished. The holder was not messaged — do not message it now either. A `WARNING` instead
     of `BACKFILLED` means the seat is yours but the entry must be written by hand.
   - on `MORNING TAKEOVER`: see "T3 Code", item 7. Relay the evidence and the `SETTLE` line, then do
     what it says before anything else.
   - on `RACE LOST` or `FAILED`: the seat was NOT taken — another session claimed it a moment
     earlier, or the marker could not be written. Do not act as coordinator; run `status` and
     tell the user what it says.
   - on the "no session registry entry" error: the script ran outside this session's
     process tree (a sandboxed bash does that) — rerun it as a normal Bash call in this
     session.

## T3 Code (this session runs in a T3 thread: `T3CODE_HOME` is set)

A worker's report reaches a T3 coordinator only through its report task, a webhook bound to the
coordinator's thread (README, "T3 Code"). A script cannot call MCP tools, so you do these steps:

1. **Claim:** `t3_thread_list` gives `currentThreadId`. Run
   `orchestrator.sh claim --thread <currentThreadId>`. A successor the holder named with
   `t3-handover` takes the seat this way even while the holder is alive.
2. **Report task:** `schedule_task` with `type: webhook`, bound to this thread, prompt exactly
   `{{body.prompt}}` (t3-wake.sh puts "Report from <from> (thread <id>): <text>" there, and a bare
   `Keepalive`, never wrapped).
3. **Bind:** `orchestrator.sh t3-bind --thread <id> --title <title> --task <taskId> --model <model>`,
   with the task's URL on **stdin** (never in argv, never printed, never in a reply). It writes the
   sidecar 0600 and, on a takeover, wakes the previous holder once.
4. **Model or effort change:** `update_scheduled_task` on the report task (or claim + t3-bind again).
   A webhook run keeps the model the task was created with.
5. **Handover:** launch the successor thread (`t3_thread_launch`), then
   `orchestrator.sh t3-handover --to-thread <id> --to-title <title>`. Keep seat and report task
   until the successor has claimed; forward late reports to it with `t3_thread_send`.
6. **Release / wrap:** `orchestrator.sh release` (it deletes the sidecar and prints the task id),
   then `delete_scheduled_task <that id>`.
7. **Asleep holder:** a `REFUSED ... asleep in T3 thread` means the holder's process ended but its
   thread still holds the seat. Wake it with `t3_thread_send <threadId>`. `--t3-asleep-ok` on `claim`
   or `release <id>` only on your user's explicit word; then delete the old report task it prints.
   **The one exception is the morning thread** (README, "Morning coordinator in T3 Code"): a thread
   the morning trigger started claims with `claim --thread <currentThreadId> --morning`. That route
   needs no word at runtime because the user's standing word sits in the config key
   `morningTakeover` (`{"allowed": true, "okBy": "<who, date>"}`); without it `--morning` is refused.
   It takes the seat of an asleep holder that has not moved for `MM_STALE_SEAT_MIN` (60 min),
   backfills the holder's wrap when its session-log entry is not completed, keeps the holder's
   thread and report task on record (`status` shows them as "Predecessor" until `t3-bind`, then as
   "previous holder"), and prints the settle step: `delete_scheduled_task <its report task>`, then
   settle its thread (morning-ritual step 3). Never `t3_thread_send` the predecessor. A live holder
   is not taken by `--morning`: the stale and expired rules above apply as for any claim.

`status` shows thread, title, report task, an open handover and the previous holder, never the URL.

Only run `claim` when the user asked for THIS session to coordinate. A hook hint that a
previous coordinator ended is not that request.
