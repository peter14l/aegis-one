// ============================================================================
// File: rtl/core/cdc_async_fifo.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Parameterized Gray-coded Asynchronous CDC FIFO for safe
//              multi-bit data and command transfers between clock domains.
// ============================================================================

`ifndef CDC_ASYNC_FIFO_SV
`define CDC_ASYNC_FIFO_SV

`timescale 1ns / 1ps

module cdc_async_fifo #(
  parameter int unsigned DATA_W = 64,
  parameter int unsigned ADDR_W = 4,   // Depth = 2^ADDR_W (e.g., 16)
  localparam int unsigned DEPTH = 1 << ADDR_W
)(
  // Write Domain
  input  logic              wclk,
  input  logic              wrst_n,
  input  logic              winc,
  input  logic [DATA_W-1:0] wdata,
  output logic              wfull,

  // Read Domain
  input  logic              rclk,
  input  logic              rrst_n,
  input  logic              rinc,
  output logic [DATA_W-1:0] rdata,
  output logic              rempty
);

  // Dual-port memory storage
  logic [DATA_W-1:0] mem [DEPTH];

  // Pointers in write domain
  logic [ADDR_W:0] wbin;
  logic [ADDR_W:0] wptr;
  logic [ADDR_W:0] wq2_rptr;

  // Pointers in read domain
  logic [ADDR_W:0] rbin;
  logic [ADDR_W:0] rptr;
  logic [ADDR_W:0] rq2_wptr;

  // Multi-stage Gray-pointer synchronizers with ASYNC_REG
  (* ASYNC_REG = "TRUE" *) logic [ADDR_W:0] wq1_rptr, wq2_rptr_r;
  (* ASYNC_REG = "TRUE" *) logic [ADDR_W:0] rq1_wptr, rq2_wptr_r;

  // Write pointer logic & Gray encoding
  wire [ADDR_W:0] wbin_next = wbin + (ADDR_W+1)'(winc && !wfull);
  wire [ADDR_W:0] wgray_next = (wbin_next >> 1) ^ wbin_next;

  always_ff @(posedge wclk) begin
    if (!wrst_n) begin
      wbin <= '0;
      wptr <= '0;
    end else begin
      wbin <= wbin_next;
      wptr <= wgray_next;
    end
  end

  // Write memory write port
  always_ff @(posedge wclk) begin
    if (winc && !wfull) begin
      mem[wbin[ADDR_W-1:0]] <= wdata;
    end
  end

  // Synchronize rptr into wclk domain
  always_ff @(posedge wclk) begin
    if (!wrst_n) begin
      wq1_rptr   <= '0;
      wq2_rptr_r <= '0;
    end else begin
      wq1_rptr   <= rptr;
      wq2_rptr_r <= wq1_rptr;
    end
  end
  assign wq2_rptr = wq2_rptr_r;

  // Write full condition: MSB inverted, next MSB inverted, LSBs match
  wire wfull_val = (wgray_next == {~wq2_rptr[ADDR_W:ADDR_W-1], wq2_rptr[ADDR_W-2:0]});
  always_ff @(posedge wclk) begin
    if (!wrst_n) wfull <= 1'b0;
    else         wfull <= wfull_val;
  end

  // Read pointer logic & Gray encoding
  wire [ADDR_W:0] rbin_next = rbin + (ADDR_W+1)'(rinc && !rempty);
  wire [ADDR_W:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

  always_ff @(posedge rclk) begin
    if (!rrst_n) begin
      rbin <= '0;
      rptr <= '0;
    end else begin
      rbin <= rbin_next;
      rptr <= rgray_next;
    end
  end

  // Read memory output (fall-through / registered)
  assign rdata = mem[rbin[ADDR_W-1:0]];

  // Synchronize wptr into rclk domain
  always_ff @(posedge rclk) begin
    if (!rrst_n) begin
      rq1_wptr   <= '0;
      rq2_wptr_r <= '0;
    end else begin
      rq1_wptr   <= wptr;
      rq2_wptr_r <= rq1_wptr;
    end
  end
  assign rq2_wptr = rq2_wptr_r;

  // Read empty condition
  wire rempty_val = (rgray_next == rq2_wptr);
  always_ff @(posedge rclk) begin
    if (!rrst_n) rempty <= 1'b1;
    else         rempty <= rempty_val;
  end

endmodule // cdc_async_fifo

`endif // CDC_ASYNC_FIFO_SV
