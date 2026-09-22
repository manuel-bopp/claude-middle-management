<!-- Copy this to the machine's session log — `$MM_SESSION_LOG`, else the `sessionLog` key in
     <config-dir>/middle-management.json, else the default `~/logs/session-log.md`. ONE file per
     machine, never one per repository. Optional: `/middle-management:wrap` creates the file in
     this shape when it is missing, so copying it is a head start, not a prerequisite. -->

# Session log

Created: <YYYY-MM-DD HH:MM> · <model-id> · direct

Every session on this machine appends here — this is how parallel sessions, tomorrow's session and
the coordinator's tab list know what happened. The file is append-only, so it carries no
`Last updated:` line nobody would re-stamp. **Append at the end, never insert above** an existing
entry: the reader (`scripts/peer-state.py`) takes the *last* matching entry and the *last*
matching marker, so an entry written on top reads as the older one and a wrapped session reads as
still working. Day headings therefore run oldest → newest down the file.

**The format is frozen, and `/middle-management:wrap` owns it** — that skill is where it is
specified; this is one example of it. A day heading `## YYYY-MM-DD`, an entry header carrying this
session's display name (one word) between the en dashes, a `Status:` line, and — only in the entry
that ends the session — the closed marker, keyed by **sessionId** (names get recycled, ids do not).

---

## 2026-01-14

### 16:20 – [example-session-name] – Topic in a handful of words
- Where the work stood when the day ended
- Status: in-progress

## 2026-01-15

### 09:12 – [example-session-name] – Topic in a handful of words
- What was done, one bullet per step
- Files modified: `path/to/file`
- Status: completed
- Session: closed · 0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9
