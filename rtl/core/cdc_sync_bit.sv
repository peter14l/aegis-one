// ============================================================================
// File: rtl/core/cdc_sync_bit.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Metastability-hardened 2-stage flip-flop CDC synchronizer
// ============================================================================

`ifndef CDC_SYNC_BIT_SV
`define CDC_SYNC_BIT_SV

`timescale 1ns / 1ps

module cdc_sync_bit #(
  parameter int unsigned STAGES = 2,
  parameter bit          INIT_VAL = 1'b0
)(
  input  logic clk,
  input  logic rst_n,
  input  logic d_in,
  output logic d_out
);

  (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_regs;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sync_regs <= {STAGES{INIT_VAL}};
    end else begin
      sync_regs <= {sync_regs[STAGES-2:0], d_in};
    end
  end

  assign d_out = sync_regs[STAGES-1];

endmodule // cdc_sync_bit

`endif // CDC_SYNC_BIT_SV
