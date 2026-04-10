#!/usr/bin/env python3
# supervise.py — tiny process supervisor for user.sh sessions
#
# Usage: supervise.py <svdir>
#
# For each subdir in svdir containing an executable 'run' script:
#   - starts the service automatically (unless a 'down' file exists)
#   - restarts on exit (1s cooldown) unless 'down' exists
#   - writes the child PID to supervise/pid
#
# Control is filesystem-based (daemontools-style) — use the 'sv' script:
#   sv start <name>    remove the 'down' file → supervisor respawns
#   sv stop  <name>    create 'down' file + SIGTERM the process
#   sv status <name>   print running/stopped state

import os, sys, time, signal, subprocess, threading
from pathlib import Path

RESTART_DELAY = 1.0

svdir = Path(sys.argv[1])

# name -> {run, proc}
services: dict[str, dict] = {}
lock = threading.Lock()


def supervise_dir(name: str, svc_dir: Path):
    run   = svc_dir / "run"
    down  = svc_dir / "down"
    spdir = svc_dir / "supervise"
    spdir.mkdir(exist_ok=True)
    pid_f = spdir / "pid"

    while True:
        if down.exists():
            pid_f.write_text("")
            time.sleep(1.0)
            continue

        try:
            proc = subprocess.Popen([str(run)], start_new_session=True)
        except Exception as e:
            print(f"supervise: {name}: failed to start: {e}", file=sys.stderr, flush=True)
            time.sleep(RESTART_DELAY)
            continue

        pid_f.write_text(str(proc.pid))
        print(f"supervise: {name}: started (pid {proc.pid})", flush=True)

        with lock:
            services[name]["proc"] = proc

        proc.wait()

        pid_f.write_text("")
        if not down.exists():
            print(f"supervise: {name}: exited ({proc.returncode}), "
                  f"restarting in {RESTART_DELAY}s", flush=True)
            time.sleep(RESTART_DELAY)


def scan_loop():
    seen = set()
    while True:
        if svdir.is_dir():
            for entry in svdir.iterdir():
                run = entry / "run"
                if entry.is_dir() and run.is_file() and os.access(run, os.X_OK):
                    if entry.name not in seen:
                        seen.add(entry.name)
                        with lock:
                            services[entry.name] = {"proc": None}
                        t = threading.Thread(
                            target=supervise_dir,
                            args=(entry.name, entry),
                            daemon=True,
                        )
                        t.start()
        time.sleep(2.0)


def cleanup(*_):
    with lock:
        for svc in services.values():
            proc = svc.get("proc")
            if proc and proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except OSError:
                    proc.terminate()
    sys.exit(0)


signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT,  cleanup)

scan_loop()
