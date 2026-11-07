// ============================================================================
// File: docs/01_INTERFACES.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Core interface definitions, control signals, and packed metadata
// ============================================================================

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off PINCONNECTEMPTY */

`ifndef AEGIS_INTERFACES_SV
`define AEGIS_INTERFACES_SV

`timescale 1ns / 1ps

package aegis_pkg;

  // Tiering commands and memory operation opcodes
  typedef enum logic [3:0] {
    TIER_CMD_NOP        = 4'h0,
    TIER_CMD_READ       = 4'h1,
    TIER_CMD_WRITE      = 4'h2,
    TIER_CMD_EVICT      = 4'h3,
    TIER_CMD_MIGRATE_T0 = 4'h4,
    TIER_CMD_MIGRATE_T1 = 4'h5,
    TIER_CMD_ERASE_BLK  = 4'h6,
    TIER_CMD_FLUSH      = 4'h7
  } tier_opcode_e;

  // Packed command descriptor between controller modules
  typedef struct packed {
    logic [7:0]         cmd_id;
    tier_opcode_e       opcode;
    logic [51:0]        host_pfn;       // Host 4KB Page Frame Number (64b - 12b)
    logic [23:0]        t0_pfn;         // Tier-0 DRAM Page Frame Number
    logic [31:0]        t1_block_addr;  // Tier-1 Physical Block Address
    logic [15:0]        byte_len;       // Transfer size in bytes
    logic [7:0]         tag;            // Request transaction context tag
  } tier_cmd_t;

  // Packed page metadata descriptor for Tag Directory and FTL tracking
  typedef struct packed {
    logic [51:0]        page_tag;       // Host PFN tag (HPA[63:12])
    logic               valid;          // Page presence in Tier-0
    logic               dirty;          // Page modified in Tier-0
    logic [3:0]         access_count;   // Frequency counter for eviction
    logic [12:0]        compressed_size;// LZ4 payload size (0 to 4096 bytes)
    logic [31:0]        t1_block_addr;  // Tier-1 backing store physical block
    logic [15:0]        t1_page_idx;    // Page index within physical block
    logic [31:0]        wear_count;     // Physical block erase/wear counter
  } page_meta_t;

endpackage // aegis_pkg

// ----------------------------------------------------------------------------
// AXI4 Memory Mapped Interface
// Standard: ARM AMBA AXI4 (Full Memory Mapped)
// ----------------------------------------------------------------------------
interface axi4_mm_if #(
  parameter int unsigned ADDR_W = 64,
  parameter int unsigned DATA_W = 512,
  parameter int unsigned ID_W   = 8,
  parameter int unsigned STRB_W = DATA_W / 8
)(
  input logic aclk,
  input logic aresetn
);

  // Write Address Channel (AW)
  logic [ID_W-1:0]      awid;
  logic [ADDR_W-1:0]    awaddr;
  logic [7:0]           awlen;
  logic [2:0]           awsize;
  logic [1:0]           awburst;
  logic                 awlock;
  logic [3:0]           awcache;
  logic [2:0]           awprot;
  logic [3:0]           awqos;
  logic                 awvalid;
  logic                 awready;

  // Write Data Channel (W)
  logic [DATA_W-1:0]    wdata;
  logic [STRB_W-1:0]    wstrb;
  logic                 wlast;
  logic                 wvalid;
  logic                 wready;

  // Write Response Channel (B)
  logic [ID_W-1:0]      bid;
  logic [1:0]           bresp;
  logic                 bvalid;
  logic                 bready;

  // Read Address Channel (AR)
  logic [ID_W-1:0]      arid;
  logic [ADDR_W-1:0]    araddr;
  logic [7:0]           arlen;
  logic [2:0]           arsize;
  logic [1:0]           arburst;
  logic                 arlock;
  logic [3:0]           arcache;
  logic [2:0]           arprot;
  logic [3:0]           arqos;
  logic                 arvalid;
  logic                 arready;

  // Read Data Channel (R)
  logic [ID_W-1:0]      rid;
  logic [DATA_W-1:0]    rdata;
  logic [1:0]           rresp;
  logic                 rlast;
  logic                 rvalid;
  logic                 rready;

  // Master Modport
  modport master (
    input  aclk, aresetn,
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awvalid,
    input  awready,
    output wdata, wstrb, wlast, wvalid,
    input  wready,
    input  bid, bresp, bvalid,
    output bready,
    output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arvalid,
    input  arready,
    input  rid, rdata, rresp, rlast, rvalid,
    output rready
  );

  // Slave Modport
  modport slave (
    input  aclk, aresetn,
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awvalid,
    output awready,
    input  wdata, wstrb, wlast, wvalid,
    output wready,
    output bid, bresp, bvalid,
    input  bready,
    input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arvalid,
    output arready,
    output rid, rdata, rresp, rlast, rvalid,
    input  rready
  );

  // Passive Monitor Modport
  modport monitor (
    input aclk, aresetn,
    input awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awready, awvalid,
    input wdata, wstrb, wlast, wready, wvalid,
    input bid, bresp, bready, bvalid,
    input arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arready, arvalid,
    input rid, rdata, rresp, rlast, rready, rvalid
  );

endinterface // axi4_mm_if

// ----------------------------------------------------------------------------
// ONFI 4.2 Synchronous NV-DDR3 Interface
// Standard: Open NAND Flash Interface (ONFI) Specification 4.2
// ----------------------------------------------------------------------------
interface onfi_sync_if #(
  parameter int unsigned DQ_W = 8
)(
  input logic clk,
  input logic rst_n
);

  // Bidirectional split lines for synthesizable RTL model
  logic [DQ_W-1:0]      dq_out;
  logic [DQ_W-1:0]      dq_in;
  logic                 dq_oe;
  logic                 dqs_out;
  logic                 dqs_in;
  logic                 dqs_oe;

  // Single-ended control lines (active low indicated by _n)
  logic                 cle;    // Command Latch Enable
  logic                 ale;    // Address Latch Enable
  logic                 we_n;   // Write Enable / Clock
  logic                 re_n;   // Read Enable / Complementary Clock
  logic                 ce_n;   // Chip Enable
  logic                 rb_n;   // Ready / Busy status

  // Controller modport (Aegis-One ONFI PHY side)
  modport controller (
    input  clk, rst_n,
    output dq_out, dq_oe, dqs_out, dqs_oe, cle, ale, we_n, re_n, ce_n,
    input  dq_in, dqs_in, rb_n
  );

  // Device modport (Target NAND Flash Die side)
  modport device (
    input  clk, rst_n,
    input  dq_out, dq_oe, dqs_out, dqs_oe, cle, ale, we_n, re_n, ce_n,
    output dq_in, dqs_in, rb_n
  );

  // Passive bus monitor
  modport monitor (
    input clk, rst_n,
    input dq_out, dq_in, dq_oe, dqs_out, dqs_in, dqs_oe,
    input cle, ale, we_n, re_n, ce_n, rb_n
  );

endinterface // onfi_sync_if

`endif // AEGIS_INTERFACES_SV
