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

cleanup() {
    echo ""
    echo ">> session ended — user, home, and all writes cleaned up"
    [[ -n "$BROKER_PID" ]] && kill "$BROKER_PID" 2>/dev/null || true
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

    BROKER_SCRIPT="$(dirname "$0")/broker.py"
    [[ -f "$BROKER_SCRIPT" ]] || { echo "error: broker.py not found next to user.sh" >&2; exit 1; }

    python3 "$BROKER_SCRIPT" "$BROKER_SOCK" "$TMPUID" "$TMPGID" "${WHITELIST[@]}" &
    BROKER_PID=$!
    disown $BROKER_PID

    # wait for socket to appear (up to 2s)
    for i in {1..20}; do
        [[ -S "$BROKER_SOCK" ]] && break
        sleep 0.1
    done
    [[ -S "$BROKER_SOCK" ]] || { echo "error: broker failed to start" >&2; exit 1; }

    # install client into session — replace the placeholder socket path
    CLIENT_SRC="$(dirname "$0")/run-as-root"
    [[ -f "$CLIENT_SRC" ]] || { echo "error: run-as-root not found next to user.sh" >&2; exit 1; }
    mkdir -p "$TMPHOME/.bin"
    sed "s|__BROKER_SOCK__|$BROKER_SOCK|g" "$CLIENT_SRC" > "$TMPHOME/.bin/run-as-root"

    chmod +x "$TMPHOME/.bin/run-as-root"
    chown -R "${TMPUSER}:${TMPUSER}" "$TMPHOME/.bin"

    echo ">> broker  : running (pid: $BROKER_PID)"
    echo ">> allowed : ${WHITELIST[*]}"
fi

# ---------- resource limits ----------
case "$MEM_LIMIT" in
    *G) MEM_KB=$(( ${MEM_LIMIT%G} * 1024 * 1024 )) ;;
    *M) MEM_KB=$(( ${MEM_LIMIT%M} * 1024 ))        ;;
    *)  echo "error: --mem must end in M or G (e.g. 512M, 2G)" >&2; exit 1 ;;
esac
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

set +e
"${UNSHARE[@]}" "${CMD[@]}"
