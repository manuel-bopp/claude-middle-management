---
description: Show and edit the team-sessions config — protected checkouts, staging protection, board path
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
---

# team-sessions setup

Show the user their current configuration, interview them about the changes they
want, then write the file back and validate it. The config is one JSON file that
arms the worktree guard, the `/wt` helper and the blanket-staging guard.

Schema (nothing else is valid):

```json
{
  "board": "/abs/path/to/board.md",
  "surgicalStaging": true,
  "protectedCheckouts": [
    { "name": "app", "root": "/abs/path/repo", "base": "origin/main",
      "install": "npm install", "worktreeDir": "/abs/path/.worktrees-app" }
  ]
}
```

`name`, `root` and `base` are required per entry; `install` and `worktreeDir`
are optional; `board` and `surgicalStaging` are optional top-level keys.

## Step 1 — show the current state first

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG="$(bash "$CHECK" file)"; echo "config file: $CFG"
bash "$CHECK" validate; echo "validate status: $?"
[ -f "$CFG" ] && cat "$CFG"
```

Status codes: `0` valid · `1` invalid (unparseable or wrong shape) · `2` no
config file yet · `3` jq is not installed.

On status `3`, stop here: tell the user the plugin needs `jq` and that setup
cannot validate anything without it.

Otherwise report to the user, in plain text: the config path, the status, and —
for each configured checkout — name, root, base, install command, and the
effective worktree directory (the configured `worktreeDir`, or the sibling
default `<parent of root>/.worktrees-<name>`). Also report the board path and
whether `surgicalStaging` is on. With no config yet, say "none yet" instead of
inventing defaults.

Done when the user has seen the current state. Never skip this: step 3 rewrites
the whole file, so entries you did not read here would be lost.

## Step 2 — interview

Ask short questions, one topic at a time. **Below ~75% confidence about what the
user wants, ask instead of assuming.** Never scan the filesystem for
repositories; the user names them.

1. **Which checkouts to protect.** Offer the current session's repository as a
   candidate:

   ```bash
   git rev-parse --show-toplevel 2>/dev/null
   ```

   Ask the user to name any further repository paths. Verify each named path and
   use the canonical root it prints:

   ```bash
   git -C "<path>" rev-parse --show-toplevel
   ```

   A path that fails this is not a git repository — say so and ask again.

2. **Name.** Derive it from the basename of the root; it is what the user types
   in `/wt <name> new <topic>` and what the guard's deny message prints. On a
   collision with another entry, append the parent directory's name or ask the
   user for a name.

3. **Base branch.** Detect a candidate, `origin/HEAD` first, current branch as
   the fallback:

   ```bash
   git -C "<root>" symbolic-ref --quiet --short refs/remotes/origin/HEAD
   git -C "<root>" rev-parse --abbrev-ref HEAD
   ```

   Show the candidate and have the user confirm it, because teams often branch
   off an integration branch that `origin/HEAD` does not point at. Write `base`
   explicitly for every entry — there is no default anywhere.

4. **Install command.** Ask for the command that installs dependencies in a
   fresh worktree (for example `npm install`). It runs as `sh -c "<command>"`
   inside the new worktree. Empty means the step is skipped.

5. **Worktree directory.** State the default — the sibling directory
   `<parent of root>/.worktrees-<name>` — and ask only whether the user wants a
   different one. Keep it outside the root so the checkout stays clean. Write
   the `worktreeDir` key only for a custom directory.

6. **Staging protection.** Ask: "Do you run several Claude Code sessions in
   parallel on this machine?" Yes means `surgicalStaging: true` (blanket
   `git add -A` and `git commit -a` are blocked so sessions cannot commit each
   other's work); no means `false`. Write the key explicitly.

7. **Board.** Ask for the path of the shared board document the coordinator
   maintains, if the user keeps one. Omit the key when there is none.

On a re-run, walk the existing entries with the user first: keep, edit or
remove each one, then ask about additions. An entry the user removes is dropped
from the file.

Done when every key you are about to write has either a confirmed value or a
deliberate omission.

## Step 3 — write and validate

`config-check.sh` validates the resolved config path, not an arbitrary file, so
back up, write, validate, and restore the backup if validation fails. Write the
complete file — every entry the user kept plus the new ones.

```bash
CHECK="${CLAUDE_PLUGIN_ROOT}/scripts/config-check.sh"
CFG="$(bash "$CHECK" file)"
mkdir -p "$(dirname "$CFG")"
[ -f "$CFG" ] && cp "$CFG" "$CFG.bak"
cat > "$CFG" <<'JSON'
{
  "surgicalStaging": true,
  "protectedCheckouts": [
    { "name": "app", "root": "/abs/path/repo", "base": "origin/main", "install": "npm install" }
  ]
}
JSON
if bash "$CHECK" validate; then
  rm -f "$CFG.bak"; echo "written and valid: $CFG"
elif [ -f "$CFG.bak" ]; then
  mv "$CFG.bak" "$CFG"; echo "invalid — previous config restored, nothing changed"
else
  rm -f "$CFG"; echo "invalid — no config written"
fi
```

If validation failed, show the user the JSON you tried to write and what the
schema requires, then correct it and run the block again.

## Step 4 — summarise

Tell the user what is protected now: per checkout the name, root, base and
effective worktree directory; whether blanket staging is blocked; the board
path. Add the two operational facts: implementation work goes into a worktree
via `/wt <name> new <topic>`, and the config takes effect immediately — the
hooks read it on every run, so no restart is needed.
