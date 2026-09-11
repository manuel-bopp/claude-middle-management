---
description: Per-topic git worktrees for a configured checkout — create, list, run the lane's server, hold it against the reaper, remove it
argument-hint: <name> new|list|run|stop|hold|chown|done [topic] — or list | cap -- <cmd>
allowed-tools: ["Bash"]
---

# Worktree helper

Run the helper with the user's arguments, exactly once:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/wt" $ARGUMENTS
```

Then:

1. Relay the script's output to the user, including every warning it printed. It
   already names the worktree path, the branch, the base and the follow-up
   command — repeat those instead of inventing your own summary.
2. If the script exited non-zero, show its error line and stop. Errors about the
   config are fixed by the user running `/middle-management-setup`; do not edit the
   config file yourself here.
3. After a successful `new`, continue the user's implementation work inside the
   printed worktree path, not in the checkout root. If this session cannot edit
   there, tell the user to add it with `/add-dir` or to start a session in that
   directory.

Arguments the helper accepts, where `<name>` is a checkout name from the plugin
config (it lists the configured names when it does not recognise one):

| Arguments | What it does |
|---|---|
| `<name> new <topic>` | worktree plus branch off the configured base, dependencies installed |
| `<name> list` | the lanes of that checkout, one row each |
| `<name> run <topic> [-- <cmd>]` | start `<cmd>`, or the checkout's configured `serve` command, in the lane's worktree as a memory-capped systemd user unit |
| `<name> stop <topic>` | stop that unit, verified |
| `<name> hold <topic> <hours>` | keep the lane reaper off this lane; `0` clears the hold |
| `<name> chown <topic> <owner>` | hand the lane over: write `<owner>` into its owner marker, so it does not count as ownerless when the session that started it ends |
| `<name> done <topic>` | remove the worktree and delete its branch once it is merged |
| `list` | every configured checkout in one view |
| `cap -- <cmd>` | run one heavy command (test run, build) memory-capped, in the foreground |

`run`, `stop`, `hold` and `cap` need Linux with a systemd user manager; the helper
says so and refuses where there is none.
