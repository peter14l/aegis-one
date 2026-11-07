// ============================================================================
// File: rtl/core/lz4_decompressor.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Thin wrapper around lz4_parallel_dec preserving top-level IP ports.
// ============================================================================

`ifndef LZ4_DECOMPRESSOR_SV
`define LZ4_DECOMPRESSOR_SV

`timescale 1ns / 1ps

/* verilator lint_off UNUSEDPARAM */

module lz4_decompressor #(
  parameter int unsigned IN_DATA_W   = 512,
  parameter int unsigned OUT_DATA_W  = 512,
  parameter int unsigned PAGE_SIZE_B = 4096,
  parameter int unsigned NUM_LANES   = 8,
  parameter int unsigned HIST_DEPTH  = 4096
)(
  input  logic                      clk,
  input  logic                      rst_n,

  input  logic                      comp_val,
  output logic                      comp_rdy,
  input  logic [IN_DATA_W-1:0]      comp_data,
  input  logic [6:0]                comp_bytes_valid,
  input  logic                      comp_last,

  output logic                      decomp_val,
  input  logic                      decomp_rdy,
  output logic [OUT_DATA_W-1:0]     decomp_data,
  output logic                      decomp_last,

  output logic                      busy,
  output logic                      frame_error
);

  logic unused_dec_err;

  lz4_parallel_dec #(
    .IN_DATA_W(IN_DATA_W),
    .OUT_DATA_W(OUT_DATA_W),
    .PAGE_SIZE_B(PAGE_SIZE_B),
    .NUM_LANES(NUM_LANES),
    .HIST_DEPTH(HIST_DEPTH)
  ) u_lz4_core (
    .clk(clk),
    .rst_n(rst_n),
    .comp_val(comp_val),
    .comp_rdy(comp_rdy),
    .comp_data(comp_data),
    .comp_bytes_valid(comp_bytes_valid),
    .comp_last(comp_last),
    .decomp_val(decomp_val),
    .decomp_rdy(decomp_rdy),
    .decomp_data(decomp_data),
    .decomp_last(decomp_last),
    .busy(busy),
    .frame_error(frame_error),
    .dec_err(unused_dec_err)
  );

  wire _unused = |{unused_dec_err};

endmodule // lz4_decompressor

`endif // LZ4_DECOMPRESSOR_SV
