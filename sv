#!/usr/bin/env python3
# sv — control script for supervise.py services
#
# Usage: sv <start|stop|restart|status> <name> [<name>...]
#
# Reads SVDIR from environment (set by user.sh).

import os, sys, signal, time
from pathlib import Path

def usage():
    print("usage: sv <start|stop|restart|status> <name> [<name>...]", file=sys.stderr)
    sys.exit(1)

if len(sys.argv) < 3:
    usage()

cmd   = sys.argv[1]
names = sys.argv[2:]

svdir_env = os.environ.get("SVDIR")
if not svdir_env:
    print("sv: SVDIR not set", file=sys.stderr)
    sys.exit(1)

svdir = Path(svdir_env)


def get_pid(name: str) -> int | None:
    pid_f = svdir / name / "supervise" / "pid"
    try:
        t = pid_f.read_text().strip()
        return int(t) if t else None
    except (FileNotFoundError, ValueError):
        return None


def is_running(name: str) -> bool:
    pid = get_pid(name)
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def svc_dir(name: str) -> Path:
    d = svdir / name
    if not d.is_dir():
        print(f"sv: {name}: service not found in {svdir}", file=sys.stderr)
        sys.exit(1)
    return d


for name in names:
    d = svc_dir(name)
    down = d / "down"

    if cmd == "start":
        down.unlink(missing_ok=True)
        print(f"{name}: starting (supervisor will respawn within 2s)")

    elif cmd == "stop":
        down.touch()
        pid = get_pid(name)
        if pid:
            try:
                os.killpg(pid, signal.SIGTERM)
                print(f"{name}: stopped (pid {pid})")
            except OSError:
                print(f"{name}: already stopped")
        else:
            print(f"{name}: already stopped")

    elif cmd == "restart":
        down.unlink(missing_ok=True)
        pid = get_pid(name)
        if pid:
            try:
                os.killpg(pid, signal.SIGTERM)
                print(f"{name}: restarting (pid {pid})")
            except OSError:
                print(f"{name}: starting fresh")
        else:
            print(f"{name}: starting")

    elif cmd == "status":
        if down.exists():
            pid = get_pid(name)
            state = f"stopped (pid {pid} orphaned?)" if pid and is_running(name) else "stopped"
        elif is_running(name):
            state = f"running (pid {get_pid(name)})"
        else:
            state = "down (waiting for supervisor)"
        print(f"{name}: {state}")

    else:
        usage()
