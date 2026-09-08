# Changelog

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
