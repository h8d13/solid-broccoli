#!/bin/bash
# sv — service control for ImutArch sessions
#
# Usage: sv <start|stop|status> <name>
#
# Services live in $SVDIR/<name>/:
#   run   executable script that starts the service
#   pid   written by session-init or sv start (PID of running process)
#   down  presence prevents auto-start and marks service as stopped

if [[ $# -lt 2 || -z "$SVDIR" ]]; then
    echo "usage: sv <start|stop|status> <name>" >&2
    exit 1
fi

CMD="$1"
NAME="$2"
SVC="$SVDIR/$NAME"

if [[ ! -d "$SVC" ]]; then
    echo "sv: $NAME: service not found in $SVDIR" >&2
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
        echo "usage: sv <start|stop|status> <name>" >&2
        exit 1
        ;;
esac
