#!/usr/bin/env python3
# middle-management plugin — the heartbeat's sender: ONE cross-session peer message to a live
# Claude Code session, addressed by sessionId.
# Consumers: orch-heartbeat.sh (beside this file); manual use when a session must be
#   re-triggered without spending a model turn. Nothing else calls it.
# Writes the CLI's own peer-message frames straight to the session's Unix socket: no `claude`
# process, no model call, no quota — the transport must not depend on the resource an API usage
# limit exhausts. The frame shape is bound to the CLI version: peerProtocol != 1 refuses, never
# guesses.
#
# The envelope declares the RECEIVER's permission mode (see target_from_mode): a session
# running in bypassPermissions holds every peer message that does not declare the same mode
# — parked for approval, never queued, and no log line anywhere.
#
# Usage:  poke-session.py <sessionId> <file with the message body>
# Exit:   0 handed to the socket (NOT an acknowledgement — the CLI sends none by design,
#           and the receiver's inbound gate may still hold it: verify, do not assume)
#         2 no live registry entry for that sessionId
#         3 socket absent or refusing (the session is gone)
#         4 unsupported peer protocol (the CLI changed its frame shape — do not guess)
# Sender name: $POKE_FROM_NAME (default "heartbeat"), shown to the receiving session.
# Mode:   $POKE_FROM_MODE=bypass|prompting|none overrides the mirrored mode (debug / retry).
# Registry: $OHB_REG, else <config dir>/sessions (config dir = $CLAUDE_CONFIG_DIR or ~/.claude).
import hashlib, json, os, socket, sys, uuid

if len(sys.argv) != 3:
    sys.exit(__doc__ or "usage: poke-session.py <sessionId> <body-file>")
sid, body = sys.argv[1], open(sys.argv[2], encoding="utf-8").read().strip()
cfg_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
reg = os.environ.get("OHB_REG") or os.path.join(cfg_dir, "sessions")

entry = next((d for d in (json.load(open(os.path.join(reg, f), encoding="utf-8"))
                          for f in os.listdir(reg) if f.endswith(".json"))
              if d.get("sessionId") == sid), None)
if entry is None:
    print(f"poke-session: no live session with id {sid}", file=sys.stderr)
    sys.exit(2)
if entry.get("peerProtocol") != 1:
    print(f"poke-session: peerProtocol {entry.get('peerProtocol')} != 1 — frame shape unknown, refusing",
          file=sys.stderr)
    sys.exit(4)

sock_path, pid = entry["messagingSocketPath"], entry["pid"]
# The peer token lives beside the registry entry, named by the socket path's digest (mode 0600).
# It is a secret: read it, never print it, never log it.
key = os.path.join(reg, "%d.%s.key" % (pid, hashlib.sha256(sock_path.encode()).hexdigest()))
token = json.load(open(key, encoding="utf-8"))["peerToken"]

# `from` is omitted on purpose: without a reply address the receiver skips the delivery receipt it
# would otherwise try to send back to a socket that does not exist.
# The sender name the receiving session sees. Default "heartbeat"; another caller on the same
# transport (a forwarder for your user's off-keyboard replies, say) sets POKE_FROM_NAME so the
# receiver can tell who is poking. Sanitised: it lands inside an attribute value.
sender = "".join(c for c in os.environ.get("POKE_FROM_NAME", "heartbeat")
                 if c.isalnum() or c in "-_") or "heartbeat"


def target_from_mode(target_pid):
    """"bypass" or "prompting" — the permission mode the RECEIVER runs in.

    The CLI gates inbound peer messages by permission mode: a session in bypassPermissions
    HOLDS every peer message that does not declare the same mode (parked for the user's
    approval, never queued, no log line, and the "held" receipt goes to a reply address we
    do not have). A session that prompts accepts an undeclared sender and holds a "bypass"
    one. So the envelope mirrors the target instead of asserting something fixed.
    Read from the target's own argv, with the config dir's settings.json as the fallback;
    both are what the CLI itself used at its start.
    ponytail: /proc is Linux-only — elsewhere the argv read fails and the settings default
    decides, which is the same answer for every session started without --permission-mode.
    """
    override = os.environ.get("POKE_FROM_MODE")
    if override in ("bypass", "prompting", "none"):
        return override
    mode = None
    try:
        argv = open("/proc/%d/cmdline" % target_pid, "rb").read().decode("utf-8", "replace").split("\0")
    except OSError:
        argv = []
    for i, a in enumerate(argv):
        if a == "--permission-mode" and i + 1 < len(argv):
            mode = argv[i + 1]
        elif a.startswith("--permission-mode="):
            mode = a.split("=", 1)[1]
    if mode is None:
        try:
            settings = json.load(open(os.path.join(cfg_dir, "settings.json"), encoding="utf-8"))
            mode = settings.get("permissions", {}).get("defaultMode")
        except (OSError, ValueError):
            mode = None
    return "bypass" if mode == "bypassPermissions" else "prompting"


# Attribute ORDER is load-bearing: the receiver re-serialises what it parsed and drops the
# envelope's metadata if the string differs (from, from-session, hop-chain, from-name, from-mode).
from_mode = target_from_mode(pid)
attrs = f'from-name="{sender}"' + (f' from-mode="{from_mode}"' if from_mode != "none" else "")
envelope = f'<cross-session-message {attrs}>\n{body}\n</cross-session-message>'
frame = {"type": "user", "session_id": sid, "uuid": str(uuid.uuid4()),
         "priority": "next", "message": {"content": envelope}}

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect(sock_path)
except OSError as e:
    print(f"poke-session: socket {sock_path} not reachable ({e.strerror})", file=sys.stderr)
    sys.exit(3)
try:
    s.sendall((json.dumps({"type": "auth", "token": token}) + "\n").encode())
    s.sendall((json.dumps(frame) + "\n").encode())
finally:
    s.close()
print(f"poke-session: handed to {entry.get('name', '?')} ({sid[:8]})")
