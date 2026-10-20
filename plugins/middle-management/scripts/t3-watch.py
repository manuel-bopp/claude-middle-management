#!/usr/bin/env python3
"""t3-watch.py - the T3 Code watcher of middle-management: one tick, no model (plan 1.4, 1.4b).

Consumers: templates/systemd/t3-watch.service (started every 10 min by t3-watch.timer; both
  installed as USER units by /middle-management-setup), tests/t3-watch.sh, by hand for
  `--dry-run` / `--stats`. Calls t3-wake.sh, scope.py and, when it exists, topics.py (all beside
  it). Reads <cfg>/state/t3-report/{failures.log,posts.tsv}, which t3-wake.sh writes.

Usage: t3-watch.py [--dry-run] | --stats
  --dry-run  print every notify, wake and probe instead of doing it, keep no state; scopes without
             a sidecar are evaluated too (the coordinator is then unknown)
  --stats    posts per day and sending thread, from posts.tsv

Per scope with a sidecar (<marker dir>/orchestrator.t3.json), over the unsettled, non-archived,
top-level threads of the scope's T3 project(s), the coordinator thread included:
  usage-limited  lastErrorClass usage_limit, no live run -> notify once per thread and episode; a
                 thread leaves the episode on a live run or a latest run completed after the limited
                 one (lastErrorClass is not trusted to clear);
                 every 30 min: coordinator limited -> t3-wake.sh --keepalive (that run is the retry);
                 only workers limited -> probe their model with one tiny headless `claude -p`, and
                 when it passes wake the coordinator with "limit over for ...". A coordinator that
                 recovers after a Keepalive gets that wake at once. "limit over" goes once per
                 (thread, run id): an announced thread is not probed again until its run id changes,
                 so the probe stops when every limited thread was announced. Episode end -> one
                 "resolved".
                 onLimitCommand (config, optional) runs once per episode with the thread ids.
  click pending  pendingRuntimeRequest seen for >10 min -> notify once per request
  other failure  status failed, another class -> wake the coordinator once per run id (the
                 coordinator's own failure is notified instead: waking it would start a new run)
  stuck run      a live run whose (activeRunId, itemCount) has not changed for >3 h -> notify once
                 per run. ponytail: itemCount, not updatedAt, because updatedAt also moves on
                 lifecycle edits (pin, visit, settle); itemCount grows only with real items.
  report lost    new lines in failures.log -> notify once per line (batched per tick)
  no coordinator the sidecar's thread is gone, settled or archived -> notify once per episode
  handover       sidecar.handover {toThreadId, toTitle, since} older than 30 min while the sidecar
                 still names the old holder -> notify once per handover
Plus: topics.py tick --scope <name> for every scope when topics.py exists (with or without sidecar).
A T3 API problem (HTTP 400 / missing keys, token rejected, server down twice in a row) -> one
notify per kind and day, never a crash. Secrets: the token (config t3TokenFile, default
~/.config/t3-threads/token, refused when group/other can read it) only goes into a request header;
notifyCommand / onLimitCommand are executed, never echoed; the webhook URL is t3-wake.sh's alone.
The T3 server: config t3Url, default http://127.0.0.1:$T3CODE_PORT (8470 when unset).
Env: T3CODE_PORT, T3W_NOW (epoch, test seam), CLAUDE_CONFIG_DIR.
Exit 0, or 1 when a notify could not be delivered (systemd's OnFailure alarm then fires).
"""
import collections, json, os, re, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scope  # noqa: E402  (beside this file)

CFG_DIR = scope.CFG
REPORT_DIR = os.path.join(CFG_DIR, "state", "t3-report")
STATE_DIR = os.path.join(CFG_DIR, "state", "t3-watch")
NOW = float(os.environ.get("T3W_NOW") or time.time())
TODAY = time.strftime("%Y-%m-%d", time.localtime(NOW))
RETRY_S, CLICK_S, STUCK_S, HANDOVER_S = 30 * 60, 10 * 60, 3 * 3600, 30 * 60
REQUIRED = ("id", "projectId", "title", "status", "activityRunStatus", "activeRunId", "latestRunId",
            "lastError", "lastErrorClass", "usageLimitResetAt", "pendingRuntimeRequest", "itemCount",
            "settledAt", "archivedAt", "modelSelection")
DRY = False
NOTIFY_FAILED = False


def log(msg):
    print("t3-watch: " + msg, file=sys.stderr)


def load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, type(default)) else default
    except (OSError, ValueError):
        return default     # a corrupt state file starts clean, it never inverts a latch


def save(path, value):
    if DRY:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def notify(scope_name, headline, facts=()):
    """One message through notifyCommand: the headline, then one fact per line."""
    global NOTIFY_FAILED
    text = "\n".join(["t3-watch %s, scope %s: %s" % (socket.gethostname().split(".")[0], scope_name, headline)]
                     + [str(f) for f in facts])
    if DRY:
        print("NOTIFY  " + text.replace("\n", "\n        "))
        return
    cmd = CFG.get("notifyCommand") if isinstance(CFG.get("notifyCommand"), str) else ""
    if not cmd:
        log("no notifyCommand in the config, NOT delivered: " + text)
        NOTIFY_FAILED = True
        return
    try:      # output dropped: a failing command may echo a URL that carries a token
        rc = subprocess.run(["sh", "-c", cmd, "notify", text], input=text, text=True, timeout=60,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    except (OSError, subprocess.TimeoutExpired):
        rc = -1
    if rc != 0:
        log("notifyCommand failed (exit %s), the message was: %s" % (rc, text))
        NOTIFY_FAILED = True


def wake(scope_name, text, keepalive=False):
    """t3-wake.sh into the scope's coordinator; True only when it answered 202."""
    if DRY:
        print("WAKE    scope %s: %s" % (scope_name, "Keepalive" if keepalive else text.replace("\n", " | ")))
        return True
    env = dict(os.environ, MM_SESSION_ID="", MM_SCOPE=scope_name)
    with tempfile.NamedTemporaryFile("w", prefix="t3-watch.", suffix=".txt", delete=False) as f:
        f.write(text)
    try:
        rc = subprocess.run(["bash", os.path.join(HERE, "t3-wake.sh"), "t3-watch",
                             "--keepalive" if keepalive else f.name], env=env, timeout=30,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    except (OSError, subprocess.TimeoutExpired):
        rc = -1
    finally:
        os.unlink(f.name)
    if rc != 0:
        log("t3-wake.sh failed (exit %s) for scope %s" % (rc, scope_name))   # it logged failures.log
    return rc == 0


def probe(model):
    """True = the model answers, False = still usage-limited, None = the probe failed otherwise.
    The logic of slack-threadwatcher's check-usage-limit.py, inlined (no dependency on a skill)."""
    if DRY:
        print("PROBE   claude -p ok --model %s" % model)
        return None
    cmd = ["claude", "-p", "ok", "--model", model, "--output-format", "json", "--no-session-persistence",
           "--strict-mcp-config", "--tools", "", "--setting-sources", ""]
    env = {k: v for k, v in os.environ.items() if not k.startswith("T3CODE_")}  # never a T3 thread
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=120, cwd="/tmp", env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        log("probe %s failed: %s" % (model, e.__class__.__name__))
        return None
    try:
        d = json.loads(p.stdout)
        err, text = bool(d.get("is_error")), str(d.get("result", ""))
        if d.get("api_error_status") == 429:
            text += " [429 %s]" % d.get("api_error_code")
    except (ValueError, AttributeError):
        err, text = p.returncode != 0, (p.stdout or "") + "\n" + (p.stderr or "")
    if not err:
        return True
    if re.search(r"usage limit|hit your limit|limit reached|out of (?:extra )?usage|\[429 ", text, re.I):
        return False
    log("probe %s: other error: %s" % (model, text.strip()[:200]))
    return None


def api_problem(gstate, kind, facts):
    """One notify per kind and day; the tick then skips the T3 part."""
    if gstate.setdefault("api", {}).get(kind) != TODAY:
        gstate["api"][kind] = TODAY
        notify("all", kind, facts)


def t3_url():
    """Config key t3Url (setup writes it), else this box's T3 server on loopback."""
    u = CFG.get("t3Url")
    return u if isinstance(u, str) and u else "http://127.0.0.1:%s" % (os.environ.get("T3CODE_PORT") or "8470")


def fetch_shell(gstate):
    """The /api/orchestration/shell JSON, or None after reporting why (never raises)."""
    path = os.path.expanduser(CFG.get("t3TokenFile") or "~/.config/t3-threads/token")
    try:
        st = os.stat(path)
        if st.st_mode & 0o077:
            api_problem(gstate, "T3 token file is readable by group/other, refused",
                        [path, "fix: chmod 600 " + path])
            return None
        with open(path, encoding="utf-8") as f:
            tok = f.read().strip()
    except OSError:
        api_problem(gstate, "T3 token file missing", [path, "config key t3TokenFile"])
        return None
    base = t3_url()
    req = urllib.request.Request(base.rstrip("/") + "/api/orchestration/shell", headers={
        "authorization": "Bearer " + tok, "x-t3-orchestration-protocol": "2"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 400:
            api_problem(gstate, "T3 API changed", ["GET /api/orchestration/shell answered 400",
                                                   "check the protocol header (plugin README, \"T3 Code\")"])
        elif e.code in (401, 403):
            api_problem(gstate, "T3 token rejected", ["HTTP %d" % e.code, path])
        else:
            return down(gstate, "HTTP %d" % e.code)
        return None
    except (urllib.error.URLError, OSError, ValueError) as e:
        if isinstance(e, ValueError):
            api_problem(gstate, "T3 API changed", ["the shell answer is not JSON"])
            return None
        return down(gstate, e.__class__.__name__)
    gstate["down"] = 0
    ok = isinstance(body, dict) and isinstance(body.get("threads"), list) \
        and isinstance(body.get("projects"), list) \
        and all(isinstance(t, dict) and all(k in t for k in REQUIRED) for t in body["threads"]) \
        and all(isinstance(p, dict) and "id" in p and "workspaceRoot" in p for p in body["projects"])
    if not ok:
        api_problem(gstate, "T3 API changed", ["the shell answer lacks keys the watcher reads",
                                               "needed per thread: " + ", ".join(REQUIRED)])
        return None
    return body


def down(gstate, why):
    """The server did not answer: a T3 restart lasts one tick, so only the second miss notifies."""
    gstate["down"] = int(gstate.get("down", 0)) + 1
    if gstate["down"] >= 2:
        api_problem(gstate, "T3 server unreachable", [why, "%d ticks in a row" % gstate["down"]])
    return None


def norm(tid):
    return (tid or "").replace(":", "-")


def label(t):
    return "%s (%s)" % (t.get("title") or "untitled", t["id"])


def model_of(t):
    m = t.get("modelSelection")
    return (m.get("model") if isinstance(m, dict) else None) or "unknown"


def err_text(t):
    e = t.get("lastError")
    if isinstance(e, dict):
        e = e.get("message") or json.dumps(e)
    return str(e or "")[:300]


def threads_of(shell, name, ss, coord_id):
    """Top-level threads of the scope's projects that are neither settled nor archived, plus the
    coordinator's row (by id) whatever its state, as (threads, coordinator row or None)."""
    memo = {}
    for p in shell["projects"]:
        try:
            memo[p["id"]] = scope.of(p["workspaceRoot"], ss)
        except scope.Unknown:
            memo[p["id"]] = None      # unknown scope: never watched, never guessed
    # ponytail: sub-agent rows are skipped (84 idle orphans today); their parent reports for them.
    out = [t for t in shell["threads"] if memo.get(t["projectId"]) == name
           and not (t.get("settledAt") or t.get("archivedAt") or t.get("deletedAt"))
           and (t.get("lineage") or {}).get("relationshipToParent") != "subagent"]
    coord = None
    if coord_id:
        coord = next((t for t in shell["threads"] if norm(t["id"]) == norm(coord_id)), None)
        if coord is not None and all(t["id"] != coord["id"] for t in out):
            out.append(coord)
    return out, coord


def check_scope(name, sdir, side, shell, ss):
    st_path = os.path.join(STATE_DIR, name + ".json")
    st = load(st_path, {})
    coord_id = side.get("threadId") if isinstance(side.get("threadId"), str) else ""
    threads, coord = threads_of(shell, name, ss, coord_id)
    is_coord = lambda t: coord is not None and t["id"] == coord["id"]  # noqa: E731
    live = lambda t: t.get("activityRunStatus") == "running"           # noqa: E731

    # no coordinator: the seat names a thread that is gone, settled or archived
    if side:
        gone = coord is None or bool(coord.get("settledAt") or coord.get("archivedAt") or coord.get("deletedAt"))
        if gone and not st.get("coordless"):
            notify(name, "folder has no coordinator", [
                "the seat names thread %s (%s), which is %s" % (side.get("title") or "?", coord_id or "?",
                                                                  "gone" if coord is None else "settled or archived"),
                "workers report into a closed thread",
                "fix: a session in this folder claims the seat (/orchestrator claim)"])
        elif not gone and st.get("coordless"):
            notify(name, "resolved: the coordinator thread is back", [label(coord)])
        st["coordless"] = gone

    # handover (orchestrator.sh t3-handover): the successor has not claimed within 30 min
    ho = side.get("handover") if isinstance(side.get("handover"), dict) else {}
    to, since = ho.get("toThreadId"), ho.get("since")
    if isinstance(to, str) and to and isinstance(since, (int, float)) and norm(to) != norm(coord_id) \
            and NOW - since > HANDOVER_S:
        key = "%s@%d" % (to, since)
        if st.get("handover") != key:
            notify(name, "handover to %s (thread %s) open for %d min, the successor has not claimed"
                   % (ho.get("toTitle") or "untitled", to, (NOW - since) // 60),
                   ["the old holder %s keeps the seat until then" % (side.get("title") or coord_id or "?"),
                    "fix: the successor runs /orchestrator claim"])
            st["handover"] = key

    # usage limit
    ep = st.get("limit") or {}
    runs = ep.get("runs", {})       # thread id -> the run that hit the limit

    def recovered(t):
        # The episode ends on a live run or on a latest run that completed AFTER the limited one; it
        # never trusts lastErrorClass to clear. (Verified 2026-10-20: the four threads limited on
        # 16. and 18.10 and resumed later read completed + lastErrorClass null now; the moment it
        # cleared is not visible in the shell, hence the run-id rule.)
        return live(t) or (t.get("status") == "completed" and t.get("latestRunId") != runs.get(t["id"]))
    limited = {t["id"]: t for t in threads
               if (t["id"] in runs and not recovered(t))
               or (t["id"] not in runs and t.get("lastErrorClass") == "usage_limit"
                   and not live(t) and t.get("status") != "completed")}
    nruns = {i: (t.get("latestRunId") if t.get("status") == "failed" else runs.get(i, t.get("latestRunId")))
             for i, t in limited.items()}
    if limited:
        if not ep:
            ep = {"since": NOW, "last_retry": NOW, "notified": [], "keepalive": False}
            cmd = CFG.get("onLimitCommand")
            if isinstance(cmd, str) and cmd:
                if DRY:
                    print("ONLIMIT %d thread ids" % len(limited))
                else:
                    try:
                        subprocess.run(["sh", "-c", cmd, "onlimit"] + sorted(limited), timeout=60,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    except (OSError, subprocess.TimeoutExpired):
                        log("onLimitCommand failed")
        ep["runs"] = nruns
        new = [t for i, t in sorted(limited.items()) if i not in ep["notified"]]
        if new:
            notify(name, "usage limit", [
                "%s, model %s, %s" % (label(t), model_of(t), "resets " + t["usageLimitResetAt"]
                                      if t.get("usageLimitResetAt") else "reset unknown")
                for t in new] + ["switch the subscription, the watcher retries every 30 min"])
            ep["notified"] = sorted(set(ep["notified"]) | set(limited))
        # "limit over" goes once per limited (thread, run id): a thread the coordinator did not
        # continue is neither probed nor named again until its run id changes (a new limit).
        freed = {i: r for i, r in (ep.get("freed") or {}).items() if i in nruns and nruns[i] == r}
        workers = [t for i, t in sorted(limited.items()) if not is_coord(t) and i not in freed]

        def limit_over(ts):
            if wake(name, "limit over for:\n%s\nsend 'Continue where you left off.' to each (t3_thread_send)."
                    % "\n".join(label(t) for t in ts)):
                freed.update((t["id"], nruns[t["id"]]) for t in ts)

        if coord is not None and coord["id"] in limited:
            if NOW - ep["last_retry"] >= RETRY_S:
                ep["last_retry"] = NOW
                ep["keepalive"] = wake(name, "", keepalive=True) or ep["keepalive"]
        elif workers and ep.get("keepalive") and coord is not None and not live(coord):
            limit_over(workers)       # the Keepalive run completed after the limited one: switched
            ep["keepalive"], ep["last_retry"] = False, NOW
        elif workers and NOW - ep["last_retry"] >= RETRY_S:
            ep["last_retry"] = NOW
            by_model = collections.defaultdict(list)
            for t in workers:
                by_model[model_of(t)].append(t)
            free = [t for m, ts in sorted(by_model.items()) if probe(m) is True for t in ts]
            if free:
                limit_over(free)
        ep["freed"] = freed
        st["limit"] = ep
    elif ep:
        notify(name, "resolved: usage limit over", ["%d thread(s) were limited since %s" % (
            len(ep.get("notified", [])), time.strftime("%d.%m.%y %H:%M", time.localtime(ep.get("since", NOW))))])
        st["limit"] = {}

    # click pending > 10 min, stuck run > 3 h, other failure once per run id
    pend, stuck, failed = st.get("pending", {}), st.get("stuck", {}), st.get("failed", {})
    npend, nstuck, nfailed = {}, {}, {}
    for t in threads:
        tid, req = t["id"], t.get("pendingRuntimeRequest")
        if req:
            key = str(req.get("id")) if isinstance(req, dict) and req.get("id") else json.dumps(req, sort_keys=True)[:200]
            e = pend.get(tid) if (pend.get(tid) or {}).get("key") == key else {"key": key, "first": NOW, "done": False}
            if not e["done"] and NOW - e["first"] >= CLICK_S:
                notify(name, "waiting on a click", [label(t), "pending for %d min" % ((NOW - e["first"]) // 60),
                                                    "open the thread in T3 and answer it"])
                e["done"] = True
            npend[tid] = e
        elif live(t):
            snap = [t.get("activeRunId"), t.get("itemCount")]
            e = stuck.get(tid) if (stuck.get(tid) or {}).get("snap") == snap else {"snap": snap, "since": NOW, "done": False}
            if not e["done"] and NOW - e["since"] >= STUCK_S:
                notify(name, "stuck run", [label(t), "no new item for %d h" % ((NOW - e["since"]) // 3600),
                                           "check the thread; stop it if it hangs"])
                e["done"] = True
            nstuck[tid] = e
        if t.get("status") == "failed" and not live(t) and t.get("lastErrorClass") != "usage_limit":
            run = t.get("latestRunId") or "?"
            if failed.get(tid) != run:
                facts = [label(t), "class %s" % (t.get("lastErrorClass") or "unknown"), err_text(t)]
                if is_coord(t):
                    notify(name, "the coordinator's last run failed", facts + ["look at the thread in T3"])
                else:
                    wake(name, "other failure in %s: %s. %s" % (label(t), t.get("lastErrorClass") or "unknown",
                                                                 err_text(t)))
            nfailed[tid] = run
    st.update(pending=npend, stuck=nstuck, failed=nfailed)
    save(st_path, st)


def report_lost(gstate):
    path = os.path.join(REPORT_DIR, "failures.log")
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    off = int(gstate.get("failures_offset", 0))
    if size < off:
        off = 0                       # rotated or truncated: read it again from the top
    with open(path, encoding="utf-8", errors="replace") as f:
        f.seek(off)
        lines = [ln.rstrip("\n") for ln in f.read().splitlines() if ln.strip()]
        gstate["failures_offset"] = f.tell()
    if lines:
        facts = []
        for ln in lines[:10]:
            c = (ln.split("\t") + [""] * 5)[:5]
            facts.append("%s from %s, thread %s: %s" % (c[0], c[1], c[3], c[4]))
        if len(lines) > 10:
            facts.append("and %d more in %s" % (len(lines) - 10, path))
        notify("all", "report lost: not delivered to the coordinator", facts)


def topics_tick(names):
    tp = os.path.join(HERE, "topics.py")
    if not os.path.isfile(tp):
        return
    for n in names:
        if DRY:
            print("TOPICS  python3 topics.py tick --scope %s" % n)
            continue
        try:
            rc = subprocess.run([sys.executable, tp, "tick", "--scope", n], timeout=120,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        except (OSError, subprocess.TimeoutExpired):
            rc = -1
        if rc != 0:
            log("topics.py tick --scope %s failed (exit %s)" % (n, rc))


def stats():
    path = os.path.join(REPORT_DIR, "posts.tsv")
    c = collections.Counter()
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for ln in f:
                p = (ln.rstrip("\n").split("\t") + ["", "", "", ""])[:4]
                if p[0]:
                    c[(p[0], p[3], p[1])] += 1
    except OSError:
        print("no posts yet (%s)" % path)
        return 0
    print("date\tposts\tthread\tfrom")
    for (d, th, fr), n in sorted(c.items()):
        print("%s\t%d\t%s\t%s" % (d, n, th, fr))
    return 0


def main(argv):
    global DRY, CFG
    if argv == ["--stats"]:
        return stats()
    if argv not in ([], ["--dry-run"]):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    DRY = argv == ["--dry-run"]
    CFG = scope.config()
    ss = scope.scopes(CFG)
    names = ["default"] + [s["name"] for s in ss]
    g_path = os.path.join(STATE_DIR, "global.json")
    gstate = load(g_path, {})
    try:
        report_lost(gstate)
        work = []
        for n in names:
            sdir = scope.info(n, CFG)[0]
            side_path = os.path.join(sdir, "orchestrator.t3.json")
            side = load(side_path, {}) if os.path.isfile(side_path) else None
            if side is not None or DRY:
                work.append((n, sdir, side or {}))
                if DRY and side is None:
                    print("SCOPE   %s: no sidecar, evaluated for the dry run only" % n)
        if work:
            shell = fetch_shell(gstate)
            if shell is not None:
                for n, sdir, side in work:
                    check_scope(n, sdir, side, shell, ss)
        topics_tick(names)
    except Exception as e:      # never a crash loop: one notify per day, then exit 0
        if gstate.setdefault("api", {}).get("internal") != TODAY:
            gstate["api"]["internal"] = TODAY
            notify("all", "t3-watch internal error", ["%s: %s" % (e.__class__.__name__, str(e)[:200]),
                                                     "journalctl --user -u t3-watch.service"])
        log("internal error: %r" % e)
    save(g_path, gstate)
    return 1 if NOTIFY_FAILED else 0


CFG = {}
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
