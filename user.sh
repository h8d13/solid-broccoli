#!/bin/env bash
# Spawn a temporary unprivileged user session.
# Usage: sudo ./user.sh [program [args...]]
# Default program: /bin/bash (interactive shell)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

# Unique throwaway username
TMPUSER="tmpuser_$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
TMPHOME="$(mktemp -d /tmp/home_XXXXXX)"   # merged mount point
TMPTFS="$(mktemp -d /tmp/tfs_XXXXXX)"     # tmpfs base (RAM only)

cleanup() {
    userdel "$TMPUSER" 2>/dev/null || true
    umount "$TMPHOME"  2>/dev/null || true
    umount "$TMPTFS"   2>/dev/null || true
    rm -rf "$TMPHOME" "$TMPTFS"
}
trap cleanup EXIT

# Mount a tmpfs so upper/work never touch the real disk
mount -t tmpfs tmpfs "$TMPTFS"
mkdir "$TMPTFS/upper" "$TMPTFS/work"

# Overlay: lower=skel (read-only), upper=tmpfs (RAM writes), merged=TMPHOME
mount -t overlay overlay \
    -o lowerdir=/etc/skel,upperdir="$TMPTFS/upper",workdir="$TMPTFS/work" \
    "$TMPHOME"

# Create user: dedicated group, temp home, no wheel/sudo
useradd \
    --home-dir  "$TMPHOME"  \
    --no-create-home        \
    --user-group            \
    --no-log-init           \
    --shell /bin/bash       \
    "$TMPUSER"

chown "${TMPUSER}:${TMPUSER}" "$TMPHOME"
chmod 700 "$TMPHOME"

echo ">> session: $TMPUSER  (home: $TMPHOME)"

# Run given program, or drop into interactive bash
if [[ $# -gt 0 ]]; then
    runuser -u "$TMPUSER" -- "$@"
else
    runuser -u "$TMPUSER" -- /bin/bash --login
fi

# trap fires here: user + home dir removed
echo ">> session ended, user and home dir cleaned up"
