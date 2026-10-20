---
name: work-packages
description: The working scheme for every sub-agent, so one that dies on a limit or server error leaves its work on disk - the `Report file:` block for the prompt, package-by-package results, resume via SendMessage before any respawn, and how big a sub-agent job should be. Use BEFORE writing any Agent tool prompt, when the work-packages gate denies an Agent call, when a sub-agent ended without its report, and on "work packages", "Arbeitspakete", "report file".
---

# Work packages: every sub-agent leaves its work on disk

A sub-agent that dies on a limit or a server error loses everything that lives only in its
context. A hook cannot catch that death (no hook output reaches anyone after an API error), so
the work itself must be on disk as it goes. The cost is a few appends; the gain is a resume
instead of a re-run.

## The parent: before you spawn

1. **Is this a sub-agent job at all?** One sub-agent per independent deliverable that needs fresh
   context: a plan review, the build of one module or file group, a diff review, one research
   question. Not for anything under ~5 min of work, not for anything that needs your
   conversation. 2-4 in parallel, rarely more. Inside one agent, packages of ~10-30 min each.
   Twenty agents that each re-read the same files cost more than one agent with five packages.
2. **Follow-ups go to the same agent** via `SendMessage` to its id (it keeps its context and its
   cache), not to a new one.
3. **Paste the block below** into the prompt, with an absolute path the agent can write. The
   gate (`hooks/require-work-packages.sh`) denies an Agent call without a `Report file:` line.
   `Report file: none` is for quick read-only lookups under 5 minutes; `subagent_type: Explore`
   needs no line.

```
Working scheme (middle-management:work-packages):
Report file: <absolute path, e.g. <lane folder>/<agent name>-report.md>
1. Before any other work, write the report file: a title, then `## Packages` with 1..n, each with its done-criterion.
2. After EACH package, append `## Package N: done · <result, paths>` at once, before you start N+1.
3. If you are resumed, read the report file first and continue at the first open package.
4. Final answer: at most 10 lines plus the report file path. The details stay in the file.
```

## The sub-agent: while you work

Follow the four lines of the block. Write findings into the file as they happen, not at the end:
the end is exactly what a limit takes away. A package marked done names its result and its paths,
so a reader (or your resumed self) does not have to redo it.

## Recovery: resume before respawn

When a sub-agent died (error, limit) or ended without its report:
1. **`SendMessage` to its agent id** first: "You were cut off. Read your report file <path> and
   continue at the first open package." Its transcript survives the death; the resume keeps the
   whole context and is far cheaper than a fresh agent that re-reads everything.
2. Only if the resume fails too (the id is gone, or it dies again on the same step): spawn a new
   agent with the same prompt plus "Report file exists: read it first and continue there".
3. On a usage limit, wait for the switch or the reset before either step; a resume into a limit
   fails again within seconds.

The SubagentStop check (`hooks/subagent-report-check.sh`) stops a sub-agent once if its report
file is missing or unchanged at the end, and tells it to write it now or to say so in the first
line of its answer. That line is your cue for step 1.
