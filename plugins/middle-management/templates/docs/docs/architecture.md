# Architecture

Created: <YYYY-MM-DD HH:MM> · <model-id> · direct
Last updated: <YYYY-MM-DD HH:MM> · <model-id>

> Template skeleton. Keep it current, keep it short: what exists, how it connects, which
> decisions are already made. History belongs in the machine's session log, gotchas in
> `docs/lessons.md`, procedures in `docs/runbooks/`.

## What this is

<Two or three sentences: the system's purpose and its boundary — what is inside, what is not.>

## Components

| Component | Lives in | Talks to | Notes |
|-----------|----------|----------|-------|
| <name> | <path or host> | <component> | <one line> |

## Flow

<The main path through the system, one numbered step per hop: trigger → processing → storage →
output. Name the format at every hand-off, not just the direction.>

## Ports and endpoints

| Port / URL | Service | Host | Public? |
|------------|---------|------|---------|
| <port> | <service> | <host> | no |

## Decisions

One line each: what was decided, and the one reason it beat the alternative. A decision that gets
reopened twice belongs in `docs/lessons.md` instead.

- <decision> — <why>
