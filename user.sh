#!/bin/env bash
# Spawn a sandboxed temporary session.
#
# Usage: sudo ./user.sh [options] [-- program [args...]]
#
# Options:
#   --mem  <size>        virtual memory limit e.g. 512M (default: 512M)
#   --files <n>          max open file descriptors (default: 1024)
#   --bind <src>:<dst>   bind-mount src read-only into session home at dst
#   --no-net             give the session an isolated loopback-only network namespace
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

# ---------- parse options ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mem)   MEM_LIMIT="$2";  shift 2 ;;
        --files) MAX_FILES="$2";  shift 2 ;;
        --bind)  BIND_MOUNTS+=("$2"); shift 2 ;;
        --no-net) USE_NET_NS=1;   shift   ;;
        --)      shift; break ;;
        *)       break ;;
    esac
done

# ---------- temp user + dirs ----------
TMPUSER="tmpuser_$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
TMPHOME="$(mktemp -d /tmp/home_XXXXXX)"   # overlay merged mount point
TMPTFS="$(mktemp -d /tmp/tfs_XXXXXX)"     # tmpfs backing upper/work (RAM only)

cleanup() {
    # unmount bind mounts before tearing down home overlay
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

# ---------- read-only bind mounts into home ----------
for bm in "${BIND_MOUNTS[@]+"${BIND_MOUNTS[@]}"}"; do
    src="${bm%%:*}"
    dst="${bm#*:}"
    mkdir -p "$TMPHOME/$dst"
    mount --bind "$src" "$TMPHOME/$dst"
    mount -o remount,ro,bind "$TMPHOME/$dst"
    echo ">> bind (ro): $src -> \$HOME/$dst"
done

# ---------- resource limits ----------
MEM_KB=$(( ${MEM_LIMIT%M} * 1024 ))
ulimit -v "$MEM_KB"   # virtual address space
ulimit -n "$MAX_FILES" # open file descriptors

# ---------- build namespace wrapper ----------
UNSHARE=(unshare
    --fork
    --pid  --mount-proc   # isolated PID namespace + fresh /proc
)
[[ $USE_NET_NS -eq 1 ]] && UNSHARE+=(--net)  # loopback-only network

# ---------- build sandboxed command ----------
# setpriv: switches to the temp user AND drops all capabilities in one step
PROG="${*:-/bin/bash --login}"
CMD=(
    setpriv
        --reuid="$TMPUID"
        --regid="$TMPGID"
        --init-groups
        --inh-caps=-all        # no inheritable capabilities
        --bounding-set=-all    # hard cap: can never re-acquire any capability
        --no-new-privs         # no suid/capability escalation ever
        --
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
