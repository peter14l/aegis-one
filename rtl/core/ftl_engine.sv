// ============================================================================
// File: rtl/core/ftl_engine.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Thin wrapper around hw_ftl preserving top-level IP compatibility.
// ============================================================================

`ifndef FTL_ENGINE_SV
`define FTL_ENGINE_SV

`timescale 1ns / 1ps

/* verilator lint_off UNUSEDPARAM */

module ftl_engine #(
  parameter int unsigned HOST_ADDR_W     = 64,
  parameter int unsigned PAGE_SIZE_B     = 4096,
  parameter int unsigned NUM_L2P_ENTRIES = 1024,
  parameter int unsigned NUM_PHYS_BLOCKS = 64,
  parameter int unsigned PAGES_PER_BLOCK = 64,
  parameter int unsigned BLOCK_ADDR_W   = 32,
  parameter int unsigned PAGE_IDX_W     = 16,
  parameter int unsigned WEAR_COUNT_W   = 32,
  localparam int unsigned PAGE_OFF_W    = $clog2(PAGE_SIZE_B),
  localparam int unsigned HOST_PFN_W    = HOST_ADDR_W - PAGE_OFF_W,
  localparam int unsigned BLK_IDX_W     = $clog2(NUM_PHYS_BLOCKS)
)(
  input  logic                      clk,
  input  logic                      rst_n,

  input  logic                      lookup_val,
  output logic                      lookup_rdy,
  input  logic [HOST_PFN_W-1:0]     lookup_pfn,
  output logic                      lookup_resp_val,
  output logic                      lookup_hit,
  output logic [BLOCK_ADDR_W-1:0]   lookup_block,
  output logic [PAGE_IDX_W-1:0]     lookup_page,

  input  logic                      alloc_val,
  output logic                      alloc_rdy,
  input  logic [HOST_PFN_W-1:0]     alloc_pfn,
  output logic                      alloc_resp_val,
  output logic [BLOCK_ADDR_W-1:0]   alloc_block,
  output logic [PAGE_IDX_W-1:0]     alloc_page,
  output logic [WEAR_COUNT_W-1:0]   alloc_wear_cnt,

  input  logic [BLK_IDX_W-1:0]      wear_query_idx,
  output logic [WEAR_COUNT_W-1:0]   wear_query_count,

  output logic                      journal_bank,
  output logic [31:0]               journal_seq
);

  logic        unused_wear_overflow;
  logic [31:0] unused_journal_crc32;
  logic        unused_journal_crc_err;

  hw_ftl #(
    .HOST_ADDR_W(HOST_ADDR_W),
    .PAGE_SIZE_B(PAGE_SIZE_B),
    .NUM_L2P_ENTRIES(NUM_L2P_ENTRIES),
    .NUM_PHYS_BLOCKS(NUM_PHYS_BLOCKS),
    .PAGES_PER_BLOCK(PAGES_PER_BLOCK),
    .BLOCK_ADDR_W(BLOCK_ADDR_W),
    .PAGE_IDX_W(PAGE_IDX_W),
    .WEAR_COUNT_W(WEAR_COUNT_W)
  ) u_hw_ftl_core (
    .clk(clk),
    .rst_n(rst_n),
    .lookup_val(lookup_val),
    .lookup_rdy(lookup_rdy),
    .lookup_pfn(lookup_pfn),
    .lookup_resp_val(lookup_resp_val),
    .lookup_hit(lookup_hit),
    .lookup_block(lookup_block),
    .lookup_page(lookup_page),
    .alloc_val(alloc_val),
    .alloc_rdy(alloc_rdy),
    .alloc_pfn(alloc_pfn),
    .alloc_resp_val(alloc_resp_val),
    .alloc_block(alloc_block),
    .alloc_page(alloc_page),
    .alloc_wear_cnt(alloc_wear_cnt),
    .wear_query_idx(wear_query_idx),
    .wear_query_count(wear_query_count),
    .wear_overflow(unused_wear_overflow),
    .journal_bank(journal_bank),
    .journal_seq(journal_seq),
    .journal_crc32(unused_journal_crc32),
    .journal_crc_err(unused_journal_crc_err)
  );

  wire _unused = |{unused_wear_overflow, unused_journal_crc32, unused_journal_crc_err};

endmodule // ftl_engine

`endif // FTL_ENGINE_SV
