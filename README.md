# team-sessions — a Claude Code plugin for many parallel sessions on one machine

Run several Claude Code sessions side by side without them stepping on each other:
exactly **one coordinator** session plans and routes, every other session works and
reports back; implementation happens in **per-topic git worktrees** instead of a shared
checkout; and **blanket git staging** (`git add -A`) is blocked so sessions cannot
commit each other's work. The regime was extracted from a production multi-session
setup; this plugin packages it so installing it is two commands and requires **no
edits to your `settings.json` or `CLAUDE.md`**.

## Install

```
/plugin marketplace add <owner>/<repo>
/plugin install team-sessions@bopp-plugins
```

Then start a new session (or run `/reload-plugins`) so the hooks arm, and run
`/team-sessions-setup` once to configure the optional worktree part.

## What you get

| Piece | Kind | What it does |
|---|---|---|
| Session roles | UserPromptSubmit hook | Tells every session, on every message, whether it is the ORCHESTRATOR or a WORKER — including the operative rules for that role. Silent when no coordinator exists. |
| `/orchestrator claim\|release\|status` | command | Appoints this session as coordinator (marker file), hands the seat back, or shows who holds it. |
| Worktree guard | PreToolUse hook | Denies direct edits inside configured main checkouts and points to the worktree workflow instead. Dormant until you configure repos. |
| `/wt <name> new\|list\|done` | command | Creates/lists/removes per-topic worktrees with the branch based on your configured base branch, deps installed. |
| Staging guard | PreToolUse hook | Blocks `git add -A` / `git add .` / `git commit -a` so parallel sessions stage only their own files. Off-switch for solo users: `surgicalStaging: false`. |
| `/team-sessions-setup` | command | Shows the current config, then interviews you and writes/edits it — with validation. |
| `team-sessions` skill | skill | Extended reference: appointment, handover between sessions, troubleshooting. |

## How the roles work

1. Your user tells one session "you are the coordinator"; that session runs
   `/orchestrator claim`, which records its session id in
   `<config-dir>/state/orchestrator`.
2. On every user message, the role hook reads that marker plus Claude Code's live
   session registry and announces the session's role with its contract. Workers talk
   ONLY to the coordinator; the coordinator plans, routes, and does not build.
3. `release` (in the coordinating session) turns the regime off; with no living
   coordinator the hook is silent and every session works standalone.
4. Terminal fallback without the marker: start a session named `orchestrator`
   (`claude -n orchestrator`) — a living session whose name starts with `orch` counts.

Solo user with a single session? You do not need `claim` at all — install, configure
the worktree part if you like it, and ignore the roles.

## Configuration

One user-global file, `<config-dir>/team-sessions.json` (config dir =
`$CLAUDE_CONFIG_DIR` or `~/.claude`), written for you by `/team-sessions-setup`:

```json
{
  "board": "/abs/path/to/your-status-board.md",
  "surgicalStaging": true,
  "protectedCheckouts": [
    { "name": "app",
      "root": "/home/you/code/app",
      "base": "origin/dev",
      "install": "npm install",
      "worktreeDir": "/home/you/code/.worktrees-app" }
  ]
}
```

- `board` (optional): a status/waiting board only the coordinator writes; workers read.
- `protectedCheckouts` (optional): repos whose main checkout is edit-protected;
  work happens in worktrees under `worktreeDir`. `base` is the branch new worktree
  branches start from — setup always writes it explicitly.
- No config file = roles-only mode; the worktree part stays completely silent.
- User-global on purpose: the coordinator seat is per machine, and protected checkouts
  are absolute paths independent of any one project. One board per machine for now.

## Failure policy (loud, not silent)

If `jq` is missing, the session registry is absent, the config file is invalid, or an
override marker was left behind, the role hook says so **on every message** — the
plugin never degrades silently. While the config is invalid, the worktree guard and
`/wt` are disarmed (announced) and the staging guard is forced ON.

## Honesty notes

- The worktree guard is a **guardrail, not a security boundary**: it intercepts the
  Edit/Write tools, not Bash-side writes (`sed -i`, redirects, `git checkout`).
- The staging guard's escape hatch: only when your user explicitly allows a direct
  main-checkout edit in the session, the deny message names an override marker;
  delete the marker right after — the role hook nags while it exists.
- Hooks **auto-update** with the marketplace by default. After an update, restart open
  sessions. If a broken update worries you, disable auto-update for this marketplace.
- Command names `/wt`, `/orchestrator` are short and generic; collision behavior with
  same-named commands from other plugins is untested.
- Uninstall (`/plugin uninstall team-sessions`) removes the plugin but NOT your data:
  `<config-dir>/team-sessions.json` and `<config-dir>/state/{orchestrator,allow-main-checkout-edits}`
  stay; delete them by hand if you want a clean slate.

## Requirements

- Claude Code recent enough to have the session registry (`<config-dir>/sessions/`)
  and cross-session peer messaging — the substrate the roles ride on.
- `jq`, `bash`, POSIX `ps`/`kill`. Linux tested; macOS expected-compatible but
  untested; Windows via WSL.
- For a private marketplace repo: working git credentials for the host on every
  installing machine (`/plugin marketplace add` clones over git).

## Why this exists

Many parallel sessions on one machine kept messaging each other crosswise, turning
the human into a context courier, committing each other's files, and editing a shared
checkout underneath a running dev server. The fix that stuck: one coordinator session
with the only pen for the board, per-topic worktrees with one branch and one small PR
per lane, and surgical staging. This plugin is that setup, made portable.
