#!/bin/bash
set -Eeuo pipefail

# Start or restart the TalkWithMe services on an already allocated gpu-h100sxm node.
# Run this from the node while the allocation is active; it does not submit a job.

# ---- edit these for your setup ----
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$HOME/llama.cpp}"
MODEL_PATH="${MODEL_PATH:-$HOME/llama.cpp/models/gemma-4-26B-A4B.Q8_0.gguf}"
LLM_PORT="${LLM_PORT:-9090}"

OMNIVOICE_DIR="${OMNIVOICE_DIR:-$HOME/OmniVoice}"
TTS_PORT="${TTS_PORT:-8181}"

WHISPER_DIR="${WHISPER_DIR:-$HOME/whisper-fastapi}"
WHISPER_MODEL="${WHISPER_MODEL:-large-v3-turbo}"
STT_PORT="${STT_PORT:-5000}"
# ------------------------------------

LLAMA_BIN="$LLAMA_CPP_DIR/build/bin/llama-server"
OMNIVOICE_PY="$OMNIVOICE_DIR/.venv/bin/python"
WHISPER_PY="$WHISPER_DIR/.venv/bin/python"

LLM_GPUS="0,1"
TTS_GPU="2"
STT_GPU="3"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${LOG_DIR:-$HOME/talkwithme-logs}"
PID_DIR="${PID_DIR:-$HOME/talkwithme-pids}"
mkdir -p "$LOG_DIR" "$PID_DIR"

if ! command -v module >/dev/null 2>&1; then
    for modules_init in /etc/profile.d/modules.sh /usr/share/Modules/init/bash; do
        if [[ -r "$modules_init" ]]; then
            # shellcheck disable=SC1090
            source "$modules_init"
            break
        fi
    done
fi
if command -v module >/dev/null 2>&1; then
    module load cuda13.0/toolkit/13.0.2
    module load python/3.11.10
fi
# cudnn9.1-cuda12.2 is loaded ONLY inside the whisper subshell below (not here):
# whisper needs cuDNN 9.1, but OmniVoice bundles its own cuDNN 9.24 via its venv,
# and having 9.1's lib dir in LD_LIBRARY_PATH globally shadows OmniVoice's
# libcudnn_engines_runtime_compiled.so.9.24.x, causing CUDNN_STATUS_SUBLIBRARY_LOADING_FAILED.

for required_file in "$LLAMA_BIN" "$OMNIVOICE_PY" "$WHISPER_PY"; do
    if [[ ! -x "$required_file" ]]; then
        echo "ERROR: executable not found: $required_file" >&2
        exit 1
    fi
done
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "ERROR: model not found: $MODEL_PATH" >&2
    exit 1
fi

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

stop_matching_processes() {
    local label="$1"
    local pattern="$2"
    local pids
    pids="$(pgrep -f "$pattern" || true)"
    if [[ -z "$pids" ]]; then
        return
    fi
    echo "Stopping existing $label process(es): $pids"
    kill $pids 2>/dev/null || true
    sleep 2
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

stop_port_processes() {
    local port="$1"
    local pids
    pids="$(find_pids_on_port "$port")"
    if [[ -z "$pids" ]]; then
        return
    fi
    echo "Stopping process(es) listening on port $port: $pids"
    kill $pids 2>/dev/null || true
    sleep 2
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

# Match the configured commands first, then clear anything still holding a service port.
stop_matching_processes "llama-server" "$LLAMA_BIN"
stop_matching_processes "OmniVoice" "$OMNIVOICE_PY.*server_omnivoice.py"
stop_matching_processes "whisper-fastapi" "$WHISPER_PY.*whisper_fastapi.py"
for port in "$LLM_PORT" "$TTS_PORT" "$STT_PORT"; do
    stop_port_processes "$port"
done

NODE_HOST="$(hostname -s)"
INFO_FILE="$HOME/.llama_server_info"
INFO_TMP="${INFO_FILE}.tmp.$$"
{
    echo "host=$NODE_HOST"
    echo "llm_port=$LLM_PORT"
    echo "tts_port=$TTS_PORT"
    echo "stt_port=$STT_PORT"
    echo "launcher_pid=$$"
} > "$INFO_TMP"
mv -f "$INFO_TMP" "$INFO_FILE"

echo "Starting services on $NODE_HOST"

echo "Starting OmniVoice TTS on $NODE_HOST:$TTS_PORT (GPU $TTS_GPU)"
(
    cd "$OMNIVOICE_DIR/tts-serve"
    export CUDA_VISIBLE_DEVICES="$TTS_GPU"
    export OMNIVOICE_HOST=0.0.0.0
    export OMNIVOICE_PORT="$TTS_PORT"
    export OMNIVOICE_DEVICE=cuda
    exec "$OMNIVOICE_PY" impl/server_omnivoice.py
) > "$LOG_DIR/tts_server_${RUN_ID}.log" 2>&1 &
echo $! > "$PID_DIR/tts.pid"

echo "Starting whisper-fastapi STT on $NODE_HOST:$STT_PORT (GPU $STT_GPU)"
(
    if command -v module >/dev/null 2>&1; then
        module load cudnn9.1-cuda12.2/9.1.1.17
    fi
    cd "$WHISPER_DIR"
    export CUDA_VISIBLE_DEVICES="$STT_GPU"
    exec "$WHISPER_PY" whisper_fastapi.py \
        --host 0.0.0.0 --port "$STT_PORT" --model "$WHISPER_MODEL" --device cuda
) > "$LOG_DIR/stt_server_${RUN_ID}.log" 2>&1 &
echo $! > "$PID_DIR/stt.pid"

echo "Starting llama-server on $NODE_HOST:$LLM_PORT (GPUs $LLM_GPUS)"
(
    export CUDA_VISIBLE_DEVICES="$LLM_GPUS"
    exec "$LLAMA_BIN" \
        -m "$MODEL_PATH" \
        --host 0.0.0.0 \
        --port "$LLM_PORT" \
        --cors-origins localhost \
        -ngl 999 \
        --tensor-split 1,1
) > "$LOG_DIR/llama_server_${RUN_ID}.log" 2>&1 &
echo $! > "$PID_DIR/llama.pid"

echo "Started services. Logs: $LOG_DIR; PIDs: $PID_DIR"