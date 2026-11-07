# ============================================================================
# File: tb/cocotb/Makefile
# Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
# Description: Cocotb Makefile for Verilator simulation in RAM
# ============================================================================

SIM ?= verilator
TOPLEVEL_LANG ?= verilog
SIM_BUILD ?= /dev/shm/cocotb_build

COCOTB_CONFIG ?= $(shell which cocotb-config 2>/dev/null || echo $(HOME)/.local/bin/cocotb-config)

VERILOG_SOURCES += $(PWD)/../../docs/01_INTERFACES.sv
VERILOG_SOURCES += $(PWD)/../../rtl/core/tag_directory.sv
VERILOG_SOURCES += $(PWD)/../../rtl/core/write_coalescing_buffer.sv
VERILOG_SOURCES += $(PWD)/../../rtl/core/ftl_engine.sv
VERILOG_SOURCES += $(PWD)/../../rtl/core/lz4_decompressor.sv
VERILOG_SOURCES += $(PWD)/../../rtl/core/migration_controller.sv
VERILOG_SOURCES += $(PWD)/../../rtl/aegis_top.sv

EXTRA_ARGS += -Wno-fatal -Wno-MULTITOP -Wno-PINCONNECTEMPTY

TOPLEVEL = aegis_top
MODULE   = test_aegis

include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
