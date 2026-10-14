#!/usr/bin/env python3
"""scope.py - which coordinator scope a directory belongs to (README, "Scopes").

Consumers: hooks/session-role.sh (`of`, `filter`), scripts/orchestrator.sh (`of`),
  scripts/orch-heartbeat.sh and its installed copy (`list`, `filter`), scripts/peer-state.py
  (`--scope`, imported), scripts/open-items.py (imported), commands/middle-management-setup.md
  (`of`, step 3), tests/run.sh, tests/peer-state.sh, tests/open-items.sh, tests/heartbeat.sh.
  The shell callers run it ONLY when the config has a non-empty "scopes" array, so a machine
  without the key never starts it.

Usage:
  scope.py of PATH     one line: name<TAB>state dir<TAB>board (the board may be empty, it is last)
  scope.py list        the same line for every named scope; nothing when there is none
  scope.py filter NAME stdin "<path><TAB><rest>" lines -> <rest> of every line whose path is in NAME
  exit 3 = git failed or timed out on a path inside a linked worktree: the scope is unknown and
  every caller fails closed (no banner, no claim, the holder keeps its seat), never "default"

Rules: "scopes" in <config dir>/middle-management.json is a list of {name, root, board}. A path
belongs to the named scope with the longest root that is the path or one of its parents (whole
segments, realpath on both sides). A directory inside a linked git worktree that matches no root
is tried again as the same subpath of its main checkout. Everything else, and an empty or relative
path, is scope "default". State dir: default = <config dir>/state, a named scope =
<config dir>/state/scopes/<name>. Board: default = the top-level "board", named = its own.
Config dir = $CLAUDE_CONFIG_DIR, else ~/.claude.
"""
import json, os, re, subprocess, sys

CFG = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")   # fullmatch() ONLY, the rule of config-check.sh


def config():
    """The config as a dict; {} when it is missing, unparseable or not an object. Never raises."""
    try:
        c = json.load(open(os.path.join(CFG, "middle-management.json"), encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return c if isinstance(c, dict) else {}


def scopes(c=None):
    """The well-formed named scopes, roots as realpaths.
    ponytail: repeats the name and root tests of config-check.sh validate on purpose. The name
    becomes a directory under state/scopes/ and a root of / would swallow every session, so both
    are refused here even when the config is invalid and nobody ran setup (trust boundary)."""
    c = config() if c is None else c
    out, ls = [], c.get("scopes")
    for e in ls if isinstance(ls, list) else []:
        if not isinstance(e, dict):
            continue
        n, r, b = e.get("name"), e.get("root"), e.get("board")
        if not (isinstance(n, str) and NAME.fullmatch(n) and n != "default"):
            continue
        if not (isinstance(r, str) and r.startswith("/")) or os.path.realpath(r) == "/":
            continue
        out.append({"name": n, "root": os.path.realpath(r), "board": b if isinstance(b, str) else ""})
    return out


def _longest(path, ss):
    best = None
    for s in ss:
        if (path == s["root"] or path.startswith(s["root"] + "/")) \
                and (best is None or len(s["root"]) > len(best["root"])):
            best = s
    return best and best["name"]


class Unknown(Exception):
    """git could not answer for a path that looks like a linked worktree: never guess "default"."""


def _linked(path):
    """True when the nearest .git above path is a FILE, the mark of a linked worktree."""
    while True:
        g = os.path.join(path, ".git")
        if os.path.exists(g):
            return os.path.isfile(g)
        if os.path.dirname(path) == path:
            return False
        path = os.path.dirname(path)


def _in_main(path):
    """The same subpath of the main checkout when path is inside a linked git worktree, else None.
    Fails closed: when git errors or times out on a path whose .git is a file, raise Unknown."""
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--path-format=absolute",
                            "--git-common-dir", "--show-toplevel"],
                           capture_output=True, text=True, timeout=2)
        common, top = r.stdout.splitlines() if r.returncode == 0 else (None, None)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        common = top = None
    if not (common and top):
        if _linked(path):
            raise Unknown(path)
        return None
    if not common.endswith("/.git"):
        return None
    return os.path.normpath(os.path.join(os.path.dirname(common), os.path.relpath(path, top)))


def of(path, ss=None):
    ss = scopes() if ss is None else ss
    if not (ss and isinstance(path, str) and path.startswith("/")):
        return "default"
    p = os.path.realpath(path)
    n = _longest(p, ss)
    if n is None and os.path.isdir(p):
        m = _in_main(p)
        n = m and _longest(m, ss)
    return n or "default"


def info(name, c=None):
    """(state dir, board) of a scope; ValueError for a name that is not configured."""
    c = config() if c is None else c
    if name == "default":
        b = c.get("board")
        return os.path.join(CFG, "state"), b if isinstance(b, str) else ""
    for s in scopes(c):
        if s["name"] == name:
            return os.path.join(CFG, "state", "scopes", name), s["board"]
    raise ValueError("no scope %r" % name)


def main(argv):
    c = config()      # ponytail: one config read per run
    ss = scopes(c)

    def line(n):
        return "%s\t%s\t%s" % ((n,) + info(n, c))
    try:
        if argv[:1] == ["of"] and len(argv) == 2:
            print(line(of(argv[1], ss)))
        elif argv == ["list"]:
            for s in ss:
                print(line(s["name"]))
        elif argv[:1] == ["filter"] and len(argv) == 2:
            memo = {}     # one git call per distinct path, not per line
            for ln in sys.stdin.read().splitlines():
                path, tab, rest = ln.partition("\t")
                if tab:
                    if path not in memo:
                        memo[path] = of(path, ss)
                    if memo[path] == argv[1]:
                        print(rest)
        else:
            print(__doc__.split("\n\n")[2], file=sys.stderr)
            return 2
    except Unknown as e:
        print("scope.py: git could not resolve the worktree %s, scope unknown" % e, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
