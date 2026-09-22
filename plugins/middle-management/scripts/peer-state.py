#!/usr/bin/env python3
"""peer-state.py - what every Claude Code session on this machine is doing, read from disk alone.

Consumers: scripts/orchestrator.sh (stale-seat check), the coordinator by hand, the
  middle-management skill. Nothing else calls it.

Why it exists: asking a session how it is doing costs THAT session its whole conversation as
fresh input tokens once it has fallen out of cache - measured on one machine in one morning:
2.37M tokens over 8 wakes, 145k-726k each, nearly all of it spent telling already-finished
sessions to close their tab. Everything below comes from the registry, the transcript file and
the session log. No socket, no message, no model turn: the target session pays nothing.

Usage: peer-state.py [--all|--wrapped] [--name N] [--session-id ID] [--cwd PATH] [--json]
  (no flags)        table of LIVE sessions, most recently active first
  --all             include sessions whose process is gone
  --wrapped         only sessions that read as finished, as a list to act on (implies --all)
  --name N          one session by registry name        -> exit 1 if there is none
  --session-id ID   one session by sessionId or a >=8-char prefix; falls back to the transcript
                    when the registry entry is already gone   -> exit 1 if there is none
  --cwd PATH        only sessions working in PATH **or anywhere below it** (prefix match on whole
                    path segments, so /x/Repo does not match /x/RepoOther)
  --json            every field, for shell consumers
Env: CLAUDE_CONFIG_DIR (default ~/.claude). The session log is resolved in three steps -
  $MM_SESSION_LOG, then "sessionLog" in <config dir>/middle-management.json (~ allowed), then
  ~/logs/session-log.md; scripts/config-check.sh session-log answers the same for shell callers.
  The rotated days next to it (<log dir>/archive/YYYY-MM-DD.md) are read too, for closed markers
  only. Its format is the frozen contract documented in the README, section "The session log".
"""
import argparse, datetime, glob, json, os, re, sys, time

CFG = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
REG_DIR = os.path.join(CFG, "sessions")
PROJ_DIR = os.path.join(CFG, "projects")


def resolve_session_log():
    """$MM_SESSION_LOG > the config key sessionLog > ~/logs/session-log.md.

    A machine with no config, a config that is not an object, a non-string value: all mean
    "nobody chose one", and the default answers. Never raises - this runs at import, and a
    reader that dies on a typo in someone's config takes the whole session table with it."""
    p = os.environ.get("MM_SESSION_LOG")
    if not p:
        try:
            p = json.load(open(os.path.join(CFG, "middle-management.json"),
                               encoding="utf-8"))["sessionLog"]
        except (OSError, ValueError, TypeError, KeyError):
            p = None
    return os.path.expanduser(p if isinstance(p, str) and p else "~/logs/session-log.md")


SESSION_LOG = resolve_session_log()

# The signal that holds (measured over 18 sessions with known state): a closing phrase in the
# LAST ONE OR TWO assistant TEXT blocks. Edit this ONE pattern; matched lowercased.
# Never grep a whole transcript for it - the coordinator instruction the session-role hook
# injects contains the same words, so every currently-working session would match.
# A miss is the expensive direction: an unlisted finished session gets messaged and pays its
# whole context (145k-726k tokens), so the wording variants people actually write all belong in
# here - tab/tabs/window, schließen/schliessen/zumachen/zu, "you can close it", and the
# "this tab can close" line the skill and the changelog tell sessions to write.
# Deliberately NOT in here: "closing out the lane" - work, not a tab, and written mid-lane.
CLOSING = re.compile(r"""(?x)
      tabs?\b [^.!?\n]{0,30} (?: schlie(?:ß|ss) | zumach | \bgeschlossen | \bkann \s+ zu\b )
    | \bclose\b [^.!?\n]{0,20} \b (?: tabs? | windows? ) \b
    | \btabs?\b [^.!?\n]{0,20} \bcan\b [^.!?\n]{0,15} \bclos
    | \byou \s+ can \s+ close \s+ it \b | \bclose \s+ it \s+ now \b
""")
# ...and only in the last CLOSING_WINDOW characters of a block: a session that is done says it
# LAST. Measured: every real closing line ends within 75 characters of its block's end, while a
# session merely WRITING about the phrase (quoting a banner, a test assertion) had it 684
# characters deep. Without this window such a session reads as finished - a false positive that
# would hide a working tab from its user.
CLOSING_WINDOW = 200

# The other half: a session that announces ITSELF closed and never mentions a tab. Observed on a
# live 401k-token session whose last line was "**Diese Session ist zu.** Sitz frei, main bei
# ce1d9418, ..." - it stayed off the tab list, got messaged, and re-paid its whole context.
# Matched in the block's LAST LINE instead of the character window, and that is the point of
# keeping it a separate pattern: the window exists because "close this tab" is a string the
# sessions in THIS repo quote at each other all day (banners, test assertions, changelog), so
# where it sits in the block is evidence. Nobody quotes a first-person "diese Session ist zu",
# so position carries no information for these - but the handover sentence that follows it does
# push it past 200 characters from the end, which is how the miss happened.
# Anchored on the session noun on purpose: a bare "ist zu" / "is done" is a lane or a ticket.
CLOSING_SELF = re.compile(r"""(?x)
      \bsession \s+ ist \s+ zu (?= \s*[.!*)\]] | \s*$ )
    | \bsession \s+ is \s+ (?: closed | done ) \b
""")

TAIL_LINES, TAIL_BYTES = 600, 2_000_000   # transcripts reach 7 MB - never read one whole
HEAD_LINES, HEAD_BYTES = 4000, 1_000_000  # only until the first assistant text, usually line ~5
LOG_HEAD = re.compile(r"^###\s+\d{1,2}:\d{2}\s*[-–—]\s*\[([^\]]+)\]\s*[-–—]\s*(.*)")
DAY_HEAD = re.compile(r"^##\s+(\d{4}-\d{2}-\d{2})\s*$")   # the log's day sections; other "## "
                                                          # headings (conventions, index) are not
ENTRY_TIME = re.compile(r"^###\s+(\d{1,2}:\d{2})")        # the entry's own clock, name-agnostic

# The DECLARED answer, as opposed to the inferred one above: the wrap routine appends
#     - Session: closed · <sessionId> — <free text>
# to its own session-log entry, and this reads it back. Keyed by sessionId and NOTHING else.
# Measured, and the reason the log's other fields cannot carry this: display NAMES are not
# identity (a resumed session gets a new derived one - hyperreel-9b -> -0b - and old ones get
# recycled: hyperreel-bc was worn by two different sessions on 2026-09-21), and `Status:
# completed` describes THE ENTRY'S WORK, not the session's life - hyperreel-5c filed completed
# and kept working for hours. So: a separate marker, carrying the one identifier that cannot be
# wrong. A prefix of >=8 characters is accepted (that is what humans paste), and is resolved
# against the sessionIds actually on the machine - a prefix matching two of them names neither.
# Tolerant about the bullet and the spacing, strict about the two tokens "Session:" and "closed".
CLOSED_MARK = re.compile(r"^\s*[-*]\s*Session:\s*closed\b[\s·:,|–—-]*([0-9a-fA-F]{8}[0-9a-fA-F-]*)",
                         re.I)
ARCHIVE_GLOB = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md"

# How long a session may still be writing AFTER its own wrap entry before the marker stops
# counting. The wrap files this line and then finishes within a few minutes, so a turn half an
# hour later does not mean the wrap is still running - it means the session was RESUMED and is
# working again, with its marker still sitting in the log. Without this, that stale "yes" would
# let `orchestrator.sh claim` take the seat from an actively working coordinator, which is the
# exact failure this whole reader exists to prevent. Fall back to the transcript and say so.
CLOSED_MARK_STALE_AFTER = 30 * 60


def updated_at(d):
    """updatedAt as a plain number. The directory holds hand-written and foreign files too, and
    comparing a str with an int would raise and take EVERY session's row down with it."""
    v = d.get("updatedAt", 0)
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def registry():
    """(sessionId -> newest entry, sessionId -> EVERY name its entries carried, in file order).

    A resumed session keeps its id but gets a new pid AND a new derived name, so the same id has
    several files: newest updatedAt wins, or the dead name wins. The losing files are still
    evidence - they hold the names this session used to answer to, and the session log is filed
    under whichever name was current when the entry was written. Hence the second map."""
    out, names = {}, {}
    for f in sorted(glob.glob(os.path.join(REG_DIR, "*.json"))):
        try:
            d = json.load(open(f, encoding="utf-8"))
        except (OSError, ValueError):
            continue          # a half-written or foreign file is skipped, never fatal
        # ...and so is one that parses as something other than an object: `[]`, `null`, `5` and
        # `"x"` are all valid JSON, and `.get` on them used to raise AttributeError - one foreign
        # file in the directory and the whole reader died, which silently turns the feature off.
        if not isinstance(d, dict):
            continue
        sid = d.get("sessionId")
        if not (isinstance(sid, str) and sid):
            continue
        n = d.get("name")
        seen = names.setdefault(sid, [])
        if isinstance(n, str) and n and n not in seen:
            seen.append(n)
        if updated_at(d) >= updated_at(out.get(sid, {})):
            out[sid] = d
    return out, names


def is_live(pid, procstart):
    """/proc/<pid>/stat field 22 (starttime) == the registry's procStart. The registry's own
    `status` is NOT liveness - entries from before a crash still claim "busy"."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if not os.path.isdir("/proc"):
        # ponytail: no /proc (macOS, BSD) - kill(pid, 0) answers "a process with this pid exists"
        # and nothing else, so the PID-reuse guard procStart gives us is DROPPED on those
        # systems. Without this branch every session there read as dead and the table was empty.
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except OSError:
            pass                                    # PermissionError: it exists, just not ours
        return True
    try:
        stat = open("/proc/%d/stat" % pid, encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    fields = stat.rsplit(") ", 1)[-1].split()   # comm may contain ") " - split at the LAST one
    return len(fields) > 19 and (not procstart or fields[19] == str(procstart))


def transcript_for(sid, cwd=None):
    if cwd:
        p = os.path.join(PROJ_DIR, cwd.replace("/", "-"), sid + ".jsonl")
        if os.path.exists(p):
            return p
    hits = glob.glob(os.path.join(PROJ_DIR, "*", sid + ".jsonl"))
    return hits[0] if hits else None


def tail_records(path):
    """Records from the end of the transcript, bounded by BOTH lines and bytes."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            pos = size = fh.tell()
            buf = b""
            while pos > 0 and buf.count(b"\n") <= TAIL_LINES and size - pos < TAIL_BYTES:
                step = min(262144, pos)
                pos -= step
                fh.seek(pos)
                buf = fh.read(step) + buf
    except OSError:
        return []
    # A truncated first line (and any other broken one) simply fails to parse and is dropped.
    return list(parsed(buf.decode("utf-8", "replace").splitlines()[-TAIL_LINES:]))


def parsed(lines):
    for line in lines:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict):
            yield rec


def assistant_texts(recs):
    """Text the session itself wrote, own turns only (sidechains are sub-agents, not the tab)."""
    out = []
    for r in recs:
        if r.get("type") != "assistant" or r.get("isSidechain"):
            continue
        msg = r.get("message")
        for b in (msg.get("content") or []) if isinstance(msg, dict) else []:
            if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip():
                out.append(b["text"].strip())
    return out


def context_size(recs):
    """The price tag of waking this session: its last usage line, all three input buckets."""
    for r in reversed(recs):
        u = r.get("message", {}).get("usage") if isinstance(r.get("message"), dict) else None
        if isinstance(u, dict):
            n = sum(int(u.get(k) or 0) for k in
                    ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            # A synthetic record (the "you've hit your session limit" turn) carries an all-zero
            # usage. Reporting 0 would read as "free to wake" for a 197k conversation.
            if n:
                return n
    return None


def epoch(ts):
    """ISO-8601 (with Z) -> seconds. The transcript is the only clock a closed session has."""
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (AttributeError, TypeError, ValueError):
        return None


def head_signals(path):
    """Head of the transcript -> (first assistant line, epoch of the first timestamped record).

    The first line is the topic: by lane rule 1 a worker's first reply names it.
    The timestamp is HOW OLD THE CONVERSATION IS, which is not how old the process is. A
    *resumed* session shows a young process age while carrying its whole previous conversation -
    a lane was handed to a session reading "started 57m ago" that in fact held ~649k tokens of an
    unrelated topic. Only this number shows that; report both, never the process age alone."""
    line = started = None
    read = 0
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, raw in enumerate(fh):
                read += len(raw)
                if i >= HEAD_LINES or read > HEAD_BYTES:
                    break
                for rec in parsed([raw]):
                    if started is None:
                        started = epoch(rec.get("timestamp"))
                    if line is None:
                        line = next((t.splitlines()[0] for t in assistant_texts([rec])), None)
                if line is not None and started is not None:
                    break
    except OSError:
        pass
    return line, started


def session_log():
    """Every entry, IN FILE ORDER: {name, status, topic, day}. Empty when the log is absent.

    A list, not a name -> entry map: one session appears under several names over its life, so
    the caller matches against a SET of names and takes the last hit - see log_entry_for().
    `day` is the "## YYYY-MM-DD" heading the entry sits under, or None where the file has none;
    read_session() needs it to tell a stale entry from a contradicting one."""
    out, cur, day = [], None, None
    try:
        lines = open(SESSION_LOG, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return out
    for line in lines:
        d = DAY_HEAD.match(line)
        if d:                                  # "## 2026-09-21" - the log's own day structure
            day, cur = d.group(1), None
            continue
        m = LOG_HEAD.match(line)
        if m:                                  # "[hyperreel-0b (ex -9b) / Fable, KOORDINATOR]"
            # The log is hand-edited by many sessions, so "### 13:00 - [ ] - topic" happens:
            # LOG_HEAD accepts a bracket of pure whitespace and split() then yields nothing.
            # Such a header names nobody - drop it AND stop attributing the Status lines under
            # it to whoever was named last.
            word = [w.strip("`*()[],") for w in m.group(1).split("/")[0].split()]
            word = [w for w in word if w]
            cur = {"name": word[0], "status": None, "topic": m.group(2).strip(),
                   "day": day} if word else None
            if cur:
                out.append(cur)
        elif cur:
            s = line.lstrip("-*# ").lower()
            if s.startswith("status:"):
                cur["status"] = s[7:].strip().strip("*`").split()[0] if s[7:].strip() else None
    return out


def marker_files():
    """The rotated days first, the live log LAST, so the newest marker for an id wins.

    The archive sits beside the log, so MM_SESSION_LOG moves both and a test never reads the real
    one. Absent directory = no archive, silently. Cost measured on this machine: 146 files,
    7.8 MB, ~30 ms - the whole --all run is 0.24 s, so the scan stays inside the noise."""
    d = os.path.join(os.path.dirname(SESSION_LOG) or ".", "archive")
    return sorted(glob.glob(os.path.join(d, ARCHIVE_GLOB))) + [SESSION_LOG]


def closed_markers():
    """Every "- Session: closed · <id>" line in the log and its archive, in file order.

    [{"id": <full id or the >=8-char prefix as written>, "day": "YYYY-MM-DD", "time": "HH:MM"}].
    day/time are the ENCLOSING entry's own stamp ("## 2026-09-21" + "### 15:05"), which is what
    the staleness guard compares against; a marker sitting under neither is kept with None there
    and refused at the use site, so it shows up in the evidence instead of vanishing. The archive
    file name seeds the day, so a rotated file missing its heading still dates its markers."""
    out = []
    for path in marker_files():
        f = re.match(r"(\d{4}-\d{2}-\d{2})\.md$", os.path.basename(path))
        day, hhmm = (f.group(1) if f else None), None
        try:
            fh = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue                           # no log, or no archive: nothing to read, not fatal
        with fh:
            for line in fh:
                if line.startswith("#"):       # headings only - keeps the scan to two cheap tests
                    d = DAY_HEAD.match(line)
                    if d:
                        day = d.group(1)
                    else:
                        t = ENTRY_TIME.match(line)
                        if t:
                            hhmm = t.group(1)
                    continue
                if "Session:" not in line:     # substring first: the regex sees ~1 line in 10000
                    continue
                m = CLOSED_MARK.match(line)
                if m:
                    out.append({"id": m.group(1), "day": day, "time": hhmm})
    return out


def marker_epoch(m):
    """The marker entry's own timestamp in seconds, or None when it has none."""
    try:
        return datetime.datetime.strptime("%s %s" % (m["day"], m["time"]),
                                          "%Y-%m-%d %H:%M").timestamp()
    except (TypeError, ValueError):
        return None


def marker_for(sid, markers, known):
    """(the newest marker naming THIS sessionId, notes about ones found and NOT used).

    `known` is every sessionId this run can see. A written prefix that matches two of them names
    neither, so it must not resolve - silently picking one would close the wrong tab. Same for a
    marker with no entry timestamp: the staleness guard cannot run on it, so it does not count.
    Both cases become a note, because "no marker" and "a marker I refused" are different facts."""
    hit, notes = None, []
    for m in markers:
        if not sid.startswith(m["id"]):
            continue
        n = sum(1 for k in known if k.startswith(m["id"]))
        if n > 1:
            notes.append('a session-closed marker for "%s" was ignored: that prefix matches %d '
                         "sessionIds on this machine, so it names none of them" % (m["id"], n))
        elif not (m["day"] and m["time"]):
            notes.append('a session-closed marker for "%s" was ignored: it sits under no "## day"'
                         ' / "### HH:MM" heading, so it cannot be checked for staleness'
                         % m["id"])
        else:
            hit = m
    return hit, notes


def log_entry_for(names, entries):
    """(this session's LAST session-log entry, every name it was filed under).

    A session changes display name - it gets a new derived one on every resume - and the log is
    filed under whichever name was current at the time, so matching the newest registry name
    alone reads a day-old entry for a session that has been writing under a new name since.
    The names therefore come from EVERY registry file carrying this sessionId, which is the only
    name-to-session link that cannot be wrong.

    The NEWEST match wins; the matches are deliberately NOT merged. Display names get handed to
    unrelated sessions later, so an older entry filed under a recycled name must never outrank
    the current one - merging (or "any completed wins") would reintroduce exactly the bug this
    exists to fix, and would do it silently.

    Deliberately NOT a source of names: the rename a log header declares in its own bracket,
    "[hyperreel-0b (vormals hyperreel-9b) / ...]". Measured on the real log: following those
    turns four correctly-wrapped sessions into "no". `hyperreel-bc` was worn by TWO sessions on
    2026-09-21 - Worker X1 kept it, Worker S1 renamed bc -> ac -> 05 - so the chain drags X1's
    finished session onto S1's later "waiting" entry. The log's names are a human convention;
    only the registry's sessionId is identity."""
    known, last = [], None
    for n in names:                            # order-preserving dedupe: the caller concatenates
        if n and n not in known:               # the winning entry's name onto the full list
            known.append(n)
    for e in entries:
        if e["name"] in known:
            last = e
    return last, known


def wrap_state(texts, log_status, log_completed):
    """yes/no/unknown + the evidence, incl. visible disagreement between the two signals.

    A closing phrase alone cannot tell "I am finished" from "YOU are finished": the session most
    likely to write "den Tab kannst du schließen" is a live coordinator writing about a worker's
    tab, and its own instructions tell it to write exactly that after every wrap. The session log
    settles it - in that case the coordinator's own entry still says in-progress. So a closing
    phrase the log CONTRADICTS is "no", never "yes": a disagreement is never a wrap.
    log_completed: True = the last entry for this session says completed, False = it says
    something else, None = no usable entry (then the phrase stands on its own). None also covers
    an entry read_session put aside as being from another calendar day.

    Accepted trade-off of that day rule: a session working PAST MIDNIGHT whose last message
    happens to quote a closing phrase reads "yes" on the tab list, because its own entry from
    "yesterday" no longer contradicts it. Cheap on purpose - the list is read by a human with
    the session's own last line printed next to it - and the coordinator seat is untouched,
    because log_completed is None there and a takeover needs a positive `completed`."""
    if not texts:
        return "unknown", ["no assistant text read (transcript empty, unreadable, or nothing "
                           "but tool calls in the tail) - unknown never counts as finished"]
    probes = [(CLOSING, t[-CLOSING_WINDOW:]) for t in texts[-2:]] + \
             [(CLOSING_SELF, t.splitlines()[-1]) for t in texts[-2:]]
    hit = next((m.group(0) for p, s in probes for m in [p.search(s.lower())] if m), None)
    ev = ['closing phrase "%s" in the last assistant text' % hit] if hit else \
         ["no closing phrase in the last two assistant texts"]
    if log_completed is not None:
        ev.append("session log says %s" % (log_status or "nothing about status"))
        if hit and not log_completed:
            ev.append("DISAGREE: closing line but the log entry is not completed - reads as NOT "
                      "wrapped (most likely a coordinator writing about someone else's tab)")
            return "no", ev
        if not hit and log_completed:
            ev.append("DISAGREE: log entry completed but no closing line - it wrapped its log "
                      "entry before its last turn, or the entry is an older one for this name")
    return ("yes" if hit else "no"), ev


def apply_log(row, log):
    """Put a session-log entry's fields on the row and return its status. log None = no usable
    entry, which is exactly what log_completed None means to every caller: nothing corroborates
    and nothing contradicts. Called twice - once with the entry found, once with None when that
    entry turns out to be from another day."""
    status = log["status"] if log else None
    row["log_name"] = log["name"] if log else None
    row["log_status"] = status
    row["topic"] = log["topic"] if log else None
    row["log_completed"] = None if log is None else bool(status and status.startswith("completed"))
    return status


def read_session(sid, entry, logs, names=(), markers=(), known=()):
    """One row. Never raises: an unreadable transcript must not take the table down."""
    e = entry or {}
    started = e.get("startedAt")
    row = {"session_id": sid, "short": sid[:8], "name": e.get("name"), "pid": e.get("pid"),
           "cwd": e.get("cwd"), "kind": e.get("kind"), "registry": entry is not None,
           "live": is_live(e.get("pid"), e.get("procStart")) if entry else False,
           "idle_seconds": None, "idle": "-", "ctx": None, "ctx_tokens": None,
           "wrapped": "unknown", "evidence": ["no transcript on disk"], "wrapped_evidence": "",
           "last": None, "topic": None, "process_age_seconds": None,
           "conversation_age_seconds": None, "transcript": transcript_for(sid, e.get("cwd"))}
    # Two different ages. The process one is what `ListAgents` shows as "started Xh ago" - it is
    # reset by every resume, so it says nothing about how much conversation the session carries.
    if isinstance(started, (int, float)) and not isinstance(started, bool) and started > 0:
        row["process_age_seconds"] = int(time.time() - started / 1000.0)
    # The log entry is looked up by EVERY name this sessionId ever carried, not just the current
    # one - see log_entry_for(). log_completed: None ONLY when no usable entry was found.
    log, row["names"] = log_entry_for([e.get("name")] + list(names or []), logs)
    status = apply_log(row, log)
    row["log_stale"] = None
    # closed_marker is non-null ONLY when the marker actually decided the verdict, so a consumer
    # tells "declared finished" from "inferred finished" with one check. A marker that was found
    # and refused (stale, ambiguous, undated) is named in the evidence, not here.
    row["closed_marker"] = None
    turn = None
    if row["transcript"]:
        try:
            recs = tail_records(row["transcript"])
            row["idle_seconds"] = int(time.time() - os.path.getmtime(row["transcript"]))
            row["idle"] = human(row["idle_seconds"])
            # An entry filed on a DIFFERENT CALENDAR DAY than the session's last turn cannot
            # describe that turn, so it is treated as ABSENT rather than as a contradiction -
            # the log's own "## YYYY-MM-DD" structure decides, not a duration somebody would
            # later tune. Measured: without this, a session that wrapped today is contradicted
            # by its own entry from yesterday and drops off the tab list.
            turn = next((t for t in (epoch(r.get("timestamp")) for r in reversed(recs)) if t),
                        os.path.getmtime(row["transcript"]))
            day = datetime.date.fromtimestamp(turn).isoformat()
            if log and log["day"] and log["day"] != day:
                row["log_stale"] = log["day"]
                log, status = None, apply_log(row, None)
            row["ctx"] = row["ctx_tokens"] = context_size(recs)
            row["cwd"] = row["cwd"] or next((r["cwd"] for r in recs if r.get("cwd")), None)
            texts = assistant_texts(recs)
            # The LAST line, not the first: that is the text at the bottom of the editor tab,
            # which is how a human finds the tab among a dozen identical ones. `topic` stays the
            # session-log topic or the FIRST line, so the two are genuinely different handles.
            row["last"] = texts[-1].splitlines()[-1].strip() if texts else None
            row["wrapped"], row["evidence"] = wrap_state(texts, status, row["log_completed"])
            first, conv = head_signals(row["transcript"])
            row["topic"] = row["topic"] or first
            if conv:
                row["conversation_age_seconds"] = int(time.time() - conv)
        except Exception as exc:               # noqa: BLE001 - one bad file, one degraded row
            row["evidence"] = ["transcript unreadable: %s" % exc]
    # The DECLARED verdict, layered on top: it overrides the inferred one, in the "yes" direction
    # only, and only while the transcript has not clearly gone on working past it. A session with
    # no marker therefore behaves exactly as it did before this existed.
    mark, notes = marker_for(sid, markers, known)
    row["evidence"].extend(notes)
    if mark:
        at = "%s on %s" % (mark["time"], mark["day"])
        when = marker_epoch(mark)
        if turn and when and turn - when > CLOSED_MARK_STALE_AFTER:
            row["evidence"].append(
                "a session log marker closes this session at %s, but its transcript has a turn "
                "%s later - STALE (resumed after its wrap, the marker is left over), ignored; "
                "the verdict below is the transcript's" % (at, human(turn - when)))
        else:
            row["closed_marker"] = mark
            row["wrapped"] = "yes"
            row["evidence"].insert(0, "session log marks this session closed at %s (marker id "
                                      "%s) - authoritative, filed by the wrap itself" % (at, mark["id"]))
    # Say that an entry was found and put aside. Dropping it silently would make the audit
    # trail claim there was no log entry at all, which is a different and much weaker fact.
    if row["log_stale"]:
        row["evidence"].append("a session log entry from %s was found and disregarded: the last "
                               "turn is from another day, so it cannot describe it"
                               % row["log_stale"])
    # A verdict that turned on an entry filed under a DIFFERENT name has to say so, or the
    # audit trail in the claiming session's transcript is simply wrong about what it read.
    if row["log_name"] and row["log_name"] != row["name"]:
        row["evidence"].append('that log entry is filed under "%s", another name of this same '
                               "sessionId (names seen: %s)"
                               % (row["log_name"], ", ".join(row["names"])))
    row["wrapped_evidence"] = "; ".join(row["evidence"])
    return row


def human(sec):
    if sec is None:
        return "?"
    m = int(sec // 60)
    return "%dm" % m if m < 60 else "%dh%02dm" % (m // 60, m % 60)


def cut(s, n):
    s = (s or "-").replace("\t", " ")
    return s if len(s) <= n else s[:n - 1] + "…"


FMT = "%-16s %-8s %-8s %-4s %-7s %-7s %-6s %-7s %-18s %s"


def table(rows):
    ctx = lambda r: "-" if r["ctx"] is None else "%dk" % (r["ctx"] // 1000)
    # CONV is the age of the CONVERSATION, not of the process - see head_signals().
    print(FMT % ("NAME", "ID", "PID", "LIVE", "IDLE", "CONV", "CTX", "WRAPPED", "CWD", "LAST"))
    for r in rows:
        print(FMT % (
            cut(r["name"], 16), r["short"], r["pid"] or "-", "yes" if r["live"] else "no",
            r["idle"], human(r["conversation_age_seconds"]), ctx(r), r["wrapped"],
            cut((r["cwd"] or "-").replace(os.path.expanduser("~"), "~"), 18), cut(r["last"], 70)))


def detail(r):
    print("%s  (%s)  pid %s  %s" % (r["name"] or "?", r["short"], r["pid"] or "-", r["cwd"] or "-"))
    print("  live    : %s%s" % (r["live"], "" if r["registry"] else "   (NO REGISTRY ENTRY - "
                                "the tab is closed; this is the transcript's word alone)"))
    print("  idle    : %s" % r["idle"])
    print("  age     : conversation %s, process %s%s" % (
        human(r["conversation_age_seconds"]), human(r["process_age_seconds"]),
        "   (RESUMED - the process is younger than the conversation it carries, so its "
        "\"started Xh ago\" says nothing about what is in its context)"
        if (r["conversation_age_seconds"] or 0) > (r["process_age_seconds"] or 0) + 900 else ""))
    print("  ctx     : %s tokens - the price of waking it" % (r["ctx"] if r["ctx"] else "?"))
    print("  wrapped : %s  (%s)" % (r["wrapped"], "; ".join(r["evidence"])))
    print("  topic   : %s" % cut(r["topic"], 200))
    print("  last    : %s" % cut(r["last"], 200))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--all", action="store_true", help="include sessions whose process is gone")
    ap.add_argument("--wrapped", action="store_true", help="only finished sessions (implies --all)")
    ap.add_argument("--name", help="one session by registry name")
    ap.add_argument("--session-id", help="one session by sessionId or a >=8-char prefix")
    ap.add_argument("--cwd", help="only sessions working in this directory OR anywhere below it "
                                  "(prefix match on whole path segments, so /x/Repo does not "
                                  "match /x/RepoOther) - a lane worker sits in a worktree, not "
                                  "in the checkout root, so an exact match would list none")
    ap.add_argument("--json", action="store_true", help="machine-readable, all fields")
    a = ap.parse_args()

    (reg, regnames), logs = registry(), session_log()
    sid = a.session_id
    if sid and sid not in reg:                 # prefix, then the transcript when the entry is gone
        hits = [s for s in reg if s.startswith(sid)] if len(sid) >= 8 else []
        if not hits and len(sid) >= 8:
            hits = [os.path.basename(p)[:-6]
                    for p in glob.glob(os.path.join(PROJ_DIR, "*", sid + "*.jsonl"))]
        if len(set(hits)) == 1:
            sid = hits[0]
        elif hits:
            print("peer-state: %r matches %d sessions" % (a.session_id, len(set(hits))),
                  file=sys.stderr)
            return 1
    # `known` is what an >=8-char marker prefix is resolved against: every sessionId in the
    # registry, plus the one asked for (its entry may already be gone with the closed tab).
    marks, known = closed_markers(), set(reg) | ({sid} if sid else set())
    rows = [read_session(s, reg.get(s), logs, regnames.get(s), marks, known)
            for s in ({sid} if sid else reg)]
    # An id with neither a registry entry nor a transcript is not a session, it is a typo.
    rows = [r for r in rows if r["registry"] or r["transcript"]]

    if a.name:
        rows = [r for r in rows if r["name"] == a.name]
    if a.cwd:
        # Prefix, on segment boundaries: the trailing separator on both sides is what keeps
        # /x/Repo from swallowing /x/RepoOther. Exact match alone excluded every lane worktree.
        want = os.path.abspath(os.path.expanduser(a.cwd)).rstrip(os.sep) + os.sep
        rows = [r for r in rows
                if r["cwd"] and (os.path.abspath(r["cwd"]) + os.sep).startswith(want)]
    if a.wrapped:
        rows = [r for r in rows if r["wrapped"] == "yes"]
    elif not (a.all or a.name or sid):
        rows = [r for r in rows if r["live"]]
    rows.sort(key=lambda r: (r["idle_seconds"] is None, r["idle_seconds"] or 0))

    if a.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
    elif a.name or sid:
        for r in rows:
            detail(r)
    elif a.wrapped:
        for r in rows:
            print("%s  (%s)  idle %s  ctx %s  live %s" % (r["name"], r["short"], r["idle"],
                  "?" if r["ctx"] is None else "%dk" % (r["ctx"] // 1000), r["live"]))
            print("  topic: %s" % cut(r["topic"], 110))
            print("  last : %s" % cut(r["last"], 110))
        print("\n%d session(s) read as finished - close these tabs instead of messaging them."
              % len(rows))
    else:
        table(rows)
    if (a.name or a.session_id) and not rows:
        print("peer-state: no session %r" % (a.name or a.session_id), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
