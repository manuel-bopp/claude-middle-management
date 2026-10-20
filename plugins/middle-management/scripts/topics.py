#!/usr/bin/env python3
"""topics.py - follow-through: every topic stays in sight until it is really finished (plan D7).

Consumers: skills/wrap/SKILL.md (closing `entry ... --review --closed` after its review loop),
  hooks/session-role.sh banner text (workers report READY/LIVE/blocked/questions with `entry`),
  the coordinator by hand (`entry --topic`, `answer`, `render`, `lint`, `stats`, `migrate`),
  scripts/t3-watch.py (`tick --scope <s>` on every watcher pass), the pathfinder runner's submit
  (`answer --scope <s> --file <answers.json>`), tests/topics.sh.

Usage:
  topics.py entry [--topic K] [--new] --status completed|in-progress|blocked
                  [--stage building|ready|reviewed|live|done] [--waits-on "<who> · <question> · rec: <r>"]
                  [--answered "<text>"] [--case REF] [--case-closed "REF · evidence"]
                  [--review "<rounds, verdict>"] [--ok "<who time>"] [--next "<step>"] [--closed]
                  [--name <peer name>] "<headline>" ["<bullet>" ...]
  topics.py answer [--scope S] --topic K "<text>"     = entry --answered (status unchanged)
  topics.py answer [--scope S] --file ANSWERS.json   books a pathfinder submit (card id = topic key)
  topics.py render [--scope S]    writes <board dir>/<board name>.topics.md
  topics.py tick [--scope S]      render + the reminder digest + the daily digest
  topics.py lint [--scope S]      log entries since the last lint without a `Topic:` line
  topics.py stats [--scope S]     re-opened after wrap: n of m topics
  topics.py migrate --board PATH [--scope S] [--skip N,..]   seed from a hand-made TOPIC TABLE;
                                  prints the board edit, never applies it

`migrate` writes the state of every row and ONE summary session-log entry.
One writer: `entry` appends the session-log entry (frozen format, README "The session log", plus
the lines Topic/Stage/Waits on/Answered/Case/Case closed/Review/OK/Next) under a flock on the log,
and updates <config dir>/state/topics/<scope>.json under its own flock (atomic replace). The table
and the reminders read only the state file. Fields: status and stage from the latest entry (a
stage stays until another one is given; `building` clears review and OK, the work restarted);
waits_on/question/rec/since stay until --answered or a new --waits-on; case stays until
--case-closed with the same REF. Scope: scope.py of the cwd. Key: --topic, else the worktree dir
lane-<name> or ~/.cache/claude/wt/<name>, else the branch lane/<name>. The coordinator seat holder
and every sub-agent pass --topic (sub-agents share their parent's sessionId); a key the scope
does not know needs --new.
Config (<config dir>/middle-management.json, all optional): notifyCommand (message as $1 and on
stdin), pageCommand (questions.json path as $1, its last stdout line = the link), userName (who
counts as the user besides "user"), okBy (who gives the final OK, default the user),
remindAfterHours (2), remindWindow ("08:00-22:00"). Delivered keys go into the ledger of
morning-ritual step 6, <config dir>/state/morning-ritual/delivered. Env MM_TOPICS_NOW (epoch)
pins the clock for tests.
"""
import argparse, contextlib, datetime, difflib, fcntl, functools, glob, hashlib, importlib.util
import io, json, os, re, subprocess, sys, tempfile, time
import scope   # beside this file

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
STATE_DIR = os.path.join(CFG, "state", "topics")
TS = "%Y-%m-%d %H:%M"
KEY = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
STAGES = ("building", "ready", "reviewed", "live", "done")
STATUSES = ("completed", "in-progress", "blocked")
# Bullets must not forge the structured lines: peer-state.py would read a bullet
# "Session: closed · <id>" as a wrap marker, and the last Status line wins there.
RESERVED = re.compile(r"(?i)^(status|session|topic|stage|waits on|answered|case|case closed|review|ok|next)\s*:")
TOPIC_LINE = re.compile(r"^\s*[-*]\s*Topic:\s*(\S+)")
STAMP = re.compile(r"· added: (\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s*$")
TODO_LINE = re.compile(r"^- (\w{8}-W\d+) · (.*)$")


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@functools.lru_cache(None)
def ps():
    return load("peer_state", "peer-state.py")     # SESSION_LOG, LOG_HEAD, DAY_HEAD, CLOSED_MARK


@functools.lru_cache(None)
def oi():
    return load("open_items", "open-items.py")     # own_session, todo, scan, DELIVERED


def now():
    return float(os.environ.get("MM_TOPICS_NOW") or time.time())


def fmt(t):
    return time.strftime(TS, time.localtime(t))


def epoch(s):
    try:
        return time.mktime(time.strptime(s, TS))
    except (TypeError, ValueError):
        return None


def flat(s):
    return " ".join(str(s).split())


@functools.lru_cache(None)
def cfg():
    return scope.config()


def user_names():
    n = cfg().get("userName")
    return {"user"} | ({n.lower()} if isinstance(n, str) and n else set())


def ok_by():
    v = cfg().get("okBy")
    return v if isinstance(v, str) and v else (cfg().get("userName") or "user")


def is_user(who):
    w = re.split(r"[\s/+,(]", (who or "").strip())[0].lower()
    return w in user_names()


def hours():
    v = cfg().get("remindAfterHours")
    return float(v) if isinstance(v, (int, float)) and v > 0 else 2.0


def in_window(t):
    v = cfg().get("remindWindow")
    pat = r"(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})"
    m = (re.fullmatch(pat, v) if isinstance(v, str) else None) or re.fullmatch(pat, "08:00-22:00")
    a, b = int(m[1]) * 60 + int(m[2]), int(m[3]) * 60 + int(m[4])
    lt = time.localtime(t)
    return a <= lt.tm_hour * 60 + lt.tm_min < b


# --- scope, paths, state ---------------------------------------------------------------------

def scope_name(arg=None):
    if arg:
        try:
            scope.info(arg)
        except ValueError:
            sys.exit("topics: no scope %r in the config" % arg)
        return arg
    try:
        return scope.of(os.getcwd())
    except scope.Unknown as e:       # fail closed, like open-items: never write into a guessed scope
        sys.exit("topics: git could not resolve the worktree %s, scope unknown" % e)


def state_path(sc):
    return os.path.join(STATE_DIR, sc + ".json")


def topics_file(sc):
    b = scope.info(sc)[1]
    return os.path.splitext(os.path.expanduser(b))[0] + ".topics.md" if b else ""


def write_atomic(path, text, mode=0o600):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def read_state(sc):
    try:
        st = json.load(open(state_path(sc), encoding="utf-8"))
    except FileNotFoundError:
        return {"topics": {}}
    except (OSError, ValueError) as e:
        # never overwrite a state we cannot read: that would drop every open topic
        sys.exit("topics: refused, %s is unreadable (%s); fix or move it by hand"
                 % (state_path(sc), type(e).__name__))
    if not isinstance(st, dict) or not isinstance(st.get("topics"), dict):
        sys.exit("topics: refused, %s has no topics object" % state_path(sc))
    return st


@contextlib.contextmanager
def locked(sc, write=True):
    """The scope's state under an exclusive flock; written back (atomic) only when the body did not raise."""
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(state_path(sc) + ".lock", "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        st = read_state(sc)
        yield st
        if write:
            write_atomic(state_path(sc), json.dumps(st, indent=1, ensure_ascii=False, sort_keys=True) + "\n")


# --- who is writing --------------------------------------------------------------------------

def seat_holder(sc):
    try:
        return open(os.path.join(scope.info(sc)[0], "orchestrator"), encoding="utf-8").readline().strip()
    except OSError:
        return ""


def derive_key(cwd):
    """lane-<name> dir or ~/.cache/claude/wt/<name>, else branch lane/<name>; None when neither."""
    wt = os.path.realpath(os.path.expanduser("~/.cache/claude/wt"))
    p = os.path.realpath(cwd)
    while p != "/":
        b = os.path.basename(p)
        if os.path.dirname(p) == wt:
            return b.lower()
        if b.startswith("lane-") and len(b) > 5:
            return b[5:].lower()
        p = os.path.dirname(p)
    try:
        r = subprocess.run(["git", "-C", cwd, "branch", "--show-current"], capture_output=True,
                           text=True, timeout=3)
        br = r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        br = ""
    return br[5:].lower() if br.startswith("lane/") and len(br) > 5 else None


def thread_of(sid):
    """T3 thread of a sessionId (plan F2): the one provider log naming "session_id":"<sid>".
    "" outside T3, on no hit and on more than one hit. ponytail: grep, not a Python scan of ~300 MB.
    ponytail: the thread TITLE `lane <name>` (plan key rule 1) needs the T3 shell read with a
    token; the worktree dir carries the same name for 13 of 15 lanes and both exceptions, so it is left out."""
    home = os.environ.get("T3CODE_HOME")
    if not (home and sid):
        return ""
    fs = glob.glob(os.path.join(home, "userdata", "logs", "provider", "events.*.log*"))
    if not fs:
        return ""
    try:
        r = subprocess.run(["grep", "-l", "-F", '"session_id":"%s"' % sid] + fs,
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    ids = {re.sub(r"\.log(\.\d+)?$", "", os.path.basename(f))[len("events."):] for f in r.stdout.split()}
    return ids.pop() if len(ids) == 1 else ""


def short_thread(t):
    m = re.search(r"[0-9a-f]{8}(?=-[0-9a-f]{4}-)", t or "")
    return m.group(0) if m else (t or "")


# --- the log ---------------------------------------------------------------------------------

def log_path():
    return ps().SESSION_LOG


def append_log(text):
    """One write under a flock on the log; a day heading first when the last one is not today."""
    path = log_path()
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a+", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.seek(0)
        old = fh.read()
        day = None
        for ln in old.splitlines():
            d = ps().DAY_HEAD.match(ln)
            if d:
                day = d.group(1)
        today = time.strftime("%Y-%m-%d", time.localtime(now()))
        out = "" if not old or old.endswith("\n") else "\n"
        if day != today:
            out += ("\n" if old else "") + "## %s\n" % today
        fh.write(out + "\n" + text)
        fh.flush()
        os.fsync(fh.fileno())
    return path


def log_entries(live_only=False):
    """Every entry of the log (and its dated archive), in file order:
    {day, time, name, head, lines, topic, closed, live}."""
    out, P = [], ps()
    files = [log_path()] if live_only else P.marker_files()
    for path in files:
        f = re.match(r"(\d{4}-\d{2}-\d{2})\.md$", os.path.basename(path))
        day, cur = (f.group(1) if f else None), None
        try:
            lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        for ln in lines:
            d = P.DAY_HEAD.match(ln)
            if d:
                day, cur = d.group(1), None
                continue
            m = P.LOG_HEAD.match(ln)
            if m:
                t = P.ENTRY_TIME.match(ln)
                cur = {"day": day, "time": t.group(1) if t else "", "name": m.group(1).split("/")[0].strip(),
                       "head": m.group(2).strip(), "header": ln, "lines": [], "topic": None, "closed": None,
                       "live": path == log_path()}
                out.append(cur)
            elif cur is not None:
                cur["lines"].append(ln)
                tm = TOPIC_LINE.match(ln)
                if tm:
                    cur["topic"] = tm.group(1)
                cm = P.CLOSED_MARK.match(ln)
                if cm:
                    cur["closed"] = cm.group(1)
    return out


def qualified(sc, key):
    return key if sc == "default" else "%s/%s" % (sc, key)


def of_scope(sc, topic):
    """The key of a log `Topic:` value when it belongs to scope sc, else None."""
    if not topic:
        return None
    if "/" in topic:
        s, k = topic.split("/", 1)
        return k if s == sc else None
    return topic if sc == "default" else None


# --- entry -----------------------------------------------------------------------------------

def parse_waits(s):
    parts = [p.strip() for p in s.split(" · ")]
    if len(parts) < 2 or not parts[0] or not parts[1]:
        sys.exit('topics: --waits-on needs "<who> · <question> · rec: <recommendation>"')
    rec = " · ".join(parts[2:])
    rec = re.sub(r"(?i)^rec(ommendation)?:\s*", "", rec)
    return parts[0], parts[1], rec


def record(sc, key, f, new=False, at=None, log=True):
    """Append the log entry and update the state for one topic. f: the parsed flags.
    Log first (the audit trail), then the state; both under their locks. log=False (migrate):
    state only, the caller writes one summary entry."""
    t = now()
    ts = fmt(at if at is not None else t)
    for b in f.get("bullets", []):
        if RESERVED.match(flat(b)):
            sys.exit("topics: refused, a bullet may not start with %r; use the flag instead"
                     % flat(b).split(":")[0])
    with locked(sc) as st:
        tp = st["topics"]
        if key not in tp and not new:
            known = ", ".join(sorted(k for k in tp)) or "none yet"
            sys.exit("topics: unknown topic %r in scope %s (first entry needs --new; known: %s)" % (key, sc, known))
        r = tp.get(key) or {"key": key, "created": ts, "entries": 0}
        if f.get("case_closed"):
            ref = f["case_closed"].split(" · ")[0].strip()
            if r.get("case") and r["case"] != ref:
                sys.exit("topics: refused, the open case of %s is %r, not %r" % (key, r["case"], ref))
        waits = parse_waits(f["waits_on"]) if f.get("waits_on") else None
        name = re.sub(r"[\[\]]", "", flat(f.get("name") or "")) or "unnamed"
        lines = ["### %s – [%s] – %s" % (time.strftime("%H:%M", time.localtime(t)), name, flat(f["headline"]))]
        lines += ["- " + flat(b) for b in f.get("bullets", []) if flat(b)]
        lines.append("- Topic: " + qualified(sc, key))
        lines.append("- Status: " + f["status"])
        for lab, k in (("Stage", "stage"), ("Answered", "answered"), ("Waits on", "waits_on"), ("Case", "case"),
                       ("Case closed", "case_closed"), ("Review", "review"), ("OK", "ok"), ("Next", "next")):
            if f.get(k):
                lines.append("- %s: %s" % (lab, flat(f[k])))
        if f.get("closed"):
            lines.append("- Session: closed · " + f["sid"])
        if log:
            append_log("\n".join(lines) + "\n")
        # the state
        r["status"] = f["status"]
        if f.get("stage"):
            r["stage"] = f["stage"]
            if f["stage"] == "building":     # work restarted: a new review and a new OK are due
                r.pop("review", None)
                r.pop("ok", None)
        if f.get("answered"):
            r.update(answered=flat(f["answered"]), answered_at=ts)
            for k in ("waits_on", "question", "rec", "since"):
                r.pop(k, None)
        if waits:
            r.update(waits_on=waits[0], question=waits[1], rec=waits[2], since=ts)
        if f.get("case"):
            r["case"] = flat(f["case"])
        if f.get("case_closed"):
            r.pop("case", None)
            r["case_closed"] = flat(f["case_closed"])
        for k in ("review", "ok", "next"):
            if f.get(k):
                r[k] = flat(f[k])
        if f.get("thread"):
            r["thread"] = f["thread"]
        if f.get("closed"):
            r.update(closed_at=ts, closed_sid=f["sid"])
        r["headline"] = flat(f["headline"])
        r["updated"] = ts
        r["entries"] = r.get("entries", 0) + 1
        r["names"] = sorted(set(r.get("names", [])) | ({name} if log else set()))   # writers in the log (lint)
        tp[key] = r
    return r


def cmd_entry(a):
    sc = scope_name()
    sid, reg = oi().own_session()
    holder = sid and sid == seat_holder(sc)
    if a.topic:
        key = a.topic.lower()
    elif holder:
        sys.exit("topics: the coordinator seat holder passes --topic on every entry")
    else:
        key = derive_key(os.getcwd())
        if not key:
            sys.exit("topics: no topic key from this directory (no lane-<name> dir, no lane/<name> branch); pass --topic")
    if not KEY.fullmatch(key):
        sys.exit("topics: bad topic key %r (lowercase letters, digits, . _ -)" % key)
    if a.closed and not sid:
        sys.exit("topics: --closed needs this session's id (no $CLAUDE_CODE_SESSION_ID, no registry entry)")
    f = {k: getattr(a, k) for k in ("status", "stage", "waits_on", "answered", "case", "case_closed",
                                    "review", "ok", "next", "closed", "headline", "bullets")}
    f.update(sid=sid, name=a.name or reg.get("name") or "",
             thread="" if holder else thread_of(sid))
    record(sc, key, f, new=a.new)
    print("topic %s (scope %s): entry in %s, state %s" % (key, sc, log_path(), state_path(sc)))


def cmd_answer(a):
    sc = scope_name(a.scope)
    sid, reg = oi().own_session()
    name = reg.get("name") or "topics-answer"
    if a.file:
        try:
            p = json.load(open(a.file, encoding="utf-8"))
            items = p["items"]
        except (OSError, ValueError, KeyError, TypeError) as e:
            sys.exit("topics: %s is not a pathfinder answers file (%s)" % (a.file, type(e).__name__))
        known = read_state(sc)["topics"]
        other = []
        for it in items if isinstance(items, list) else []:
            if not isinstance(it, dict):
                continue
            key = str(it.get("ticket", ""))
            for ans in it.get("answers", []) if key in known and isinstance(it.get("answers"), list) else []:
                if not isinstance(ans, dict):
                    continue
                text = " · ".join(x for x in (flat(ans.get("choice_label") or "") if ans.get("choice_key") else "",
                                              flat(ans.get("comment") or "")) if x)
                if not text:
                    continue          # skipped card: the wait stays open
                ok = str(ans.get("id", "")).endswith("-ok") and ans.get("choice_key")
                f = {"status": known[key].get("status", "in-progress"), "headline": "answer booked from the page",
                     "bullets": [], "name": name, "answered": None if ok else text,
                     "ok": "%s %s (%s)" % (ok_by(), fmt(now()), text) if ok else None}
                record(sc, key, f)
                print("booked %s: %s" % (key, text))
            if key and key not in known and it.get("answers"):
                other.append(key)
        if other:
            print("not topics of scope %s (book by hand, e.g. open items): %s" % (sc, ", ".join(other)))
        return
    if not (a.topic and a.text):
        sys.exit("topics: answer needs --topic K \"<text>\" or --file ANSWERS.json")
    st = read_state(sc)["topics"].get(a.topic)
    if not st:
        sys.exit("topics: unknown topic %r in scope %s" % (a.topic, sc))
    record(sc, a.topic, {"status": st.get("status", "in-progress"), "headline": "answered",
                         "bullets": [], "name": name, "answered": a.text})
    print("topic %s: answer booked" % a.topic)


# --- render ----------------------------------------------------------------------------------

def finished(r):
    """Removal rule (c): done + review + OK, and no open case (a case clears only by --case-closed)."""
    return r.get("stage") == "done" and r.get("review") and r.get("ok") and not r.get("case")


def ok_pending(r):
    return r.get("stage") == "done" and r.get("review") and not r.get("ok") and not r.get("waits_on")


def waiting_on_user(r):
    return is_user(r["waits_on"]) if r.get("waits_on") else bool(ok_pending(r) and is_user(ok_by()))


def cell(s):
    return flat(s or "-").replace("|", "\\|")


def render(sc, st):
    path = topics_file(sc)
    if not path:
        print("topics: no board configured for scope %s, nothing rendered" % sc)
        return ""
    rows = [r for r in st["topics"].values() if not finished(r)]
    rows.sort(key=lambda r: (not waiting_on_user(r), -(epoch(r.get("updated")) or 0)))
    out = ["# Topics, scope %s" % sc, "",
           "Generated by topics.py render at %s. Do not edit: write with `topics.py entry`." % fmt(now()),
           "%d open, %d waiting on %s." % (len(rows), sum(map(waiting_on_user, rows)), ok_by()), "",
           "| topic | thread | status/stage | waits on | since | next |", "|---|---|---|---|---|---|"]
    for r in rows:
        if r.get("waits_on"):
            w = "%s: %s%s" % (r["waits_on"], r.get("question", ""), " (rec: %s)" % r["rec"] if r.get("rec") else "")
            since = r.get("since")
        elif ok_pending(r):
            w, since = "%s (OK; review %s)" % (ok_by(), r["review"]), r.get("updated")
        else:
            w, since = "", ""
        if r.get("case"):
            w = (w + "; " if w else "") + "case " + r["case"]
        out.append("| %s |" % " | ".join(map(cell, (
            r["key"], short_thread(r.get("thread")), "/".join(x for x in (r.get("status"), r.get("stage")) if x),
            w, since, r.get("next") or r.get("headline")))))
    write_atomic(path, "\n".join(out) + "\n", 0o644)
    return path


def cmd_render(a):
    sc = scope_name(a.scope)
    p = render(sc, read_state(sc))
    if p:
        print("rendered " + p)


# --- reminders -------------------------------------------------------------------------------

def notify(msg):
    """0 delivered, 1 failed, 2 no notifyCommand. Output discarded: a sender may echo its token."""
    cmd = cfg().get("notifyCommand")
    if not (isinstance(cmd, str) and cmd):
        return 2
    try:
        return 0 if subprocess.run(["sh", "-c", cmd, "notify", msg], input=msg, text=True, timeout=60,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0 else 1
    except (OSError, subprocess.TimeoutExpired):
        return 1


def ledger():
    d = {}
    try:
        for ln in open(oi().DELIVERED, encoding="utf-8"):
            k, tab, t = ln.rstrip("\n").partition("\t")
            if tab:
                d[k] = max(d.get(k, ""), t)
    except OSError:
        pass
    return d


def deliver(keys):
    path = oi().DELIVERED
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.writelines("%s\t%s\n" % (k, fmt(now())) for k in keys)


def user_items(sc):
    """(key, text, stamp epoch) of the scope's open user items that carry an `added:` stamp."""
    mod = oi()
    named = bool(mod.scope_cfg()[1])
    mod.my_scope = lambda: sc if named else None     # the timer runs in no session: pin the scope
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            mod.todo(["--all"])
    except (OSError, SystemExit):
        return []
    out = []
    for ln in buf.getvalue().splitlines():
        m, s = TODO_LINE.match(ln), STAMP.search(ln)
        if m and s:
            out.append((m.group(1), m.group(2), epoch(s.group(1))))
    return out


def ledger_key(sc, key):
    return "topic:%s:%s" % (sc, key)


def due(sc, st, t):
    """[(ledger key, card or None, inline lines)] of everything waiting on the user past the threshold."""
    h, seen, out = hours() * 3600, ledger(), []

    def fresh(lk):
        last = epoch(seen.get(lk))
        return last is None or t - last >= h
    for r in sorted(st["topics"].values(), key=lambda r: r.get("since") or r.get("updated") or ""):
        if finished(r) or not waiting_on_user(r):
            continue
        since = epoch(r.get("since") if r.get("waits_on") else r.get("updated"))
        lk = ledger_key(sc, r["key"])
        if since is None or t - since < h or not fresh(lk):
            continue
        if r.get("waits_on"):
            q, rec, qid = r.get("question", ""), r.get("rec", ""), r["key"] + "-q1"
        else:
            q, rec, qid = "OK to close %s? Review: %s" % (r["key"], r["review"]), "OK", r["key"] + "-ok"
        lines = ["%s · %s" % (r["key"], q)] + (["rec: " + rec] if rec else [])
        card = {"ticket": r["key"], "title": "%s: %s" % (r["key"], r.get("headline", "")), "url": "",
                "priority": "", "asked_at": datetime.datetime.fromtimestamp(since).astimezone().isoformat(),
                "briefing": "Waiting on you since %s.%s%s" % (
                    fmt(since), " Thread %s." % short_thread(r["thread"]) if r.get("thread") else "",
                    " Next: %s." % r["next"] if r.get("next") else ""),
                "already_decided": [],
                "questions": [{"id": qid, "text": q, "why": "Open since %s." % fmt(since), "type": "choice",
                               "options": [{"key": "a", "label": rec or "Done",
                                            "consequence": "booked as the answer to this topic"}],
                               "recommendation": {"key": "a", "reason": "the recommendation given with the question"
                                                  if rec else "no recommendation given, comment instead"}}],
                "after_answers": "topics.py answer --file books each choice or comment"}
        out.append((lk, card, lines))
    for k, text, stamp in user_items(sc):
        if t - stamp >= h and fresh(k):
            out.append((k, None, ["%s · %s" % (k, text)]))
    return out


def page(sc, items):
    """Write the cards and run pageCommand; the link or None."""
    cmd = cfg().get("pageCommand")
    if not (isinstance(cmd, str) and cmd):
        return None
    qpath = os.path.join(STATE_DIR, sc + ".questions.json")
    cards = [c or {"ticket": k, "title": k, "url": "", "priority": "", "briefing": lines[0], "already_decided": [],
                   "questions": [{"id": k + "-q1", "text": lines[0], "why": "An open item for you.", "type": "choice",
                                  "options": [{"key": "a", "label": "Done", "consequence": "the coordinator closes it"}],
                                  "recommendation": {"key": "a", "reason": "close it when it is done"}}],
                   "after_answers": "the coordinator books open items by hand"}
             for k, c, lines in items]
    write_atomic(qpath, json.dumps({"generated": datetime.datetime.fromtimestamp(now()).astimezone().isoformat(),
                                    "scope": sc, "tickets": cards}, ensure_ascii=False, indent=1) + "\n")
    try:
        r = subprocess.run(["sh", "-c", cmd, "page", qpath], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    last = (r.stdout.strip().splitlines() or [""])[-1].strip()
    return last if r.returncode == 0 and re.match(r"https?://\S+$", last) else None


def stats_line(sc):
    per = stats(sc)
    closed = {k: n for k, n in per.items() if n is not None}
    re_ = sorted(n for n in closed.values() if n)
    med = re_[len(re_) // 2] if re_ else 0
    return "re-opened after wrap: %d of %d topics (median %d entries after the marker)" % (len(re_), len(closed), med)


def cmd_tick(a):
    """Compute under the lock, send without it (a hanging sender must not block `entry`), then
    record what went out under the lock again."""
    sc = scope_name(a.scope)
    t, rc, digest, daily = now(), 0, None, None
    today = time.strftime("%Y-%m-%d", time.localtime(t))
    with locked(sc) as st:
        p = render(sc, st)
        if p:
            print("rendered " + p)
        if not in_window(t):
            print("outside remindWindow, no reminder")
            return
        if t - (st.get("last_digest") or 0) >= hours() * 3600 - 300:   # (b) one digest per remindAfterHours
            digest = due(sc, st, t) or None
        if st.get("last_daily") != today:                               # (c) once a day
            open_ = [r for r in st["topics"].values() if not finished(r) and not waiting_on_user(r)]
            daily = ([r for r in open_ if t - (epoch(r.get("updated")) or t) >= 86400],
                     [r for r in open_ if r.get("stage") == "done" and not r.get("ok")])
    sent_digest = sent_daily = False
    if digest:
        link = page(sc, digest) if len(digest) > 3 else None
        if link:
            msg = "Waiting on you: %d\nOne page with all of them: %s" % (len(digest), link)
        else:
            msg = "\n".join(["Waiting on you: %d" % len(digest)] + [ln for _, _, ls in digest for ln in ls])
            if len(digest) > 3:
                print("no page (pageCommand missing or failed), inline digest instead")
        rc = send(msg, [k for k, _, _ in digest])
        sent_digest = rc == 0
    if daily is not None:
        stale, nook = daily
        if stale or nook:
            lines = ["Topics digest, scope %s" % sc]
            lines += ["stale %s · %s · last entry %s" % (r["key"], "waits on " + r["waits_on"] if r.get("waits_on")
                                                         else r.get("status"), r.get("updated")) for r in stale]
            lines += ["done without OK %s · %s" % (r["key"], "review " + r["review"] if r.get("review")
                                                   else "no review") for r in nook]
            lines.append(stats_line(sc))
            d = send("\n".join(lines), [])
            rc = rc or d
            sent_daily = d == 0
        else:
            sent_daily = True
    if sent_digest or sent_daily:
        with locked(sc) as st:
            if sent_digest:
                st["last_digest"] = t
            if sent_daily:
                st["last_daily"] = today
    sys.exit(rc)


def send(msg, keys):
    r = notify(msg)
    if r == 2:
        print("not sent (no notifyCommand); the message would have been:\n" + msg)
        return 0
    if r == 1:
        print("topics: notifyCommand failed; the message was:\n" + msg, file=sys.stderr)
        return 1
    if keys:
        deliver(keys)
    print("sent:\n" + msg)
    return 0


# --- lint, stats -----------------------------------------------------------------------------

def cmd_lint(a):
    sc = scope_name(a.scope)
    with locked(sc) as st:
        names = {n for r in st["topics"].values() for n in r.get("names", [])}
        seen = set(st.get("linted", []))
        found, hashes = [], []
        for e in log_entries(live_only=True):
            h = hashlib.sha1("\n".join([e["day"] or "", e["header"]] + e["lines"]).encode()).hexdigest()[:12]
            hashes.append(h)
            if h in seen or e["topic"] or e["name"] not in names:
                continue      # F13: only sessions that already write topics; starts and backfills are exempt
            if re.match(r"(?i)session (started|resumed)", e["head"]) or any("backfilled by" in l for l in e["lines"]):
                continue
            found.append(e)
        st["linted"] = (list(seen - set(hashes)) + hashes)[-5000:]
    for e in found:
        print("%s %s [%s] %s" % (e["day"], e["time"], e["name"], e["head"]))
    print("%d entr%s without a Topic: line since the last lint (scope %s)"
          % (len(found), "y" if len(found) == 1 else "ies", sc))


def stats(sc):
    """{topic key: entries after its first `Session: closed` marker, or None without a marker}."""
    per = {}
    for e in log_entries():
        k = of_scope(sc, e["topic"])
        if k is None:
            continue
        if k not in per:
            per[k] = None
        if per[k] is not None:
            per[k] += 1
        if e["closed"] and per[k] is None:
            per[k] = 0
    return per


def cmd_stats(a):
    sc = scope_name(a.scope)
    per = stats(sc)
    for k, n in sorted(per.items()):
        if n:
            print("%s: %d entr%s after its wrap" % (k, n, "y" if n == 1 else "ies"))
    print(stats_line(sc))


# --- migrate ---------------------------------------------------------------------------------

def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def worktree_names():
    """branch -> worktree key, for every lane-<x> worktree T3 or wt keeps (dir beats branch)."""
    m = {}
    dirs = glob.glob(os.path.expanduser("~/.t3/worktrees/*/lane-*")) + glob.glob(os.path.expanduser("~/.cache/claude/wt/*"))
    for d in dirs:
        try:
            br = subprocess.run(["git", "-C", d, "branch", "--show-current"], capture_output=True, text=True,
                                timeout=3).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            continue
        b = os.path.basename(d)
        if br:
            m.setdefault(br, b[5:] if b.startswith("lane-") else b)
    return m


def migrate_rows(table_lines):
    rows = []
    for ln in table_lines:
        c = [x.strip() for x in ln.strip().strip("|").split("|")]
        if len(c) >= 7 and c[0].isdigit():
            rows.append({"n": int(c[0]), "topic": c[1], "lane": c[2], "status": c[3], "waits": c[4],
                         "since": c[5], "next": c[6]})
    return rows


def row_fields(r, year):
    s = r["status"].lower()
    status, stage = "in-progress", None
    if s.startswith("blocked"):
        status = "blocked"
    elif s.startswith("live"):
        status, stage = "completed", "live"
    elif s.startswith("ready"):
        stage = "ready"
    elif s.startswith(("building", "rendering")):
        stage = "building"
    w = r["waits"]
    waits = None
    if w and not re.match(r"(?i)nothing\b", w):
        who = re.split(r"[\s(]", w)[0]
        q = w[len(who):].strip(" ,:;") or w
        q = q[1:-1] if q.startswith("(") and q.endswith(")") else q
        waits = "%s · %s · rec: " % (who, q.replace(" · ", ", "))
    m = re.match(r"(\d{2})-(\d{2})(?:\s+(\d{1,2}:\d{2}))?$", r["since"])
    at = epoch("%s-%s-%s %s" % (year, m[1], m[2], m[3] or "00:00")) if m else None
    return status, stage, waits, at


def cmd_migrate(a):
    bpath = os.path.expanduser(a.board)
    sc = a.scope
    if not sc:
        for n in ["default"] + [s["name"] for s in scope.scopes()]:
            if os.path.expanduser(scope.info(n)[1] or "") == bpath:
                sc = n
        sc = sc or scope_name()
    sc = scope_name(sc)
    if os.path.realpath(os.path.expanduser(scope.info(sc)[1] or "")) != os.path.realpath(bpath):
        sys.exit("topics: %s is not the board of scope %s" % (bpath, sc))
    text = open(bpath, encoding="utf-8").read()
    lines = text.splitlines(keepends=True)
    start = next((i for i, l in enumerate(lines) if l.startswith("## TOPIC TABLE")), None)
    if start is None:
        sys.exit("topics: no '## TOPIC TABLE' heading in %s" % bpath)
    end = start + 1
    while end < len(lines) and not lines[end].startswith("## "):
        end += 1
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1                                  # keep the blank line before the next section
    skip = {int(x) for x in (a.skip or "").split(",") if x.strip().isdigit()}
    rows = [r for r in migrate_rows(lines[start:end]) if r["n"] not in skip]
    year = time.strftime("%Y", time.localtime(now()))
    wts, by_thread, used = worktree_names(), {}, set()
    for r in rows:                                # pass 1: lanes and their threads
        br = re.search(r"\blane/([\w.-]+)", r["lane"])
        th = re.search(r"\b[0-9a-f]{8}\b", r["lane"])
        r["thread"] = th.group(0) if th else ""
        if br:
            r["key"] = wts.get("lane/" + br.group(1), br.group(1)).lower()
            used.add(r["key"])
            if r["thread"]:
                by_thread.setdefault(r["thread"], r["key"])
    for r in rows:                                # pass 2: the rest by thread, else by the topic's head
        if "key" in r:
            continue
        if r["thread"] in by_thread:
            r["key"] = by_thread[r["thread"]]
            continue
        words = re.split(r"\s*[(:,]", r["topic"])[0].split()
        words = words[:next((i for i, w in enumerate(words) if "/" in w), len(words))]   # stop at a path
        if words and "-" in words[0]:
            k = slug(words[0])                    # "cast-india step 2" -> the lane's own name
        else:                                     # ponytail: a tiny stoplist, the coordinator reads the dry-run
            k = slug(" ".join([w for w in words if w.lower() not in ("a", "an", "the", "for", "of", "to", "only", "and")][:3]))
        k = base = k[:60] or "topic"
        n = 2
        while k in used:                          # two different topics with the same head
            k, n = "%s-%d" % (base, n), n + 1
        r["key"] = k
        used.add(k)
        if r["thread"]:
            by_thread[r["thread"]] = k
    rows.sort(key=lambda r: (row_fields(r, year)[3] or 0))   # oldest first: later rows are later entries
    known = set(read_state(sc)["topics"])
    for r in rows:
        status, stage, waits, at = row_fields(r, year)
        f = {"status": status, "stage": stage, "waits_on": waits, "next": r["next"], "thread": r["thread"],
             "headline": "migrated from the board TOPIC TABLE row %d: %s" % (r["n"], r["topic"]),
             "bullets": ["was: status %s · waits on %s · since %s" % (r["status"], r["waits"], r["since"])],
             "name": "topics-migrate"}
        record(sc, r["key"], f, new=r["key"] not in known, at=at, log=False)
        known.add(r["key"])
        print("row %2d -> %-24s %s%s" % (r["n"], r["key"], status, "/" + stage if stage else ""))
    keys = sorted({r["key"] for r in rows})
    append_log("\n".join([   # ONE summary entry for the whole migration, not one per row
        "### %s – [topics-migrate] – migrated %d topics from the board table"
        % (time.strftime("%H:%M", time.localtime(now())), len(keys)),
        "- From %s, %d rows%s" % (bpath, len(rows), " (skipped rows %s)" % a.skip if skip else ""),
        "- Keys: " + ", ".join(keys),
        "- Status: completed"]) + "\n")
    p = render(sc, read_state(sc))
    print("rendered " + p)
    # open-item keys that occur only inside the table would count as unfiled once it is gone
    # (open-items.py files a key found anywhere in the board): the link line carries them over
    BK = oi().BOARD_KEY
    in_table = set(BK.findall("".join(lines[start:end])))
    only = sorted(in_table - set(BK.findall("".join(lines[:start] + lines[end:]))))
    link = ("Topics: %s (generated by topics.py; replaces the hand-made TOPIC TABLE, migrated %s)%s\n"
            % (p, fmt(now()), "; open-item keys carried over from it: " + ", ".join(only) if only else ""))
    new = lines[:start] + [link] + lines[end:]
    print("\n--- the board edit (NOT applied) ---")
    sys.stdout.writelines(difflib.unified_diff(lines, new, bpath, bpath + " (after)", n=1))
    print("\n--- open-items check ---")
    print("keys inside the table: %d; only inside the table: %s%s" % (
        len(in_table), ", ".join(only) or "none", " (carried over in the link line)" if only else ""))
    mod = oi()
    named = bool(mod.scope_cfg()[1])
    mod.my_scope = lambda: sc if named else None
    for lab, ks in (("before", set(BK.findall("".join(lines)))), ("after", set(BK.findall("".join(new))))):
        ok, bad = mod.scan(ks)
        print("open-items.py list %s: %d unfiled in %d files (%d unreadable)"
              % (lab, sum(len(t) for _, t in ok), sum(1 for _, t in ok if t), len(bad)))


# --- main ------------------------------------------------------------------------------------

def main(argv):
    ap = argparse.ArgumentParser(prog="topics.py", description="follow-through: one writer, one state per scope")
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("entry")
    e.add_argument("--topic")
    e.add_argument("--new", action="store_true")
    e.add_argument("--status", required=True, choices=STATUSES)
    e.add_argument("--stage", choices=STAGES)
    for o in ("--waits-on", "--answered", "--case", "--case-closed", "--review", "--ok", "--next", "--name"):
        e.add_argument(o)
    e.add_argument("--closed", action="store_true")
    e.add_argument("headline")
    e.add_argument("bullets", nargs="*")
    an = sub.add_parser("answer")
    an.add_argument("--scope")
    an.add_argument("--topic")
    an.add_argument("--file")
    an.add_argument("text", nargs="?")
    for n in ("render", "tick", "lint", "stats"):
        sub.add_parser(n).add_argument("--scope")
    m = sub.add_parser("migrate")
    m.add_argument("--board", required=True)
    m.add_argument("--scope")
    m.add_argument("--skip", help="row numbers to leave out, e.g. 27 (another scope's row)")
    a = ap.parse_args(argv)
    if a.cmd == "entry" and not flat(a.headline):
        sys.exit("topics: the headline is empty")
    {"entry": cmd_entry, "answer": cmd_answer, "render": cmd_render, "tick": cmd_tick, "lint": cmd_lint,
     "stats": cmd_stats, "migrate": cmd_migrate}[a.cmd](a)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except scope.Unknown as e:
        sys.exit("topics: git could not resolve the worktree %s, scope unknown" % e)
