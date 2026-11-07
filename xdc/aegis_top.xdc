# ============================================================================
# File: xdc/aegis_top.xdc
# Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
# Target: Xilinx UltraScale+ (XCVU9P / Zynq UltraScale+ MPSoC)
# Description: Physical timing constraints for 400 MHz core operational frequency
# ============================================================================

# Primary 400 MHz Core System Clock (Period: 2.500 ns)
create_clock -period 2.500 -name clk -waveform {0.000 1.250} [get_ports clk]

# Clock Uncertainty and Jitter
set_clock_uncertainty -setup 0.100 [get_clocks clk]
set_clock_uncertainty -hold 0.050 [get_clocks clk]

# Synchronous Reset Asynchronous Deassertion False Path
set_false_path -through [get_ports rst_n]

# Input Delays for Host AXI4-MM Slave Interface (Assuming 40% clock period budget)
set_input_delay -clock clk -max 1.000 [get_ports s_axi_*valid]
set_input_delay -clock clk -min 0.200 [get_ports s_axi_*valid]
set_input_delay -clock clk -max 1.000 [get_ports s_axi_*ready]
set_input_delay -clock clk -min 0.200 [get_ports s_axi_*ready]
set_input_delay -clock clk -max 1.000 [get_ports s_axi_*addr*]
set_input_delay -clock clk -min 0.200 [get_ports s_axi_*addr*]
set_input_delay -clock clk -max 1.000 [get_ports s_axi_*data*]
set_input_delay -clock clk -min 0.200 [get_ports s_axi_*data*]

# Output Delays for Host AXI4-MM Slave Responses
set_output_delay -clock clk -max 1.000 [get_ports s_axi_*ready]
set_output_delay -clock clk -min 0.200 [get_ports s_axi_*ready]
set_output_delay -clock clk -max 1.000 [get_ports s_axi_*valid]
set_output_delay -clock clk -min 0.200 [get_ports s_axi_*valid]
set_output_delay -clock clk -max 1.000 [get_ports s_axi_*data*]
set_output_delay -clock clk -min 0.200 [get_ports s_axi_*data*]

# Input / Output Delays for Tier-0 DRAM AXI4-MM Master Interface
set_output_delay -clock clk -max 1.000 [get_ports m_t0_arvalid]
set_output_delay -clock clk -min 0.200 [get_ports m_t0_arvalid]
set_output_delay -clock clk -max 1.000 [get_ports m_t0_araddr*]
set_output_delay -clock clk -min 0.200 [get_ports m_t0_araddr*]
set_input_delay  -clock clk -max 1.000 [get_ports m_t0_rvalid]
set_input_delay  -clock clk -min 0.200 [get_ports m_t0_rvalid]
set_input_delay  -clock clk -max 1.000 [get_ports m_t0_rdata*]
set_input_delay  -clock clk -min 0.200 [get_ports m_t0_rdata*]

# Multi-cycle path exceptions for slow telemetry status outputs
set_multicycle_path -setup -from [get_pins {busy_reg/C}] -to [get_ports busy] 2
set_multicycle_path -hold  -from [get_pins {busy_reg/C}] -to [get_ports busy] 1
