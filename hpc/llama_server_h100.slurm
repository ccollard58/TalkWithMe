#!/bin/bash
#SBATCH --job-name=talkwithme-xlarge
#SBATCH --output=llama_server_%j.out
#SBATCH --error=llama_server_%j.err
#SBATCH --partition=gpu-h100
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=32
#SBATCH --gpus-per-task=2
#SBATCH --time=24:00:00

# H100 setup: llama.cpp (Gemma 4 26B A4B) + OmniVoice TTS + whisper-fastapi.
# The H100 partition allows two GPUs per node: one for TTS/STT and one for the LLM.
# TTS/STT venvs are set up ahead of time by hpc/build_tts_stt.ps1.

# ---- edit these for your setup ----
LLAMA_CPP_DIR="$HOME/llama.cpp"
MODEL_PATH="$HOME/llama.cpp/models/gemma-4-26B-A4B.Q8_0.gguf"   # <-- point this at your Gemma 4 26B A4B .gguf
LLM_PORT=9090

OMNIVOICE_DIR="$HOME/OmniVoice"   # venv + tts-serve checkout, see build_tts_stt.ps1
TTS_PORT=8181

WHISPER_DIR="$HOME/whisper-fastapi"
WHISPER_MODEL="large-v3-turbo"
STT_PORT=5000
# ------------------------------------

module load cuda13.0/toolkit/13.0.2
module load python/3.11.10

srun hostname

LLAMA_BIN="$LLAMA_CPP_DIR/build/bin/llama-server"
OMNIVOICE_PY="$OMNIVOICE_DIR/.venv/bin/python"
WHISPER_PY="$WHISPER_DIR/.venv/bin/python"

# GPU nodes have no git/cmake/compiler/pip network access, so everything below
# must already be built on the head node first (build_llama_cpp.ps1 / build_tts_stt.ps1).
if [[ ! -x "$LLAMA_BIN" ]]; then
    echo "ERROR: $LLAMA_BIN not found. Run hpc/build_llama_cpp.ps1 from your workstation first." >&2
    exit 1
fi
if [[ ! -x "$OMNIVOICE_PY" ]]; then
    echo "ERROR: OmniVoice venv not found at $OMNIVOICE_DIR/.venv. Run hpc/build_tts_stt.ps1 first." >&2
    exit 1
fi
if [[ ! -x "$WHISPER_PY" ]]; then
    echo "ERROR: whisper-fastapi venv not found at $WHISPER_DIR/.venv. Run hpc/build_tts_stt.ps1 first." >&2
    exit 1
fi

if command -v ss >/dev/null 2>&1; then
    for port in "$LLM_PORT" "$TTS_PORT" "$STT_PORT"; do
        if ss -ltn "sport = :$port" | grep -q LISTEN; then
            echo "ERROR: port $port is already in use on $(hostname -s)." >&2
            echo "       Check for another SLURM job or server before submitting again." >&2
            exit 1
        fi
    done
fi

# Share one GPU between TTS and STT; reserve the other for the LLM.
AUX_GPU="0"
LLM_GPU="1"

NODE_HOST="$(hostname -s)"
{
    echo "host=$NODE_HOST"
    echo "llm_port=$LLM_PORT"
    echo "tts_port=$TTS_PORT"
    echo "stt_port=$STT_PORT"
    echo "job_id=$SLURM_JOB_ID"
} > "$HOME/.llama_server_info"

echo "Starting OmniVoice TTS on $NODE_HOST:$TTS_PORT (GPU $AUX_GPU)"
(
    cd "$OMNIVOICE_DIR/tts-serve"
    export CUDA_VISIBLE_DEVICES="$AUX_GPU"
    export OMNIVOICE_HOST=0.0.0.0
    export OMNIVOICE_PORT="$TTS_PORT"
    export OMNIVOICE_DEVICE=cuda
    exec "$OMNIVOICE_PY" impl/server_omnivoice.py
) > "$HOME/tts_server_${SLURM_JOB_ID}.log" 2>&1 &

echo "Starting whisper-fastapi STT on $NODE_HOST:$STT_PORT (GPU $AUX_GPU)"
(
    cd "$WHISPER_DIR"
    export CUDA_VISIBLE_DEVICES="$AUX_GPU"
    exec "$WHISPER_PY" whisper_fastapi.py \
        --host 0.0.0.0 --port "$STT_PORT" --model "$WHISPER_MODEL" --device cuda
) > "$HOME/stt_server_${SLURM_JOB_ID}.log" 2>&1 &

echo "Starting llama-server on $NODE_HOST:$LLM_PORT (GPU $LLM_GPU)"
export CUDA_VISIBLE_DEVICES="$LLM_GPU"
exec "$LLAMA_BIN" \
    -m "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port "$LLM_PORT" \
    --cors-origins localhost \
    -ngl 999 \
    --tensor-split 1

