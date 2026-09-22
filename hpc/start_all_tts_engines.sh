#!/bin/bash
set -Eeuo pipefail

# Start every tts-serve engine TalkWithMe knows about, each as its own
# server process on its own port (tts-serve has no single server that
# swaps engines in place — see README.md "TTS engines"). Run this from a
# GPU node with an active allocation; it does not submit a job.
#
# Each engine needs its own install (its own venv, its own pip/git install,
# and its own `tts-serve` checkout inside that venv's directory) — follow
# the engine-specific doc linked from https://github.com/scorbo2/tts-serve
# before enabling it here. An engine whose directory doesn't exist is
# skipped with a warning rather than failing the whole script, since most
# setups will only have a handful of these actually installed.
#
# The default ports here match app/config.py's built-in TTS Model dropdown
# entries — start engines on these ports (the defaults) and the web GUI
# dropdown works with zero extra configuration.
#
# Qwen3-TTS (MLX) is disabled by default: it only runs on Apple Silicon via
# `mlx-audio`, which this script (written for a CUDA node) cannot exercise.
# Enable it explicitly (ENABLE_QWEN3TTS_MLX=1) only when running this on a Mac.
#
# CAUTION: every enabled engine here shares GPU $TTS_GPU (default 0) and all
# start at once — running every installed engine simultaneously can easily
# exceed a single GPU's VRAM. Disable engines you don't need right now with
# ENABLE_<KEY>=0 (e.g. ENABLE_CHATTERBOX=0), or set TTS_GPU per engine by
# editing the loop below if you have more than one GPU to spread them across.

PID_DIR="${PID_DIR:-$HOME/talkwithme-pids}"
LOG_DIR="${LOG_DIR:-$HOME/talkwithme-logs}"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$PID_DIR" "$LOG_DIR"

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

# Every engine follows the same on-disk layout documented by tts-serve:
# <engine_dir>/.venv/bin/python and <engine_dir>/tts-serve/impl/<script>.
#
# Fields: key : dir env var : default dir : script (relative to tts-serve/)
#         : host env var : port env var : default port
#         : device env var (blank = engine has none) : default device
#         : enabled by default (1/0)
ENGINES=(
    "omnivoice:OMNIVOICE_DIR:$HOME/OmniVoice:impl/server_omnivoice.py:OMNIVOICE_HOST:OMNIVOICE_PORT:8181:OMNIVOICE_DEVICE:cuda:1"
    "chatterbox:CHATTERBOX_DIR:$HOME/Chatterbox:impl/server_chatterbox.py:CHATTERBOX_HOST:CHATTERBOX_PORT:8182:CHATTERBOX_DEVICE:cuda:1"
    "qwen3tts:QWEN3TTS_DIR:$HOME/Qwen3TTS:impl/server_qwen3TTS.py:QWEN3TTS_HOST:QWEN3TTS_PORT:8183:QWEN3TTS_DEVICE:cuda:1"
    "qwen3tts_mlx:QWEN3TTS_MLX_DIR:$HOME/Qwen3TTSMLX:impl/server_qwen3TTS_mlx.py:QWEN3TTS_MLX_HOST:QWEN3TTS_MLX_PORT:8184:::0"
    "faster_qwen3tts:FASTER_QWEN3TTS_DIR:$HOME/faster-Qwen3TTS:impl/server_fasterQwen3TTS.py:FASTER_QWEN3TTS_HOST:FASTER_QWEN3TTS_PORT:8185:::1"
    "dots_tts:DOTS_TTS_DIR:$HOME/dots.tts:impl/server_dotsTTS.py:DOTS_TTS_HOST:DOTS_TTS_PORT:8186:::1"
    "indextts:INDEXTTS_DIR:$HOME/index-tts:impl/server_indexTTS.py:INDEXTTS_HOST:INDEXTTS_PORT:8187:INDEXTTS_DEVICE:cuda:1"
    "luxtts:LUX_TTS_DIR:$HOME/LuxTTS:impl/server_luxTTS.py:LUX_TTS_HOST:LUX_TTS_PORT:8188:LUX_TTS_DEVICE:cuda:1"
)

GPU="${TTS_GPU:-0}"
STARTED=0
SKIPPED=0
# Ports actually started, so callers (start_servers_*.sh, the .slurm jobs,
# connect_tunnel.ps1) know exactly what to tunnel — see the info file written
# at the bottom of this script.
STARTED_PORTS=()
STARTED_KEYS=()

for record in "${ENGINES[@]}"; do
    IFS=':' read -r key dir_var default_dir script host_var port_var default_port \
        device_var default_device enabled_default <<< "$record"

    enable_var="ENABLE_${key^^}"
    enabled="${!enable_var:-$enabled_default}"
    if [[ "$enabled" != "1" ]]; then
        echo "Skipping $key (disabled; set $enable_var=1 to enable)"
        continue
    fi

    engine_dir="${!dir_var:-$default_dir}"
    engine_py="$engine_dir/.venv/bin/python"
    engine_script="$engine_dir/tts-serve/$script"
    port="${!port_var:-$default_port}"

    if [[ ! -x "$engine_py" || ! -f "$engine_script" ]]; then
        echo "Skipping $key: not installed at $engine_dir (see https://github.com/scorbo2/tts-serve for setup)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    stop_port_processes "$port"

    echo "Starting $key on port $port (GPU $GPU)"
    (
        cd "$engine_dir/tts-serve"
        export CUDA_VISIBLE_DEVICES="$GPU"
        [[ -n "$host_var" ]] && export "$host_var"="0.0.0.0"
        [[ -n "$port_var" ]] && export "$port_var"="$port"
        if [[ -n "$device_var" ]]; then
            export "$device_var"="${!device_var:-$default_device}"
        fi
        exec "$engine_py" "$script"
    ) > "$LOG_DIR/tts_${key}_${RUN_ID}.log" 2>&1 &
    echo $! > "$PID_DIR/tts_${key}.pid"
    STARTED=$((STARTED + 1))
    STARTED_PORTS+=("$port")
    STARTED_KEYS+=("${key}=${port}")
done

# Machine-readable record of what actually started, for callers that need to
# know which ports to tunnel (connect_tunnel.ps1) or fold into their own info
# file (start_servers_*.sh, the .slurm jobs). Written even when nothing
# started (empty ports= line) so a stale file from a previous run is never
# mistaken for the current one.
TTS_INFO_FILE="${TTS_INFO_FILE:-$HOME/.tts_engines_info}"
TTS_INFO_TMP="${TTS_INFO_FILE}.tmp.$$"
{
    IFS=','; echo "ports=${STARTED_PORTS[*]:-}"; unset IFS
    for kv in "${STARTED_KEYS[@]:-}"; do
        [[ -n "$kv" ]] && echo "$kv"
    done
} > "$TTS_INFO_TMP"
mv -f "$TTS_INFO_TMP" "$TTS_INFO_FILE"

echo "Started $STARTED TTS engine(s), skipped $SKIPPED not-installed engine(s)."
echo "Logs: $LOG_DIR; PIDs: $PID_DIR; port list: $TTS_INFO_FILE"
echo "Point TalkWithMe's \"TTS Model\" dropdown entries at these ports (the app's"
echo "built-in defaults already match — see app/config.py TTSConfig.engine_profiles)."
