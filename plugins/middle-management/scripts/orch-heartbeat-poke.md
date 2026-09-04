# Heartbeat poke — what the coordinator does when it is re-triggered

Read by `orch-heartbeat.sh` (beside this file), which sends the text below the `---` line to the
coordinator session over its own Unix socket when that session's last turn got no answer.
`/middle-management-setup` copies this file to `<config dir>/middle-management-heartbeat/` ONCE;
later runs of the install step do not overwrite that copy, so edit the CUSTOMIZE lines there.
Prose below the line is the message; everything above it stays here.

---

Your last turn ended without an answer, and an unattended timer re-triggered you. **Do not answer
this message.** Work the checklist, then stop.

1. **If you already handled a heartbeat poke since your last completed answer: do nothing, stop.**
   If several copies arrived: act on the first one, ignore the rest.
2. **Am I still the coordinator?** Run `/orchestrator status`.
   - It names another session → you are a worker: send that session ONE peer message with what
     you would have written below, touch nothing else, stop.
   - It says there is no coordinator → the regime is off. Do nothing, stop.
3. **Reconcile board against roster.** Read the newest block of the board (CUSTOMIZE: the path
   configured as `board` by `/middle-management-setup`) and compare it with the live sessions
   (`<config dir>/sessions/*.json`; live = `kill -0 <pid>` and `kind == "interactive"`).
4. **Poke the workers whose turn may have died the same way.** For each live worker with an open
   lane, send ONE peer message, no reply requested: "your coordinator's turn died and was
   re-triggered; if your last turn ended in an API error, continue your lane now; keep working,
   hold outward coordination, close your books when done or blocked — do not answer this
   message." Workers that are gone: list them, do not resume them.
5. **Write ONE dated RE-WAKE line** at the top of the board: when the turn died, who was poked,
   who is gone, and what waits on your user with its default. Commit the board only — surgical,
   no push (CUSTOMIZE: your team's commit convention).
6. **Tell your user**, one short line (CUSTOMIZE: the same channel the heartbeat's
   `notifyCommand` uses — run that command with the line as its argument). Never echo a token.
7. **Stop.** No new work, no pushes, no outward posts beyond step 6, and never resume another
   session while its process may be alive.
