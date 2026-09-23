# Changelog

## 0.7.2 — 2026-09-23

**The tab list now shows which sessions are waiting on their user.** `peer-state.py` gains a
`waiting` field, a WAITING column and a `--waiting` filter, read from the same bounded transcript
tail as everything else, so the target pays nothing. `permission`: the session's last own record
is a tool call with no result and it has been quiet for three minutes, which is what a session
parked on a permission dialog looks like; the heartbeat reads exactly that as healthy. `question`:
an AskUserQuestion is open, or the last text ends in a question mark or asks in so many words.
Only live, unwrapped sessions qualify. A finished concept once sat 40 minutes unnoticed in a worker
tab; the coordinator now has a cheap look instead of a guess, and the banner tells it the one
thing to do with the answer: such a session is alive but will not move until its user acts, so
do not message it, tell the user. The reading is a "may be" on purpose: a tool that simply runs
long reads `permission` too, and nothing is ever sent on it.

**A ready claim is bound to the commit it was tested on.** The report names the tip SHA the tests
and the blocker check ran on; a rebase or a new commit voids it until re-run on the new tip, and
the landing refuses when the branch no longer points at the reported SHA. A rebase that leaves
the tree byte-identical keeps the claim, so nobody re-runs a suite on the same bytes. The
autonomous merge in the skill, the worker section and the wrap's report step all say it now,
because one lane was rebased twice before landing and the hold had to be written by hand into a
handover.

**Workers tick off their own success criteria before they call a package ready.** Kickoffs have
always carried criteria; nothing made anyone read them again. The worker now re-reads its kickoff
and marks each criterion met or not met with its evidence (test number, link, screenshot path),
and a criterion without evidence is not met. The coordinator checks a list against the kickoff
instead of re-deriving it from prose.

**Open questions live in one ledger.** One row per question: who was asked, where, when it was
sent, what waits on it, and the default with the time it applies. The coordinator walks it on
every pass and the morning ritual walks it in step 1; an answered row is acted on and deleted in
the same pass. A handover once listed eight open asks with no send time and no default, and two
answers sat unread on pages nobody looked at again. The ledger is the same list the user already
hears, not a second one.

**A landing wave ends with a check of the coordinator itself.** Re-read the lane rules and the
head of the latest handover, count lanes against the cap, re-scan the queue for what the landing
unblocked, tell lanes whose base moved to rebase (by message only when live and idle under an
hour, otherwise on the board), and hand over at three quarters of context. The banner keeps the
plugin's rules in view on every message; it never kept the long project rules in view, and that
is where the day's slips came from. The morning ritual runs the same check over the night's
landings.

**Every deliverable goes through a review loop, with a hard end.** New skill `review-loop`: before
a plan or handoff is sent, and before a result is reported done or "geprüft", a fresh-context
reviewer checks it against its acceptance criteria and must prove each finding against the code or
doc; a finding without evidence is dropped. The session fixes what was confirmed and a NEW
reviewer runs on the revised version, until a round finds nothing. Four rounds per deliverable at
most, then the open findings go to the coordinator or the user and nothing is called clean. Opus
at xhigh reviews by default; Fable reviews money, security, data and the customer path from the
first round, and takes over when Opus still finds something after two, both inside the cap. The
rule existed as one sentence and a diagram edge; the only loop anyone ran lived in a skill on
another machine and covered plans only. Both wraps now run it before the recap unless it already
ran on the final state, the worker section names it beside the criteria tick-off, and an
optional gate (`reviewLoopGate`, off by default) holds a real plan or a handoff doc until the loop
ran in the same session within the hour.

**Sessions waiting on their user stay warm.** The heartbeat tick now also looks at every live
session: one that has not wrapped, has been idle 45 to 55 minutes, and ends on an open question
(or carries a hold file `<config dir>/state/keep-warm/<sessionId>`) gets one peer message from
`keepwarm` asking it to reply `ok`. That turn reads the prompt cache for a tenth of its price and
keeps it for another hour; a cold wake costs the whole context again. At most 3 pings per wait phase, about 2.5 hours, then it goes cold;
the count starts over when the session moves. Never on a session parked on a permission prompt,
where a queued message starts no turn. `<config dir>/state/keep-warm/off` turns it off for the
machine. The wake-cost rule gains its one exception: this ping is the only message that may go
to a waiting session, and its user still answers the question. The units run copies, so re-run
setup step 5 after the update; it now copies `peer-state.py` too.

## 0.7.1 — 2026-09-23

**The closing line is one fixed string again: `Close this tab.`, alone on the last line, in every
language.** 0.6.1 let the line follow the chat's language, and the reader accepted both, so
sessions ended on `Diesen Tab kannst du schließen.`, `You can close this tab.`, or the sentence
folded into a paragraph — correct for the tab list, useless for the user, who scans a row of tabs
for one string and now had to read each ending. The two lines above it (session name, topic) still
follow the chat. Changed in both skills, the role banner and the README; `peer-state.py` needs no
change, its `close … tab` branch already matches the literal.

## 0.7.0 — 2026-09-22

**The plugin now ships the wrap it has always depended on.** Since 0.6.1 the tab list decides
whether a session is finished by reading a session-log line that no file in this repo produced:
`peer-state.py` parsed the marker, the `middle-management` skill described it in prose, and the
routine that actually writes it lived on the author's machine. `middle-management:wrap` closes
that gap — nine steps from resolving your own name and sessionId to the three closing lines,
with the log format quoted as the frozen contract it is, including the `## YYYY-MM-DD` day
heading a marker needs in order to be checkable for staleness at all: the one part of the
contract no previous text stated, and the easiest way to file a perfectly formed marker that is
then discarded in silence. A personal `~/.claude/skills/wrap` still wins the bare `/wrap`.

**Reading the tab list and writing it are one dependency, and it is now declared.** The wrap says
which of its output the coordinator reads and why both halves must come from the same session: a
closing phrase whose entry says anything but `Status: completed` reads as a coordinator writing
about someone else's tab, and a display name is never the machine identity — that stays the
sessionId. Everything the routine needs beyond this plugin — a knowledge-graph server, a ticket
tracker, a formatter — is optional and names its fallback in the step itself, so a stranger
without any of them gets a complete wrap and one line saying what was skipped.

**The session log has a path a reader can look up, and a format it can be held to.**
`~/logs/session-log.md` was hard-coded in one python file and mentioned in no README section, no
skill, no setup step and no config key. It resolves in three steps now — `$MM_SESSION_LOG`, the
new `sessionLog` config key (`~` expanded), then that default — implemented once in
`scripts/config-check.sh session-log` for shell callers and once in `peer-state.py` for itself,
with the same fallbacks on both sides down to what a non-string value does. README §"The session
log" carries the shape the reader accepts — the day heading `## YYYY-MM-DD`, the entry header
`### HH:MM – [name] – topic`, a `Status:` line, the marker `- Session: closed · <sessionId>` —
as a worked example with who writes it, who reads it, and why a marker under no day heading is
ignored: its age cannot be checked. Anything else parses as zero entries, which is
indistinguishable from an absent file. The parser did not change; it was described. Setup now
asks about the path and writes the key **only** when you name a different one, so a config
without it behaves exactly as before, byte for byte.

**A `sessionLog` must be an absolute path, and a relative one is rejected instead of silently
meaning two different files.** The value was taken as any string and handed to `open()` on one
side and `[ -f ]` on the other, so `"logs/session-log.md"` resolved against whatever directory
the caller happened to run in — and the coordinator sits in the checkout root, a worker in its
lane worktree, a wrap somewhere else again. Proven on one machine with one config: from one
directory `/orchestrator claim` took the seat over, from another it refused with "this machine
has no session log at all" — two coordinators at once is the exact failure the reader exists to
prevent. A value that is not absolute (after `~` expansion) now makes the config invalid, which
the role hook announces like every other shape error, and both resolvers answer with the
built-in default instead of naming a file that depends on a cwd.

**The stale-seat takeover could never fire on a machine that had no session log — and now it
says so instead.** `claim` needs two agreeing signals, and the second one is the holder's session
log entry. With no log anywhere `peer-state.py` reports `log_completed: null`, which the seat read
as "no entry under its name" — the same message whether the holder had simply not wrapped yet or
the machine had no such file at all. The two states are told apart now: an absent log still
refuses the takeover (the two-signal rule is untouched), but the refusal names the resolved path,
names `middle-management:wrap` as the thing that files the entry, and names `release <id>` for the
case where that tab is simply gone. Proven in a fake HOME: no log → refusal, one entry in the
documented shape → the seat moves.

**And the banner stops asking for something a session cannot file.** `Your wrap entry in the
session log ends with one line: - Session: closed · <id>` fired in every session on every message,
for both roles, on machines that had no session log and no way to learn where one goes. It now
prints where a log exists or a path was configured, and where neither is true a single line takes
its place: `No session log yet — the middle-management:wrap skill creates it at <path> (or set
sessionLog via /middle-management-setup).` Beside it the banner carries one half-sentence for the
sessions that never open a skill — *When finished: name yourself, your topic, then the closing
line (middle-management:wrap).* — outside both role branches, because the tab list reads
coordinator and worker tabs with the same regex.

**And a documentation structure to wrap into.** `templates/docs/` holds the skeletons a fresh
project is missing on its first wrap: a `CLAUDE.md` with the pointer table and the session ritual,
`docs/architecture.md`, `docs/lessons.md`, and README conventions for `docs/runbooks/` and
`docs/handoffs/`. Step 1 of the wrap scaffolds from them when a project has no `docs/` at all,
which turns "the log does not exist yet" from a dead end into a first entry. The session log is
the one file that is not per project: its skeleton sits beside them as `templates/session-log.md`
and belongs at the machine-wide path.

**Fixes from an audit read on a machine that is not the author's.** *macOS*: `peer-state.py` falls
back to `kill(pid, 0)` where there is no `/proc`, so the session table reads live sessions as live
instead of silently showing nothing; the morning ritual's `ss -ltnp` and `free -m` carry CUSTOMIZE
markers with their macOS equivalents, so the machine-cleanup step no longer dies mid-ritual.
*The staging guard* matches in command position now, like the long-runner hook: `echo "git add
-A"` or a commit message about it no longer trips the plugin's own guard, while `git add -A`,
`cd x && git add .` and `git commit -a` still deny — and the awk that strips the command drops
heredoc bodies without mistaking a `<<<` herestring for one, which used to swallow every following
line of a command unseen. *GNU `date`*: `/wt <name> hold` and the lane reaper detect a non-GNU
`date` once and refuse with the fix, instead of quietly computing ages from timestamps they could
not parse (`/wt list` degrades its date columns to `-`); Requirements now says `python3` and GNU
`date` are core, not heartbeat-only, because `peer-state.py` runs on every coordinator message.
*And the README says what is true*: with no config file the roles **and** the staging guard are
on — only the worktree part is silent — and a "First five minutes" smoke test (two tabs, claim,
banner, status, release) says what a working install looks like. `plugin.json` carries `homepage`
and `repository`, so an installed plugin points at its issue tracker, and the session-name
examples in the `middle-management` skill are neutral placeholders instead of the author's own.

**The pictures show what the plugin does today.** New `docs/journey.svg` draws a day from your
side of the table: you appoint one session as today's coordinator, it reports once with what the
day looks like and which sessions it needs, you open those tabs, and you act when it reports
back — close these, open one more, decide this one thing. Between the second step and the fourth
there is nothing for you to do; the one thing a coordinator cannot do is open a tab. `docs/flow.svg`
was redrawn for 0.4–0.6 behaviour — the wrap and the session log, the tab list read off disk
instead of messaged into existence, a worker running its own lane through sub-agents, and peer
messaging marked as the thing you spend on live sessions only; `docs/overview.svg` got the
clearance pass that goes with it.

tests/run.sh 313 passed, tests/peer-state.sh 118 passed, tests/heartbeat.sh 110 passed, 0 failed.

## 0.6.2 — 2026-09-22

**A closing session says which session it is.** Two editor tabs, both holding a session named
`hyperreel-68`, both ending on the identical prescribed sentence: their user could not tell which
of the two was finished. The rule prescribed the closing *sentence* and never asked the session to
say its own name — and the tab list built on that sentence (`peer-state.py --wrapped`, which
prints each session's last line so the tab can be found by what is on screen in it) inherited the
same blind spot. A wrap now ends on three lines and nothing after them: the session's own name,
its topic in a handful of words, then the closing line. Names are derived and recycled, so this is
a human-facing label only — the machine identity stays the sessionId in the session-log line, and
the skill says so, so nobody harmonises the two.

**And exactly one closing line, in the language of the chat.** The skill demanded the English
sentence *verbatim*; a session whose chat ran in German read that as a requirement it could only
satisfy twice and emitted both variants. It never had to: `CLOSING` in `peer-state.py` carries the
German alternative (`Tab … schließen`) right beside the English one and has since 0.6.0 — the
instruction was stricter than its own reader. It now points at both branches, so the next reader
can check rather than trust. What still does not match is a near-variant of one's own invention;
the example the old text used for that ("you can close it now") had meanwhile been added to the
pattern, so it is replaced with two that genuinely miss.

Documentation only — no script, hook or command changed. tests/run.sh 271 passed,
tests/peer-state.sh 106 passed, tests/heartbeat.sh 110 passed, 0 failed.

## 0.6.1 — 2026-09-22

**A finishing session says so, instead of leaving the next one to infer it.** 0.6.0 reads whether a
session has wrapped out of its transcript — a closing phrase in the last assistant text block. That
works, but its recall rests on a phrase list, and a phrase list always has a tail: a session that
ends with "Diese Session ist zu" rather than naming a tab was missed until the wording was added,
and a miss is paid for in that session's whole context.

The session log is already the table of every session, and the wrap routine already writes into it.
So the wrap now appends one line to its entry:

```
- Session: closed · <sessionId> — <optional free text>
```

`peer-state.py` looks that up and reports the session as finished **authoritatively**, with no phrase
matching at all. The transcript heuristic stays as the fallback for sessions that never get to wrap —
a freeze, a crash, a closed tab — which is what it was built for.

Two details are load-bearing, and both come from measurements rather than taste. The marker is keyed
by **sessionId**, not by the session's display name: names are not stable across a resume
(`hyperreel-9b` became `hyperreel-0b`) and they get recycled (`hyperreel-bc` was worn by two
different sessions on one day; following the rename chain misclassified four sessions). And it is a
**separate line**, not a `Status:` value: `Status:` describes the entry's work, not the session's
life — a session filing `Status: completed` for one task and then working for hours is normal.

A marker is **not** believed forever. A session can be resumed after it wrapped, and then the marker
sits in the log while the session is alive again — believing it would let `claim` take the seat from
a working coordinator, the very failure this line of work exists to prevent. So a marker whose
session has a transcript turn more than `CLOSED_MARK_STALE_AFTER` (30 minutes) later is stale: it is
ignored, the evidence says so, and the transcript decides instead.

Rotated logs under the session log's `archive/` are read too, and `closed_marker` in the JSON is
non-null only when the marker actually decided the verdict, so a caller can tell "declared finished"
from "inferred finished" in one check.

tests/peer-state.sh 86 -> 106 passed; tests/run.sh 270 passed (1 pre-existing failure,
`lane reaper: the first run of a new day sends a digest anyway`, which fails identically on the
untouched 0.5.0 tree — a date-dependent test, not from this work).

## 0.6.0 — 2026-09-21

**Nobody is woken to be told they are finished.** A cross-session peer message to a session whose
prompt cache has gone cold makes that session re-read its entire conversation as fresh input.
Measured on one machine on 2026-09-21: eight sessions idle 15.5-17.3 h, messaged once each,
**2,369,094 fresh input tokens — 144,750 to 726,003 per session, 92-99 % of each one's own
context**. Seven of those messages said nothing but "close this tab"; the eighth asked a
coordinator that had wrapped the night before to hand over the seat. A second message to the same
session within the hour cost nothing extra — the cache was still warm. So the rule of thumb is:
**a message to a session idle for more than about an hour costs that session its whole context;
under an hour it is cheap.**

This reverses the part of 0.5.0 that told the coordinator to send each closable session its own
peer message. The reason behind that rule stands — users cannot map peer names to editor tabs and
have closed the wrong ones — but the answer is not a model turn in every tab. **A session's state
is on disk.** New `scripts/peer-state.py` (stdlib only, read-only) reports for every session its
name, sessionId, liveness, idle age, rough context size, whether it has **wrapped**, its topic and
**its own last line** — at zero cost to the session it describes. `--wrapped` prints the list the
coordinator now hands to its user instead of messaging anyone: each entry carries the last line
that session wrote, which is the text visible at the bottom of that tab, so the tab is found by
what is on screen in it.

What the detection had to learn: grepping a transcript for the closing phrase does **not** work,
because the coordinator instruction containing that phrase is injected into every transcript by
the role hook — every working session matches. Only the **last assistant text block** counts, and
only its last 200 characters (a live session was caught *quoting* a closing line out of a test).
Idle time on its own proves nothing either: sessions idle mid-work look identical from outside,
and `unknown` always means "may be messaged" — the reader never suppresses a message it is not
sure about.

`orchestrator.sh claim` gains the case that cost the 726,003 tokens. A holder whose **process is
gone** was already taken over; a holder that is **still running but has wrapped** could only be
appealed to, and the appeal is the wake. `claim` now takes the seat when the holder reads as
wrapped on disk, **its session-log entry agrees**, and it has been idle past `MM_STALE_SEAT_MIN`
(default 60 minutes — the regular prompt-cache TTL, not a politeness delay: below it the appeal is
cheap, above it the appeal costs the holder everything; under usage overage the TTL drops to five
minutes, so the threshold is an upper bound on "cheap", which is why it is configurable).

**The tab list runs on one signal, the seat needs two**, and the reason is a case the review
caught: a closing phrase cannot tell "I am finished" from "you are finished". A live coordinator
writing "Lane W1 ist gelandet — den Tab kannst du schließen" about a *worker's* tab reads as
wrapped by phrase alone — and the banner tells it to write exactly that after every wrap. Its
session log still says `in-progress`, so a disagreement between the two signals now counts as
**not** wrapped, everywhere, and the seat additionally requires the log entry to exist and say
completed. The takeover prints the evidence it used, and **fails closed** on every uncertainty: no
reader, a reader error, a timeout, unparseable output, `wrapped` anything but `yes`, a missing or
disagreeing log entry, an unusable idle age, or a threshold that is not a sane number all keep the
old refusal. Two coordinators are worse than one expensive wake. When it does refuse, it now says
whether the holder is live and working or merely warm enough to appeal to cheaply, and `status`
shows the holder's idle age and wrapped state.

The wrap side moves the cost to zero rather than reducing it: a session releases the seat **at
wrap time, while it is still warm**, and writes its own "this tab can close" line then, instead of
being woken hours later to be told. An empty marker is a perfectly good state — the successor
simply claims it.

## 0.5.0 — 2026-09-11

Synced from the master setup (2026-09-11, round 4): **a lane runs itself and ends clean**. The
WORKER banner and the skill now say that a worker is the **sub-orchestrator of its own lane** —
plan review, build, diff review, screenshots and report writing run in sub-agents with fresh
context, each prompt naming model and effort; every sub-agent writes long output to a file and
returns at most ten lines, twenty when the report carries a decision the worker must make; the
worker reads reports, not whole files or diffs; and every status to the coordinator ends with the
worker's rough context fill. The ten-line and model-choice rules were coordinator-only until now.
For the coordinator: **one lane = one session** (a new lane gets a fresh session, asked for with
the model named, never a second lane stacked silently into a running one — exception only after
around half an hour of user silence and only for safe, reversible work); **a wrapped session is
closed for good**, so after every wrap the coordinator says unprompted which tabs can go and
sends each of those sessions its own peer message so it answers in its own tab with "close this
tab" (users cannot map peer names to editor tabs and have closed the wrong ones); and every
**waiting item carries its link or command line in the SAME line, at every repetition**. The
skill's off-keyboard section gains the rule for teams whose channel has an inbound leg: an answer
arriving there is the user's word when it references the concrete question (reply-to, or the item
named), and a loose "yes" is not.

`poke-session.py` now declares the RECEIVER's permission mode in the envelope
(`from-mode`, mirrored from the target's `--permission-mode` or the config dir's
`permissions.defaultMode`; `POKE_FROM_MODE` overrides). Without it a session running in
bypassPermissions HOLDS every peer message that does not declare the same mode — parked for
approval, never queued, no log line anywhere — so heartbeat pokes and off-keyboard replies were
silently swallowed. The attribute order in the envelope is load-bearing.

`wt done` deletes the branch of work that is merged into the base instead of hinting at it,
using `git update-ref -d refs/heads/<branch> <tip>` after recording the tip SHA and checking no
other worktree still has the branch checked out (`git branch -D` is deny-listed in careful setups
and `branch -d` refuses squash-merged branches); an unmerged branch is kept with that same
update-ref line as the hint. `done` also refuses when the calling shell's cwd is inside the
worktree, and exits 0 with "already removed" when the worktree is gone, so cleanup routines can
call it blind. Seventeen new test cases (108 + 101).

**Resource management for lanes.** A lane is no longer only a directory: `wt <name> run <topic>
[-- <cmd>]` starts its dev server — the command passed in, or the checkout's new `serve` key — as
a memory-capped transient systemd user unit `wt-<name>-<topic>`, `stop` takes it down and waits
for the cgroup to be empty instead of believing systemd's "inactive", `hold <topic> <hours>` keeps
the reaper off a lane that must stay up, and `wt cap -- <cmd>` caps one heavy build or test run in
the foreground. At most `maxUnits` (default 2) lane units run at once. `wt list` becomes the one
view: a documented, whitespace-separated row per lane (checkout, worktree, branch, unit, owner,
alive, started, memory, hold, git state, merged, pull request) that a cleanup routine can parse.
`done` stops the lane's unit first and now refuses while ANY live process has its cwd inside the
worktree, not just the calling shell.

An OPTIONAL PreToolUse hook, off unless `longRunningAsUnit: true`, rewrites hand-started dev
servers and heavy one-shots into those capped units — in command position only, so prose about a
command is left alone — and refuses a dev server inside a compound command with the replacement
line to copy.

A lane that has produced nothing is never mistaken for a merged one: `wt new` branches off the
base and git sets the new branch's upstream to the base, so an untouched lane used to read
`merged yes` and could be removed — worktree, branch and everything gitignored inside it —
within half an hour of being created. `merged` now also requires that the lane tracks a branch
of its own and has moved since it was created. `wt list` also gained honest pull-request
semantics: `-` where there is no information to be had (no `gh`, no GitHub remote, `gh` never
logged in), `none` only for gh's own "no pull requests found", and `error` — which the reaper
alarms about — for everything else. `wt done` refuses with exit 3 while a live process sits in
the worktree, which the reaper reports as a busy lane with the pids instead of alarming every
half hour, and `wt chown <topic> <owner>` hands a lane over so it does not go ownerless when
the session that started it ends. `run` keeps the caller's cwd when it is inside the lane,
`stop` keeps a valid hold, and `list` fails loudly on a checkout whose root it cannot read.

An OPTIONAL lane reaper, installed like the heartbeat by the new setup step 6 into
`<config dir>/middle-management-reaper/`, runs every 30 minutes: it stops lane units that ran past
`reaperMaxHours` or whose owning session has been gone for `reaperOwnerlessMinutes` (confirmed on
a second sighting), removes the worktree of a merged, clean, pushed lane through `wt done`, and
lists everything else — dirty, unpushed, not merged, unknown owner — with its reason instead of
touching it. It never kills a process by pid and never deletes a ref. It reports through
`notifyCommand` when something happened, when the listed set changed, and once a day from
`reaperDigestHour` (default 7), so a dead timer cannot look like a quiet machine. It ships
without the master's idle rule — deciding a lane is idle means reading request lines out of its
server's log, which no plugin can know the shape of; `reaperMaxHours` catches those units
later instead. It also ships without the master's lock around `wt`'s verbs and without its
free-memory check: two racing `run` calls can exceed `maxUnits`, which `MemoryMax` per unit
bounds anyway.

Both role banners carry the rule this exists for: a lane ends with its unit stopped and its
worktree removed, proven by the `wt list` line in the wrap, and `wt hold` is how a slot stays.
Stopping a lane unit and removing a merged, clean, pushed worktree is housekeeping, done unasked;
anything dirty, unpushed or unmerged stays and goes to the user. Morning-ritual step 5 reads the
reaper's listing and works only its list-only rows, by verified PID lineage.

`wt done` took the branch name from `rev-parse --abbrev-ref HEAD`, which shortens to the shortest
UNAMBIGUOUS name: a tag sharing the branch name yielded `heads/<name>`, and the delete then
targeted `refs/heads/heads/<name>` and failed after the worktree was already gone. The tip SHA had
the mirror bug — resolved in the root checkout, where tags outrank heads and a detached worktree
reported the root's HEAD. Both now come from the worktree, from the full ref. Ninety-one new test
cases (199 + 110), including a real `wt new` followed by a real reaper run that has to leave
the lane standing.

The marketplace is renamed from `bopp-plugins` to `dr-bopp`. Nothing migrates automatically:
uninstall, `/plugin marketplace remove bopp-plugins`, re-add, install from `dr-bopp` — the README
carries the four commands.

## 0.4.0 — 2026-09-08

Synced from the master setup (2026-09-08, round 3): **what a coordinator does when nobody is
watching**. The `middle-management` skill gained four sections and the ORCHESTRATOR banner three
lines. *The autonomous loop (optional)*: merge into the integration branch on the coordinator's
own word when the pull request is green, carries the team's review artifact and a fresh-context
review sub-agent found no blocker; take the next items from a written queue of decision-free
packages, one lane per worktree; the gates that stay human (promotion to production, taste,
data-loss migrations, outward communication, secrets, deletions, anything a concept calls a
decision); and the reporting that makes the first three safe — plus the failure mode where a
pushing sub-agent stalls invisibly on a permission prompt. *Reaching your user off-keyboard*:
`notifyCommand` is now the ONE sender on the machine — the heartbeat, the unit-failure alarm and
the coordinator all call it, callers pass plain text, decoration and the plain fallback live
inside that one command, output is discarded because a failing command can echo a token, and a
non-zero rc means "not delivered, say so in the tab". README and `/middle-management-setup` say
the same; the plugin still ships the outbound leg only. *Fresh sessions*: an unbriefed living
session is free for the coordinator to take for a lane, a session that already ran one is not.
Sub-agents write long results to a FILE and return the coordinator at most ten lines; every
sub-agent the coordinator announces names its model and whether the strongest was needed, with
the escalation ladder (cheapest plausible first, escalate after two failed attempts). A review
sub-agent gets its OWN temporary worktree, never the worker's. Before an outbound draft, a cheap
sub-agent reads the channels one to two weeks back; before a question to the user, check what is
already decided. Gotcha: a peer message to a session that holds inbound for approval expires
after a few minutes. `poke exit 0` is a hand-over, not a delivery — persist first, then poke, and
`POKE_FROM_NAME` now names the sender the receiving session sees. The morning ritual reads the
off-keyboard inbox too, if the team runs one. Five new banner tests (91 + 101 cases).

Heartbeat note: an installed heartbeat runs a COPY of `poke-session.py` under
`<config-dir>/middle-management-heartbeat/` — re-run `/middle-management-setup` step 5 after this
update to refresh it.

## 0.3.0 — 2026-09-04

Synced from the master setup (2026-09-04, round 2): **the stuck-coordinator heartbeat** — a
systemd user timer (Linux) that alarms through the new config key `notifyCommand` when the
coordinator's last turn got no answer for 45 minutes and pokes the session over its own
socket (`scripts/orch-heartbeat.sh`, `poke-session.py`, `unit-failure-alarm.sh`, unit
templates, the poke prompt with CUSTOMIZE marks; setup step 5 installs a copy under
`<config-dir>/middle-management-heartbeat/`; 96 test cases in `tests/heartbeat.sh`). Liveness
is now decided by sessionId and `kind == "interactive"` in both the role hook and
`orchestrator.sh` (a nameless coordinator no longer reads as a stale marker); a nameless
session keeps its id (tab-IFS row shape); a non-holder clears an orphaned marker only with
`release <id>`; the stale-marker hint names both exits, the marker id and the worker conduct
while the coordinator is dead; the ORCHESTRATOR banner and the skill carry "RE-WAKE checklist
first"; the override-marker nag tests `-e` like the guard and fires before the jq check; the
morning ritual's wrap audit skips non-interactive registry entries; `tests/run.sh` mirrors the
master matrix's behaviour cases and cleans up its fake HOMEs. Skill: section "Recovery after
a kill".

Added the end-user overview picture (`docs/overview.svg`: boss, middle manager, workers,
the manager's duties) at the top of the README; the detailed flow diagram stays under
"How the roles work".

Synced from the master setup (2026-09-03): `wt done` names the real branch in its
delete hint (the topic may be the directory name); the ORCHESTRATOR banner carries the
explicit allowed/not-yourself split, the "user starts worker sessions" rule, the
proceed-with-the-default fallback and resource hygiene; `morning-ritual` gained step 5
"Machine cleanup"; the `middle-management` skill gained Remote Control for coordinators,
"surface every waiting session to your user, one line each", resource hygiene and the
wrap-in-one-motion rule; the checkout-guard deny text says "one lane = one branch = one
pull request"; the `claim` reminder names `claude --rc -n orchestrator`; README lists the
recommended `settings.json` entries (retry watchdog, Remote Control off by default).

## 0.2.0 — 2026-09-02

Added the `morning-ritual` skill (coordinator day-opener with CUSTOMIZE markers),
the conditional Remote Control reminder after `claim`, and the session-role flow
diagram (README + docs/flow.svg). License changed from MIT to the Unlicense
(public domain).

## 0.1.0 — 2026-09-01

Initial release: coordinator/worker session roles (UserPromptSubmit hook +
`/orchestrator`), per-topic worktree discipline (PreToolUse guard + `/wt` +
`/middle-management-setup`), surgical git staging guard, `middle-management` reference skill.
