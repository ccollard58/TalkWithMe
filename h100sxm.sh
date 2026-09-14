#!/bin/bash
#SBATCH --job-name=ollama
#SBATCH --output=ollama_serve_%j.out
#SBATCH --error=ollama_serve_%j.err
#SBATCH --partition=gpu-h100sxm
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=32
#SBATCH --gpus-per-task=2
#SBATCH --time=72:00:00

# Load necessary modules or set up environment
module load cuda12.8/toolkit/12.8.1

srun hostname

# Set Ollama to listen on all interfaces
export OLLAMA_HOST=0.0.0.0
echo $OLLAMA_HOST

# Execute the ollama serve command
exec ollama serve
