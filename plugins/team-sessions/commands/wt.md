---
description: Create, list or remove a per-topic git worktree for a configured checkout
argument-hint: <name> new|list|done [topic]
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
   config are fixed by the user running `/team-sessions-setup`; do not edit the
   config file yourself here.
3. After a successful `new`, continue the user's implementation work inside the
   printed worktree path, not in the checkout root. If this session cannot edit
   there, tell the user to add it with `/add-dir` or to start a session in that
   directory.

Arguments the helper accepts: `<name> new <topic>`, `<name> list`,
`<name> done <topic>`. `<name>` is a checkout name from the plugin config; the
helper lists the configured names when it does not recognise one.
