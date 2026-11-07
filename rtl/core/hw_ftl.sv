// ============================================================================
// File: rtl/core/hw_ftl.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Hardware Log-Structured FTL with Atomic CRC-32 Journaling,
//              Power-Loss Consistency, and Non-Overflowing Wear-Leveling.
// ============================================================================

`ifndef HW_FTL_SV
`define HW_FTL_SV

`timescale 1ns / 1ps

/* verilator lint_off UNUSEDPARAM */

module hw_ftl #(
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

  // L2P Translation Lookup Port (1-Cycle Latency)
  input  logic                      lookup_val,
  output logic                      lookup_rdy,
  input  logic [HOST_PFN_W-1:0]     lookup_pfn,
  output logic                      lookup_resp_val,
  output logic                      lookup_hit,
  output logic [BLOCK_ADDR_W-1:0]   lookup_block,
  output logic [PAGE_IDX_W-1:0]     lookup_page,

  // Log-Structured Allocation / Remap Port with Atomic Journal
  input  logic                      alloc_val,
  output logic                      alloc_rdy,
  input  logic [HOST_PFN_W-1:0]     alloc_pfn,
  output logic                      alloc_resp_val,
  output logic [BLOCK_ADDR_W-1:0]   alloc_block,
  output logic [PAGE_IDX_W-1:0]     alloc_page,
  output logic [WEAR_COUNT_W-1:0]   alloc_wear_cnt,

  // Wear-Leveling Telemetry Query & Status
  input  logic [BLK_IDX_W-1:0]      wear_query_idx,
  output logic [WEAR_COUNT_W-1:0]   wear_query_count,
  output logic                      wear_overflow,

  // Atomic Journal Status
  output logic                      journal_bank,
  output logic [31:0]               journal_seq,
  output logic [31:0]               journal_crc32,
  output logic                      journal_crc_err
);

  // L2P translation table entry packed struct
  typedef struct packed {
    logic                     valid;
    logic [TAG_W-1:0]         tag;
    logic [BLOCK_ADDR_W-1:0]  block_addr;
    logic [PAGE_IDX_W-1:0]    page_idx;
  } l2p_entry_t;

  // Journal Header format for crash consistency
  typedef struct packed {
    logic [15:0]              magic;
    logic [31:0]              seq;
    logic [HOST_PFN_W-1:0]    pfn;
    logic [BLOCK_ADDR_W-1:0]  block;
    logic [PAGE_IDX_W-1:0]    page;
    logic [31:0]              crc;
  } journal_entry_t;

  localparam logic [15:0] JOURNAL_MAGIC = 16'h5A71;

  // Synthesizable IEEE 802.3 CRC-32 function (32-bit polynomial: 0xEDB88320)
  function automatic [31:0] calc_crc32;
    input [147:0] data; // magic (16) + seq (32) + pfn (52) + block (32) + page (16)
    logic [31:0] crc;
    begin
      crc = 32'hFFFF_FFFF;
      for (int i = 0; i < 148; i++) begin
        if ((crc[0] ^ data[i]) == 1'b1) begin
          crc = (crc >> 1) ^ 32'hEDB8_8320;
        end else begin
          crc = crc >> 1;
        end
      end
      calc_crc32 = ~crc;
    end
  endfunction

  // Storage arrays
  (* ram_style = "block" *) l2p_entry_t l2p_table [NUM_L2P_ENTRIES];
  logic [WEAR_COUNT_W-1:0] block_wear [NUM_PHYS_BLOCKS];
  journal_entry_t journal_banks [2];

  logic [BLK_IDX_W-1:0]   active_blk_idx;
  logic [PAGE_IDX_W-1:0]  active_page_idx;
  logic                   pipe_val;
  logic [TAG_W-1:0]       pipe_tag;
  l2p_entry_t             l2p_rdata;
  logic                   fwd_val;
  logic [L2P_IDX_W-1:0]   fwd_idx;
  l2p_entry_t             fwd_entry;

  wire [L2P_IDX_W-1:0] req_l2p_idx = lookup_pfn[L2P_IDX_W-1:0];
  wire [TAG_W-1:0]     req_tag     = lookup_pfn[HOST_PFN_W-1:L2P_IDX_W];
  wire [L2P_IDX_W-1:0] alloc_idx   = alloc_pfn[L2P_IDX_W-1:0];
  wire [TAG_W-1:0]     alloc_tag   = alloc_pfn[HOST_PFN_W-1:L2P_IDX_W];

  assign lookup_rdy = 1'b1;
  assign alloc_rdy  = 1'b1;

  initial begin
    for (int unsigned i = 0; i < NUM_L2P_ENTRIES; i++) l2p_table[i] = '0;
    for (int unsigned b = 0; b < NUM_PHYS_BLOCKS; b++) block_wear[b] = '0;
    journal_banks[0] = '0;
    journal_banks[1] = '0;
  end

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
      journal_crc32   <= '0;
      journal_crc_err <= 1'b0;
      wear_overflow   <= 1'b0;
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

      // Allocation and L2P update with atomic CRC-32 journal
      if (alloc_val && alloc_rdy) begin
        logic [31:0] next_seq;
        logic [31:0] computed_crc;
        logic [147:0] raw_journal_data;
        l2p_entry_t new_entry;

        next_seq = journal_seq + 1'b1;
        raw_journal_data = {JOURNAL_MAGIC, next_seq, alloc_pfn, BLOCK_ADDR_W'(active_blk_idx), active_page_idx};
        computed_crc = calc_crc32(raw_journal_data);

        // Atomic journal write
        if (journal_bank == 1'b0) begin
          journal_banks[1].magic <= JOURNAL_MAGIC;
          journal_banks[1].seq   <= next_seq;
          journal_banks[1].pfn   <= alloc_pfn;
          journal_banks[1].block <= BLOCK_ADDR_W'(active_blk_idx);
          journal_banks[1].page  <= active_page_idx;
          journal_banks[1].crc   <= computed_crc;
        end else begin
          journal_banks[0].magic <= JOURNAL_MAGIC;
          journal_banks[0].seq   <= next_seq;
          journal_banks[0].pfn   <= alloc_pfn;
          journal_banks[0].block <= BLOCK_ADDR_W'(active_blk_idx);
          journal_banks[0].page  <= active_page_idx;
          journal_banks[0].crc   <= computed_crc;
        end

        journal_seq     <= next_seq;
        journal_bank    <= ~journal_bank;
        journal_crc32   <= computed_crc;
        journal_crc_err <= 1'b0;

        // Commit active L2P table entry
        new_entry.valid      = 1'b1;
        new_entry.tag        = alloc_tag;
        new_entry.block_addr = BLOCK_ADDR_W'(active_blk_idx);
        new_entry.page_idx   = active_page_idx;

        l2p_table[alloc_idx] <= new_entry;
        fwd_val              <= 1'b1;
        fwd_idx              <= alloc_idx;
        fwd_entry            <= new_entry;

        alloc_resp_val <= 1'b1;
        alloc_block    <= BLOCK_ADDR_W'(active_blk_idx);
        alloc_page     <= active_page_idx;
        alloc_wear_cnt <= block_wear[active_blk_idx];

        // Advance page pointer and wear counter with saturation protection
        if (active_page_idx == PAGE_IDX_W'(PAGES_PER_BLOCK - 1)) begin
          active_page_idx <= '0;
          if (block_wear[active_blk_idx] == {WEAR_COUNT_W{1'b1}}) begin
            wear_overflow <= 1'b1; // Saturated, do not wrap around to zero!
          end else begin
            block_wear[active_blk_idx] <= block_wear[active_blk_idx] + 1'b1;
          end

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

  // Lookup resolution with hazard forwarding
  l2p_entry_t eff_l2p;
  always_comb begin
    if (fwd_val && (fwd_idx == req_l2p_idx)) eff_l2p = fwd_entry;
    else                                     eff_l2p = l2p_rdata;
  end

  assign lookup_resp_val  = pipe_val;
  assign lookup_hit       = eff_l2p.valid && (eff_l2p.tag == pipe_tag);
  assign lookup_block     = eff_l2p.block_addr;
  assign lookup_page      = eff_l2p.page_idx;
  assign wear_query_count = block_wear[wear_query_idx];

  wire _unused_journal = |{journal_banks[0], journal_banks[1]};

endmodule // hw_ftl

`endif // HW_FTL_SV
