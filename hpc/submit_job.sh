#!/bin/bash
# Submits llama_server.slurm (must be uploaded alongside this script).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sbatch "$SCRIPT_DIR/llama_server.slurm"
