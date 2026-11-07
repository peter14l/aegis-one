// ============================================================================
// File: rtl/core/write_coalescing_buffer.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: In-DRAM Write-Coalescing Buffer absorbing 64B sub-page writes
//              and flushing coalesced 4KB pages in sequential bursts
// ============================================================================

`ifndef WRITE_COALESCING_BUFFER_SV
`define WRITE_COALESCING_BUFFER_SV

`timescale 1ns / 1ps

module write_coalescing_buffer #(
  parameter int unsigned DATA_W         = 512,
  parameter int unsigned STRB_W         = DATA_W / 8,
  parameter int unsigned HOST_ADDR_W    = 64,
  parameter int unsigned PAGE_SIZE_B    = 4096,
  parameter int unsigned NUM_SLOTS      = 8,
  parameter int unsigned MAX_AGE        = 128,
  localparam int unsigned PAGE_OFF_W    = $clog2(PAGE_SIZE_B),        // 12
  localparam int unsigned HOST_PFN_W    = HOST_ADDR_W - PAGE_OFF_W,  // 52
  localparam int unsigned LINES_PER_PAGE= PAGE_SIZE_B / (DATA_W / 8),// 64
  localparam int unsigned LINE_IDX_W    = $clog2(LINES_PER_PAGE),    // 6
  localparam int unsigned SLOT_W        = $clog2(NUM_SLOTS),         // 3
  localparam int unsigned TOTAL_LINES   = NUM_SLOTS * LINES_PER_PAGE // 512
)(
  input  logic                      clk,
  input  logic                      rst_n,

  // --------------------------------------------------------------------------
  // Write Ingestion Interface (Sub-page 64B Write Absorption)
  // --------------------------------------------------------------------------
  input  logic                      wr_val,
  output logic                      wr_rdy,
  input  logic [HOST_PFN_W-1:0]     wr_pfn,
  input  logic [LINE_IDX_W-1:0]     wr_line_idx,
  input  logic [DATA_W-1:0]         wr_data,
  input  logic [STRB_W-1:0]         wr_strb,

  // --------------------------------------------------------------------------
  // Drain / Flush Stream Interface (Coalesced 4KB Burst to Tier-1 / Backing)
  // --------------------------------------------------------------------------
  output logic                      drain_val,
  input  logic                      drain_rdy,
  output logic [HOST_PFN_W-1:0]     drain_pfn,
  output logic [LINE_IDX_W-1:0]     drain_line_idx,
  output logic [DATA_W-1:0]         drain_data,
  output logic                      drain_last,

  // Manual flush command
  input  logic                      flush_all_req,
  output logic                      flush_all_done
);

  // 512-word Block RAM storing coalesced lines
  (* ram_style = "block" *) logic [DATA_W-1:0] buffer_ram [TOTAL_LINES];

  // Per-slot metadata
  logic [HOST_PFN_W-1:0]     slot_pfn        [NUM_SLOTS];
  logic [LINES_PER_PAGE-1:0] slot_dirty_mask [NUM_SLOTS];
  logic [7:0]                slot_age        [NUM_SLOTS];
  logic [NUM_SLOTS-1:0]      slot_valid;
  logic [NUM_SLOTS-1:0]      slot_draining;

  // Drain FSM state encoding
  typedef enum logic [1:0] {
    ST_DRAIN_IDLE   = 2'b00,
    ST_DRAIN_BURST  = 2'b01,
    ST_DRAIN_DONE   = 2'b10
  } drain_state_e;

  drain_state_e drain_state;
  logic [SLOT_W-1:0]     drain_slot_idx;
  logic [LINE_IDX_W-1:0] drain_line_cnt;

  // Initial power-on state
  initial begin
    for (int unsigned i = 0; i < TOTAL_LINES; i++) begin
      buffer_ram[i] = '0;
    end
  end

  // --------------------------------------------------------------------------
  // Slot Lookup and Match Logic
  // --------------------------------------------------------------------------
  logic [NUM_SLOTS-1:0] slot_hit;
  logic [SLOT_W-1:0]    hit_slot_idx;
  logic                 has_hit;

  logic [NUM_SLOTS-1:0] slot_free;
  logic [SLOT_W-1:0]    free_slot_idx;
  logic                 has_free;

  always_comb begin
    for (int unsigned s = 0; s < NUM_SLOTS; s++) begin
      slot_hit[s]  = slot_valid[s] && (!slot_draining[s]) && (slot_pfn[s] == wr_pfn);
      slot_free[s] = !slot_valid[s];
    end
    has_hit  = |slot_hit;
    has_free = |slot_free;

    casez (slot_hit)
      8'b???????1: hit_slot_idx = 3'd0; 8'b??????10: hit_slot_idx = 3'd1;
      8'b?????100: hit_slot_idx = 3'd2; 8'b????1000: hit_slot_idx = 3'd3;
      8'b???10000: hit_slot_idx = 3'd4; 8'b??100000: hit_slot_idx = 3'd5;
      8'b?1000000: hit_slot_idx = 3'd6; default:     hit_slot_idx = 3'd7;
    endcase

    casez (slot_free)
      8'b???????1: free_slot_idx = 3'd0; 8'b??????10: free_slot_idx = 3'd1;
      8'b?????100: free_slot_idx = 3'd2; 8'b????1000: free_slot_idx = 3'd3;
      8'b???10000: free_slot_idx = 3'd4; 8'b??100000: free_slot_idx = 3'd5;
      8'b?1000000: free_slot_idx = 3'd6; default:     free_slot_idx = 3'd7;
    endcase
  end

  // Ready to accept new write if slot hits or free slot is available
  assign wr_rdy = has_hit || has_free;

  // Selected write destination
  wire [SLOT_W-1:0] target_slot = has_hit ? hit_slot_idx : free_slot_idx;
  wire [8:0] wr_ram_addr = {target_slot, wr_line_idx};

  // --------------------------------------------------------------------------
  // Candidate Selection for Eviction / Drain
  // --------------------------------------------------------------------------
  logic [NUM_SLOTS-1:0] drain_candidate;
  logic [SLOT_W-1:0]    selected_drain_slot;
  logic                 has_candidate;

  always_comb begin
    for (int unsigned s = 0; s < NUM_SLOTS; s++) begin
      drain_candidate[s] = slot_valid[s] && (!slot_draining[s]) &&
                           ((&slot_dirty_mask[s]) || (slot_age[s] >= 8'(MAX_AGE)) || flush_all_req);
    end
    has_candidate = |drain_candidate;

    casez (drain_candidate)
      8'b???????1: selected_drain_slot = 3'd0;
      8'b??????10: selected_drain_slot = 3'd1;
      8'b?????100: selected_drain_slot = 3'd2;
      8'b????1000: selected_drain_slot = 3'd3;
      8'b???10000: selected_drain_slot = 3'd4;
      8'b??100000: selected_drain_slot = 3'd5;
      8'b?1000000: selected_drain_slot = 3'd6;
      default:     selected_drain_slot = 3'd7;
    endcase
  end

  // Synchronous BRAM address for draining
  wire [8:0] drain_ram_addr = {drain_slot_idx, drain_line_cnt};

  // --------------------------------------------------------------------------
  // Sequential Logic: Write Ingestion & Coalescing Storage
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      slot_valid    <= '0;
      slot_draining <= '0;
      for (int unsigned s = 0; s < NUM_SLOTS; s++) begin
        slot_pfn[s]        <= '0;
        slot_dirty_mask[s] <= '0;
        slot_age[s]        <= '0;
      end
    end else begin
      // Ingest incoming 64B write
      if (wr_val && wr_rdy) begin
        for (int unsigned b = 0; b < STRB_W; b++) begin
          if (wr_strb[b]) begin
            buffer_ram[wr_ram_addr][b*8 +: 8] <= wr_data[b*8 +: 8];
          end
        end
        if (!has_hit) begin
          slot_valid[free_slot_idx]        <= 1'b1;
          slot_pfn[free_slot_idx]          <= wr_pfn;
          slot_dirty_mask[free_slot_idx]   <= (64'd1 << wr_line_idx);
          slot_age[free_slot_idx]          <= '0;
        end else begin
          slot_dirty_mask[hit_slot_idx][wr_line_idx] <= 1'b1;
          slot_age[hit_slot_idx]                     <= '0;
        end
      end

      // Age increment for valid, non-draining slots
      for (int unsigned s = 0; s < NUM_SLOTS; s++) begin
        if (slot_valid[s] && (!slot_draining[s])) begin
          if (slot_age[s] < 8'hFF) begin
            slot_age[s] <= slot_age[s] + 1'b1;
          end
        end
      end

      // Mark slot as draining when FSM locks onto it
      if ((drain_state == ST_DRAIN_IDLE) && has_candidate) begin
        slot_draining[selected_drain_slot] <= 1'b1;
      end

      // Free slot upon completion of burst drain
      if (drain_state == ST_DRAIN_DONE) begin
        slot_valid[drain_slot_idx]    <= 1'b0;
        slot_draining[drain_slot_idx] <= 1'b0;
        slot_dirty_mask[drain_slot_idx] <= '0;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Drain / Flush Burst FSM
  // --------------------------------------------------------------------------
  logic [DATA_W-1:0] drain_ram_rdata;
  logic [DATA_W-1:0] drain_data_buf;
  logic              drain_data_val;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      drain_state    <= ST_DRAIN_IDLE;
      drain_slot_idx <= '0;
      drain_line_cnt <= '0;
      drain_data_buf <= '0;
      drain_data_val <= 1'b0;
    end else begin
      // BRAM registered read
      drain_ram_rdata <= buffer_ram[drain_ram_addr];

      case (drain_state)
        ST_DRAIN_IDLE: begin
          drain_data_val <= 1'b0;
          if (has_candidate) begin
            drain_slot_idx <= selected_drain_slot;
            drain_line_cnt <= '0;
            drain_state    <= ST_DRAIN_BURST;
          end
        end

        ST_DRAIN_BURST: begin
          // Find next dirty line to emit
          if (slot_dirty_mask[drain_slot_idx][drain_line_cnt]) begin
            drain_data_buf <= drain_ram_rdata;
            drain_data_val <= 1'b1;
            if (drain_val && drain_rdy) begin
              drain_data_val <= 1'b0;
              if (drain_line_cnt == 6'd63) begin
                drain_state <= ST_DRAIN_DONE;
              end else begin
                drain_line_cnt <= drain_line_cnt + 1'b1;
              end
            end
          end else begin
            // Skip clean line
            drain_data_val <= 1'b0;
            if (drain_line_cnt == 6'd63) begin
              drain_state <= ST_DRAIN_DONE;
            end else begin
              drain_line_cnt <= drain_line_cnt + 1'b1;
            end
          end
        end

        ST_DRAIN_DONE: begin
          drain_data_val <= 1'b0;
          drain_state    <= ST_DRAIN_IDLE;
        end

        default: drain_state <= ST_DRAIN_IDLE;
      endcase
    end
  end

  // Check if current line is the last dirty line in this page
  logic is_last_dirty;
  always_comb begin
    is_last_dirty = 1'b1;
    for (int unsigned l = 0; l < LINES_PER_PAGE; l++) begin
      if ((l > unsigned'(drain_line_cnt)) && slot_dirty_mask[drain_slot_idx][l]) begin
        is_last_dirty = 1'b0;
      end
    end
  end

  // Output assignments
  assign drain_val       = drain_data_val && slot_dirty_mask[drain_slot_idx][drain_line_cnt];
  assign drain_pfn       = slot_pfn[drain_slot_idx];
  assign drain_line_idx  = drain_line_cnt;
  assign drain_data      = drain_data_buf;
  assign drain_last      = is_last_dirty;
  assign flush_all_done  = (slot_valid == '0);

endmodule // write_coalescing_buffer

`endif // WRITE_COALESCING_BUFFER_SV
