#!/usr/bin/env python3
# broker.py — root-side command broker for user.sh
#
# Usage: python3 broker.py <sock_path> <uid> <gid> <cmd> [<cmd> ...]
#
# Listens on a Unix socket owned by the session user. Each connection sends
# a JSON array of args + the session's mount ns fd + stdin/stdout/stderr via
# SCM_RIGHTS. The broker enters the session's mount namespace with nsenter so
# commands see the session's overlay directly (packages installed via pacman
# are immediately visible). Returns the exit code as JSON.

import socket, os, sys, subprocess, json, signal, array, shutil, syslog, select, struct

# detach from the terminal's process group so background reads don't
# get SIGTTIN when an interactive command (e.g. pacman) reads from stdin
os.setsid()
syslog.openlog(ident="sandbox-broker", facility=syslog.LOG_AUTH)

sock_path = sys.argv[1]
uid       = int(sys.argv[2])
gid       = int(sys.argv[3])


def resolve(cmd):
    """Return the canonical real path of a command, or None if not found."""
    if os.path.isabs(cmd):
        p = cmd
    else:
        p = shutil.which(cmd)
    return os.path.realpath(p) if p else None


# resolve whitelist entries to full canonical paths at startup
whitelist = set()
for entry in sys.argv[4:]:
    path = resolve(entry)
    if path and os.path.isfile(path):
        whitelist.add(path)
    else:
        print(f"broker: warning: whitelisted command '{entry}' not found, skipping", file=sys.stderr)

if os.path.exists(sock_path):
    os.unlink(sock_path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
os.chown(sock_path, uid, gid)  # only the session user can connect
os.chmod(sock_path, 0o600)
server.listen(5)

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))


def peer_uid(conn):
    """Return the UID of the process on the other end of the socket."""
    cred = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    _, peer_uid_, _ = struct.unpack("3i", cred)
    return peer_uid_


def handle(conn):
    with conn:
        # verify the connecting process is the session user — no other UID may use the broker
        try:
            connecting_uid = peer_uid(conn)
        except OSError as e:
            syslog.syslog(syslog.LOG_WARNING, f"PEERCRED failed: {e}")
            conn.sendall(json.dumps({"error": "identity check failed"}).encode() + b"\n")
            return
        if connecting_uid != uid:
            syslog.syslog(syslog.LOG_WARNING,
                f"REJECTED uid={connecting_uid} (expected {uid})")
            conn.sendall(json.dumps({"error": "permission denied"}).encode() + b"\n")
            return

        # receive JSON command + mnt_fd + stdin/stdout/stderr FDs in one recvmsg call
        fds_arr    = array.array('i')
        cmsg_space = socket.CMSG_SPACE(4 * fds_arr.itemsize)
        try:
            msg, ancdata, _, _ = conn.recvmsg(65536, cmsg_space)
        except OSError as e:
            conn.sendall(json.dumps({"error": str(e)}).encode() + b"\n")
            return

        passed_fds = []
        for cmsg_level, cmsg_type, cmsg_data in ancdata:
            if cmsg_level == socket.SOL_SOCKET and cmsg_type == socket.SCM_RIGHTS:
                fds_arr.frombytes(cmsg_data[:4 * fds_arr.itemsize])
                passed_fds = list(fds_arr[:4])

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
        if len(passed_fds) == 4:
            mnt_fd, stdin_fd, stdout_fd, stderr_fd = passed_fds
        else:
            mnt_fd, stdin_fd, stdout_fd, stderr_fd = None, 0, 1, 2

        # nsenter the session's mount namespace (sees the full overlay), then
        # unshare a fresh PID namespace + remount /proc so pacman can read
        # /proc/self/mounts without hitting the session's PID-namespace-locked proc
        if mnt_fd is not None:
            cmd_prefix = [
                "nsenter", f"--mount=/proc/self/fd/{mnt_fd}", "--",
                "unshare", "--mount", "--pid", "--fork", "--mount-proc", "--",
            ]
            ns_fds = (mnt_fd,)
        else:
            cmd_prefix = []
            ns_fds = ()

        try:
            proc = subprocess.Popen(
                cmd_prefix + args,
                stdin=stdin_fd,
                stdout=stdout_fd,
                stderr=stderr_fd,
                start_new_session=True,
                pass_fds=ns_fds,
            )
        except FileNotFoundError:
            conn.sendall(json.dumps({"error": f"command not found: {args[0]}"}).encode() + b"\n")
            return
        except Exception as e:
            conn.sendall(json.dumps({"error": str(e)}).encode() + b"\n")
            return

        # mnt_fd no longer needed — child has its own copy via pass_fds
        for fd in ns_fds:
            try:
                os.close(fd)
            except OSError:
                pass
        passed_fds = [stdin_fd, stdout_fd, stderr_fd]

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
