#!/usr/bin/env python3
"""open-items.py - the open-items drop: every session writes its "for later" items to one file, the
coordinator files them on the board, nothing lives in prose only.

Consumers: hooks/session-role.sh (`count`, coordinator branch; the write-now line names `add`),
  skills/wrap/SKILL.md step 5 (`add`, `add --done`, `add --wrapped`), skills/morning-ritual/SKILL.md
  steps 3 and 4 (`list`), the coordinator by hand (`list`, `done`), tests/open-items.sh.

Usage:
  open-items.py add --owner user|coordinator|lane|external:<who> "<what> · next: <step> · src: <who, when> · <path>"
  open-items.py add --done W<n> "<evidence: commit, live, the user's answer>"
  open-items.py add --wrapped          the wrap's last line, also when nothing is open
  open-items.py list                   every item not on the board yet, plus sessions that died unwrapped
  open-items.py count                  one banner line, or nothing when there is nothing to file
  open-items.py done <file>            delete a drop file: refused unless every open key is on the
                                       board AND the session is gone

Drop dir: <config dir>/open-items/ (config dir = $CLAUDE_CONFIG_DIR or ~/.claude), one file per
session, <sid8>-session-notes.md. Board: the `board` key of <config dir>/middle-management.json, read
through symlinks. "Filed" = the item's whole key <sid8>-W<n> appears anywhere in the board file.
Own session: $CLAUDE_CODE_SESSION_ID, else the registry entry of the nearest ancestor process (the
wrap skill's step 0 walk). Liveness is peer-state.py's is_live, with its PID-reuse guard.
"""
import fcntl, functools, glob, importlib.util, json, os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
DROP = os.path.join(CFG, "open-items")
SUFFIX = "-session-notes.md"
ITEM = re.compile(r"^- W(\d+) · owner: ")
DONE = re.compile(r"^- W(\d+) done\b")
WRAPPED = re.compile(r"^- WRAPPED\b")
# Whole key only: b42d7700-W1 must not read as filed because b42d7700-W10 is on the board.
BOARD_KEY = re.compile(r"(?<![\w-])(\w{8}-W\d+)(?!\w)")
OWNER = re.compile(r"^(user|coordinator|lane|external:\S+)$")


@functools.lru_cache(None)
def peer_state():
    spec = importlib.util.spec_from_file_location("peer_state", os.path.join(HERE, "peer-state.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def board():
    """(path or "", text or None). None = unset or unreadable: nothing counts as filed."""
    try:
        p = json.load(open(os.path.join(CFG, "middle-management.json"), encoding="utf-8")).get("board")
    except (OSError, ValueError, AttributeError):
        p = None
    if not (isinstance(p, str) and p):
        return "", None
    p = os.path.expanduser(p)
    try:
        return p, open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return p, None


def parse(path):
    """(lines, open {n: line}, max n, wrapped). Wrapped = a WRAPPED line after the last item."""
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    items, done, top, wrapped = {}, set(), 0, False
    for ln in lines:
        m = ITEM.match(ln) or DONE.match(ln)
        if m:
            top = max(top, int(m.group(1)))
        if ITEM.match(ln):
            items[int(m.group(1))] = ln
            wrapped = False
        elif DONE.match(ln):
            done.add(int(m.group(1)))
        elif WRAPPED.match(ln):
            wrapped = True
    return lines, {n: l for n, l in items.items() if n not in done}, top, wrapped


def sid8_of(path):
    return os.path.basename(path)[:-len(SUFFIX)]


def unfiled(path, text):
    s8, (_, opn, _, _) = sid8_of(path), parse(path)
    keys = set(BOARD_KEY.findall(text or ""))
    return [(n, l) for n, l in sorted(opn.items()) if "%s-W%d" % (s8, n) not in keys]


def is_gone(s8):
    ps = peer_state()
    reg, _ = ps.registry()
    return not any(ps.is_live(e.get("pid"), e.get("procStart"))
                   for sid, e in reg.items() if sid.startswith(s8))


def own_session():
    """(sessionId, registry entry or {})."""
    reg, _ = peer_state().registry()
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if sid:
        return sid, reg.get(sid, {})
    p = os.getppid()
    for _ in range(12):
        f = os.path.join(CFG, "sessions", "%d.json" % p)
        if os.path.isfile(f):
            e = json.load(open(f, encoding="utf-8"))
            return e.get("sessionId", ""), e
        try:
            p = int(open("/proc/%d/stat" % p).read().rsplit(") ", 1)[-1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return "", {}


def add(argv):
    sid, entry = own_session()
    if not sid:
        sys.exit("open-items: cannot resolve this session's id (no $CLAUDE_CODE_SESSION_ID, no registry entry up the process tree)")
    os.makedirs(DROP, exist_ok=True)
    path = os.path.join(DROP, sid[:8] + SUFFIX)
    with open(path, "a+", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)   # parallel Bash calls of one session must not share a W<n>
        fh.seek(0)
        if not fh.read(1):
            fh.write("# %s · %s · %s\n" % (entry.get("name") or "unnamed", sid,
                                            entry.get("cwd") or os.getcwd()))
            fh.flush()
        _, opn, top, _ = parse(path)
        if argv[:1] == ["--wrapped"]:
            line = "- WRAPPED %s · %d open" % (time.strftime("%H:%M"), len(opn))
        elif argv[:1] == ["--done"] and len(argv) == 3:
            n = int(argv[1].lstrip("Ww")) if argv[1].lstrip("Ww").isdigit() else 0
            if n not in opn:
                sys.exit("open-items: W%s is not an open item in %s" % (argv[1].lstrip("Ww"), path))
            line = "- W%d done · %s" % (n, argv[2])
        elif argv[:1] == ["--owner"] and len(argv) == 3 and OWNER.match(argv[1]) and argv[2].strip():
            # Next free number from the file AND the board: a file deleted after its session died
            # comes back on resume (same sessionId), and W1 would then read as already filed.
            _, text = board()
            n = 1 + max([top] + [int(k.split("-W")[1]) for k in BOARD_KEY.findall(text or "")
                                 if k.startswith(sid[:8] + "-")])
            line = "- W%d · owner: %s · %s" % (n, argv[1], argv[2].strip())
            print("%s-W%d" % (sid[:8], n))
        else:
            sys.exit(__doc__.split("\n\n")[2])
        fh.write(line + "\n")
    print(path)


def files():
    return sorted(glob.glob(os.path.join(DROP, "*" + SUFFIX)))


def not_configured(bpath, n):
    if not bpath:
        return "board not configured (/middle-management-setup), %d items cannot be filed." % n
    return "board %s is not readable, %d items cannot be filed." % (bpath, n)


def count():
    bpath, text = board()
    per = [len(unfiled(f, text)) for f in files()]
    n, m = sum(per), sum(1 for c in per if c)
    if not n:
        return
    if text is None:
        print("Open-items inbox: " + not_configured(bpath, n))
    else:
        print('Open-items inbox: %d unfiled in %d file%s (python3 "%s" list); put each key on the board,'
              " then open-items.py done <file> (middle-management skill, \"Open items\")."
              % (n, m, "s" if m > 1 else "", os.path.abspath(__file__)))


def list_():
    bpath, text = board()
    if text is None:
        print("Open-items inbox: " + not_configured(bpath, sum(len(unfiled(f, None)) for f in files())))
    for f in files():
        todo, gone = unfiled(f, text), is_gone(sid8_of(f))
        lines, _, _, wrapped = parse(f)
        if gone and not wrapped:
            state = "died unwrapped → backfill (resume it and run the wrap)"
        elif gone and not todo:
            state = "all filed, session gone → open-items.py done %s" % f
        elif todo:
            state = "live" if not gone else "wrapped, session gone"
        else:
            continue
        print("%s · %s" % (f, state))
        if lines and lines[0].startswith("# "):
            print("  " + lines[0])
        for n, l in todo:
            print("  %s-W%d · %s" % (sid8_of(f), n, l.split(" · ", 1)[1]))


def done(arg):
    f = arg if os.path.isfile(arg) else os.path.join(DROP, os.path.basename(arg))
    if not (os.path.isfile(f) and f.endswith(SUFFIX)):
        sys.exit("open-items: no drop file %s" % arg)
    bpath, text = board()
    if text is None:
        sys.exit("open-items: refused, " + not_configured(bpath, len(unfiled(f, None))))
    todo = unfiled(f, text)
    if todo:
        sys.exit("open-items: refused, not on the board yet: "
                 + ", ".join("%s-W%d" % (sid8_of(f), n) for n, _ in todo))
    if not is_gone(sid8_of(f)):
        sys.exit("open-items: refused, session %s is still live (a wrapped tab gets reused); its file stays"
                 % sid8_of(f))
    os.unlink(f)
    print("deleted " + f)


def main(argv):
    cmd = argv[:1]
    if cmd == ["add"]:
        add(argv[1:])
    elif cmd == ["list"] and len(argv) == 1:
        list_()
    elif cmd == ["count"] and len(argv) == 1:
        count()
    elif cmd == ["done"] and len(argv) == 2:
        done(argv[1])
    else:
        sys.exit(__doc__.split("\n\n")[2])


if __name__ == "__main__":
    main(sys.argv[1:])
