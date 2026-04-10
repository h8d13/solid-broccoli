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
#   --eth                veth pair + bridge with a random ULA IPv6 address
#   --port  <h:c>        forward host port h → session port c (requires --eth, repeatable)
#   --cap   <name>       raise an ambient capability in the session (repeatable)
#   --wayland            nested Wayland session (passes host socket + GPU render node)
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
USE_ETH=0
WHITELIST=()
AMBIENT_CAPS=()
PORT_MAPS=()
USE_WAYLAND=0
WAYLAND_SOCK=""
ETH_BRIDGE=""
ETH_NETNS=""
ETH_VETH_HOST=""
ETH_HOST_IF=""
ETH_HOST_IF4=""
ETH_PREFIX=""
ETH_IPV4_NET=""
SAVED_IP_FORWARD=""
SAVED_IP6_FORWARD=""
SAVED_ACCEPT_RA=""

# ---------- parse options ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mem)    MEM_LIMIT="$2";      shift 2 ;;
        --files)  MAX_FILES="$2";      shift 2 ;;
        --bind)   BIND_MOUNTS+=("$2"); shift 2 ;;
        --no-net) USE_NET_NS=1;              shift   ;;
        --eth)    USE_ETH=1;                 shift   ;;
        --port)   PORT_MAPS+=("$2");         shift 2 ;;
        --cap)    AMBIENT_CAPS+=("$2");      shift 2 ;;
        --wayland) USE_WAYLAND=1;           shift   ;;
        --allow)  WHITELIST+=("$2");         shift 2 ;;
        --)       shift; break ;;
        *)        break ;;
    esac
done

# ---------- temp user + dirs ----------
TMPUSER="tmpuser_$(openssl rand -hex 4)"
SANDBOX_ID="$(openssl rand -hex 4)"
TMPHOME="$(mktemp -d /var/tmp/home_XXXXXX)"   # overlay merged mount point
TMPTFS="$(mktemp -d /var/tmp/tfs_XXXXXX)"     # tmpfs backing upper/work (RAM only)
BROKER_SOCK="$TMPHOME/.broker.sock"

# persistent store — survives session, owned by the invoking user
REAL_USER="${SUDO_USER:-root}"
IMUT_DIR="/home/$REAL_USER/.imut"
[[ "$REAL_USER" == "root" ]] && IMUT_DIR="/root/.imut"
mkdir -p "$IMUT_DIR"
BROKER_PID=""

cleanup() {
    echo ""
    echo ">> session ended — user, home, and all writes cleaned up"
    [[ -n "$BROKER_PID" ]] && kill "$BROKER_PID" 2>/dev/null || true
    if [[ ${#BIND_MOUNTS[@]} -gt 0 ]]; then
        for bm in "${BIND_MOUNTS[@]}"; do
            dst="${bm#*:}"
            umount "$TMPHOME/$dst" 2>/dev/null || true
        done
    fi
    userdel "$TMPUSER" 2>/dev/null || true
    for pm in "${PORT_MAPS[@]}"; do
        hp="${pm%%:*}"; cp_="${pm#*:}"
        iptables -t nat -D PREROUTING  -p tcp --dport "$hp" -j DNAT --to-destination "${ETH_IPV4_CONT}:${cp_}" 2>/dev/null || true
        iptables      -D FORWARD       -p tcp -d "$ETH_IPV4_CONT" --dport "$cp_" -j ACCEPT 2>/dev/null || true
    done
    if [[ -n "$ETH_HOST_IF4" && -n "$ETH_IPV4_NET" ]]; then
        iptables  -t nat -D POSTROUTING -s "$ETH_IPV4_NET" -o "$ETH_HOST_IF4" -j MASQUERADE 2>/dev/null || true
        iptables  -D FORWARD -i "$ETH_BRIDGE"    -o "$ETH_HOST_IF4" -j ACCEPT 2>/dev/null || true
        iptables  -D FORWARD -i "$ETH_HOST_IF4"  -o "$ETH_BRIDGE"   -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        [[ -n "$SAVED_IP_FORWARD" ]]  && echo "$SAVED_IP_FORWARD"  > /proc/sys/net/ipv4/ip_forward
    fi
    if [[ -n "$ETH_HOST_IF" && -n "$ETH_PREFIX" ]]; then
        ip6tables -t nat -D POSTROUTING -s "$ETH_PREFIX"   -o "$ETH_HOST_IF"  -j MASQUERADE 2>/dev/null || true
        ip6tables -D FORWARD -i "$ETH_BRIDGE"   -o "$ETH_HOST_IF"  -j ACCEPT 2>/dev/null || true
        ip6tables -D FORWARD -i "$ETH_HOST_IF"  -o "$ETH_BRIDGE"   -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        [[ -n "$SAVED_IP6_FORWARD" ]] && echo "$SAVED_IP6_FORWARD" > /proc/sys/net/ipv6/conf/all/forwarding
        [[ -n "$SAVED_ACCEPT_RA" ]]   && echo "$SAVED_ACCEPT_RA"   > "/proc/sys/net/ipv6/conf/${ETH_HOST_IF}/accept_ra"
    fi
    if [[ -n "$ETH_BRIDGE" ]]; then
        ip link set "$ETH_BRIDGE" down 2>/dev/null || true
        ip link del "$ETH_BRIDGE"     2>/dev/null || true
    fi
    [[ -n "$ETH_NETNS" ]] && ip netns del "$ETH_NETNS" 2>/dev/null || true
    [[ -n "$WAYLAND_SOCK" ]] && umount "$TMPHOME/.run/$WAYLAND_SOCK" 2>/dev/null || true
    umount "$TMPHOME/.imut" 2>/dev/null || true
    umount "$TMPHOME"  2>/dev/null || true
    umount "$TMPTFS"   2>/dev/null || true
    rm -rf "$TMPHOME" "$TMPTFS"
}
trap cleanup EXIT

# ---------- overlay home (RAM-only writes) ----------
mount -t tmpfs tmpfs "$TMPTFS"
mkdir "$TMPTFS/upper"           "$TMPTFS/work"

# overlay dirs for system paths — all RAM-backed, gone on exit
mkdir -p "$TMPTFS/usr/upper"    "$TMPTFS/usr/work"
mkdir -p "$TMPTFS/pacman/upper" "$TMPTFS/pacman/work"
mkdir -p "$TMPTFS/cache/upper"  "$TMPTFS/cache/work"

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
TMPHOSTNAME="sandbox-$SANDBOX_ID"

if [[ $USE_NET_NS -eq 1 && $USE_ETH -eq 1 ]]; then
    echo "error: --no-net and --eth are mutually exclusive" >&2; exit 1
fi
if [[ ${#PORT_MAPS[@]} -gt 0 && $USE_ETH -eq 0 ]]; then
    echo "error: --port requires --eth" >&2; exit 1
fi

# ---------- veth + bridge (--eth) ----------
if [[ $USE_ETH -eq 1 ]]; then
    ETH_NETNS="ns-$SANDBOX_ID"
    ETH_VETH_HOST="veth-h-$SANDBOX_ID"
    ETH_BRIDGE="br-$SANDBOX_ID"

    # random addresses from R (6 random bytes)
    R=$(openssl rand -hex 6)

    # ULA IPv6 prefix: fdXX:XXXX:XXXX::/64
    ETH_PREFIX="fd${R:0:2}:${R:2:4}:${R:6:4}::/64"
    ETH_IPV6_HOST="fd${R:0:2}:${R:2:4}:${R:6:4}::1"
    ETH_IPV6_CONT="fd${R:0:2}:${R:2:4}:${R:6:4}::2"

    # random RFC1918 IPv4 subnet: 10.A.B.0/24
    IPV4_A=$(( 0x${R:0:2} % 223 + 1 ))
    IPV4_B=$(( 0x${R:2:2} ))
    ETH_IPV4_NET="10.${IPV4_A}.${IPV4_B}.0/24"
    ETH_IPV4_HOST="10.${IPV4_A}.${IPV4_B}.1"
    ETH_IPV4_CONT="10.${IPV4_A}.${IPV4_B}.2"

    ip netns add "$ETH_NETNS"
    # create veth pair — container end lands directly in the netns
    ip link add "$ETH_VETH_HOST" type veth peer name eth0 netns "$ETH_NETNS"

    # host side: attach to bridge, assign both IPv4 and IPv6, bring up
    ip link add "$ETH_BRIDGE" type bridge
    ip link set "$ETH_VETH_HOST" master "$ETH_BRIDGE"
    ip    addr add "${ETH_IPV4_HOST}/24" dev "$ETH_BRIDGE"
    ip -6 addr add "${ETH_IPV6_HOST}/64" dev "$ETH_BRIDGE"
    ip link set "$ETH_VETH_HOST" up
    ip link set "$ETH_BRIDGE" up

    # container side: IPv4 + IPv6 + default routes
    ip netns exec "$ETH_NETNS" ip link set lo up
    ip netns exec "$ETH_NETNS" ip link set eth0 up
    ip netns exec "$ETH_NETNS" ip    addr add "${ETH_IPV4_CONT}/24" dev eth0
    ip netns exec "$ETH_NETNS" ip -6 addr add "${ETH_IPV6_CONT}/64" dev eth0
    ip netns exec "$ETH_NETNS" ip    route add default via "$ETH_IPV4_HOST" dev eth0
    ip netns exec "$ETH_NETNS" ip -6 route add default via "$ETH_IPV6_HOST" dev eth0

    # IPv4 NAT
    ETH_HOST_IF4=$(ip route show default | awk 'NR==1{print $5}')
    if [[ -n "$ETH_HOST_IF4" ]]; then
        SAVED_IP_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward)
        echo 1 > /proc/sys/net/ipv4/ip_forward
        iptables -t nat -A POSTROUTING -s "$ETH_IPV4_NET" -o "$ETH_HOST_IF4" -j MASQUERADE
        iptables -A FORWARD -i "$ETH_BRIDGE" -o "$ETH_HOST_IF4" -j ACCEPT
        iptables -A FORWARD -i "$ETH_HOST_IF4" -o "$ETH_BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    else
        echo "warning: no default IPv4 route on host — outbound IPv4 will not work" >&2
    fi

    # IPv6 NAT66 — preserve host RA so enabling forwarding doesn't drop the host's own IPv6 default route
    ETH_HOST_IF=$(ip -6 route show default | awk 'NR==1{print $5}')
    if [[ -n "$ETH_HOST_IF" ]]; then
        SAVED_IP6_FORWARD=$(cat /proc/sys/net/ipv6/conf/all/forwarding)
        echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
        if [[ -f "/proc/sys/net/ipv6/conf/${ETH_HOST_IF}/accept_ra" ]]; then
            SAVED_ACCEPT_RA=$(cat "/proc/sys/net/ipv6/conf/${ETH_HOST_IF}/accept_ra")
            echo 2 > "/proc/sys/net/ipv6/conf/${ETH_HOST_IF}/accept_ra"
        fi
        ip6tables -t nat -A POSTROUTING -s "$ETH_PREFIX" -o "$ETH_HOST_IF" -j MASQUERADE
        ip6tables -A FORWARD -i "$ETH_BRIDGE" -o "$ETH_HOST_IF" -j ACCEPT
        ip6tables -A FORWARD -i "$ETH_HOST_IF" -o "$ETH_BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    else
        echo "warning: no default IPv6 route on host — outbound IPv6 will not work" >&2
    fi

    # ---------- port forwarding (host → session) ----------
    for pm in "${PORT_MAPS[@]}"; do
        hp="${pm%%:*}"; cp_="${pm#*:}"
        iptables -t nat -A PREROUTING  -p tcp --dport "$hp" -j DNAT --to-destination "${ETH_IPV4_CONT}:${cp_}"
        iptables      -A FORWARD       -p tcp -d "$ETH_IPV4_CONT" --dport "$cp_" -j ACCEPT
    done
fi

# ---------- persistent .imut ----------
mkdir -p "$TMPHOME/.imut"
mount --bind "$IMUT_DIR" "$TMPHOME/.imut"
chown "${TMPUSER}:${TMPUSER}" "$TMPHOME/.imut"

# ---------- read-only bind mounts ----------
if [[ ${#BIND_MOUNTS[@]} -gt 0 ]]; then
    for bm in "${BIND_MOUNTS[@]}"; do
        src="${bm%%:*}"
        dst="${bm#*:}"
        mkdir -p "$TMPHOME/$dst"
        mount --bind "$src" "$TMPHOME/$dst"
        mount -o remount,ro,bind "$TMPHOME/$dst"
        echo ">> bind (ro): $src -> \$HOME/$dst"
    done
fi

# ---------- nested Wayland (--wayland) ----------
if [[ $USE_WAYLAND -eq 1 ]]; then
    REAL_UID=$(id -u "$REAL_USER")
    HOST_XDG="/run/user/$REAL_UID"

    # find the host Wayland socket
    for _name in wayland-0 wayland-1 wayland-2; do
        [[ -S "$HOST_XDG/$_name" ]] && WAYLAND_SOCK="$_name" && break
    done
    [[ -z "$WAYLAND_SOCK" ]] && { echo "error: no Wayland socket found in $HOST_XDG" >&2; exit 1; }

    # session XDG_RUNTIME_DIR inside home
    SESSION_XDG="$TMPHOME/.run"
    mkdir -p "$SESSION_XDG"
    chmod 700 "$SESSION_XDG"
    chown "${TMPUSER}:${TMPUSER}" "$SESSION_XDG"

    # bind-mount the host Wayland socket in
    touch "$SESSION_XDG/$WAYLAND_SOCK"
    mount --bind "$HOST_XDG/$WAYLAND_SOCK" "$SESSION_XDG/$WAYLAND_SOCK"

    # add tmpuser to the render group for GPU acceleration (render node, no KMS needed)
    RENDER_GROUP=$(stat -c %G /dev/dri/renderD128 2>/dev/null || true)
    [[ -n "$RENDER_GROUP" ]] && usermod -aG "$RENDER_GROUP" "$TMPUSER" 2>/dev/null || true

    echo ">> wayland : $WAYLAND_SOCK (host $HOST_XDG)"
fi

# ---------- broker ----------
if [[ ${#WHITELIST[@]} -gt 0 ]]; then

    BROKER_SCRIPT="$(dirname "$0")/broker.py"
    [[ -f "$BROKER_SCRIPT" ]] || { echo "error: broker.py not found next to user.sh" >&2; exit 1; }

    python3 "$BROKER_SCRIPT" "$BROKER_SOCK" "$TMPUID" "$TMPGID" "$TMPTFS" "${WHITELIST[@]}" &
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
    *G) MEM_BYTES=$(( ${MEM_LIMIT%G} * 1024 * 1024 * 1024 )) ;;
    *M) MEM_BYTES=$(( ${MEM_LIMIT%M} * 1024 * 1024 ))        ;;
    *)  echo "error: --mem must end in M or G (e.g. 512M, 2G)" >&2; exit 1 ;;
esac

# ---------- fake /proc files ----------
MEM_KB=$(( MEM_BYTES / 1024 ))
cat > "$TMPTFS/meminfo" <<EOF
MemTotal:       ${MEM_KB} kB
MemFree:        ${MEM_KB} kB
MemAvailable:   ${MEM_KB} kB
Buffers:               0 kB
Cached:                0 kB
SwapCached:            0 kB
Active:                0 kB
Inactive:              0 kB
SwapTotal:             0 kB
SwapFree:              0 kB
Dirty:                 0 kB
EOF

# ---------- namespace wrapper ----------
UNSHARE=(unshare --fork --pid --mount-proc --mount --uts --cgroup)
[[ $USE_NET_NS -eq 1 ]] && UNSHARE+=(--net)

# ---------- capability flags ----------
# Build inheritable + ambient sets from --cap options
INH_CAPS="-all"
AMBIENT_FLAGS=()
for cap in "${AMBIENT_CAPS[@]}"; do
    INH_CAPS+=",+$cap"
    AMBIENT_FLAGS+=(--ambient-caps="+$cap")
done

# ---------- sandboxed command ----------
# inner: apply resource limits, drop privileges, optionally install seccomp, then exec
INNER=(
    prlimit
        "--as=$MEM_BYTES"
        "--nofile=$MAX_FILES"
        --
    setpriv
        --reuid="$TMPUID"
        --regid="$TMPGID"
        --init-groups
        --inh-caps="$INH_CAPS"
        "${AMBIENT_FLAGS[@]}"
        --bounding-set=-all
        --no-new-privs
        --pdeathsig=SIGKILL
        --
)

# inject seccomp filter if seccomp-wrap.py is present next to user.sh
SECCOMP_SRC="$(dirname "$0")/seccomp-wrap.py"
if [[ -f "$SECCOMP_SRC" ]]; then
    cp "$SECCOMP_SRC" "$TMPTFS/seccomp-wrap.py"
    INNER+=(python3 "$TMPTFS/seccomp-wrap.py" --)
fi

SESSION_ENV=(
    HOME="$TMPHOME"
    USER="$TMPUSER"
    LOGNAME="$TMPUSER"
    TERM="${TERM:-xterm}"
    LANG="${LANG:-C.UTF-8}"
    PATH="${BROKER_PID:+$TMPHOME/.bin:}$TMPTFS/usr/upper/local/bin:$TMPTFS/usr/upper/bin:/usr/local/bin:/usr/bin:/bin"
)

if [[ $USE_WAYLAND -eq 1 ]]; then
    SESSION_ENV+=(
        WAYLAND_DISPLAY="$WAYLAND_SOCK"
        XDG_RUNTIME_DIR="$TMPHOME/.run"
        WLR_BACKENDS=wayland
        WLR_NO_HARDWARE_CURSORS=1
        XDG_SESSION_TYPE=wayland
    )
fi

INNER+=(env -i "${SESSION_ENV[@]}")

if [[ $# -gt 0 ]]; then
    INNER+=("$@")
else
    INNER+=(/bin/bash --login)
fi

# outer: runs as root inside the new namespace — mount fresh /tmp and
# overlay /usr (shared upper dir with broker) so packages installed via
# run-as-root are visible in the session, then hand off to INNER
SETUP="set -e
echo $TMPHOSTNAME > /proc/sys/kernel/hostname

# isolate mount propagation — nothing we do here leaks to the host (nsjail: MS_REC|MS_PRIVATE on /)
mount --make-rprivate /

# tmp: nosuid+nodev so binaries dropped here can't escalate
mount -t tmpfs -o nosuid,nodev,mode=1777 tmpfs /tmp

# usr/pacman overlays: session writes land in RAM-backed upper, host lower is read-only
mount -t overlay overlay -o nosuid,nodev,lowerdir=/usr,upperdir=$TMPTFS/usr/upper,workdir=$TMPTFS/usr/work,index=off /usr
mount -t overlay overlay -o nosuid,nodev,lowerdir=/var/lib/pacman,upperdir=$TMPTFS/pacman/upper,workdir=$TMPTFS/pacman/work,index=off /var/lib/pacman
mount -t overlay overlay -o nosuid,nodev,lowerdir=/var/cache/pacman,upperdir=$TMPTFS/cache/upper,workdir=$TMPTFS/cache/work,index=off /var/cache/pacman

# fresh sysfs — respects our net namespace for /sys/class/net
mount -t sysfs -o nosuid,nodev,noexec sysfs /sys
# mask hardware-identifying sysfs paths (GPU, PCI, firmware, DMI, power telemetry)
for _d in /sys/class/drm /sys/bus/pci /sys/firmware /sys/kernel/debug /sys/kernel/security; do
    [ -d \"\$_d\" ] && mount -t tmpfs -o nosuid,nodev,noexec tmpfs \"\$_d\"
done

# mask /proc files that reveal host hardware or kernel internals (nsjail pattern)
for _f in /proc/cpuinfo /proc/version /proc/swaps /proc/diskstats /proc/partitions \
          /proc/kcore /proc/kallsyms /proc/kmsg /proc/sysrq-trigger \
          /proc/iomem /proc/ioports; do
    [ -e \"\$_f\" ] && mount --bind /dev/null \"\$_f\"
done
mount --bind $TMPTFS/meminfo /proc/meminfo

exec \"\$@\""

CMD=(
    bash -c "$SETUP" --
    "${INNER[@]}"
)

# --eth: enter the named netns rather than letting unshare create a fresh one
if [[ $USE_ETH -eq 1 ]]; then
    CMD=(nsenter --net=/run/netns/"$ETH_NETNS" -- "${CMD[@]}")
fi

echo ">> session : $TMPUSER"
echo ">> hostname: $TMPHOSTNAME"
echo ">> home    : $TMPHOME (overlay, RAM-backed)"
echo ">> mem     : ${MEM_LIMIT} virt  |  files: ${MAX_FILES}"
if [[ $USE_ETH -eq 1 ]]; then
    echo ">> net     : veth (bridge: $ETH_BRIDGE)"
    echo ">>   ipv4  : $ETH_IPV4_HOST  <->  $ETH_IPV4_CONT"
    echo ">>   ipv6  : $ETH_IPV6_HOST  <->  $ETH_IPV6_CONT"
    for pm in "${PORT_MAPS[@]}"; do
        echo ">>   port  : host:${pm%%:*} -> session:${pm#*:}"
    done
elif [[ $USE_NET_NS -eq 1 ]]; then
    echo ">> net     : isolated (loopback only)"
else
    echo ">> net     : host"
fi
[[ ${#AMBIENT_CAPS[@]} -gt 0 ]] && echo ">> caps    : ${AMBIENT_CAPS[*]}"
[[ -f "$SECCOMP_SRC" ]]         && echo ">> seccomp : denylist active"
echo ""

set +e
"${UNSHARE[@]}" "${CMD[@]}"
