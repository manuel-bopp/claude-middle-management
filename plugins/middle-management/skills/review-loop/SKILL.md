---
name: review-loop
description: The review loop every deliverable goes through before it is handed on as finished. A fresh-context reviewer sub-agent checks it against its acceptance criteria and verifies every finding against the code or doc (refute by default), the session fixes what was confirmed, and a NEW fresh reviewer runs again, until a round comes back with zero confirmed findings or the hard cap of 4 rounds is reached. Use before a plan or handoff doc is sent, before ExitPlanMode on a real plan, before a finished result (code, docs, a lane) is reported as done, ready or "geprüft", when the review gate hook denies a plan or handoff, and on "review loop", "review until clean", "prüf den Plan", "review the plan", "lass das reviewen".
---

# Review loop: until clean, at most 4 rounds

The session that built something cannot see what it left out: it inherits its own blind spots.
A reviewer with fresh context can, and a reviewer that has to prove each finding cannot drown
you in guesses. So every deliverable is reviewed, fixed and reviewed again by a new reviewer
until a round finds nothing, and the loop has a hard end so it never grinds.

**When.** Whenever you believe a deliverable is finished:
- a **plan, concept or handoff doc**, BEFORE it is sent (to your user, the coordinator, a worker);
- a **finished result** (code, docs, a whole lane), BEFORE it is reported as done, ready or
  "geprüft".

A trivial edit you would not ask anyone to check is not a deliverable. Anything with acceptance
criteria is.

**Cost.** Each round is one sub-agent. The cheapest round is the one on the plan, before the
build: a gap found there costs a paragraph, the same gap found in the result costs a rebuild.
Review the plan, then the result.

## Step 1: assemble what the reviewer needs

A sub-agent shares nothing with you; everything travels in its prompt:
- the deliverable: the plan or handoff text, or for a result the branch, diff range or file list;
- **its acceptance criteria**, verbatim: the kickoff, the ticket, or the plan the result was
  built from. No criteria written down anywhere? Write them now, one line each, and send those;
- the repo root(s) and the paths of the decision log and planning docs it touches;
- the one-sentence goal behind the request.

## Step 2: pick the reviewer model

| Case | Reviewer |
|---|---|
| Default | **Opus** (currently Opus 5.5, `claude-opus-5-5`), effort **xhigh** |
| Critical deliverable: money, security, data, customer path | **Fable** (`claude-fable-5-1`), effort xhigh, from round 1 |
| Opus still has confirmed findings after 2 rounds | **Fable** for rounds 3 and 4 |

Both switches stay inside the 4-round cap; escalating never buys extra rounds. Name the model
and effort in the reviewer's prompt, and set them on the sub-agent call (`model: opus` or
`model: fable`).

For a plan, concept or handoff: dispatch a **second** reviewer in parallel carrying only lens 6
(walkthrough) when the plan touches more than one repo, moves a data path, or changes a contract.

## Step 3: dispatch a fresh reviewer

Always a NEW sub-agent, never a continued one: a reviewer that saw round 1 defends its own
findings in round 2. Read-only tools. Its prompt carries the material from step 1, the lenses
below, the output shape, and these rules verbatim:

> You are a fresh-context reviewer (model <model>, effort <effort>). Check the deliverable against
> EVERY acceptance criterion first: met, not met, or unverifiable, each with evidence. Style is
> last. Refute by default: before you report a finding, verify it yourself against the code or
> the doc. A finding you cannot ground in `file:line` or a quoted line is dropped, not reported
> as "probably". Something you cannot settle from the repo is an OPEN QUESTION that names what
> would settle it.
> Report file: <scratch dir>/review-<deliverable>-r<N>.md
> Write that file first (a title and your packages), append each result at once, and return at
> most 15 lines: the verdict line and one line per finding.

`<scratch dir>` is your session's scratch directory (the one your house rules name; without one,
`/tmp/<sessionId>/`), filled in as an absolute path: the `Report file:` line is what the
work-packages gate (`hooks/require-work-packages.sh`) looks for, and it refuses an Agent prompt
without one. The report file is the record; your context gets the 15 lines.

**Lenses for a plan, concept or handoff** (the ten lenses of the completeness gate, verbatim).
The reviewer answers **every** lens, each ending in a finding or in `covered — <plan section>`.
A lens left silent is an unfinished review.

1. **Mirror.** For every operation the plan changes, name its counterparts: write ↔ read,
   create ↔ delete, list, update, subscribe/live-update, export ↔ import. Which counterpart is
   absent from the plan, and does the plan say that absence is deliberate?
2. **Both ends of the data flow.** Producer and consumer of every record the plan touches. When a
   record moves to a new home, who still reads it from the old one?
3. **Decision log.** Grep the project's decision log and planning docs for the nouns in the plan.
   A decision that already covers a piece the plan ignores is a finding, quoted with its ID.
4. **Other callers.** Grep for importers and callers of every module the plan changes. Who else
   travels this path, and does the plan account for them?
5. **Existing state.** Rows, files, env vars, feature flags, caches created by the old path — what
   happens to each after the change?
6. **Walkthrough.** Take one real end-to-end user action and walk it step by step through the
   system **as the plan leaves it**. The first step that breaks is the missing scope.
7. **Assumed to exist.** Endpoints, fields, permissions, packages the plan relies on: which were
   verified against the code or the API, and which are assumed?
8. **Failure path.** What happens when the new path fails at runtime? A failure that lands only in
   a log, or falls back silently to the old path, is a finding.
9. **Blast radius beyond this repo.** Work the plan implies in another repo, another team member's
   review, a contract change, a migration — named in the plan, or discovered later?
10. **Named out-of-scope.** Everything deliberately excluded is stated in the plan with a reason.
    Implicit exclusion is the defect this whole gate exists for.

**Lenses for a result.** Every acceptance criterion with its evidence (a test that ran, a link,
a screenshot path); tests claimed but not run; callers of changed code the diff did not touch;
the failure path; a claim in the report the diff does not support; scope cut silently.

**Output shape**, per finding:

```
[BLOCKER|GAP|QUESTION] <lens or criterion> - <one-line claim>
evidence: <file:line, or quoted doc line, or "unverified — question">
the question the human would have asked: "<…>"
```

Findings only: a summary of the deliverable is wasted tokens. Last line: `CLEAN` (every
criterion met, every lens covered, zero findings; the completeness gate called this `PASS`) or
`FINDINGS: <n>`.

## Step 4: verify every finding yourself, then fix

A reviewer's finding is a **claim**, not a fact. Before anything is written down or handed on,
every finding is checked against the code — by you or by verifier sub-agents in parallel (each
with its own `Report file:` line), each told to **refute by default**: a claim that cannot be
grounded in `file:line` is REFUTED, not "probably right".

Each finding leaves this step with one verdict:

| Verdict | What happens |
|---|---|
| CONFIRMED | goes on the fix list with its evidence |
| PARTIAL | the corrected, narrower claim goes on the list; the overstated part dies |
| REFUTED | dropped, with the evidence that killed it — it never reaches the human |
| OPEN QUESTION | ungroundable from the repo; names exactly what would settle it |

Findings that survive get fixed — in the plan, or in the code if that is the task. An open
question goes to whoever can answer it; it does not block the next round. Handing an unverified
reviewer dump to the human is the failure this step exists to prevent.

## Step 5: loop

Back to step 3 with a NEW reviewer on the **revised** deliverable, fresh context again. The loop
ends when a round returns **zero confirmed findings**, or when two consecutive rounds surface
nothing new (only findings already confirmed-and-open or refuted before). Every round is cheaper
than the correction round it prevents.

**Hard cap: 4 rounds per deliverable, no exception.** After round 4 you stop, report the
findings still open to the coordinator or your user, and do NOT call the deliverable clean,
ready or "geprüft". A fifth round, a "quick last check", a reviewer told to be lenient: all of
them are the grinding this cap exists to stop.

## Step 6: open the gate, report the loop

If the review gate hook is on (`reviewLoopGate: true`), the marker is the record that the loop
ran; write it after the last round, clean or capped:

```bash
D="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/review-loop"; mkdir -p "$D"
printf '{"at":"%s","cwd":"%s","rounds":%s,"open":%s}\n' "$(date -Iseconds)" "$PWD" \
  "<rounds>" "<open findings>" > "$D/$CLAUDE_CODE_SESSION_ID.json"
```

The gate holds ExitPlanMode on a real plan and a Write to any file named
`<YYYY-MM-DD>_handoff-*.md` until that marker is under an hour old, so draft the
handoff in your scratch dir, run the loop on the draft, then write it. Without the hook you are
the gate: nothing that step "When" names leaves your session before the loop ran.

The gate also accepts the marker of the older completeness gate,
`<config dir>/state/plan-review/<sessionId>.json`, under the same one-hour rule, so a machine
moving from a site-local `plan-review` skill to this loop loses no open gate on the switch.

What your user or the coordinator reads is the result of the loop — the **delta**, never a raw
reviewer dump: confirmed findings with evidence, what was fixed, what stays open and why, how many
rounds it took, the last reviewer's model and verdict. Refuted claims are named as refuted: they
are the proof that the verification step ran. In one line, for a report or a wrap
recap: `Review loop: 2 rounds, last verdict CLEAN (Opus 5.5, xhigh).`
