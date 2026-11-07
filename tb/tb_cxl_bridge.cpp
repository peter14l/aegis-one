// ============================================================================
// File: tb/tb_cxl_bridge.cpp
// Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
// Standard: C++17 / Verilator Simulation
// Description: Cycle-accurate testbench verifying CXL Type 3 M2S/S2M flits,
//              tag FIFO tracking, AXI4-MM handshakes, and backpressure.
// ============================================================================

#include <iostream>
#include <iomanip>
#include <cassert>
#include <memory>
#include "Vcxl_type3_bridge.h"
#include "verilated.h"

static void tick(Vcxl_type3_bridge* top, uint64_t& cycle) {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
  cycle++;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto top = std::make_unique<Vcxl_type3_bridge>();
  uint64_t cycle = 0;

  std::cout << "============================================================" << std::endl;
  std::cout << "[Aegis-One] CXL Type 3 Protocol & Flit Verification Suite" << std::endl;
  std::cout << "============================================================" << std::endl;

  // --------------------------------------------------------------------------
  // SCENARIO 1: Reset Sequence
  // --------------------------------------------------------------------------
  top->rst_n = 0;
  top->m2s_val = 0;
  top->s2m_rdy = 1;
  top->m_axi_awready = 1;
  top->m_axi_wready = 1;
  top->m_axi_bvalid = 0;
  top->m_axi_arready = 1;
  top->m_axi_rvalid = 0;

  for (int i = 0; i < 5; ++i) tick(top.get(), cycle);
  top->rst_n = 1;
  tick(top.get(), cycle);

  assert(top->m2s_rdy == 1 && "ERROR: m2s_rdy should be high in idle after reset");
  assert(top->s2m_val == 0 && "ERROR: s2m_val should be low after reset");
  std::cout << "[SCENARIO 1] CXL Bridge reset sequence verified." << std::endl;

  // --------------------------------------------------------------------------
  // SCENARIO 2: CXL.mem MemWr Flit -> AXI Write Handshake -> S2M MemRsp
  // --------------------------------------------------------------------------
  top->m2s_val = 1;
  top->m2s_opcode = 2; // MemWr
  top->m2s_tag = 0xAA01;
  top->m2s_addr = 0x00001000ULL;
  top->m2s_strb = 0xFFFFFFFFFFFFFFFFULL;
  for (int w = 0; w < 16; ++w) top->m2s_data[w] = 0x11111111U * static_cast<uint32_t>(w + 1);

  top->m_axi_awready = 1;
  top->m_axi_wready = 1;
  tick(top.get(), cycle);

  assert(top->m_axi_awvalid == 1 && "ERROR: m_axi_awvalid should be asserted for MemWr");
  assert(top->m_axi_wvalid == 1 && "ERROR: m_axi_wvalid should be asserted for MemWr");

  // Deassert M2S write beat
  top->m2s_val = 0;

  // Emulate AXI B response
  top->m_axi_bvalid = 1;
  top->m_axi_bresp = 0; // OKAY
  top->eval();

  assert(top->s2m_val == 1 && "ERROR: s2m_val should assert on AXI B response");
  assert(top->s2m_opcode == 2 && "ERROR: s2m_opcode should be MemRsp (2)");
  tick(top.get(), cycle);
  top->m_axi_bvalid = 0;
  top->eval();
  std::cout << "[SCENARIO 2] CXL MemWr flit converted to AXI4 AW+W and S2M MemRsp verified." << std::endl;

  // --------------------------------------------------------------------------
  // SCENARIO 3: CXL.mem MemRd Flit -> AXI Read -> S2M MemData (Tag Preservation)
  // --------------------------------------------------------------------------
  top->m2s_val = 1;
  top->m2s_opcode = 1; // MemRd
  const uint16_t EXPECTED_TAG = 0x55FA;
  top->m2s_tag = EXPECTED_TAG;
  top->m2s_addr = 0x00008040ULL;
  top->m_axi_arready = 1;
  tick(top.get(), cycle);

  assert(top->m_axi_arvalid == 1 && "ERROR: m_axi_arvalid should assert for MemRd");
  top->m2s_val = 0;

  // Emulate AXI R read data response from Aegis-One
  top->m_axi_rvalid = 1;
  top->m_axi_rdata[0] = 0xDEADBEEF;
  top->eval();

  assert(top->s2m_val == 1 && "ERROR: s2m_val should assert for MemData");
  assert(top->s2m_opcode == 1 && "ERROR: s2m_opcode should be MemData (1)");
  assert(top->s2m_tag == EXPECTED_TAG && "ERROR: s2m_tag must match original M2S request tag!");
  assert(top->s2m_data[0] == 0xDEADBEEF && "ERROR: s2m_data payload mismatch");

  tick(top.get(), cycle);
  top->m_axi_rvalid = 0;
  top->eval();
  std::cout << "[SCENARIO 3] CXL MemRd flit with Tag 0x" << std::hex << EXPECTED_TAG
            << " correctly returned in S2M MemData." << std::dec << std::endl;

  // --------------------------------------------------------------------------
  // SCENARIO 4: Backpressure Handling (s2m_rdy de-assertion & tag FIFO)
  // --------------------------------------------------------------------------
  top->s2m_rdy = 0; // Subordinate not ready
  top->m_axi_rvalid = 1;
  top->eval();

  assert(top->m_axi_rready == 0 && "ERROR: AXI rready must backpressure when s2m_rdy is low");

  top->s2m_rdy = 1;
  top->eval();
  assert(top->m_axi_rready == 1 && "ERROR: AXI rready must assert when s2m_rdy is high");

  tick(top.get(), cycle);
  top->m_axi_rvalid = 0;
  tick(top.get(), cycle);

  std::cout << "[SCENARIO 4] CXL S2M backpressure successfully propagated to AXI4." << std::endl;
  std::cout << "============================================================" << std::endl;
  std::cout << "[ALL CXL SCENARIOS PASSED] CXL Type 3 protocol bridge verified!" << std::endl;
  std::cout << "============================================================" << std::endl;

  return 0;
}
