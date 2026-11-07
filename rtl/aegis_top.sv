// ============================================================================
// File: rtl/aegis_top.sv
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: IEEE 1800-2017 SystemVerilog
// Description: Top-Level Memory Controller IP integrating Host AXI4-MM,
//              BRAM Tag Directory, Write-Coalescing Buffer, LZ4 Engine, FTL
// ============================================================================

/* verilator lint_off UNUSEDPARAM */

`ifndef AEGIS_TOP_SV
`define AEGIS_TOP_SV

`timescale 1ns / 1ps

module aegis_top #(
  parameter int unsigned ADDR_W = 64,
  parameter int unsigned DATA_W = 512,
  parameter int unsigned ID_W   = 8,
  parameter int unsigned STRB_W = DATA_W / 8
)(
  input  logic                      clk,
  input  logic                      rst_n,

  // --------------------------------------------------------------------------
  // Host AXI4-MM Slave Interface
  // --------------------------------------------------------------------------
  input  logic [ID_W-1:0]           s_axi_awid,
  input  logic [ADDR_W-1:0]         s_axi_awaddr,
  input  logic [7:0]                s_axi_awlen,
  input  logic [2:0]                s_axi_awsize,
  input  logic [1:0]                s_axi_awburst,
  input  logic                      s_axi_awvalid,
  output logic                      s_axi_awready,

  input  logic [DATA_W-1:0]         s_axi_wdata,
  input  logic [STRB_W-1:0]         s_axi_wstrb,
  input  logic                      s_axi_wlast,
  input  logic                      s_axi_wvalid,
  output logic                      s_axi_wready,

  output logic [ID_W-1:0]           s_axi_bid,
  output logic [1:0]                s_axi_bresp,
  output logic                      s_axi_bvalid,
  input  logic                      s_axi_bready,

  input  logic [ID_W-1:0]           s_axi_arid,
  input  logic [ADDR_W-1:0]         s_axi_araddr,
  input  logic [7:0]                s_axi_arlen,
  input  logic [2:0]                s_axi_arsize,
  input  logic [1:0]                s_axi_arburst,
  input  logic                      s_axi_arvalid,
  output logic                      s_axi_arready,

  output logic [ID_W-1:0]           s_axi_rid,
  output logic [DATA_W-1:0]         s_axi_rdata,
  output logic [1:0]                s_axi_rresp,
  output logic                      s_axi_rlast,
  output logic                      s_axi_rvalid,
  input  logic                      s_axi_rready,

  // --------------------------------------------------------------------------
  // Tier-0 DRAM AXI4-MM Master Interface
  // --------------------------------------------------------------------------
  output logic [ID_W-1:0]           m_t0_arid,
  output logic [ADDR_W-1:0]         m_t0_araddr,
  output logic [7:0]                m_t0_arlen,
  output logic [2:0]                m_t0_arsize,
  output logic [1:0]                m_t0_arburst,
  output logic                      m_t0_arvalid,
  input  logic                      m_t0_arready,

  input  logic [ID_W-1:0]           m_t0_rid,
  input  logic [DATA_W-1:0]         m_t0_rdata,
  input  logic [1:0]                m_t0_rresp,
  input  logic                      m_t0_rlast,
  input  logic                      m_t0_rvalid,
  output logic                      m_t0_rready,

  // --------------------------------------------------------------------------
  // Tier-1 ONFI 4.2 PHY Controller Interface
  // --------------------------------------------------------------------------
  output logic [7:0]                onfi_dq_out,
  input  logic [7:0]                onfi_dq_in,
  output logic                      onfi_dq_oe,
  output logic                      onfi_dqs_out,
  input  logic                      onfi_dqs_in,
  output logic                      onfi_dqs_oe,
  output logic                      onfi_cle,
  output logic                      onfi_ale,
  output logic                      onfi_we_n,
  output logic                      onfi_re_n,
  output logic                      onfi_ce_n,
  input  logic                      onfi_rb_n,

  // Telemetry
  output logic                      busy,
  output logic [31:0]               hit_count,
  output logic [31:0]               miss_count
);

  localparam int unsigned HOST_PFN_W = ADDR_W - 12; // 52 bits
  localparam int unsigned LINE_IDX_W = 6;           // 64 lines/page

  wire [HOST_PFN_W-1:0] host_ar_pfn  = s_axi_araddr[ADDR_W-1:12];
  wire [HOST_PFN_W-1:0] host_aw_pfn  = s_axi_awaddr[ADDR_W-1:12];
  wire [LINE_IDX_W-1:0] host_aw_line = s_axi_awaddr[11:6];

  // Interconnect signals
  logic        tag_lookup_val, tag_lookup_rdy, tag_hit_val, tag_hit, tag_hit_dirty;
  logic [1:0]  tag_hit_way, tag_victim_way, tag_update_way;
  logic [23:0] tag_hit_t0_pfn, tag_victim_t0_pfn, tag_update_t0_pfn;
  logic [41:0] tag_hit_tag, tag_victim_tag, tag_update_tag;
  logic        tag_victim_val, tag_victim_dirty, tag_update_val, tag_update_rdy;
  logic [9:0]  tag_update_set;
  logic        tag_update_we, tag_update_valid, tag_update_dirty;
  logic [3:0]  tag_update_access_count;
  logic        tag_update_dirty_only, tag_update_dirty_val;

  logic        wcb_wr_val, wcb_wr_rdy, wcb_drain_val, wcb_drain_rdy, wcb_drain_last;
  logic [HOST_PFN_W-1:0] wcb_drain_pfn;
  logic [LINE_IDX_W-1:0] wcb_drain_line_idx;
  logic [DATA_W-1:0]    wcb_drain_data;
  logic                 wcb_flush_done;

  logic        ftl_lookup_val, ftl_lookup_rdy, ftl_lookup_resp_val, ftl_lookup_hit;
  logic [31:0] ftl_lookup_block, ftl_alloc_block, ftl_alloc_wear_cnt, ftl_journal_seq;
  logic [15:0] ftl_lookup_page, ftl_alloc_page;
  logic        ftl_alloc_val, ftl_alloc_rdy, ftl_alloc_resp_val, ftl_journal_bank;
  logic [31:0] ftl_wear_query_count;

  logic        lz4_comp_val, lz4_comp_rdy, lz4_comp_last, lz4_decomp_val;
  logic        lz4_decomp_rdy, lz4_decomp_last, lz4_busy, lz4_frame_error;
  logic [DATA_W-1:0] lz4_comp_data, lz4_decomp_data;
  logic [6:0]        lz4_comp_bytes_valid;

  // Submodules
  tag_directory #(.HOST_ADDR_W(ADDR_W), .PAGE_SIZE_B(4096), .NUM_WAYS(4), .NUM_SETS(1024), .T0_PFN_W(24)) u_tag_dir (
    .clk(clk), .rst_n(rst_n), .lookup_val(tag_lookup_val), .lookup_rdy(tag_lookup_rdy),
    .lookup_pfn(host_ar_pfn), .hit_out_rdy(1'b1), .hit_out_val(tag_hit_val), .hit_out_hit(tag_hit),
    .hit_out_way(tag_hit_way), .hit_out_t0_pfn(tag_hit_t0_pfn), .hit_out_dirty(tag_hit_dirty),
    .hit_out_tag(tag_hit_tag), .victim_way(tag_victim_way), .victim_val(tag_victim_val),
    .victim_dirty(tag_victim_dirty), .victim_tag(tag_victim_tag), .victim_t0_pfn(tag_victim_t0_pfn),
    .update_val(tag_update_val), .update_rdy(tag_update_rdy), .update_set(tag_update_set),
    .update_way(tag_update_way), .update_we(tag_update_we), .update_valid(tag_update_valid),
    .update_dirty(tag_update_dirty), .update_access_count(tag_update_access_count),
    .update_t0_pfn(tag_update_t0_pfn), .update_tag(tag_update_tag),
    .update_dirty_only(tag_update_dirty_only), .update_dirty_val(tag_update_dirty_val)
  );

  write_coalescing_buffer #(.DATA_W(DATA_W), .STRB_W(STRB_W), .HOST_ADDR_W(ADDR_W), .PAGE_SIZE_B(4096), .NUM_SLOTS(8), .MAX_AGE(128)) u_wcb (
    .clk(clk), .rst_n(rst_n), .wr_val(wcb_wr_val), .wr_rdy(wcb_wr_rdy), .wr_pfn(host_aw_pfn),
    .wr_line_idx(host_aw_line), .wr_data(s_axi_wdata), .wr_strb(s_axi_wstrb),
    .drain_val(wcb_drain_val), .drain_rdy(wcb_drain_rdy), .drain_pfn(wcb_drain_pfn),
    .drain_line_idx(wcb_drain_line_idx), .drain_data(wcb_drain_data), .drain_last(wcb_drain_last),
    .flush_all_req(1'b0), .flush_all_done(wcb_flush_done)
  );

  ftl_engine #(.HOST_ADDR_W(ADDR_W), .PAGE_SIZE_B(4096), .NUM_L2P_ENTRIES(1024), .NUM_PHYS_BLOCKS(64), .PAGES_PER_BLOCK(64)) u_ftl (
    .clk(clk), .rst_n(rst_n), .lookup_val(ftl_lookup_val), .lookup_rdy(ftl_lookup_rdy),
    .lookup_pfn(host_ar_pfn), .lookup_resp_val(ftl_lookup_resp_val), .lookup_hit(ftl_lookup_hit),
    .lookup_block(ftl_lookup_block), .lookup_page(ftl_lookup_page), .alloc_val(ftl_alloc_val),
    .alloc_rdy(ftl_alloc_rdy), .alloc_pfn(wcb_drain_pfn), .alloc_resp_val(ftl_alloc_resp_val),
    .alloc_block(ftl_alloc_block), .alloc_page(ftl_alloc_page), .alloc_wear_cnt(ftl_alloc_wear_cnt),
    .wear_query_idx(6'd0), .wear_query_count(ftl_wear_query_count), .journal_bank(ftl_journal_bank), .journal_seq(ftl_journal_seq)
  );

  lz4_decompressor #(.IN_DATA_W(DATA_W), .OUT_DATA_W(DATA_W), .PAGE_SIZE_B(4096), .NUM_LANES(8)) u_lz4 (
    .clk(clk), .rst_n(rst_n), .comp_val(lz4_comp_val), .comp_rdy(lz4_comp_rdy),
    .comp_data(lz4_comp_data), .comp_bytes_valid(lz4_comp_bytes_valid), .comp_last(lz4_comp_last),
    .decomp_val(lz4_decomp_val), .decomp_rdy(lz4_decomp_rdy), .decomp_data(lz4_decomp_data),
    .decomp_last(lz4_decomp_last), .busy(lz4_busy), .frame_error(lz4_frame_error)
  );

  // Host Write Channel
  assign wcb_wr_val    = s_axi_awvalid && s_axi_wvalid;
  assign s_axi_awready = wcb_wr_rdy;
  assign s_axi_wready  = wcb_wr_rdy;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_axi_bvalid <= 1'b0;
      s_axi_bid    <= '0;
      s_axi_bresp  <= 2'b00;
    end else begin
      if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end else if (wcb_wr_val && wcb_wr_rdy) begin
        s_axi_bvalid <= 1'b1;
        s_axi_bid    <= s_axi_awid;
        s_axi_bresp  <= 2'b00;
      end
    end
  end

  // Host Read Channel & Tier-0 Bypass
  assign tag_lookup_val = s_axi_arvalid;
  assign s_axi_arready  = tag_lookup_rdy;

  assign m_t0_arvalid   = tag_hit_val && tag_hit;
  assign m_t0_arid      = s_axi_arid;
  assign m_t0_araddr    = {28'h000_0000, tag_hit_t0_pfn, s_axi_araddr[11:0]};
  assign m_t0_arlen     = s_axi_arlen;
  assign m_t0_arsize    = s_axi_arsize;
  assign m_t0_arburst   = s_axi_arburst;

  assign s_axi_rvalid   = m_t0_rvalid;
  assign s_axi_rid      = m_t0_rid;
  assign s_axi_rdata    = m_t0_rdata;
  assign s_axi_rresp    = m_t0_rresp;
  assign s_axi_rlast    = m_t0_rlast;
  assign m_t0_rready    = s_axi_rready;

  // Tag Directory Updates
  always_comb begin
    tag_update_val          = wcb_wr_val && wcb_wr_rdy;
    tag_update_set          = host_aw_pfn[9:0];
    tag_update_way          = 2'd0;
    tag_update_we           = wcb_wr_val && wcb_wr_rdy;
    tag_update_valid        = 1'b1;
    tag_update_dirty        = 1'b1;
    tag_update_access_count = 4'd1;
    tag_update_t0_pfn       = 24'd0;
    tag_update_tag          = host_aw_pfn[51:10];
    tag_update_dirty_only   = 1'b0;
    tag_update_dirty_val    = 1'b1;
  end

  // WCB Drain, FTL, and ONFI Ties
  assign ftl_alloc_val        = wcb_drain_val && wcb_drain_last;
  assign wcb_drain_rdy        = 1'b1;
  assign ftl_lookup_val       = tag_hit_val && (!tag_hit);
  assign onfi_dq_out          = 8'h00;
  assign onfi_dq_oe           = 1'b0;
  assign onfi_dqs_out         = 1'b0;
  assign onfi_dqs_oe          = 1'b0;
  assign onfi_cle             = 1'b0;
  assign onfi_ale             = 1'b0;
  assign onfi_we_n            = 1'b1;
  assign onfi_re_n            = 1'b1;
  assign onfi_ce_n            = 1'b1;
  assign lz4_comp_val         = 1'b0;
  assign lz4_comp_data        = '0;
  assign lz4_comp_bytes_valid = 7'd0;
  assign lz4_comp_last        = 1'b0;
  assign lz4_decomp_rdy       = 1'b1;

  // Telemetry counters
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hit_count  <= '0;
      miss_count <= '0;
      busy       <= 1'b0;
    end else begin
      busy <= lz4_busy || wcb_drain_val;
      if (tag_hit_val) begin
        if (tag_hit) hit_count  <= hit_count + 1'b1;
        else         miss_count <= miss_count + 1'b1;
      end
    end
  end

  // Suppress unused signal warnings across connected interfaces
  wire _unused = |{tag_hit_tag, tag_hit_dirty, tag_hit_way, tag_victim_way,
                   tag_victim_val, tag_victim_dirty, tag_victim_tag,
                   tag_victim_t0_pfn, tag_update_rdy, ftl_lookup_rdy,
                   ftl_lookup_resp_val, ftl_lookup_hit, ftl_lookup_block,
                   ftl_lookup_page, ftl_alloc_rdy, ftl_alloc_resp_val,
                   ftl_alloc_block, ftl_alloc_page, ftl_alloc_wear_cnt,
                   ftl_journal_bank, ftl_journal_seq, lz4_comp_rdy,
                   lz4_decomp_val, lz4_decomp_data, lz4_decomp_last,
                   lz4_frame_error, onfi_dq_in, onfi_dqs_in, onfi_rb_n,
                   wcb_drain_pfn, wcb_drain_line_idx, wcb_drain_data,
                   wcb_flush_done, ftl_wear_query_count, s_axi_awlen,
                   s_axi_awsize, s_axi_awburst, s_axi_wlast,
                   s_axi_awaddr[5:0], m_t0_arready};

endmodule // aegis_top

`endif // AEGIS_TOP_SV
