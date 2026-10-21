---
name: self-wakeup
description: Wait on something only your user can give (a reply to a question, an approval, a session they must start) without idling for hours. Schedules escalating self-wakeups, checks on each wake whether the user responded, and proceeds autonomously ONLY on a decision you are at least 75% sure of AND that is safe and reversible; otherwise waits another, longer stage. Use when you are blocked on the user and the work would otherwise stall, or when the user says things like "wake yourself and check", "wait for me but don't just sit there", "proceed if I don't answer", "set a timer on this", or asks for self-wake, escalation or a wait-then-proceed on a pending decision. Do NOT use for destructive or outward-facing actions (sending, deleting, pushing, publishing: those always need explicit human approval), and do NOT use when the pending decision is genuinely unclear or high-stakes; there, stay blocked and keep asking.
---

# self-wakeup: wait for your user without stalling

You are blocked on your user for a reply, an approval, or a session they must start. Instead of
sitting idle until they happen to return, you wait in stages: wake yourself, check, and either act
or wait longer. The point is to keep clearly decided, low-risk work moving when they are slow,
never to substitute your judgment for theirs on anything that matters.

In the coordinator regime (middle-management skill): a WORKER that waits on the user reports the
wait to its coordinator instead (the coordinator surfaces every wait to the user); this skill is
for the coordinator, and for sessions that run without one.

## The one rule that governs everything

**Proceed autonomously only when BOTH hold:**
1. You are **at least 75% sure** what your user would choose (the option is obvious, or they
   pre-signalled it, or your house rules name an unambiguous recommended option), AND
2. The action is **safe and reversible**: no send or post, no delete or overwrite, no push or
   publish, nothing outward-facing or hard to undo.

If either fails: **do not act. Keep waiting or hand back.** Destructive and outward-facing actions
ALWAYS need explicit human approval, no matter how long the user is gone.

## Procedure

1. **State the pending decision and your default.** In one line: what you are waiting on, and the
   specific action you would take if the user stays silent (the recommended option). If you cannot
   name a safe default you are at least 75% sure of, this skill does not apply: stay blocked and
   keep asking.

2. **Set the escalation ladder.** Pick delays that match what you are waiting for; `ScheduleWakeup`
   clamps each `delaySeconds` to [60, 3600] (no such tool in your harness: use its own scheduled
   wake, or a background `sleep` that re-invokes you when it ends). A sensible default ladder
   roughly doubles: about 300 s, 900 s, 1800 s, 3600 s (5, 15, 30, 60 minutes), at most 4 to 5
   stages. Shorten it for time-sensitive work, lengthen it for quiet holds. Call `ScheduleWakeup`
   with that delay, a one-line `reason` (what you are waiting for) and `noop: true` (nothing changed
   yet), and pass the same task `prompt` back so the next wake re-enters this procedure. Then send
   ONE nudge right away (see **Nudge** below): you use this skill because the user is away, so
   alert them early rather than waiting silently.

3. **On each wake, check first: did the user respond?**
   - **Responded:** act on what they said and `ScheduleWakeup({stop: true})`. Done. Their input
     always wins; never proceed on your default after they have spoken.
   - **No response:** go to step 4.

4. **Decide: proceed, or escalate.**
   - If the one rule above holds (at least 75% sure AND safe and reversible): **do the recommended
     option now**, record the decision where it belongs (your report, plus the board or log your
     project keeps; say plainly that you proceeded because the user was unreachable, and what you
     chose), then `ScheduleWakeup({stop: true})`.
   - Otherwise: **escalate**: schedule the next, longer stage (`ScheduleWakeup` with the next delay,
     `noop: true`). Do NOT re-nudge every stage: after the early nudge from step 2, send a second
     nudge only near the FINAL stage (or at the handback, step 5). Then wait.

5. **Ladder exhausted, still blocked, still cannot safely proceed:** stop the loop and hand back
   clearly: "still waiting on X after N stages; I will not proceed because it is risky / outward-
   facing / unclear; here is the recommended option for when you are back." Do not keep
   rescheduling forever.

## Nudge

A nudge reaches the user through the plugin's one sender, `notifyCommand` (config,
`/middle-management-setup`). It is useless if the user cannot tell WHICH of their sessions and
machines it comes from, so every nudge names the host, the session and its topic, the pending
decision, your default and the stage. Never a bare "a session is waiting".

```bash
CFG="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh" file)"
CMD="$(jq -r '.notifyCommand // ""' "$CFG")"
MSG="[$(hostname -s)] <your session name> (<topic>): waiting on <what you need>. My default if you stay silent: <recommended option>. Stage <N>/<M>."
if [ -n "$CMD" ] && printf '%s\n' "$MSG" | sh -c "$CMD" notify "$MSG" >/dev/null 2>&1; then echo "nudge: sent"; else echo "nudge: NOT sent"; fi
```

- **Session name:** your own (the role banner names it; else your registry entry in
  `<config dir>/sessions/*.json`, found by your sessionId).
- **Language:** the one you talk to your user in.
- No `notifyCommand`, or the send fails: note it and keep waiting on the schedule anyway. A failed
  nudge is never a reason to proceed.

## Notes

- This runs as a self-paced loop: each `ScheduleWakeup` schedules exactly the next wake, and you
  re-enter this procedure when it fires. `stop: true` ends it. Set `noop: false` on a wake only when
  you actually did something worth keeping (you proceeded, nudged, or advanced state).
- "The user responded" means genuine new user input since you posed the question. A background or
  task notification, a message from another session, or your own earlier text is NOT a response
  and NOT approval.
- Escalation is about the WAIT interval and the nudge, not about lowering the 75% and safety bar.
  The bar never drops because you have waited longer; a risky decision stays the user's no matter
  what.
- Keep the held context lean: you only need the pending decision, your default, and the stage.
