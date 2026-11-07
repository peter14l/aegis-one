// ============================================================================
// File: rtl/core/ftl_engine.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Hardware Log-Structured FTL with Atomic Journal Updates,
//              L2P Translation Table, and Wear-Leveling Counters
// ============================================================================

`ifndef FTL_ENGINE_SV
`define FTL_ENGINE_SV

`timescale 1ns / 1ps

module ftl_engine #(
  parameter int unsigned HOST_ADDR_W     = 64,
  parameter int unsigned PAGE_SIZE_B     = 4096,
  parameter int unsigned NUM_L2P_ENTRIES = 1024,
  parameter int unsigned NUM_PHYS_BLOCKS = 64,
  parameter int unsigned PAGES_PER_BLOCK = 64,
  parameter int unsigned BLOCK_ADDR_W   = 32,
  parameter int unsigned PAGE_IDX_W     = 16,
  parameter int unsigned WEAR_COUNT_W   = 32,
  localparam int unsigned PAGE_OFF_W    = $clog2(PAGE_SIZE_B),        // 12
  localparam int unsigned HOST_PFN_W    = HOST_ADDR_W - PAGE_OFF_W,  // 52
  localparam int unsigned L2P_IDX_W     = $clog2(NUM_L2P_ENTRIES),   // 10
  localparam int unsigned TAG_W         = HOST_PFN_W - L2P_IDX_W,    // 42
  localparam int unsigned BLK_IDX_W     = $clog2(NUM_PHYS_BLOCKS)    // 6
)(
  input  logic                      clk,
  input  logic                      rst_n,

  // --------------------------------------------------------------------------
  // L2P Translation Lookup Port (1-Cycle Latency)
  // --------------------------------------------------------------------------
  input  logic                      lookup_val,
  output logic                      lookup_rdy,
  input  logic [HOST_PFN_W-1:0]     lookup_pfn,

  output logic                      lookup_resp_val,
  output logic                      lookup_hit,
  output logic [BLOCK_ADDR_W-1:0]   lookup_block,
  output logic [PAGE_IDX_W-1:0]     lookup_page,

  // --------------------------------------------------------------------------
  // Log-Structured Allocation / Remap Port
  // --------------------------------------------------------------------------
  input  logic                      alloc_val,
  output logic                      alloc_rdy,
  input  logic [HOST_PFN_W-1:0]     alloc_pfn,

  output logic                      alloc_resp_val,
  output logic [BLOCK_ADDR_W-1:0]   alloc_block,
  output logic [PAGE_IDX_W-1:0]     alloc_page,
  output logic [WEAR_COUNT_W-1:0]   alloc_wear_cnt,

  // --------------------------------------------------------------------------
  // Wear-Leveling Telemetry Query
  // --------------------------------------------------------------------------
  input  logic [BLK_IDX_W-1:0]      wear_query_idx,
  output logic [WEAR_COUNT_W-1:0]   wear_query_count,

  // Atomic Journal Status
  output logic                      journal_bank,
  output logic [31:0]               journal_seq
);

  // L2P translation table entry packed struct
  typedef struct packed {
    logic                     valid;
    logic [TAG_W-1:0]         tag;
    logic [BLOCK_ADDR_W-1:0]  block_addr;
    logic [PAGE_IDX_W-1:0]    page_idx;
  } l2p_entry_t;

  // L2P BRAM storage (Simple Dual-Port)
  (* ram_style = "block" *)       l2p_entry_t l2p_table [NUM_L2P_ENTRIES];
  (* ram_style = "distributed" *) logic [WEAR_COUNT_W-1:0] block_wear [NUM_PHYS_BLOCKS];

  // Active append-only allocation registers
  logic [BLK_IDX_W-1:0]   active_blk_idx;
  logic [PAGE_IDX_W-1:0]  active_page_idx;

  // Pipeline stage registers for lookup
  logic                   pipe_val;
  logic [TAG_W-1:0]       pipe_tag;
  l2p_entry_t             l2p_rdata;

  // Forwarding register for allocation hazard
  logic                   fwd_val;
  logic [L2P_IDX_W-1:0]   fwd_idx;
  l2p_entry_t             fwd_entry;

  // Address slicing
  wire [L2P_IDX_W-1:0] req_l2p_idx = lookup_pfn[L2P_IDX_W-1:0];
  wire [TAG_W-1:0]     req_tag     = lookup_pfn[HOST_PFN_W-1:L2P_IDX_W];
  wire [L2P_IDX_W-1:0] alloc_idx   = alloc_pfn[L2P_IDX_W-1:0];
  wire [TAG_W-1:0]     alloc_tag   = alloc_pfn[HOST_PFN_W-1:L2P_IDX_W];

  assign lookup_rdy = 1'b1;
  assign alloc_rdy  = 1'b1;

  // Power-on table initialization
  initial begin
    for (int unsigned i = 0; i < NUM_L2P_ENTRIES; i++) begin
      l2p_table[i] = '0;
    end
    for (int unsigned b = 0; b < NUM_PHYS_BLOCKS; b++) begin
      block_wear[b] = '0;
    end
  end

  // --------------------------------------------------------------------------
  // Synchronous Memory Access & Pipeline Control
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pipe_val        <= 1'b0;
      pipe_tag        <= '0;
      fwd_val         <= 1'b0;
      fwd_idx         <= '0;
      fwd_entry       <= '0;
      active_blk_idx  <= '0;
      active_page_idx <= '0;
      journal_bank    <= 1'b0;
      journal_seq     <= '0;
      alloc_resp_val  <= 1'b0;
      alloc_block     <= '0;
      alloc_page      <= '0;
      alloc_wear_cnt  <= '0;
    end else begin
      // Lookup read pipeline
      if (lookup_val && lookup_rdy) begin
        pipe_val  <= 1'b1;
        pipe_tag  <= req_tag;
        l2p_rdata <= l2p_table[req_l2p_idx];
      end else begin
        pipe_val  <= 1'b0;
      end

      // Allocation and L2P update
      if (alloc_val && alloc_rdy) begin
        l2p_entry_t new_entry;
        new_entry.valid      = 1'b1;
        new_entry.tag        = alloc_tag;
        new_entry.block_addr = BLOCK_ADDR_W'(active_blk_idx);
        new_entry.page_idx   = active_page_idx;

        l2p_table[alloc_idx] <= new_entry;

        // Forwarding control for concurrent lookups
        fwd_val   <= 1'b1;
        fwd_idx   <= alloc_idx;
        fwd_entry <= new_entry;

        // Allocation response
        alloc_resp_val <= 1'b1;
        alloc_block    <= BLOCK_ADDR_W'(active_blk_idx);
        alloc_page     <= active_page_idx;
        alloc_wear_cnt <= block_wear[active_blk_idx];

        // Atomic journal update
        journal_seq  <= journal_seq + 1'b1;
        journal_bank <= ~journal_bank;

        // Advance log-structured append pointer
        if (active_page_idx == PAGE_IDX_W'(PAGES_PER_BLOCK - 1)) begin
          active_page_idx <= '0;
          block_wear[active_blk_idx] <= block_wear[active_blk_idx] + 1'b1;
          // Advance to next physical block
          if (active_blk_idx == BLK_IDX_W'(NUM_PHYS_BLOCKS - 1)) begin
            active_blk_idx <= '0;
          end else begin
            active_blk_idx <= active_blk_idx + 1'b1;
          end
        end else begin
          active_page_idx <= active_page_idx + 1'b1;
        end
      end else begin
        alloc_resp_val <= 1'b0;
        fwd_val        <= 1'b0;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Stage 1: Hit Detection & L2P Output
  // --------------------------------------------------------------------------
  l2p_entry_t eff_l2p;
  always_comb begin
    if (fwd_val && (fwd_idx == req_l2p_idx)) begin
      eff_l2p = fwd_entry;
    end else begin
      eff_l2p = l2p_rdata;
    end
  end

  assign lookup_resp_val  = pipe_val;
  assign lookup_hit       = eff_l2p.valid && (eff_l2p.tag == pipe_tag);
  assign lookup_block     = eff_l2p.block_addr;
  assign lookup_page      = eff_l2p.page_idx;
  assign wear_query_count = block_wear[wear_query_idx];

endmodule // ftl_engine

`endif // FTL_ENGINE_SV
