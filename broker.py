#!/usr/bin/env python3
# broker.py — root-side command broker for user.sh
#
# Usage: python3 broker.py <sock_path> <uid> <gid> <cmd> [<cmd> ...]
#
# Listens on a Unix socket owned by the session user. Each connection sends
# a JSON array of args + the session's stdin/stdout/stderr via SCM_RIGHTS.
# The broker validates the command against the whitelist, runs it as root
# with the session's actual terminal, and returns the exit code as JSON.

import socket, os, sys, subprocess, json, signal, array, shutil, syslog, select

# detach from the terminal's process group so background reads don't
# get SIGTTIN when an interactive command (e.g. pacman) reads from stdin
os.setsid()
syslog.openlog(ident="sandbox-broker", facility=syslog.LOG_AUTH)

sock_path = sys.argv[1]
uid       = int(sys.argv[2])
gid       = int(sys.argv[3])
tmptfs    = sys.argv[4]


def resolve(cmd):
    """Return the canonical real path of a command, or None if not found."""
    if os.path.isabs(cmd):
        p = cmd
    else:
        p = shutil.which(cmd)
    return os.path.realpath(p) if p else None


# resolve whitelist entries to full canonical paths at startup
whitelist = set()
for entry in sys.argv[5:]:
    path = resolve(entry)
    if path and os.path.isfile(path):
        whitelist.add(path)
    else:
        print(f"broker: warning: whitelisted command '{entry}' not found, skipping", file=sys.stderr)

# overlay mount setup — runs inside a temporary mount namespace per command
# upper dirs persist in tmptfs across calls so pacman db state accumulates
OVERLAY_SETUP = f"""set -e
mount -t overlay overlay -o lowerdir=/usr,upperdir={tmptfs}/usr/upper,workdir={tmptfs}/usr/work,index=off /usr
mount -t overlay overlay -o lowerdir=/etc,upperdir={tmptfs}/etc/upper,workdir={tmptfs}/etc/work,index=off /etc
mount -t overlay overlay -o lowerdir=/var/lib/pacman,upperdir={tmptfs}/pacman/upper,workdir={tmptfs}/pacman/work,index=off /var/lib/pacman
mount -t overlay overlay -o lowerdir=/var/cache/pacman,upperdir={tmptfs}/cache/upper,workdir={tmptfs}/cache/work,index=off /var/cache/pacman
exec "$@"
"""

if os.path.exists(sock_path):
    os.unlink(sock_path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
os.chown(sock_path, uid, gid)  # only the session user can connect
os.chmod(sock_path, 0o600)
server.listen(5)

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))


def handle(conn):
    with conn:
        # receive JSON command + stdin/stdout/stderr FDs in one recvmsg call
        fds_arr    = array.array('i')
        cmsg_space = socket.CMSG_SPACE(3 * fds_arr.itemsize)
        try:
            msg, ancdata, _, _ = conn.recvmsg(65536, cmsg_space)
        except OSError as e:
            conn.sendall(json.dumps({"error": str(e)}).encode() + b"\n")
            return

        passed_fds = []
        for cmsg_level, cmsg_type, cmsg_data in ancdata:
            if cmsg_level == socket.SOL_SOCKET and cmsg_type == socket.SCM_RIGHTS:
                fds_arr.frombytes(cmsg_data[:3 * fds_arr.itemsize])
                passed_fds = list(fds_arr[:3])

        try:
            args = json.loads(msg.decode().strip())
        except json.JSONDecodeError as e:
            conn.sendall(json.dumps({"error": f"bad request: {e}"}).encode() + b"\n")
            return

        if not isinstance(args, list) or not args:
            conn.sendall(json.dumps({"error": "request must be a non-empty JSON array"}).encode() + b"\n")
            return

        cmd_path = resolve(str(args[0]))
        if not cmd_path or cmd_path not in whitelist:
            syslog.syslog(syslog.LOG_WARNING,
                f"DENIED  uid={uid} cmd={args}")
            conn.sendall(json.dumps({"error": f"'{args[0]}' is not whitelisted"}).encode() + b"\n")
            return

        syslog.syslog(syslog.LOG_INFO,
            f"ALLOWED uid={uid} cmd={args}")

        # run with the session's actual stdin/stdout/stderr so interactive prompts work
        if len(passed_fds) == 3:
            stdin_fd, stdout_fd, stderr_fd = passed_fds
        else:
            stdin_fd, stdout_fd, stderr_fd = 0, 1, 2

        try:
            proc = subprocess.Popen(
                ["unshare", "--mount", "bash", "-c", OVERLAY_SETUP, "--"] + args,
                stdin=stdin_fd,
                stdout=stdout_fd,
                stderr=stderr_fd,
                start_new_session=True,
            )
        except FileNotFoundError:
            conn.sendall(json.dumps({"error": f"command not found: {args[0]}"}).encode() + b"\n")
            return
        except Exception as e:
            conn.sendall(json.dumps({"error": str(e)}).encode() + b"\n")
            return

        # Poll for client disconnect while the subprocess runs.
        # run-as-root keeps the connection open (no shutdown), so any
        # readability event here means the client closed (Ctrl+C).
        try:
            while proc.poll() is None:
                r, _, _ = select.select([conn], [], [], 0.2)
                if r:
                    data = conn.recv(1)
                    if not data:
                        try:
                            os.killpg(proc.pid, signal.SIGKILL)
                        except OSError:
                            proc.kill()
                        proc.wait()
                        syslog.syslog(syslog.LOG_INFO,
                            f"KILLED  uid={uid} cmd={args} (client disconnected)")
                        return
        except OSError:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                proc.kill()
            proc.wait()
            return

        returncode = proc.wait()
        syslog.syslog(syslog.LOG_INFO,
            f"EXITED  uid={uid} cmd={args} exit={returncode}")
        try:
            conn.sendall(json.dumps({"exit": returncode}).encode() + b"\n")
        except OSError:
            pass  # client already gone
        finally:
            for fd in passed_fds:
                try:
                    os.close(fd)
                except OSError:
                    pass


while True:
    try:
        conn, _ = server.accept()
        handle(conn)
    except OSError:
        break
