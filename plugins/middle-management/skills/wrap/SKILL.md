---
name: wrap
description: The end-of-session routine every middle-management session runs, and the one the coordinator's tab list (`scripts/peer-state.py`) reads its verdict from — update the docs this session touched, harvest what was learned, write the session-log entry with the `Session: closed · <sessionId>` marker, sweep the whole session for open items and give each one an owner, write a handoff when anything stays open, and end on the three closing lines that tell your user this tab can go. Use when the user says "/wrap", "wrap", "wrap up", "wrap this session", "Session Wrap Up", "update the docs", "update the documentation", "Bitte update die Dokumentationen", "Update die Docs", "Session abschließen", or when a session's work is finished and its tab is about to be closed.
---

# Wrap — closing one session

Nine steps, in order. The coordinator's tab list (`scripts/peer-state.py --wrapped`) reads its
verdict out of what this routine writes — the session-log marker first, the closing lines as the
fallback — and both must come from the same wrap in the same session, or neither counts: a
closing phrase whose log entry says anything but `Status: completed` reads as a coordinator
writing about someone else's tab.

Steps marked **optional** need something this plugin does not ship: missing → do the named
fallback, say so in one line of the recap, and carry on — never an error, never a stop.
**Precedence:** where a personal `~/.claude/skills/wrap` exists, that one wins the bare `/wrap`;
this skill is addressed `/middle-management:wrap`.

## 0. Resolve your name and your sessionId

Two identifiers, never merged. The **display name** is for your user's eyes and goes in the
closing block and the log entry's bracket; the **sessionId** is the machine identity and goes in
the closed marker, nowhere else. Names are recycled and change on resume, the id does not; both
sit as `.name` and `.sessionId` in `<config-dir>/sessions/<pid>.json`, which `/orchestrator
status` prints too. Without the plugin, walk up from a Bash call (works from a sub-agent too):

```bash
p=$$; for i in $(seq 1 12); do p=$(ps -o ppid= -p "$p" | tr -d ' '); [ -z "$p" ] && break
  [ -f "$HOME/.claude/sessions/$p.json" ] && { jq -r '.name, .sessionId' "$HOME/.claude/sessions/$p.json"; break; }; done
```

With `CLAUDE_CONFIG_DIR` set, substitute it for `$HOME/.claude`. Never invent a name: nothing
resolved → line 1 of the closing block reads "I am the session in this tab (name unresolved)".

## 1. Discover the project

Glob, do not assume: `docs/**/*.md`, `**/runbooks/**`, `**/lessons/**`, `CLAUDE.md`, and wherever
this project keeps handoffs; note whether the root is a git repository. A wrap **never scaffolds
and never overwrites** a project's `CLAUDE.md` or docs: no `docs/` at all → one line in the recap
naming `${CLAUDE_PLUGIN_ROOT}/templates/docs/` as a skeleton to start from, then carry on.

## 2. Update only the docs this session touched

Architecture when services, ports or structure moved; runbooks when a procedure changed; the
roadmap when items closed; the file index with **one** `what → where` line per new file or
feature. Pointer tables hold one-liners, never changelogs — the detail belongs in the target doc,
and CLAUDE.md takes only behavioural rules, its pointer table and the directory tree. Where the
project already carries `Created:` / `Last updated:` metadata, bump `Last updated:` on every file
you edited and never touch `Created:`. **Optional:** no such convention → skip it, do not
introduce one.

## 3. Harvest what was learned — optional

Signals: your user corrected you, something failed unexpectedly, a new service or tool arrived, a
preference was stated. Record durable facts in What / Why / Fix form — never a dated changelog,
that is step 4's job — and supersede a stale lesson by rewriting it, not by appending "RESOLVED".
Store them in a memory/knowledge-graph MCP server (`mcp__memory__*`) when those tools are in this
session. **Missing → append to `docs/lessons.md`**, and one line names which store took it.

## 4. Session-log entry — never skipped

Path, first hit wins: `$MM_SESSION_LOG` · `sessionLog` in `<config-dir>/middle-management.json` ·
`~/logs/session-log.md`. Create the file and its parent directory when they do not exist. The
format is frozen — `scripts/peer-state.py` parses exactly this:

```
## 2026-01-15

### 15:05 – [your-session-name] – Topic in a handful of words
- What was done (one bullet per step)
- Files modified: `path/to/file`
- Status: completed
- Session: closed · 0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9
```

- **Where it goes** — **append at the end of the file, never insert above** an existing entry:
  the reader keeps the *last* matching entry and the *last* matching marker, so an entry written
  on top reads as the older one and a wrapped session reads as still working.
- **The `## YYYY-MM-DD` day heading** — is the file's last `## YYYY-MM-DD` heading not today's?
  Then append `## <today>` before your entry. A marker missing either the day heading or its
  `### HH:MM` entry header is discarded in silence: staleness cannot be checked on it.
- **The entry header** — `###`, `HH:MM`, en dash `–`, your display name in brackets — **one
  word**, since the parser keeps the first one; model, role and a former name go after a `/` —
  en dash, the topic; that topic is the tab list's topic column, an empty bracket voids the entry.
- **`Status:`** — this entry's work, and it must read `completed` for the session to count as
  wrapped. Ending blocked → `Status: blocked`, the marker still goes in, and the seat is released
  rather than taken over. A separate line from the marker, which is about the session's life.
- **Lane teardown** — working a `/wt` lane? End it here: `/wt <name> done <topic>`, or
  `/wt <name> hold <topic> <hours>` naming the reason the slot has to stay, and the `/wt list`
  line that proves worktree and unit are gone goes in this entry as a bullet. No lane → skip it,
  one line of the recap says so.
- **`- Session: closed · <sessionId>`** — only in the entry that ends the session. Full id or a
  ≥8-character prefix (one matching two sessionIds on the machine names neither and is refused),
  optional ` — a few words` after it; stale 30 minutes after the entry's own timestamp if the
  session keeps working, i.e. after a resume.

## 5. Completeness sweep, then the handoff

Walk the session from its beginning, not just the last stretch: open decisions, started-but-
unfinished work, promises you made and did not keep, findings neither fixed nor filed, work now
waiting on someone else. Give each a stable ID `W1, W2, …` and an **owner**, and state the result
in the recap either way — the list, or "Completeness sweep: nothing open."

Anything open that will not be finished here gets `docs/handoffs/<YYYY-MM-DD>_handoff-<topic>.md`:
3–5 sentences of context, then per item status · next step · who it waits on · paths, ending on
`## Suggested skills` and, last, `## Coordinate Closet` — literal `key: value` coordinates: ids,
SHAs, ports, absolute paths, branch names. The copy-paste next-session prompt goes in the recap
with a `Recommended model:` line. Items waiting on your user go under "Your call" instead.

## 6. File the open items — optional

With a tracker reachable from this session (its MCP server, `gh issue`, a capture skill): file
every uncaptured, actionable item as a full ticket — context, links, acceptance criteria — after
checking for duplicates. **Missing → the handoff is the record**, and one line says so.

## 7. Commit — git repositories only

Skip the step entirely otherwise. Run the repo's configured formatter/linter if one is configured
*and* installed (never install one). Stage **by pathspec, your own session's files only** —
`git add -A` sweeps a parallel session's parked work into your commit, which is what this
plugin's staging guard exists to stop — then commit with a message mirroring the log headline.
**Never push**; mention push status only where a remote exists.

## 8. Recap, then the three closing lines

Recap in the language of the chat: headline sentence · what happened (3–7 bullets of the real
work, not the doc updates) · what the wrap itself did · the sweep result · a self-critique where
every kept doubt names the command that would settle it or is dropped, the cheap ones run now and
a confirmed defect acted on rather than narrated · "Your call" · the handoff prompt. Links
absolute. Holding the coordinator seat? `/orchestrator release` now, while you are still warm.

Then the block, last, with **nothing after it** — the match runs in the last 200 characters of
your message. Lines 1 and 2 follow the language of the chat; **line 3 is always the literal
`Close this tab.`, alone on the last line, in every language** (the user scans for that one
fixed string; a translated or reworded line is what he asked to have removed, 2026-09-23):

```
I am session <your name>.
Our topic was: <a handful of words>.
Close this tab.
```

```
Ich bin Session <resolved session name>.
Unser Topic war: <a handful of words>.
Close this tab.
```

Never "Diesen Tab kannst du schließen.", never "You can close this tab.", never the sentence
folded into a paragraph. A near-variant of your own invention — "closing out here", "I'm done
here" — matches nothing: the session reads as still working and gets woken to be told it is
finished, which costs it its whole conversation as fresh input. Report to the coordinator by peer message where one exists,
otherwise to your user in chat; the **recap** goes in the tab, never through `notifyCommand`.
