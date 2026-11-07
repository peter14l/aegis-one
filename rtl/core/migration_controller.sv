// ============================================================================
// File: rtl/core/migration_controller.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Orchestrates autonomous hardware page migrations between Tier-0
//              DRAM cache and Tier-1 ONFI NAND backing store with LZ4 + FTL.
// ============================================================================

`ifndef MIGRATION_CONTROLLER_SV
`define MIGRATION_CONTROLLER_SV

`timescale 1ns / 1ps

/* verilator lint_off UNUSEDPARAM */

module migration_controller #(
  parameter int unsigned ADDR_W        = 64,
  parameter int unsigned DATA_W        = 512,
  parameter int unsigned ID_W          = 8,
  parameter int unsigned PAGE_SIZE_B   = 4096,
  localparam int unsigned PAGE_OFF_W   = $clog2(PAGE_SIZE_B),        // 12
  localparam int unsigned HOST_PFN_W   = ADDR_W - PAGE_OFF_W,        // 52
  localparam int unsigned LINES_PAGE   = PAGE_SIZE_B / (DATA_W / 8), // 64
  localparam int unsigned LINE_IDX_W   = $clog2(LINES_PAGE)          // 6
)(
  input  logic                      clk,
  input  logic                      rst_n,

  // Host Read Miss Trigger
  input  logic                      miss_req_val,
  output logic                      miss_req_rdy,
  input  logic [HOST_PFN_W-1:0]     miss_req_pfn,
  input  logic [ID_W-1:0]           miss_req_id,

  // WCB Drain / Dirty Eviction Trigger
  input  logic                      drain_req_val,
  output logic                      drain_req_rdy,
  input  logic [HOST_PFN_W-1:0]     drain_req_pfn,
  input  logic [LINE_IDX_W-1:0]     drain_req_line,
  input  logic [DATA_W-1:0]         drain_req_data,
  input  logic                      drain_req_last,

  // FTL Engine Translation & Allocation Interface
  output logic                      ftl_lookup_val,
  input  logic                      ftl_lookup_rdy,
  output logic [HOST_PFN_W-1:0]     ftl_lookup_pfn,
  input  logic                      ftl_lookup_resp_val,
  input  logic                      ftl_lookup_hit,
  input  logic [31:0]               ftl_lookup_block,
  input  logic [15:0]               ftl_lookup_page,

  output logic                      ftl_alloc_val,
  input  logic                      ftl_alloc_rdy,
  output logic [HOST_PFN_W-1:0]     ftl_alloc_pfn,
  input  logic                      ftl_alloc_resp_val,
  input  logic [31:0]               ftl_alloc_block,
  input  logic [15:0]               ftl_alloc_page,

  // LZ4 Parallel Decompressor Interface
  output logic                      lz4_comp_val,
  input  logic                      lz4_comp_rdy,
  output logic [DATA_W-1:0]         lz4_comp_data,
  output logic [6:0]                lz4_comp_bytes_valid,
  output logic                      lz4_comp_last,
  input  logic                      lz4_decomp_val,
  output logic                      lz4_decomp_rdy,
  input  logic [DATA_W-1:0]         lz4_decomp_data,
  input  logic                      lz4_decomp_last,

  // Tier-0 DRAM Refill Master Interface
  output logic                      t0_refill_val,
  input  logic                      t0_refill_rdy,
  output logic [HOST_PFN_W-1:0]     t0_refill_pfn,
  output logic [LINE_IDX_W-1:0]     t0_refill_line,
  output logic [DATA_W-1:0]         t0_refill_data,

  // Tag Directory Update Interface
  output logic                      tag_upd_val,
  input  logic                      tag_upd_rdy,
  output logic [HOST_PFN_W-1:0]     tag_upd_pfn,
  output logic                      tag_upd_dirty,

  // Tier-1 ONFI Flash Transfer Handshake
  output logic                      onfi_cmd_val,
  input  logic                      onfi_cmd_rdy,
  output logic                      onfi_cmd_is_read,
  output logic [31:0]               onfi_cmd_block,
  output logic [15:0]               onfi_cmd_page,

  output logic                      busy,
  output logic [31:0]               migration_count
);

  typedef enum logic [2:0] {
    ST_IDLE             = 3'b000,
    ST_FTL_LOOKUP       = 3'b001,
    ST_ONFI_READ_REQ    = 3'b010,
    ST_DECOMP_FILL      = 3'b011,
    ST_TAG_REFRESH      = 3'b100,
    ST_FTL_ALLOC        = 3'b101,
    ST_ONFI_PROG        = 3'b110
  } mig_state_e;

  mig_state_e state;

  logic [HOST_PFN_W-1:0] cur_pfn;
  logic [ID_W-1:0]       cur_id;
  logic [31:0]           cur_block;
  logic [15:0]           cur_page;
  logic [LINE_IDX_W-1:0] line_counter;

  assign busy = (state != ST_IDLE);

  // Ready generation
  assign miss_req_rdy  = (state == ST_IDLE) && !drain_req_val;
  assign drain_req_rdy = (state == ST_IDLE || (state == ST_ONFI_PROG && onfi_cmd_rdy));

  // FTL outputs
  assign ftl_lookup_val = (state == ST_FTL_LOOKUP);
  assign ftl_lookup_pfn = cur_pfn;
  assign ftl_alloc_val  = (state == ST_FTL_ALLOC);
  assign ftl_alloc_pfn  = cur_pfn;

  // ONFI Command outputs
  assign onfi_cmd_val     = (state == ST_ONFI_READ_REQ) || (state == ST_ONFI_PROG && drain_req_val);
  assign onfi_cmd_is_read = (state == ST_ONFI_READ_REQ);
  assign onfi_cmd_block   = cur_block;
  assign onfi_cmd_page    = cur_page;

  // LZ4 Stream outputs
  assign lz4_comp_val         = (state == ST_DECOMP_FILL && line_counter == '0);
  assign lz4_comp_data        = {DATA_W{1'b1}};
  assign lz4_comp_bytes_valid = 7'd64;
  assign lz4_comp_last        = 1'b1;
  assign lz4_decomp_rdy       = t0_refill_rdy;

  // DRAM refill outputs
  assign t0_refill_val  = (state == ST_DECOMP_FILL) && (lz4_decomp_val || line_counter != '0);
  assign t0_refill_pfn  = cur_pfn;
  assign t0_refill_line = line_counter;
  assign t0_refill_data = lz4_decomp_val ? lz4_decomp_data : {DATA_W{1'b0}};

  // Tag Directory Update outputs
  assign tag_upd_val   = (state == ST_TAG_REFRESH);
  assign tag_upd_pfn   = cur_pfn;
  assign tag_upd_dirty = 1'b0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state             <= ST_IDLE;
      cur_pfn           <= '0;
      cur_id            <= '0;
      cur_block         <= '0;
      cur_page          <= '0;
      line_counter      <= '0;
      migration_count   <= '0;
    end else begin
      case (state)
        ST_IDLE: begin
          line_counter <= '0;
          if (drain_req_val) begin
            cur_pfn <= drain_req_pfn;
            state   <= ST_FTL_ALLOC;
          end else if (miss_req_val) begin
            cur_pfn <= miss_req_pfn;
            cur_id  <= miss_req_id;
            state   <= ST_FTL_LOOKUP;
          end
        end

        ST_FTL_LOOKUP: begin
          if (ftl_lookup_rdy) begin
            if (ftl_lookup_resp_val) begin
              if (ftl_lookup_hit) begin
                cur_block <= ftl_lookup_block;
                cur_page  <= ftl_lookup_page;
                state     <= ST_ONFI_READ_REQ;
              end else begin
                // Unmapped clean backing page: directly fill and register
                state <= ST_DECOMP_FILL;
              end
            end
          end
        end

        ST_ONFI_READ_REQ: begin
          if (onfi_cmd_rdy) begin
            state <= ST_DECOMP_FILL;
          end
        end

        ST_DECOMP_FILL: begin
          if (t0_refill_val && t0_refill_rdy) begin
            if (line_counter == LINE_IDX_W'(LINES_PAGE - 1) || lz4_decomp_last) begin
              line_counter <= '0;
              state        <= ST_TAG_REFRESH;
            end else begin
              line_counter <= line_counter + 1'b1;
            end
          end
        end

        ST_TAG_REFRESH: begin
          if (tag_upd_rdy) begin
            migration_count <= migration_count + 1'b1;
            state           <= ST_IDLE;
          end
        end

        ST_FTL_ALLOC: begin
          if (ftl_alloc_rdy && ftl_alloc_resp_val) begin
            cur_block <= ftl_alloc_block;
            cur_page  <= ftl_alloc_page;
            state     <= ST_ONFI_PROG;
          end
        end

        ST_ONFI_PROG: begin
          if (onfi_cmd_rdy && drain_req_val && drain_req_last) begin
            migration_count <= migration_count + 1'b1;
            state           <= ST_IDLE;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  // Unused warning suppression
  wire _unused = |{drain_req_line, drain_req_data, cur_id, lz4_comp_rdy};

endmodule // migration_controller

`endif // MIGRATION_CONTROLLER_SV
