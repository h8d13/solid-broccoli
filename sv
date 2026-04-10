#!/bin/bash
# sv — service control for ImutArch sessions
#
# Usage: sv <setup|start|stop|status|delete> <name>
#
# Services live in $SVDIR/<name>/:
#   run   executable script that starts the service
#   pid   written by session-init or sv start (PID of running process)
#   down  presence prevents auto-start and marks service as stopped

if [[ $# -lt 2 || -z "$SVDIR" ]]; then
    echo "usage: sv [--temp] <setup|start|stop|status> <name> [command...]" >&2
    exit 1
fi

# --temp uses the ephemeral service dir (gone on session exit)
TARGET_DIR="$SVDIR"
if [[ "$1" == "--temp" ]]; then
    TARGET_DIR="${SVDIR_TEMP:?SVDIR_TEMP not set}"
    shift
fi

CMD="$1"
NAME="$2"
SVC="$TARGET_DIR/$NAME"

if [[ "$CMD" == "delete" ]]; then
    [[ -d "$SVC" ]] || { echo "sv: $NAME: service not found in $TARGET_DIR" >&2; exit 1; }
    pid=$(cat "$SVC/pid" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        echo "$NAME: stopped (pid $pid)"
    fi
    rm -rf "$SVC"
    echo "$NAME: deleted"
    exit 0
fi

if [[ "$CMD" == "setup" ]]; then
    [[ -d "$SVC" ]] && { echo "sv: $NAME: already exists"; exit 0; }
    mkdir -p "$SVC"
    CMD_LINE="${@:3}"
    printf '#!/bin/sh\nexec %s\n' "${CMD_LINE:-$NAME}" > "$SVC/run"
    chmod +x "$SVC/run"
    echo "$NAME: created ($SVC/run)"
    echo "  edit $SVC/run if needed, then: sv start $NAME"
    exit 0
fi

if [[ ! -d "$SVC" ]]; then
    echo "sv: $NAME: service not found in $TARGET_DIR" >&2
    exit 1
fi

case "$CMD" in
    start)
        [[ -x "$SVC/run" ]] || { echo "sv: $NAME: no executable run script" >&2; exit 1; }
        rm -f "$SVC/down"
        "$SVC/run" &
        echo $! > "$SVC/pid"
        echo "$NAME: started (pid $!)"
        ;;
    stop)
        touch "$SVC/down"
        pid=$(cat "$SVC/pid" 2>/dev/null) || { echo "$NAME: not running"; exit 0; }
        if kill "$pid" 2>/dev/null; then
            echo "$NAME: stopped (pid $pid)"
        else
            echo "$NAME: already stopped"
        fi
        rm -f "$SVC/pid"
        ;;
    status)
        pid=$(cat "$SVC/pid" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$NAME: running (pid $pid)"
        else
            echo "$NAME: stopped"
        fi
        ;;
    *)
        echo "usage: sv [--temp] <setup|start|stop|status|delete> <name>" >&2
        exit 1
        ;;
esac
