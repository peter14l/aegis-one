# Aegis-One: Hyper-Hybrid Tiered Memory Controller Specification

## 1. System Overview
Aegis-One is an enterprise-grade synthesizable memory controller IP bridging a low-latency Tier-0 DRAM cache (LPDDR5/DDR4) with a high-capacity Tier-1 non-volatile backing store (ONFI 4.2 NAND / eMMC) behind a standard CXL Type 3 / AXI4-MM host interface.

```
                      +---------------------------------------+
                      |       AXI4-MM Host Interface          |
                      |    (64-bit Addr, 512-bit Data)        |
                      +-------------------+-------------------+
                                          |
                      +-------------------v-------------------+
                      |      Aegis-One Top Crossbar & MPU     |
                      +---------+-------------------+---------+
                                |                   |
            +-------------------v---+   +-----------v-------------------+
            |  Tag Directory (BRAM) |   | Write-Coalescing Dirty Buffer |
            |  1-Cycle Hit Bypass   |   | (Sub-page 64B write absorber) |
            +-----------+-----------+   +-----------+-------------------+
                        |                           |
            +-----------v-----------+   +-----------v-------------------+
            |   Tier-0 DRAM Cache   |   | Hardware LZ4 Decompressor &   |
            |   (LPDDR5 / DDR4)     |   | Log-Structured FTL Engine     |
            +-----------------------+   +-----------+-------------------+
                                                    |
                                        +-----------v-------------------+
                                        |    Tier-1 ONFI 4.2 NV-DDR3    |
                                        +-------------------------------+
```

## 2. Core Timing & Bus Architecture
- **Core Clock**: 400 MHz nominal operational frequency ($T_{\text{clk}} = 2.5\text{ ns}$).
- **Internal Data Path**: 512-bit synchronous data bus (64 bytes/cycle; line-rate throughput: 25.6 GB/s).
- **Page Granularity**: 4096-byte (4KB) physical migration and decompression frame.
- **Cache Line Granularity**: 64 bytes (matching single-cycle 512-bit transfer).
- **Host Address Space**: 64-bit byte-addressed Host Physical Address (HPA).
  - Bits [5:0]: Byte Offset within 64-byte Cache Line.
  - Bits [11:6]: Line Index within 4KB Page (64 lines/page).
  - Bits [63:12]: 4KB Physical Page Frame Number (PFN).

## 3. Tiering & Cache Management Subsystems

### 3.1 BRAM Tag Directory
- **Topology**: Parameterized 4-way set-associative or direct-mapped dual-port Block RAM (UltraScale+ RAMB36 primitives).
- **Latency**: 1 clock cycle hit detection and tag query latency for direct bypass to Tier-0 DRAM.
- **Entry Metadata**: Valid (1b), Dirty (1b), Access Frequency (4b), Tier-0 PFN (24b), LRU age bits (2b/way).

### 3.2 In-DRAM Write-Coalescing Dirty Buffer
- Absorbs random high-frequency 64B sub-page host writes to prevent NAND write amplification.
- Coalesces modified 64B lines into contiguous 4KB pages and bundles migrations into 64KB–128KB erase-block-aligned sequential write bursts.
- Hardware CLOCK / pseudo-LRU candidate selection for deterministic page eviction and writeback.

### 3.3 Hardware Log-Structured FTL Engine
- Log-structured append-only allocation avoiding in-place NAND overwrites.
- Hardware-managed Translation Table (L2P) with dual-bank journal for atomic crash-consistent updates.
- Real-time wear-leveling monitoring per physical block with bad-block remapping counters.

### 3.4 8-Lane Pipelined LZ4 Hardware Decompressor
- **Architecture**: 8 independent 64-bit parsing lanes executing parallel token parsing and literal/match copy.
- **Throughput**: 64 bytes/cycle sustained decompressed output (25.6 GB/s at 400 MHz).
- **Latency**: Under 50 ns (20 clock cycles) from first Tier-1 token arrival to first decompressed 64B word delivered to host/Tier-0.
