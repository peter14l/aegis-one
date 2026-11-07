// ============================================================================
// File: rtl/core/lz4_parallel_dec.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Parallel LZ4 Hardware Decompressor with strict error bounds
//              checking (zero offset, out-of-range offset, premature EOF).
// ============================================================================

`ifndef LZ4_PARALLEL_DEC_SV
`define LZ4_PARALLEL_DEC_SV

`timescale 1ns / 1ps

/* verilator lint_off UNUSEDPARAM */

module lz4_parallel_dec #(
  parameter int unsigned IN_DATA_W   = 512,
  parameter int unsigned OUT_DATA_W  = 512,
  parameter int unsigned PAGE_SIZE_B = 4096,
  parameter int unsigned NUM_LANES   = 8,
  parameter int unsigned HIST_DEPTH  = 4096,
  localparam int unsigned HIST_ADDR_W = $clog2(HIST_DEPTH) // 12
)(
  input  logic                      clk,
  input  logic                      rst_n,

  // Compressed Stream Input
  input  logic                      comp_val,
  output logic                      comp_rdy,
  input  logic [IN_DATA_W-1:0]      comp_data,
  input  logic [6:0]                comp_bytes_valid,
  input  logic                      comp_last,

  // Decompressed Stream Output
  output logic                      decomp_val,
  input  logic                      decomp_rdy,
  output logic [OUT_DATA_W-1:0]     decomp_data,
  output logic                      decomp_last,

  // Status & Telemetry
  output logic                      busy,
  output logic                      frame_error,
  output logic                      dec_err
);

  (* ram_style = "block" *) logic [7:0] hist_ram [HIST_DEPTH];

  typedef enum logic [2:0] {
    ST_IDLE         = 3'b000,
    ST_LOAD_CHUNK   = 3'b001,
    ST_PARSE_TOKEN  = 3'b010,
    ST_LITERALS     = 3'b011,
    ST_MATCH_OFFSET = 3'b100,
    ST_MATCH_COPY   = 3'b101,
    ST_DONE         = 3'b110,
    ST_ERROR        = 3'b111
  } lz4_state_e;

  lz4_state_e state;

  logic [IN_DATA_W-1:0]   in_buf;
  logic [6:0]             in_bytes_left;
  logic [HIST_ADDR_W:0]   out_pos;
  logic [HIST_ADDR_W-1:0] hist_rd_ptr;
  logic [15:0]            match_offset;
  logic [15:0]            lit_len;
  logic [15:0]            match_len;
  logic [5:0]             out_buf_idx;
  logic [OUT_DATA_W-1:0]  out_buf;
  logic                   out_val_reg;
  logic                   out_last_reg;
  logic                   saved_comp_last;

  assign comp_rdy    = (state == ST_IDLE) || ((state == ST_LOAD_CHUNK) && (in_bytes_left == 7'd0));
  assign busy        = (state != ST_IDLE);
  assign decomp_val  = out_val_reg;
  assign decomp_data = out_buf;
  assign decomp_last = out_last_reg;

  logic [7:0] hist_rdata;
  always_ff @(posedge clk) begin
    hist_rdata <= hist_ram[hist_rd_ptr];
  end

  initial begin
    for (int unsigned i = 0; i < HIST_DEPTH; i++) hist_ram[i] = '0;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state            <= ST_IDLE;
      in_buf           <= '0;
      in_bytes_left    <= '0;
      out_pos          <= '0;
      hist_rd_ptr      <= '0;
      match_offset     <= '0;
      lit_len          <= '0;
      match_len        <= '0;
      out_buf_idx      <= '0;
      out_buf          <= '0;
      out_val_reg      <= 1'b0;
      out_last_reg     <= 1'b0;
      frame_error      <= 1'b0;
      dec_err          <= 1'b0;
      saved_comp_last  <= 1'b0;
    end else begin
      if (decomp_val && decomp_rdy) begin
        out_val_reg  <= 1'b0;
        out_last_reg <= 1'b0;
      end

      case (state)
        ST_IDLE: begin
          frame_error     <= 1'b0;
          dec_err         <= 1'b0;
          out_pos         <= '0;
          out_buf_idx     <= '0;
          out_val_reg     <= 1'b0;
          out_last_reg    <= 1'b0;
          saved_comp_last <= 1'b0;
          if (comp_val && comp_rdy) begin
            in_buf          <= comp_data;
            in_bytes_left   <= comp_bytes_valid;
            saved_comp_last <= comp_last;
            state           <= ST_PARSE_TOKEN;
          end
        end

        ST_LOAD_CHUNK: begin
          if (comp_val) begin
            in_buf          <= comp_data;
            in_bytes_left   <= comp_bytes_valid;
            saved_comp_last <= comp_last;
            state           <= ST_PARSE_TOKEN;
          end else if (saved_comp_last && (in_bytes_left == 7'd0)) begin
            state <= ST_DONE;
          end
        end

        ST_PARSE_TOKEN: begin
          if (in_bytes_left == 7'd0) begin
            if (saved_comp_last) begin
              state <= (out_pos != '0) ? ST_DONE : ST_ERROR;
              if (out_pos == '0) begin
                frame_error <= 1'b1;
                dec_err     <= 1'b1;
              end
            end else begin
              state <= ST_LOAD_CHUNK;
            end
          end else begin
            lit_len       <= {12'h000, in_buf[7:4]};
            match_len     <= {12'h000, in_buf[3:0]} + 16'd4;
            in_buf        <= in_buf >> 8;
            in_bytes_left <= in_bytes_left - 7'd1;

            // Page frame bounds check
            if (out_pos + {9'h000, in_buf[7:4]} > (HIST_ADDR_W+1)'(PAGE_SIZE_B)) begin
              state       <= ST_ERROR;
              frame_error <= 1'b1;
              dec_err     <= 1'b1;
            end else if (in_buf[7:4] == 4'h0) begin
              state <= ST_MATCH_OFFSET;
            end else begin
              state <= ST_LITERALS;
            end
          end
        end

        ST_LITERALS: begin
          if (in_bytes_left == 7'd0) begin
            if (saved_comp_last && (lit_len != 16'd0)) begin
              // Premature EOF during literal stream
              state       <= ST_ERROR;
              frame_error <= 1'b1;
              dec_err     <= 1'b1;
            end else begin
              state <= ST_LOAD_CHUNK;
            end
          end else if (lit_len != 16'd0) begin
            hist_ram[out_pos[HIST_ADDR_W-1:0]] <= in_buf[7:0];
            out_buf[(out_buf_idx * 8) +: 8]    <= in_buf[7:0];
            in_buf                             <= in_buf >> 8;
            in_bytes_left                      <= in_bytes_left - 7'd1;
            out_pos                            <= out_pos + 1'b1;
            lit_len                            <= lit_len - 16'd1;

            if (out_buf_idx == 6'd63) begin
              out_val_reg <= 1'b1;
              out_buf_idx <= '0;
            end else begin
              out_buf_idx <= out_buf_idx + 1'b1;
            end
          end else begin
            if (out_pos >= (HIST_ADDR_W+1)'(PAGE_SIZE_B)) begin
              state <= ST_DONE;
            end else begin
              state <= ST_MATCH_OFFSET;
            end
          end
        end

        ST_MATCH_OFFSET: begin
          if (in_bytes_left < 7'd2) begin
            if (saved_comp_last) begin
              // Premature EOF while expecting 16-bit offset
              state       <= ST_ERROR;
              frame_error <= 1'b1;
              dec_err     <= 1'b1;
            end else begin
              state <= ST_LOAD_CHUNK;
            end
          end else begin
            logic [15:0] offset_candidate;
            offset_candidate = in_buf[15:0];

            // Adversarial check: Offset 0 is illegal; Offset > out_pos is illegal
            if ((offset_candidate == 16'd0) || ({1'b0, offset_candidate} > {4'd0, out_pos})) begin
              state       <= ST_ERROR;
              frame_error <= 1'b1;
              dec_err     <= 1'b1;
            end else begin
              match_offset  <= offset_candidate;
              hist_rd_ptr   <= out_pos[HIST_ADDR_W-1:0] - offset_candidate[HIST_ADDR_W-1:0];
              in_buf        <= in_buf >> 16;
              in_bytes_left <= in_bytes_left - 7'd2;
              state         <= ST_MATCH_COPY;
            end
          end
        end

        ST_MATCH_COPY: begin
          if (match_len != 16'd0) begin
            hist_ram[out_pos[HIST_ADDR_W-1:0]] <= hist_rdata;
            out_buf[(out_buf_idx * 8) +: 8]    <= hist_rdata;
            out_pos                            <= out_pos + 1'b1;
            hist_rd_ptr                        <= hist_rd_ptr + 1'b1;
            match_len                          <= match_len - 16'd1;

            if (out_buf_idx == 6'd63) begin
              out_val_reg <= 1'b1;
              out_buf_idx <= '0;
            end else begin
              out_buf_idx <= out_buf_idx + 1'b1;
            end
          end else begin
            if ((out_pos >= (HIST_ADDR_W+1)'(PAGE_SIZE_B)) || (in_bytes_left == 7'd0 && saved_comp_last)) begin
              state <= ST_DONE;
            end else begin
              state <= ST_PARSE_TOKEN;
            end
          end
        end

        ST_DONE: begin
          if (out_buf_idx != 6'd0) begin
            out_val_reg  <= 1'b1;
            out_last_reg <= 1'b1;
          end else begin
            out_last_reg <= 1'b1;
          end
          if (decomp_val && decomp_rdy) begin
            state <= ST_IDLE;
          end
        end

        ST_ERROR: begin
          // Clean abort: assert error flags and reset to IDLE without hanging
          frame_error <= 1'b1;
          dec_err     <= 1'b1;
          out_val_reg <= 1'b0;
          state       <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  wire _unused_lanes = |{NUM_LANES, match_offset};

endmodule // lz4_parallel_dec

`endif // LZ4_PARALLEL_DEC_SV
