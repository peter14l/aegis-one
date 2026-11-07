#!/usr/bin/env bash
# ============================================================================
# Script: scripts/lint.sh
# Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
# Description: RAM-only Verilator lint runner for zero disk wear
# ============================================================================

set -euo pipefail

# Locate repository root relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Target RAM filesystem for build output
RAM_BASE="/dev/shm"
if [ ! -d "${RAM_BASE}" ]; then
  RAM_BASE="/tmp"
fi

VLINT_DIR="${RAM_BASE}/aegis_vlint_$$"
mkdir -p "${VLINT_DIR}"
trap 'rm -rf "${VLINT_DIR}"' EXIT

cd "${REPO_ROOT}"

# Enable recursive globbing
shopt -s globstar nullglob

# Collect synthesizable source files
FILES=("docs/01_INTERFACES.sv")
if [ -d "rtl" ]; then
  FILES+=(rtl/**/*.sv)
fi

echo "==> [Aegis-One] Running Verilator lint in RAM (${VLINT_DIR})..."
echo "==> Files under analysis: ${FILES[*]}"

verilator --lint-only -Wall -Wno-MULTITOP --timing -Mdir "${VLINT_DIR}" "${FILES[@]}"

echo "==> [Aegis-One] Lint clean. Zero warnings, zero errors."
