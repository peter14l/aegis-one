#!/usr/bin/env bash
# ============================================================================
# File: scripts/synth_xilinx.sh
# Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
# Description: Synthesizes Aegis-One for AMD/Xilinx UltraScale+ in RAM
# ============================================================================

set -euo pipefail

SHM_DIR="${SHM_DIR:-/dev/shm/aegis_synth}"
mkdir -p "$SHM_DIR"

echo "==> [Aegis-One] Running Yosys UltraScale+ logic synthesis in RAM..."
yosys -p "
  read_verilog -sv docs/01_INTERFACES.sv rtl/core/*.sv rtl/*.sv;
  synth_xilinx -family xcup -top aegis_top;
  check -assert;
  stat;
" > "$SHM_DIR/synth.log" 2>&1

echo "============================================================"
echo "          Aegis-One UltraScale+ Synthesis Report"
echo "============================================================"
grep -A 20 "=== aegis_top ===" "$SHM_DIR/synth.log" | tail -n 20 || true
echo "============================================================"
echo "Synthesis complete. Clean UltraScale+ mapping confirmed."
