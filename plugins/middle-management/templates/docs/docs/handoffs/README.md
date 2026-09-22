# Handoffs

Created: <YYYY-MM-DD HH:MM> · <model-id> · direct
Last updated: <YYYY-MM-DD HH:MM> · <model-id>

What one session leaves for the next. The wrap routine writes a handoff whenever its completeness
sweep finds something open that will not be finished in that session.

- **Name:** `<YYYY-MM-DD>_handoff-<topic>.md` — the date sorts, the topic is searchable.
- **Body:** the metadata block, 3–5 sentences of context (goal, current state), then one entry per
  open item: **status · the concrete next step · who it waits on · paths**.
- **Last two sections, in this order:** `## Suggested skills` (1–5, each with a one-clause why),
  then `## Coordinate Closet` — literal `key: value` lines pinning every exact identifier the next
  session needs: ticket ids, commit SHAs, ports, absolute paths, service names, URLs, branches.
  Prose is where coordinates silently drift; that block is the ground truth.
- **No second copies.** Anything already written down elsewhere is referenced by absolute path or
  full URL, not restated.
- **Lifecycle:** when the work is done, move the file to `docs/archive/` — create that directory
  the first time; nothing else in this skeleton does.

A handoff must work in a fresh session with no other context.
