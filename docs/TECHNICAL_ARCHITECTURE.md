# Aegis-One: Deep Technical Architecture & Silicon Specification

This document contains in-depth silicon engineering details, protocol breakdowns, and register/pipeline specifications for the Aegis-One Memory Controller IP.

---

## 1. System Interconnect & Frequency Specifications

- **Target Operational Frequency**: 400 MHz ($T_{\text{clk}} = 2.5\text{ ns}$).
- **Internal Synchronous Datapath**: 512-bit width (64 bytes/cycle; sustained line-rate: 25.6 GB/s).
- **Physical Migration Granularity**: 4096-byte (4KB) frames.
- **Cache Line Granularity**: 64 bytes (single-cycle 512-bit transfer).
- **Host Address Mapping**: 64-bit Host Physical Address (HPA):
  - `HPA[5:0]`: Byte offset within 64-byte line (6 bits).
  - `HPA[11:6]`: Cache line index within 4KB page (6 bits, 64 lines/page).
  - `HPA[63:12]`: 4KB Page Frame Number (52 bits).

---

## 2. Core Subsystems

### 2.1 BRAM Tag Directory (`rtl/core/tag_directory.sv`)
- **Structure**: 4-way set-associative dual-port Block RAM (`NUM_SETS = 1024`, 4096 total page slots).
- **Lookup Latency**: 1 clock cycle.
- **Replacement Policy**: 3-bit Tree Pseudo-LRU (Tree-PLRU) per set:
  - $b_0$: points to left pair {0, 1} vs right pair {2, 3}.
  - $b_1$: points to way 0 vs way 1.
  - $b_2$: points to way 2 vs way 3.
- **Entry Bitfield (72 bits total)**:
  - `valid` [1b]
  - `dirty` [1b]
  - `access_count` [4b]
  - `t0_pfn` [24b]
  - `tag` [42b]

### 2.2 In-DRAM Write-Coalescing Buffer (`rtl/core/write_coalescing_buffer.sv`)
- **Capacity**: 8 active page frames (512 cache lines = 32 KB total buffer storage).
- **Mask Tracking**: 64-bit dirty mask per slot; sets bit `wr_line_idx` on sub-page writes.
- **Flush Triggers**: Full page dirty (`&mask == 1`), age threshold (`MAX_AGE = 128` cycles), or explicit flush request.
- **Hardware Primitives**: 8 Xilinx UltraScale+ RAMB36E2 Block RAMs.

### 2.3 8-Lane Parallel LZ4 Decompressor (`rtl/core/lz4_decompressor.sv`)
- **Throughput**: 64 bytes/cycle sustained decompressed output.
- **Latency**: <50 ns (<20 cycles) from token arrival to first decompressed word.
- **History Memory**: 4KB dual-port cyclic BRAM holding the active sliding window for back-references.

### 2.4 Hardware Log-Structured FTL (`rtl/core/ftl_engine.sv`)
- **Architecture**: Append-only log allocator avoiding in-place NAND overwrites.
- **L2P Translation Table**: 1024 entries mapping Host PFN to physical NAND block (32-bit) and page (16-bit).
- **Atomic Journaling**: Dual-bank ping-pong journal with monotonic sequence numbers for transaction consistency.
- **Wear Leveling**: Dedicated per-block erase cycle counter array.

### 2.5 CXL Type 3 Protocol Adapter (`rtl/cxl/cxl_type3_bridge.sv`)
- **Protocol**: CXL.mem M2S (Master to Subordinate) and S2M (Subordinate to Master).
- **Flit Conversion**: Translates `MemRd` and `MemWr` into standard 512-bit AXI4-MM transactions with 16-entry tag tracking FIFO.

---

## 3. FPGA Resource Utilization (Xilinx UltraScale+ `xcup`)

Synthesized with Yosys Open SYnthesis Suite (`synth_xilinx -family xcup -top aegis_top`):

| Primitive | Quantity | Purpose |
| :--- | :---: | :--- |
| **RAMB36E2** | 9 | Tag Directory, Write Buffer, LZ4 History |
| **RAM64M8** | 10 | FTL Wear Counters & L2P LUTRAM |
| **FDRE / Registers** | 2,709 | Pipeline registers, FSMs, telemetry |
| **LUT (LUT1–LUT6)** | 6,207 | Hit detection, priority encoders, muxes |
| **CARRY4** | 72 | Arithmetic counters and age timers |
