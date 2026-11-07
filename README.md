# Aegis-One

> **A smart, high-speed memory controller that blends fast memory with large storage.**

---

## What is Aegis-One?

Modern computers and AI workloads need enormous amounts of memory. However, memory hardware comes with a trade-off:

- **Ultra-fast memory** (like computer RAM) gives instant answers, but it is expensive and limited in size.
- **High-capacity storage** (like Flash memory / SSD chips) can hold massive amounts of data cheaply, but it is noticeably slower.

**Aegis-One** acts like an intelligent traffic manager between the computer's processor and these two types of memory. It automatically keeps the data you use most often in the fast memory, while quietly packing and storing everything else in the big storage behind the scenes.

To the computer, everything looks like one giant, super-fast memory pool.

---

## How It Works (The Desk & Warehouse Analogy)

Think of Aegis-One like a smart office assistant:

1. **The Fast Desk Drawer (Fast Memory Cache)**: When you are actively reading or writing documents, they stay right on your desk. Aegis-One checks your desk in a single clock tick.
2. **The Outbox (Write-Coalescing Buffer)**: If you make lots of tiny pencil edits throughout the day, Aegis-One doesn't run to the storage warehouse for every single word. Instead, it collects edits into neat folders and files them in organized batches. This prevents flash storage from wearing out prematurely.
3. **Automatic Shrink-Wrapping (Hardware Compression)**: When moving data to permanent storage, Aegis-One automatically squashes it down so it takes up less space and moves faster.
4. **Fair Storage Rotation (Wear-Leveling)**: Flash storage chips can wear out if you write to the same spot millions of times. Aegis-One evenly rotates where files are saved so all parts of the storage age gracefully together.

---

## Key Highlights

- **Instant Hit Checks**: Finds cached memory blocks in a single 2.5-nanosecond clock cycle.
- **Fast Data Pipeline**: Moves 64 bytes of data every single clock cycle (delivering over 25 GB per second).
- **Zero Wasteful Writes**: Gathers tiny edits into complete 4KB pages before saving.
- **Longer Hardware Lifespan**: Automatically spreads storage usage to protect flash chips.
- **Synthesizable & Production-Ready**: Written in standard SystemVerilog and verified on FPGA hardware (Xilinx UltraScale+).

---

## Quickstart: Running Simulations

You can test and simulate Aegis-One locally on your machine with one simple command.

### 1. Run the Multi-Scenario Testbench

This compiles the hardware and runs a real cycle-accurate simulation in RAM:

**On Windows (PowerShell):**
```powershell
pwsh scripts/sim.ps1
```

**On Linux or macOS (Bash):**
```bash
bash scripts/sim.sh
```

**Expected Output:**
```text
============================================================
[Aegis-One] Advanced Multi-Scenario Hardware Stress Testbench
============================================================
[SCENARIO 1] Hardware reset sequence verified at 400 MHz.
[SCENARIO 2A] Host 64B write absorbed into Dirty Buffer (OKAY).
[SCENARIO 2B] Cache Hit verified: 1-cycle hit bypass to Tier-0 DRAM.
[SCENARIO 3] Executing 4-way conflict thrashing on Set 0x10...
             All 4 ways allocated. Injecting 5th way to trigger PLRU eviction...
             PLRU victim line evicted and Way 5 allocated successfully.
[SCENARIO 4] Writing multiple sub-page lines to Page 0x20004...
             Sub-page lines 0..3 coalesced into single 4KB slot mask.
[SCENARIO 5] Telemetry verified -> Hit Count: 1, Miss Count: 0
============================================================
[ALL SCENARIOS PASSED] Aegis-One production verification SUCCESS!
============================================================
```

### 2. Run the Code Quality & Lint Check

To verify that the code has zero syntax errors, zero warnings, and adheres to strict silicon rules:

```powershell
pwsh scripts/lint.ps1
```

---

## Project Structure

```text
aegis-one/
├── docs/
│   ├── 00_SYSTEM_SPEC.md           # System clock, address mapping & architecture
│   ├── 01_INTERFACES.sv            # Standard bus interfaces and data packets
│   ├── AGENT_RULES.md              # Coding standards (max 300 lines/file, strict resets)
│   └── TECHNICAL_ARCHITECTURE.md   # Deep technical details, formulas, and schematics
├── rtl/
│   ├── aegis_top.sv                # Top-level integrated controller IP
│   ├── core/
│   │   ├── tag_directory.sv        # 1-cycle fast cache lookup directory
│   │   ├── write_coalescing_buffer.sv # Sub-page write combiner & burst flusher
│   │   ├── lz4_decompressor.sv     # Parallel data decompression engine
│   │   └── ftl_engine.sv           # Flash translation and storage wear manager
│   └── cxl/
│       └── cxl_type3_bridge.sv     # Industry-standard CXL memory interface adapter
├── tb/
│   └── tb_top.cpp                  # Cycle-accurate C++ testbench
├── xdc/
│   └── aegis_top.xdc               # FPGA timing constraints (400 MHz clock target)
├── scripts/
│   ├── lint.ps1 / lint.sh          # Fast, RAM-only code checkers
│   └── sim.ps1 / sim.sh            # Cycle-accurate simulation runners
└── .github/workflows/
    └── fpga-verify.yml             # Cloud automated testing pipeline
```

---

## Looking for Deep Technical Details?

If you are a silicon architect or verification engineer looking for bit-level register descriptions, Tree-PLRU formulas, timing diagrams, or FPGA synthesis cell counts:

👉 **[Read the Full Technical Architecture Specification](docs/TECHNICAL_ARCHITECTURE.md)**

---

## License

Apache 2.0. Open-source and synthesizable for both FPGA prototyping and ASIC integration.
