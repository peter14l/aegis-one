// ============================================================================
// File: rtl/core/tag_directory.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Parameterized 4-Way Set-Associative BRAM Tag Directory with
//              1-Cycle Hit Detection, Tree Pseudo-LRU, and Full Backpressure
// ============================================================================

`ifndef TAG_DIRECTORY_SV
`define TAG_DIRECTORY_SV

`timescale 1ns / 1ps

module tag_directory #(
  parameter int unsigned HOST_ADDR_W = 64,
  parameter int unsigned PAGE_SIZE_B = 4096,
  parameter int unsigned NUM_WAYS    = 4,
  parameter int unsigned NUM_SETS    = 1024,
  parameter int unsigned T0_PFN_W    = 24,
  localparam int unsigned PAGE_OFF_W = $clog2(PAGE_SIZE_B),       // 12
  localparam int unsigned HOST_PFN_W = HOST_ADDR_W - PAGE_OFF_W, // 52
  localparam int unsigned SET_IDX_W  = $clog2(NUM_SETS),          // 10
  localparam int unsigned TAG_W      = HOST_PFN_W - SET_IDX_W,    // 42
  localparam int unsigned WAY_W      = $clog2(NUM_WAYS)           // 2
)(
  input  logic                      clk,
  input  logic                      rst_n,

  // --------------------------------------------------------------------------
  // Port A: Lookup / Query Interface (1-Cycle Latency with Backpressure)
  // --------------------------------------------------------------------------
  input  logic                      lookup_val,
  output logic                      lookup_rdy,
  input  logic [HOST_PFN_W-1:0]     lookup_pfn,

  input  logic                      hit_out_rdy,
  output logic                      hit_out_val,
  output logic                      hit_out_hit,
  output logic [WAY_W-1:0]          hit_out_way,
  output logic [T0_PFN_W-1:0]       hit_out_t0_pfn,
  output logic                      hit_out_dirty,
  output logic [TAG_W-1:0]          hit_out_tag,

  // Eviction candidate information for missed lookups
  output logic [WAY_W-1:0]          victim_way,
  output logic                      victim_val,
  output logic                      victim_dirty,
  output logic [TAG_W-1:0]          victim_tag,
  output logic [T0_PFN_W-1:0]       victim_t0_pfn,

  // --------------------------------------------------------------------------
  // Port B: Update / Allocation / Invalidate Interface
  // --------------------------------------------------------------------------
  input  logic                      update_val,
  output logic                      update_rdy,
  input  logic [SET_IDX_W-1:0]      update_set,
  input  logic [WAY_W-1:0]          update_way,
  input  logic                      update_we,          // 1: Write full entry
  input  logic                      update_valid,
  input  logic                      update_dirty,
  input  logic [3:0]                update_access_count,
  input  logic [T0_PFN_W-1:0]       update_t0_pfn,
  input  logic [TAG_W-1:0]          update_tag,
  input  logic                      update_dirty_only,  // 1: Selectively update dirty
  input  logic                      update_dirty_val
);

  // Tag directory entry packed struct definition
  typedef struct packed {
    logic                 valid;
    logic                 dirty;
    logic [3:0]           access_count;
    logic [T0_PFN_W-1:0]  t0_pfn;
    logic [TAG_W-1:0]     tag;
  } dir_entry_t;

  // UltraScale+ Block RAM inference: Simple Dual-Port per way (1 read, 1 write)
  (* ram_style = "block" *)       dir_entry_t tag_ram  [NUM_WAYS][NUM_SETS];
  (* ram_style = "distributed" *) logic [2:0] plru_ram [NUM_SETS];

  // Pipeline stage registers
  logic                 pipe_val;
  logic [SET_IDX_W-1:0] pipe_set;
  logic [TAG_W-1:0]     pipe_tag;
  dir_entry_t           tag_rdata [NUM_WAYS];
  logic [2:0]           plru_rdata;

  // Port B forwarding bypass to resolve read-during-write collision in Cycle 1
  logic                 fwd_val;
  logic [SET_IDX_W-1:0] fwd_set;
  logic [WAY_W-1:0]     fwd_way;
  dir_entry_t           fwd_entry;

  // Extract address breakdown from request
  wire [SET_IDX_W-1:0]  req_set = lookup_pfn[SET_IDX_W-1:0];
  wire [TAG_W-1:0]      req_tag = lookup_pfn[HOST_PFN_W-1:SET_IDX_W];

  assign lookup_rdy = (!pipe_val || hit_out_rdy);
  assign update_rdy = 1'b1;

  // Initial power-on state for FPGA BRAM
  initial begin
    for (int unsigned w = 0; w < NUM_WAYS; w++) begin
      for (int unsigned s = 0; s < NUM_SETS; s++) begin
        tag_ram[w][s] = '0;
      end
    end
    for (int unsigned s = 0; s < NUM_SETS; s++) begin
      plru_ram[s] = '0;
    end
  end

  // Formatted write entry
  dir_entry_t w_entry;
  always_comb begin
    w_entry.valid        = update_valid;
    w_entry.dirty        = update_dirty_only ? update_dirty_val : update_dirty;
    w_entry.access_count = update_access_count;
    w_entry.t0_pfn       = update_t0_pfn;
    w_entry.tag          = update_tag;
  end

  // --------------------------------------------------------------------------
  // PLRU Next-State Calculation Function
  // --------------------------------------------------------------------------
  /* verilator lint_off BLKSEQ */
  function [2:0] plru_touch;
    input [2:0] cur;
    input [WAY_W-1:0] way;
    reg [2:0] nxt;
    begin
      nxt = cur;
      case (way)
        2'b00: begin nxt[0] = 1'b1; nxt[1] = 1'b1; end
        2'b01: begin nxt[0] = 1'b1; nxt[1] = 1'b0; end
        2'b10: begin nxt[0] = 1'b0; nxt[2] = 1'b1; end
        2'b11: begin nxt[0] = 1'b0; nxt[2] = 1'b0; end
        default: nxt = cur;
      endcase
      plru_touch = nxt;
    end
  endfunction

  // --------------------------------------------------------------------------
  // Synchronous Memory Access & Pipeline Control
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pipe_val  <= 1'b0;
      pipe_set  <= '0;
      pipe_tag  <= '0;
      fwd_val   <= 1'b0;
      fwd_set   <= '0;
      fwd_way   <= '0;
      fwd_entry <= '0;
    end else begin
      // Forwarding control update
      if (update_val && update_rdy && (update_we || update_dirty_only)) begin
        fwd_val   <= 1'b1;
        fwd_set   <= update_set;
        fwd_way   <= update_way;
        fwd_entry <= w_entry;
      end else begin
        fwd_val   <= 1'b0;
      end

      // Port A synchronous read pipeline with backpressure hold
      if (pipe_val && !hit_out_rdy) begin
        pipe_val <= 1'b1;
      end else if (lookup_val && lookup_rdy) begin
        pipe_val   <= 1'b1;
        pipe_set   <= req_set;
        pipe_tag   <= req_tag;
        for (int unsigned w = 0; w < NUM_WAYS; w++) begin
          tag_rdata[w] <= tag_ram[w][req_set];
        end
        plru_rdata <= plru_ram[req_set];
      end else begin
        pipe_val <= 1'b0;
      end

      // Port B synchronous write
      if (update_val && update_rdy && (update_we || update_dirty_only)) begin
        tag_ram[update_way][update_set] <= w_entry;
        if (update_we && update_valid) begin
          plru_ram[update_set] <= plru_touch(plru_ram[update_set], update_way);
        end
      end else if (pipe_val && hit_out_rdy && (|way_hit)) begin
        plru_ram[pipe_set] <= plru_touch(plru_rdata, hit_way_idx);
      end
    end
  end

  // --------------------------------------------------------------------------
  // Stage 1: Hit Detection & Forwarding Resolution
  // --------------------------------------------------------------------------
  dir_entry_t eff_entry [NUM_WAYS];
  logic [NUM_WAYS-1:0] way_hit;
  logic [WAY_W-1:0] hit_way_idx;

  always_comb begin
    for (int unsigned w = 0; w < NUM_WAYS; w++) begin
      if (fwd_val && (fwd_set == pipe_set) && (fwd_way == WAY_W'(w))) begin
        eff_entry[w] = fwd_entry;
      end else begin
        eff_entry[w] = tag_rdata[w];
      end
      way_hit[w] = eff_entry[w].valid && (eff_entry[w].tag == pipe_tag);
    end

    casez (way_hit)
      4'b???1: hit_way_idx = 2'b00;
      4'b??10: hit_way_idx = 2'b01;
      4'b?100: hit_way_idx = 2'b10;
      4'b1000: hit_way_idx = 2'b11;
      default: hit_way_idx = 2'b00;
    endcase
  end

  // --------------------------------------------------------------------------
  // Stage 1: Victim Selection via Tree Pseudo-LRU
  // --------------------------------------------------------------------------
  logic [WAY_W-1:0] v_way_idx;

  always_comb begin
    if (!eff_entry[0].valid)      v_way_idx = 2'b00;
    else if (!eff_entry[1].valid) v_way_idx = 2'b01;
    else if (!eff_entry[2].valid) v_way_idx = 2'b10;
    else if (!eff_entry[3].valid) v_way_idx = 2'b11;
    else begin
      if (plru_rdata[0] == 1'b0) begin
        v_way_idx = (plru_rdata[1] == 1'b0) ? 2'b00 : 2'b01;
      end else begin
        v_way_idx = (plru_rdata[2] == 1'b0) ? 2'b10 : 2'b11;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Output Port Multiplexing & Assignments
  // --------------------------------------------------------------------------
  assign hit_out_val = pipe_val;
  assign hit_out_hit = |way_hit;
  assign hit_out_way = hit_way_idx;
  assign victim_way  = v_way_idx;

  always_comb begin
    case (hit_way_idx)
      2'b00: begin hit_out_t0_pfn = eff_entry[0].t0_pfn; hit_out_dirty = eff_entry[0].dirty; hit_out_tag = eff_entry[0].tag; end
      2'b01: begin hit_out_t0_pfn = eff_entry[1].t0_pfn; hit_out_dirty = eff_entry[1].dirty; hit_out_tag = eff_entry[1].tag; end
      2'b10: begin hit_out_t0_pfn = eff_entry[2].t0_pfn; hit_out_dirty = eff_entry[2].dirty; hit_out_tag = eff_entry[2].tag; end
      default: begin hit_out_t0_pfn = eff_entry[3].t0_pfn; hit_out_dirty = eff_entry[3].dirty; hit_out_tag = eff_entry[3].tag; end
    endcase
    case (v_way_idx)
      2'b00: begin victim_val = eff_entry[0].valid; victim_dirty = eff_entry[0].dirty; victim_tag = eff_entry[0].tag; victim_t0_pfn = eff_entry[0].t0_pfn; end
      2'b01: begin victim_val = eff_entry[1].valid; victim_dirty = eff_entry[1].dirty; victim_tag = eff_entry[1].tag; victim_t0_pfn = eff_entry[1].t0_pfn; end
      2'b10: begin victim_val = eff_entry[2].valid; victim_dirty = eff_entry[2].dirty; victim_tag = eff_entry[2].tag; victim_t0_pfn = eff_entry[2].t0_pfn; end
      default: begin victim_val = eff_entry[3].valid; victim_dirty = eff_entry[3].dirty; victim_tag = eff_entry[3].tag; victim_t0_pfn = eff_entry[3].t0_pfn; end
    endcase
  end

endmodule // tag_directory

`endif // TAG_DIRECTORY_SV
