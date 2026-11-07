// ============================================================================
// File: rtl/cxl/cxl_type3_bridge.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: CXL Type 3 Protocol Shim bridging CXL.mem M2S/S2M flits
//              to internal 512-bit AXI4-MM Memory Controller host interface
// ============================================================================

`ifndef CXL_TYPE3_BRIDGE_SV
`define CXL_TYPE3_BRIDGE_SV

`timescale 1ns / 1ps

module cxl_type3_bridge #(
  parameter int unsigned ADDR_W = 64,
  parameter int unsigned DATA_W = 512,
  parameter int unsigned TAG_W  = 16,
  parameter int unsigned STRB_W = DATA_W / 8
)(
  input  logic                      clk,
  input  logic                      rst_n,

  // --------------------------------------------------------------------------
  // CXL.mem M2S (Master to Subordinate) Interface
  // --------------------------------------------------------------------------
  input  logic                      m2s_val,
  output logic                      m2s_rdy,
  input  logic [3:0]                m2s_opcode,     // 0: NOP, 1: MemRd, 2: MemWr, 3: MemInv
  input  logic [TAG_W-1:0]          m2s_tag,
  input  logic [ADDR_W-1:0]         m2s_addr,
  input  logic [DATA_W-1:0]         m2s_data,
  input  logic [STRB_W-1:0]         m2s_strb,

  // --------------------------------------------------------------------------
  // CXL.mem S2M (Subordinate to Master) Response Interface
  // --------------------------------------------------------------------------
  output logic                      s2m_val,
  input  logic                      s2m_rdy,
  output logic [3:0]                s2m_opcode,     // 1: MemData, 2: MemRsp
  output logic [TAG_W-1:0]          s2m_tag,
  output logic [DATA_W-1:0]         s2m_data,

  // --------------------------------------------------------------------------
  // Outbound AXI4-MM Master Port (Connects to aegis_top Host Port)
  // --------------------------------------------------------------------------
  output logic [7:0]                m_axi_awid,
  output logic [ADDR_W-1:0]         m_axi_awaddr,
  output logic [7:0]                m_axi_awlen,
  output logic [2:0]                m_axi_awsize,
  output logic [1:0]                m_axi_awburst,
  output logic                      m_axi_awvalid,
  input  logic                      m_axi_awready,

  output logic [DATA_W-1:0]         m_axi_wdata,
  output logic [STRB_W-1:0]         m_axi_wstrb,
  output logic                      m_axi_wlast,
  output logic                      m_axi_wvalid,
  input  logic                      m_axi_wready,

  input  logic [7:0]                m_axi_bid,
  input  logic [1:0]                m_axi_bresp,
  input  logic                      m_axi_bvalid,
  output logic                      m_axi_bready,

  output logic [7:0]                m_axi_arid,
  output logic [ADDR_W-1:0]         m_axi_araddr,
  output logic [7:0]                m_axi_arlen,
  output logic [2:0]                m_axi_arsize,
  output logic [1:0]                m_axi_arburst,
  output logic                      m_axi_arvalid,
  input  logic                      m_axi_arready,

  input  logic [7:0]                m_axi_rid,
  input  logic [DATA_W-1:0]         m_axi_rdata,
  input  logic [1:0]                m_axi_rresp,
  input  logic                      m_axi_rlast,
  input  logic                      m_axi_rvalid,
  output logic                      m_axi_rready
);

  localparam logic [3:0] CXL_MEM_NOP   = 4'h0;
  localparam logic [3:0] CXL_MEM_RD    = 4'h1;
  localparam logic [3:0] CXL_MEM_WR    = 4'h2;
  localparam logic [3:0] CXL_MEM_DATA  = 4'h1;
  localparam logic [3:0] CXL_MEM_RSP   = 4'h2;

  // Tag tracking FIFO for outstanding reads (16 entries)
  logic [TAG_W-1:0] read_tag_fifo [16];
  logic [3:0]       tag_wr_ptr;
  logic [3:0]       tag_rd_ptr;
  logic [4:0]       tag_count;

  // M2S request decode
  wire is_read  = m2s_val && (m2s_opcode == CXL_MEM_RD);
  wire is_write = m2s_val && (m2s_opcode == CXL_MEM_WR);

  // AXI Read Channel Driving
  assign m_axi_arid    = 8'd0;
  assign m_axi_araddr  = m2s_addr;
  assign m_axi_arlen   = 8'd0;       // Single 64B beat
  assign m_axi_arsize  = 3'b110;     // 64 bytes (512 bits)
  assign m_axi_arburst = 2'b01;      // INCR
  assign m_axi_arvalid = is_read && (tag_count < 5'd16);

  logic aw_done, w_done;
  wire aw_fire = m_axi_awvalid && m_axi_awready;
  wire w_fire  = m_axi_wvalid  && m_axi_wready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_done <= 1'b0;
      w_done  <= 1'b0;
    end else if (is_write) begin
      if (m2s_rdy) begin
        aw_done <= 1'b0;
        w_done  <= 1'b0;
      end else begin
        if (aw_fire) aw_done <= 1'b1;
        if (w_fire)  w_done  <= 1'b1;
      end
    end else begin
      aw_done <= 1'b0;
      w_done  <= 1'b0;
    end
  end

  // AXI Write Channel Driving
  assign m_axi_awid    = 8'd0;
  assign m_axi_awaddr  = m2s_addr;
  assign m_axi_awlen   = 8'd0;       // Single 64B beat
  assign m_axi_awsize  = 3'b110;     // 64 bytes
  assign m_axi_awburst = 2'b01;
  assign m_axi_awvalid = is_write && !aw_done;

  assign m_axi_wdata   = m2s_data;
  assign m_axi_wstrb   = m2s_strb;
  assign m_axi_wlast   = 1'b1;
  assign m_axi_wvalid  = is_write && !w_done;

  // Ready generation back to CXL M2S bus
  always_comb begin
    if (is_read) begin
      m2s_rdy = m_axi_arready && (tag_count < 5'd16);
    end else if (is_write) begin
      m2s_rdy = (aw_done || aw_fire) && (w_done || w_fire);
    end else begin
      m2s_rdy = 1'b1;
    end
  end

  // Read Tag FIFO management
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tag_wr_ptr <= '0;
      tag_rd_ptr <= '0;
      tag_count  <= '0;
    end else begin
      // Enqueue tag on read issue
      if (m_axi_arvalid && m_axi_arready) begin
        read_tag_fifo[tag_wr_ptr] <= m2s_tag;
        tag_wr_ptr <= tag_wr_ptr + 1'b1;
      end

      // Dequeue tag on read completion
      if (m_axi_rvalid && m_axi_rready) begin
        tag_rd_ptr <= tag_rd_ptr + 1'b1;
      end

      // Counter update
      case ({(m_axi_arvalid && m_axi_arready), (m_axi_rvalid && m_axi_rready)})
        2'b10:   tag_count <= tag_count + 1'b1;
        2'b01:   tag_count <= tag_count - 1'b1;
        default: tag_count <= tag_count;
      endcase
    end
  end

  // CXL.mem S2M Response generation
  always_comb begin
    if (m_axi_rvalid) begin
      s2m_val    = 1'b1;
      s2m_opcode = CXL_MEM_DATA;
      s2m_tag    = read_tag_fifo[tag_rd_ptr];
      s2m_data   = m_axi_rdata;
      m_axi_rready = s2m_rdy;
      m_axi_bready = 1'b0;
    end else if (m_axi_bvalid) begin
      s2m_val    = 1'b1;
      s2m_opcode = CXL_MEM_RSP;
      s2m_tag    = '0;
      s2m_data   = '0;
      m_axi_rready = 1'b0;
      m_axi_bready = s2m_rdy;
    end else begin
      s2m_val    = 1'b0;
      s2m_opcode = CXL_MEM_NOP;
      s2m_tag    = '0;
      s2m_data   = '0;
      m_axi_rready = 1'b1;
      m_axi_bready = 1'b1;
    end
  end

  // Suppress unused signal warnings
  wire _unused = |{m_axi_bid, m_axi_bresp, m_axi_rid, m_axi_rresp, m_axi_rlast};

endmodule // cxl_type3_bridge

`endif // CXL_TYPE3_BRIDGE_SV
