# Aegis-One Agent & Architecture Engineering Rules

## 1. Strict Engineering Principles
- **Zero Fake Logic**: All SystemVerilog code must be fully synthesizable IEEE 1800-2017 RTL. No placeholders, stubs, behavioral delays (`#delay`), or unverified mock modules.
- **Atomic Generation**: Exactly one module per prompt/file. Every individual source file must remain strictly under 300 lines of code.
- **Synchronous Resets**: All sequential logic must use synchronous active-low resets (`rst_n`) clocked on the rising edge of `clk`. No asynchronous reset topologies.
- **Backpressure & Handshakes**: All inter-module streaming data paths must implement strict AXI4 / Ready-Valid handshakes (`valid && ready`). Data words must remain stable whenever `valid` is asserted and `ready` is deasserted.
- **Zero Inferred Latches**: Every `unique case` or `priority case` must be fully specified or include a `default` assignment. In combinational `always_comb` blocks, all outputs must be assigned default values at the top of the block.

## 2. Resource & Disk Management
- **RAM-Only Temporary Artifacts**: All compilation artifacts, intermediate C++ models, and object files must reside in RAM:
  - Linux/WSL: `/dev/shm/vlint` or `/dev/shm/vbuild`
  - Windows Native: `$env:TEMP\vlint` (or RAM drive when configured)
- **Zero Waveform Dumps**: Local verification must never emit `.vcd` or `.fst` trace dumps unless explicitly requested for debugging an isolated cycle failure.
- **Lightweight Checkouts**: Git state and scratch logs must not pollute persistent physical SSD storage.

## 3. Lint & Synthesis Commands
- **Local Verilator Lint (Linux / WSL / RAM-disk)**:
  ```bash
  mkdir -p /dev/shm/vlint
  verilator --lint-only -Wall --timing -Mdir /dev/shm/vlint docs/01_INTERFACES.sv rtl/**/*.sv
  ```
- **Local Windows Fallback (PowerShell)**:
  ```powershell
  $vdir = Join-Path $env:TEMP "vlint"
  New-Item -ItemType Directory -Force -Path $vdir | Out-Null
  verilator --lint-only -Wall --timing -Mdir $vdir docs/01_INTERFACES.sv rtl/**/*.sv
  ```
- **Cloud FPGA Gate-Level & Logic Check (Yosys UltraScale+)**:
  ```bash
  yosys -p "read_verilog -sv docs/01_INTERFACES.sv rtl/**/*.sv; synth_xilinx -family xcup -top aegis_top; check -assert"
  ```
