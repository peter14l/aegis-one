#!/usr/bin/env bash
# ============================================================================
# Script: scripts/sim.sh
# Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
# Description: Compiles and runs cycle-accurate Verilator C++ simulation in RAM
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RAM_BASE="/dev/shm"
if [ ! -d "${RAM_BASE}" ]; then
  RAM_BASE="/tmp"
fi

VBUILD_DIR="${RAM_BASE}/aegis_vbuild_$$"
mkdir -p "${VBUILD_DIR}"
trap 'rm -rf "${VBUILD_DIR}"' EXIT

cd "${REPO_ROOT}"

echo "==> [Aegis-One] Building cycle-accurate simulation in RAM (${VBUILD_DIR})..."

NPROC=$(nproc 2>/dev/null || echo 4)

verilator --cc --exe -O3 --build -j "${NPROC}" \
  -Mdir "${VBUILD_DIR}" \
  -Wall -Wno-MULTITOP \
  --top-module aegis_top \
  docs/01_INTERFACES.sv rtl/*.sv rtl/core/*.sv tb/tb_top.cpp

echo "==> [Aegis-One] Executing regression binary..."
"${VBUILD_DIR}/Vaegis_top"
