# Changelog

## Unreleased

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
