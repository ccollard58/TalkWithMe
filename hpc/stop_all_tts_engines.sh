#!/bin/bash
set -Eeuo pipefail

# Stop every tts-serve engine started by start_all_tts_engines.sh.
# For each engine it first stops the PID recorded in $PID_DIR/tts_<key>.pid,
# then anything still listening on the engine's port (same defaults and
# *_PORT env overrides as the start script), and finally removes the stale
# port-list file the start script wrote.

PID_DIR="${PID_DIR:-$HOME/talkwithme-pids}"
TTS_INFO_FILE="${TTS_INFO_FILE:-$HOME/.tts_engines_info}"

# key : port env var : default port  (keep in sync with start_all_tts_engines.sh)
ENGINES=(
    "omnivoice:OMNIVOICE_PORT:8181"
    "chatterbox:CHATTERBOX_PORT:8182"
    "qwen3tts:QWEN3TTS_PORT:8183"
    "qwen3tts_mlx:QWEN3TTS_MLX_PORT:8184"
    "faster_qwen3tts:FASTER_QWEN3TTS_PORT:8185"
    "dots_tts:DOTS_TTS_PORT:8186"
    "indextts:INDEXTTS_PORT:8187"
    "luxtts:LUX_TTS_PORT:8188"
)

find_pids_on_port() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -t -n -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
    elif command -v ss >/dev/null 2>&1; then
        ss -ltnp "sport = :$port" 2>/dev/null \
            | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' \
            | sort -u
    fi
}

# Terminate the given PIDs: SIGTERM, wait up to ~5s, then SIGKILL stragglers.
terminate_pids() {
    local pids=("$@")
    ((${#pids[@]})) || return 0
    kill "${pids[@]}" 2>/dev/null || true
    local i pid alive
    for i in 1 2 3 4 5; do
        alive=0
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && alive=1
        done
        ((alive)) || return 0
        sleep 1
    done
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

STOPPED=0

for record in "${ENGINES[@]}"; do
    IFS=':' read -r key port_var default_port <<< "$record"
    port="${!port_var:-$default_port}"
    pid_file="$PID_DIR/tts_${key}.pid"
    pids=()

    if [[ -f "$pid_file" ]]; then
        pid="$(<"$pid_file")"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            pids+=("$pid")
        fi
        rm -f "$pid_file"
    fi

    for pid in $(find_pids_on_port "$port"); do
        pids+=("$pid")
    done

    if ((${#pids[@]})); then
        mapfile -t pids < <(printf '%s\n' "${pids[@]}" | sort -un)
        echo "Stopping $key (port $port): ${pids[*]}"
        terminate_pids "${pids[@]}"
        STOPPED=$((STOPPED + 1))
    else
        echo "$key not running (port $port)"
    fi
done

rm -f "$TTS_INFO_FILE"

echo "Stopped $STOPPED TTS engine(s)."
