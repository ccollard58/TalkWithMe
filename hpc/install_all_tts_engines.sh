#!/bin/bash
set -Eeuo pipefail

# Install all non-OmniVoice TTS engines used by start_all_tts_engines.sh.
#
# Each engine gets its own directory and virtual environment, as required by
# tts-serve.  The script is intentionally idempotent: existing clones/venvs
# are reused and dependencies are updated rather than blindly recreated.
#
# Target environment: Linux GPU node, NVIDIA/CUDA, Python 3.11.x module.
#
# By default this installs:
#   Chatterbox       -> $HOME/Chatterbox
#   Qwen3-TTS        -> $HOME/Qwen3TTS
#   Faster Qwen3-TTS -> $HOME/faster-Qwen3TTS
#   dots.tts         -> $HOME/dots.tts
#   Index-TTS        -> $HOME/index-tts
#   LuxTTS           -> $HOME/LuxTTS
#
# Qwen3-TTS (MLX) is deliberately NOT installed because it is Apple-Silicon
# only and is disabled in the supplied start_all_tts_engines.sh.
#
# Environment variables:
#   TTS_INSTALL_ROOT  Base directory for all engine directories (default $HOME)
#   TTS_SERVE_REPO    tts-serve git URL
#   TTS_SERVE_BRANCH  tts-serve branch (default master)
#   SKIP_<ENGINE>=1   Skip one engine, e.g. SKIP_CHATTERBOX=1
#
# The script does not install OmniVoice because you said it is already present.

set -o pipefail

TTS_INSTALL_ROOT="${TTS_INSTALL_ROOT:-$HOME}"
TTS_SERVE_REPO="${TTS_SERVE_REPO:-https://github.com/scorbo2/tts-serve.git}"
TTS_SERVE_BRANCH="${TTS_SERVE_BRANCH:-master}"

PYTHON_BIN="${PYTHON_BIN:-python3}"

FAILED=()
INSTALLED=()
SKIPPED=()

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required but was not found."
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "$PYTHON_BIN was not found."

# Load environment modules when this is an HPC system using Environment Modules.
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
    # Match the modules used by start_all_tts_engines.sh.
    module load cuda13.0/toolkit/13.0.2 || warn "Could not load cuda13.0/toolkit/13.0.2"
    module load python/3.11.10 || warn "Could not load python/3.11.10"
fi

command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "Python is not available after loading modules."

PY_VER="$("$PYTHON_BIN" -c 'import sys; print(".".join(map(str,sys.version_info[:3])))')"
log "Using Python $PY_VER"
"$PYTHON_BIN" -m pip --version >/dev/null 2>&1 || die "pip is not available for $PYTHON_BIN."

# We use the exact tts-serve dependency installation prescribed by its
# engine-specific installation documents.
install_tts_serve() {
    local engine_dir="$1"

    if [[ -d "$engine_dir/tts-serve/.git" ]]; then
        log "Updating tts-serve in $engine_dir"
        git -C "$engine_dir/tts-serve" fetch --quiet origin "$TTS_SERVE_BRANCH"
        git -C "$engine_dir/tts-serve" checkout -q "$TTS_SERVE_BRANCH"
        git -C "$engine_dir/tts-serve" pull --ff-only
    elif [[ -e "$engine_dir/tts-serve" ]]; then
        die "$engine_dir/tts-serve exists but is not a git checkout."
    else
        log "Cloning tts-serve into $engine_dir"
        git clone --branch "$TTS_SERVE_BRANCH" "$TTS_SERVE_REPO" "$engine_dir/tts-serve"
    fi

    "$engine_dir/.venv/bin/python" -m pip install -U pip
    "$engine_dir/.venv/bin/python" -m pip install \
        "$engine_dir/tts-serve/tts-engine-common" \
        fastapi uvicorn loguru soundfile
}

ensure_venv() {
    local dir="$1"
    if [[ ! -x "$dir/.venv/bin/python" ]]; then
        log "Creating virtual environment in $dir/.venv"
        mkdir -p "$dir"
        "$PYTHON_BIN" -m venv "$dir/.venv"
    fi
}

run_engine() {
    local key="$1"
    shift

    local skip_var="SKIP_${key}"
    if [[ "${!skip_var:-0}" == "1" ]]; then
        echo "Skipping $key (${skip_var}=1)"
        SKIPPED+=("$key")
        return 0
    fi

    if "$@"; then
        INSTALLED+=("$key")
        return 0
    else
        warn "$key installation failed. Continuing with the other engines."
        FAILED+=("$key")
        return 0
    fi
}

install_chatterbox() {
    local dir="$TTS_INSTALL_ROOT/Chatterbox"
    log "Installing Chatterbox -> $dir"
    mkdir -p "$dir"
    ensure_venv "$dir"

    "$dir/.venv/bin/python" -m pip install -U pip
    "$dir/.venv/bin/python" -m pip install -U chatterbox-tts

    install_tts_serve "$dir"

    test -f "$dir/tts-serve/impl/server_chatterbox.py"
    echo "Chatterbox installation complete."
}

install_qwen3tts() {
    local dir="$TTS_INSTALL_ROOT/Qwen3TTS"
    log "Installing Qwen3-TTS -> $dir"
    mkdir -p "$dir"
    ensure_venv "$dir"

    "$dir/.venv/bin/python" -m pip install -U pip
    "$dir/.venv/bin/python" -m pip install -U qwen-tts

    install_tts_serve "$dir"

    test -f "$dir/tts-serve/impl/server_qwen3TTS.py"
    echo "Qwen3-TTS installation complete."
}

install_faster_qwen3tts() {
    local dir="$TTS_INSTALL_ROOT/faster-Qwen3TTS"
    log "Installing Faster Qwen3-TTS -> $dir"
    mkdir -p "$dir"
    ensure_venv "$dir"

    "$dir/.venv/bin/python" -m pip install -U pip
    "$dir/.venv/bin/python" -m pip install -U faster-qwen3-tts

    install_tts_serve "$dir"

    test -f "$dir/tts-serve/impl/server_fasterQwen3TTS.py"
    echo "Faster Qwen3-TTS installation complete."
}

install_dots_tts() {
    local dir="$TTS_INSTALL_ROOT/dots.tts"
    log "Installing dots.tts -> $dir"
    mkdir -p "$dir"
    ensure_venv "$dir"

    "$dir/.venv/bin/python" -m pip install -U pip
    "$dir/.venv/bin/python" -m pip install -U dots.tts

    install_tts_serve "$dir"

    test -f "$dir/tts-serve/impl/server_dotsTTS.py"
    echo "dots.tts installation complete."
}

install_index_tts() {
    local dir="$TTS_INSTALL_ROOT/index-tts"
    log "Installing Index-TTS -> $dir"

    command -v uv >/dev/null 2>&1 || {
        warn "uv is required by the current Index-TTS installation instructions."
        warn "Install uv first (for example: $PYTHON_BIN -m pip install -U uv), then rerun."
        return 1
    }

    mkdir -p "$TTS_INSTALL_ROOT"

    if [[ -d "$dir/.git" ]]; then
        log "Updating Index-TTS checkout"
        git -C "$dir" fetch --quiet origin
        git -C "$dir" pull --ff-only
    elif [[ -e "$dir" ]]; then
        die "$dir exists but is not an Index-TTS git checkout."
    else
        git clone https://github.com/index-tts/index-tts.git "$dir"
    fi

    cd "$dir"
    uv sync --all-extras

    # The current tts-serve instructions put the tts-serve checkout inside
    # index-tts and use the Index-TTS .venv created by uv.
    install_tts_serve "$dir"

    test -f "$dir/tts-serve/impl/server_indexTTS.py"
    echo "Index-TTS installation complete."
}

install_luxtts() {
    local dir="$TTS_INSTALL_ROOT/LuxTTS"
    log "Installing LuxTTS -> $dir"
    mkdir -p "$dir"

    if [[ -d "$dir/LuxTTS/.git" ]]; then
        log "Updating LuxTTS checkout"
        git -C "$dir/LuxTTS" pull --ff-only
    elif [[ -e "$dir/LuxTTS" ]]; then
        die "$dir/LuxTTS exists but is not a LuxTTS git checkout."
    else
        git clone https://github.com/ysharma3501/LuxTTS.git "$dir/LuxTTS"
    fi

    # tts-serve's LuxTTS layout expects .venv at $HOME/LuxTTS/.venv and the
    # upstream LuxTTS repository below it.
    ensure_venv "$dir"

    "$dir/.venv/bin/python" -m pip install -U pip

    cd "$dir/LuxTTS"
    "$dir/.venv/bin/python" -m pip install -r requirements.txt
    "$dir/.venv/bin/python" -m pip install . --no-deps

    install_tts_serve "$dir"

    test -f "$dir/tts-serve/impl/server_luxTTS.py"
    echo "LuxTTS installation complete."
}

# Index-TTS uses uv. Installing uv here is harmless if it already exists and
# avoids making the user perform an extra manual step.
if ! command -v uv >/dev/null 2>&1; then
    log "Installing uv (needed by Index-TTS)"
    "$PYTHON_BIN" -m pip install -U uv
fi

run_engine CHATTERBOX install_chatterbox
run_engine QWEN3TTS install_qwen3tts
run_engine FASTER_QWEN3TTS install_faster_qwen3tts
run_engine DOTS_TTS install_dots_tts
run_engine INDEXTTS install_index_tts
run_engine LUX_TTS install_luxtts

log "Installation summary"

if ((${#INSTALLED[@]})); then
    echo "Installed/updated:"
    printf '  %s\n' "${INSTALLED[@]}"
fi

if ((${#SKIPPED[@]})); then
    echo "Skipped:"
    printf '  %s\n' "${SKIPPED[@]}"
fi

if ((${#FAILED[@]})); then
    echo "FAILED:"
    printf '  %s\n' "${FAILED[@]}"
    echo
    echo "The failed engines were left in place so you can inspect/re-run them."
    exit 1
fi

cat <<EOF

All requested non-OmniVoice engines are installed.

Expected directories:
  $TTS_INSTALL_ROOT/Chatterbox
  $TTS_INSTALL_ROOT/Qwen3TTS
  $TTS_INSTALL_ROOT/faster-Qwen3TTS
  $TTS_INSTALL_ROOT/dots.tts
  $TTS_INSTALL_ROOT/index-tts
  $TTS_INSTALL_ROOT/LuxTTS

The first time each server is started, its model may be downloaded from
Hugging Face. Your start_all_tts_engines.sh will then find the corresponding
.venv/bin/python and impl/server_*.py files.

IMPORTANT:
  Your start_all_tts_engines.sh starts every enabled engine concurrently.
  That can exceed GPU VRAM. Consider enabling/testing them one at a time
  initially, especially Chatterbox, Qwen3-TTS, Faster Qwen3-TTS, Index-TTS,
  and LuxTTS.

Qwen3-TTS (MLX) was intentionally not installed because it is Apple-Silicon
only and your startup script disables it by default.
EOF
