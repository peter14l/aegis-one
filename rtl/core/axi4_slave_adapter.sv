// ============================================================================
// File: rtl/core/axi4_slave_adapter.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: AXI4-MM Slave Protocol Adapter with decoupled AW/W skid buffers,
//              independent WVALID-before-AWVALID arrival, and response backpressure.
// ============================================================================

`ifndef AXI4_SLAVE_ADAPTER_SV
`define AXI4_SLAVE_ADAPTER_SV

`timescale 1ns / 1ps

/* verilator lint_off UNUSEDPARAM */

module axi4_slave_adapter #(
  parameter int unsigned ADDR_W = 64,
  parameter int unsigned DATA_W = 512,
  parameter int unsigned ID_W   = 8,
  parameter int unsigned STRB_W = DATA_W / 8
)(
  input  logic                      clk,
  input  logic                      rst_n,

  // AXI4-MM Write Channels
  input  logic [ID_W-1:0]           s_axi_awid,
  input  logic [ADDR_W-1:0]         s_axi_awaddr,
  input  logic                      s_axi_awvalid,
  output logic                      s_axi_awready,

  input  logic [DATA_W-1:0]         s_axi_wdata,
  input  logic [STRB_W-1:0]         s_axi_wstrb,
  input  logic                      s_axi_wvalid,
  output logic                      s_axi_wready,

  output logic [ID_W-1:0]           s_axi_bid,
  output logic [1:0]                s_axi_bresp,
  output logic                      s_axi_bvalid,
  input  logic                      s_axi_bready,

  // AXI4-MM Read Channels
  input  logic                      s_axi_arvalid,
  output logic                      s_axi_arready,

  // Core Interconnect Handshake
  output logic                      wcb_wr_val,
  input  logic                      wcb_wr_rdy,
  output logic [ADDR_W-1:0]         wcb_wr_addr,
  output logic [DATA_W-1:0]         wcb_wr_data,
  output logic [STRB_W-1:0]         wcb_wr_strb,

  output logic                      tag_lookup_val,
  input  logic                      tag_lookup_rdy
);

  // Decoupled skid capture registers
  logic              aw_captured, w_captured;
  logic [ID_W-1:0]   buf_awid;
  logic [ADDR_W-1:0] buf_awaddr;
  logic [DATA_W-1:0] buf_wdata;
  logic [STRB_W-1:0] buf_wstrb;

  wire wr_tx_fire    = aw_captured && w_captured && wcb_wr_rdy;
  wire b_backpress   = s_axi_bvalid && !s_axi_bready;
  wire can_accept_aw = (!aw_captured || wr_tx_fire) && !b_backpress;
  wire can_accept_w  = (!w_captured  || wr_tx_fire) && !b_backpress;

  assign s_axi_awready = can_accept_aw;
  assign s_axi_wready  = can_accept_w;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_captured <= 1'b0;
      w_captured  <= 1'b0;
      buf_awid    <= '0;
      buf_awaddr  <= '0;
      buf_wdata   <= '0;
      buf_wstrb   <= '0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        aw_captured <= 1'b1;
        buf_awid    <= s_axi_awid;
        buf_awaddr  <= s_axi_awaddr;
      end else if (wr_tx_fire) begin
        aw_captured <= 1'b0;
      end

      if (s_axi_wvalid && s_axi_wready) begin
        w_captured <= 1'b1;
        buf_wdata  <= s_axi_wdata;
        buf_wstrb  <= s_axi_wstrb;
      end else if (wr_tx_fire) begin
        w_captured <= 1'b0;
      end
    end
  end

  assign wcb_wr_val  = aw_captured && w_captured;
  assign wcb_wr_addr = buf_awaddr;
  assign wcb_wr_data = buf_wdata;
  assign wcb_wr_strb = buf_wstrb;

  // B Channel response register
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_axi_bvalid <= 1'b0;
      s_axi_bid    <= '0;
      s_axi_bresp  <= 2'b00;
    end else if (s_axi_bvalid && s_axi_bready) begin
      s_axi_bvalid <= 1'b0;
    end else if (wr_tx_fire) begin
      s_axi_bvalid <= 1'b1;
      s_axi_bid    <= buf_awid;
      s_axi_bresp  <= 2'b00;
    end
  end

  // Fair Round-Robin Read/Write Arbitration
  logic ar_aw_priority;
  always_ff @(posedge clk) begin
    if (!rst_n) ar_aw_priority <= 1'b0;
    else if (s_axi_arvalid && wcb_wr_val) ar_aw_priority <= ~ar_aw_priority;
  end

  assign tag_lookup_val = s_axi_arvalid && (!wcb_wr_val || !ar_aw_priority);
  assign s_axi_arready  = tag_lookup_rdy && (!wcb_wr_val || !ar_aw_priority);

endmodule // axi4_slave_adapter

`endif // AXI4_SLAVE_ADAPTER_SV
