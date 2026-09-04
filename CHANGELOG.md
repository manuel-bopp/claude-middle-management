# Changelog

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
