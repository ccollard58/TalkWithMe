#!/bin/bash
# Sets up OmniVoice (TTS) and whisper-fastapi (STT) venvs. Run this once on
# the head node before submitting the SLURM job. Safe to re-run: skips
# whichever venv already exists.
set -e

OMNIVOICE_DIR="${OMNIVOICE_DIR:-$HOME/OmniVoice}"
WHISPER_DIR="${WHISPER_DIR:-$HOME/whisper-fastapi}"

module load module-git
module load gcc/13.1.0
module load cuda13.0/toolkit/13.0.2
module load cuda13.0/blas/13.0.2
module load cuda13.0/fft/13.0.2
module load cuda13.0/nsight/13.0.2
module load cuda13.0/profiler/13.0.2
module load cmake/3.30.0
module load python/3.11.10

if [ -x "$OMNIVOICE_DIR/.venv/bin/python" ]; then
    echo "OmniVoice venv already set up at $OMNIVOICE_DIR, skipping"
else
    mkdir -p "$OMNIVOICE_DIR"
    cd "$OMNIVOICE_DIR"
    python3.11 -m venv .venv
    . .venv/bin/activate
    pip install omnivoice
    if [ ! -d tts-serve ]; then
        git clone https://github.com/scorbo2/tts-serve
    fi
    cd tts-serve
    pip install ./tts-engine-common fastapi uvicorn loguru soundfile
    deactivate
fi

if [ -x "$WHISPER_DIR/.venv/bin/python" ]; then
    echo "whisper-fastapi venv already set up at $WHISPER_DIR, skipping"
else
    if [ ! -d "$WHISPER_DIR" ]; then
        git clone https://github.com/heimoshuiyu/whisper-fastapi.git "$WHISPER_DIR"
    fi
    cd "$WHISPER_DIR"
    python3.11 -m venv .venv
    . .venv/bin/activate
    pip install -r requirements.txt
    deactivate
fi
