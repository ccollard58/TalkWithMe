#!/bin/bash
# Builds llama.cpp with CUDA support. Run this once on the head node before
# submitting the SLURM job — GPU compute nodes have no git/cmake/compiler.
# Safe to re-run: skips the build if llama-server already exists with the same
# compiler and CUDA architectures; otherwise wipes and rebuilds.
set -e

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$HOME/llama.cpp}"
JOBS="${JOBS:-4}"

module load module-git
module load gcc/13.1.0
module load cuda13.0/toolkit/13.0.2
module load cuda13.0/blas/13.0.2
module load cuda13.0/fft/13.0.2
module load cuda13.0/nsight/13.0.2
module load cuda13.0/profiler/13.0.2
module load cmake/3.30.0

# CUDA and the host linker must use the same libstdc++ ABI.  Without these
# explicit paths, CMake may select the system GCC 11 while nvcc uses GCC 13,
# which produces GLIBCXX_3.4.30 link errors in the CUDA shared library.
CC="$(command -v gcc)"
CXX="$(command -v g++)"
if [ -z "$CC" ] || [ -z "$CXX" ]; then
    echo "GCC 13.1.0 was not found after loading its module" >&2
    exit 1
fi
if [[ "$($CXX -dumpfullversion -dumpversion)" != 13.1.* ]]; then
    echo "Expected GCC 13.1.x, found $($CXX --version | head -n 1)" >&2
    exit 1
fi
export CC CXX

if [ ! -d "$LLAMA_CPP_DIR" ]; then
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_CPP_DIR"
fi

BUILD_DIR="$LLAMA_CPP_DIR/build"
# 89 = Ada Lovelace (L40S), 90 = Hopper (H100/H200). The job may land on either
# partition, so both kernel images must be baked into the same binary — a build
# with only one arch fails at runtime on the other with "no kernel image is
# available for execution on the device" (CUDA_ARCHITECTURES is not a substring
# match, so a stale single-arch build must be wiped, not just a compiler change).
CUDA_ARCHITECTURES="89;90"
if [ -f "$BUILD_DIR/CMakeCache.txt" ] && { ! grep -Eq "^CMAKE_CXX_COMPILER:(FILEPATH|STRING)=$CXX$" "$BUILD_DIR/CMakeCache.txt" || ! grep -Eq "^CMAKE_CUDA_ARCHITECTURES:STRING=$CUDA_ARCHITECTURES$" "$BUILD_DIR/CMakeCache.txt"; }; then
    echo "Removing stale build configured with a different C++ compiler or CUDA architectures"
    rm -rf "$BUILD_DIR"
elif [ -x "$LLAMA_CPP_DIR/build/bin/llama-server" ]; then
    echo "llama-server already built at $LLAMA_CPP_DIR/build/bin/llama-server, skipping"
    exit 0
fi

# GGML_NATIVE=OFF: the head node's binutils is older than the loaded GCC and
# can't assemble the AVX512-VNNI instructions -march=native would emit.
# JOBS is capped (not nproc) because nvcc/cc1plus are memory-hungry and this
# is a shared head node, not the dedicated GPU compute node.
cmake -S "$LLAMA_CPP_DIR" -B "$BUILD_DIR" \
    -DGGML_CUDA=ON \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_CUDA_HOST_COMPILER="$CXX" \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHITECTURES" \
    -DGGML_NATIVE=OFF
cmake --build "$BUILD_DIR" --config Release -j"$JOBS"
