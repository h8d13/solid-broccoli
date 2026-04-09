#!/bin/env bash
# Spawn a sandboxed temporary session with an optional root command broker.
#
# Usage: sudo ./user.sh [options] [-- program [args...]]
#
# Options:
#   --mem   <size>       virtual memory limit e.g. 512M (default: 512M)
#   --files <n>          max open file descriptors (default: 1024)
#   --bind  <src>:<dst>  bind-mount src read-only into session home at dst
#   --no-net             isolated loopback-only network namespace
#   --allow <cmd>        whitelist a command the session can run as root (repeatable)
#   --                   end of options; everything after is the program + args

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

# ---------- defaults ----------
MEM_LIMIT="512M"
MAX_FILES=1024
BIND_MOUNTS=()
USE_NET_NS=0
WHITELIST=()

# ---------- parse options ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mem)    MEM_LIMIT="$2";      shift 2 ;;
        --files)  MAX_FILES="$2";      shift 2 ;;
        --bind)   BIND_MOUNTS+=("$2"); shift 2 ;;
        --no-net) USE_NET_NS=1;        shift   ;;
        --allow)  WHITELIST+=("$2");   shift 2 ;;
        --)       shift; break ;;
        *)        break ;;
    esac
done

# ---------- temp user + dirs ----------
TMPUSER="tmpuser_$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
TMPHOME="$(mktemp -d /tmp/home_XXXXXX)"   # overlay merged mount point
TMPTFS="$(mktemp -d /tmp/tfs_XXXXXX)"     # tmpfs backing upper/work (RAM only)
BROKER_SOCK="$TMPHOME/.broker.sock"
BROKER_PID=""
BROKER_SCRIPT=""

cleanup() {
    [[ -n "$BROKER_PID" ]] && kill "$BROKER_PID" 2>/dev/null || true
    [[ -n "$BROKER_SCRIPT" ]] && rm -f "$BROKER_SCRIPT"
    for bm in "${BIND_MOUNTS[@]+"${BIND_MOUNTS[@]}"}"; do
        dst="${bm#*:}"
        umount "$TMPHOME/$dst" 2>/dev/null || true
    done
    userdel "$TMPUSER" 2>/dev/null || true
    umount "$TMPHOME"  2>/dev/null || true
    umount "$TMPTFS"   2>/dev/null || true
    rm -rf "$TMPHOME" "$TMPTFS"
}
trap cleanup EXIT

# ---------- overlay home (RAM-only writes) ----------
mount -t tmpfs tmpfs "$TMPTFS"
mkdir "$TMPTFS/upper" "$TMPTFS/work"

mount -t overlay overlay \
    -o lowerdir=/etc/skel,upperdir="$TMPTFS/upper",workdir="$TMPTFS/work" \
    "$TMPHOME"

# ---------- create user (no wheel, no sudo) ----------
useradd \
    --home-dir "$TMPHOME" \
    --no-create-home \
    --user-group \
    --no-log-init \
    --shell /bin/bash \
    "$TMPUSER"

chown "${TMPUSER}:${TMPUSER}" "$TMPHOME"
chmod 700 "$TMPHOME"

TMPUID=$(id -u "$TMPUSER")
TMPGID=$(id -g "$TMPUSER")

# ---------- read-only bind mounts ----------
for bm in "${BIND_MOUNTS[@]+"${BIND_MOUNTS[@]}"}"; do
    src="${bm%%:*}"
    dst="${bm#*:}"
    mkdir -p "$TMPHOME/$dst"
    mount --bind "$src" "$TMPHOME/$dst"
    mount -o remount,ro,bind "$TMPHOME/$dst"
    echo ">> bind (ro): $src -> \$HOME/$dst"
done

# ---------- broker ----------
if [[ ${#WHITELIST[@]} -gt 0 ]]; then

    # write the broker to a temp file — it's deleted after the process starts
    BROKER_SCRIPT="$(mktemp /tmp/broker_XXXXXX.py)"

    cat > "$BROKER_SCRIPT" << 'PYEOF'
import socket, os, sys, subprocess, json, signal

sock_path = sys.argv[1]
uid       = int(sys.argv[2])
gid       = int(sys.argv[3])
whitelist = set(sys.argv[4:])

if os.path.exists(sock_path):
    os.unlink(sock_path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
os.chown(sock_path, uid, gid)   # only the temp user can connect
os.chmod(sock_path, 0o600)
server.listen(5)

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

def handle(conn):
    with conn:
        raw = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            raw += chunk
            if b"\n" in raw:
                break

        try:
            args = json.loads(raw.decode())
        except json.JSONDecodeError as e:
            conn.sendall(json.dumps({"error": f"bad request: {e}"}).encode() + b"\n")
            return

        if not isinstance(args, list) or not args:
            conn.sendall(json.dumps({"error": "request must be a non-empty JSON array"}).encode() + b"\n")
            return

        base = os.path.basename(str(args[0]))
        if base not in whitelist:
            conn.sendall(json.dumps({"error": f"'{base}' is not whitelisted"}).encode() + b"\n")
            return

        try:
            result = subprocess.run(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            conn.sendall(json.dumps({
                "stdout": result.stdout.decode(errors="replace"),
                "exit":   result.returncode,
            }).encode() + b"\n")
        except FileNotFoundError:
            conn.sendall(json.dumps({"error": f"command not found: {args[0]}"}).encode() + b"\n")
        except Exception as e:
            conn.sendall(json.dumps({"error": str(e)}).encode() + b"\n")

while True:
    try:
        conn, _ = server.accept()
        handle(conn)
    except OSError:
        break
PYEOF

    python3 "$BROKER_SCRIPT" "$BROKER_SOCK" "$TMPUID" "$TMPGID" "${WHITELIST[@]}" &
    BROKER_PID=$!

    # wait for socket to appear (up to 2s)
    for i in {1..20}; do
        [[ -S "$BROKER_SOCK" ]] && break
        sleep 0.1
    done
    [[ -S "$BROKER_SOCK" ]] || { echo "error: broker failed to start" >&2; exit 1; }

    # write client into session — $BROKER_SOCK expands here (root context, correct path)
    mkdir -p "$TMPHOME/.bin"
    cat > "$TMPHOME/.bin/run-as-root" << CLIENTEOF
#!/usr/bin/env python3
import socket, os, sys, json

SOCK = "$BROKER_SOCK"

if len(sys.argv) < 2:
    print("usage: run-as-root <command> [args...]", file=sys.stderr)
    sys.exit(1)

s = socket.socket(socket.AF_UNIX)
try:
    s.connect(SOCK)
except OSError as e:
    print(f"run-as-root: could not connect to broker: {e}", file=sys.stderr)
    sys.exit(1)

s.sendall(json.dumps(sys.argv[1:]).encode() + b"\n")
s.shutdown(socket.SHUT_WR)

raw = b""
while chunk := s.recv(4096):
    raw += chunk

try:
    resp = json.loads(raw.decode())
except json.JSONDecodeError:
    print("run-as-root: malformed response from broker", file=sys.stderr)
    sys.exit(1)

if "error" in resp:
    print(f"run-as-root: {resp['error']}", file=sys.stderr)
    sys.exit(1)

print(resp.get("stdout", ""), end="")
sys.exit(resp.get("exit", 0))
CLIENTEOF

    chmod +x "$TMPHOME/.bin/run-as-root"
    chown -R "${TMPUSER}:${TMPUSER}" "$TMPHOME/.bin"

    echo ">> broker  : running (pid: $BROKER_PID)"
    echo ">> allowed : ${WHITELIST[*]}"
fi

# ---------- resource limits ----------
MEM_KB=$(( ${MEM_LIMIT%M} * 1024 ))
ulimit -v "$MEM_KB"
ulimit -n "$MAX_FILES"

# ---------- namespace wrapper ----------
UNSHARE=(unshare --fork --pid --mount-proc)
[[ $USE_NET_NS -eq 1 ]] && UNSHARE+=(--net)

# ---------- sandboxed command ----------
CMD=(
    setpriv
        --reuid="$TMPUID"
        --regid="$TMPGID"
        --init-groups
        --inh-caps=-all
        --bounding-set=-all
        --no-new-privs
        --
    env
        HOME="$TMPHOME"
        USER="$TMPUSER"
        LOGNAME="$TMPUSER"
        PATH="$TMPHOME/.bin:/usr/local/bin:/usr/bin:/bin"
)

if [[ $# -gt 0 ]]; then
    CMD+=("$@")
else
    CMD+=(/bin/bash --login)
fi

echo ">> session : $TMPUSER"
echo ">> home    : $TMPHOME (overlay, RAM-backed)"
echo ">> mem     : ${MEM_LIMIT} virt  |  files: ${MAX_FILES}"
echo ">> net     : $([ $USE_NET_NS -eq 1 ] && echo 'isolated (loopback only)' || echo 'host')"
echo ""

"${UNSHARE[@]}" "${CMD[@]}"

echo ""
echo ">> session ended — user, home, and all writes cleaned up"
