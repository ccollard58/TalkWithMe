#!/bin/bash
set -Eeuo pipefail

# Stop every TalkWithMe server on the HPC node: llama-server (LLM),
# whisper-fastapi (STT), and all tts-serve engines. Safe to run when
# nothing is running. Same defaults/env overrides as start_servers_*.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$HOME/llama.cpp}"
LLM_PORT="${LLM_PORT:-9090}"
WHISPER_DIR="${WHISPER_DIR:-$HOME/whisper-fastapi}"
STT_PORT="${STT_PORT:-5000}"
PID_DIR="${PID_DIR:-$HOME/talkwithme-pids}"

LLAMA_BIN="$LLAMA_CPP_DIR/build/bin/llama-server"
WHISPER_PY="$WHISPER_DIR/.venv/bin/python"

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

# stop_service <label> <pid-file> <port> <pgrep-pattern>
# Collects the recorded PID, whatever listens on the port, and any process
# matching the command-line pattern, then terminates them all.
stop_service() {
    local label="$1" pid_file="$2" port="$3" pattern="$4"
    local pids=() pid

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
    for pid in $(pgrep -f "$pattern" 2>/dev/null || true); do
        pids+=("$pid")
    done
    # Never kill ourselves (our own command line may contain the pattern).
    local filtered=()
    for pid in "${pids[@]}"; do
        [[ "$pid" != "$$" ]] && filtered+=("$pid")
    done
    pids=("${filtered[@]}")

    if ((${#pids[@]})); then
        mapfile -t pids < <(printf '%s\n' "${pids[@]}" | sort -un)
        echo "Stopping $label (port $port): ${pids[*]}"
        terminate_pids "${pids[@]}"
    else
        echo "$label not running (port $port)"
    fi
}

stop_service "llama-server" "$PID_DIR/llama.pid" "$LLM_PORT" "$LLAMA_BIN"
stop_service "whisper-fastapi" "$PID_DIR/stt.pid" "$STT_PORT" "$WHISPER_PY.*whisper_fastapi.py"

bash "$SCRIPT_DIR/stop_all_tts_engines.sh"

# Remove the stale connection info the start scripts wrote.
rm -f "$HOME/.llama_server_info"

echo "All TalkWithMe servers stopped."
