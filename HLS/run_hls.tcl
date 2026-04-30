# =============================================================================
# run_hls.tcl
# Vitis HLS automation script for the 2nd-order CIFB SDM
#
# Usage:
#   vitis_hls -f run_hls.tcl
#
# Or interactively:
#   vitis_hls
#   source run_hls.tcl
# =============================================================================

# Project setup
open_project -reset sdm_hls_project
set_top sdm_cifb_2nd

# Source files
add_files sdm_cifb_2nd.cpp -cflags "-std=c++14"

# Testbench files
add_files -tb sdm_cifb_2nd_tb.cpp -cflags "-std=c++14"

# Solution setup
open_solution -reset "solution1" -flow_target vivado

# Target FPGA — change as needed
# Common Xilinx 7-series:
#   xc7a35tcpg236-1   (Artix-7  — Cmod A7, Arty A7 35T)
#   xc7a100tcsg324-1  (Artix-7  — Arty A7 100T)
#   xc7z020clg400-1   (Zynq-7000 — Zybo Z7-20)
# Common UltraScale+:
#   xczu3eg-sbva484-1-i  (Zynq UltraScale+)
set_part {xc7a35tcpg236-1}

# 100 MHz clock target
create_clock -period 10 -name default

# Configuration
config_compile -name_max_length 80
config_export -format ip_catalog -rtl verilog

puts "==============================================="
puts " Step 1: C simulation (functional verification)"
puts "==============================================="
csim_design

puts "==============================================="
puts " Step 2: C synthesis (HDL generation)"
puts "==============================================="
csynth_design

puts "==============================================="
puts " Step 3: Co-simulation (RTL vs C verification)"
puts "==============================================="
cosim_design -rtl verilog

puts "==============================================="
puts " Step 4: Export RTL as IP"
puts "==============================================="
export_design -format ip_catalog -display_name "SDM CIFB 2nd Order"

puts "==============================================="
puts " HLS flow complete"
puts "==============================================="
puts " Generated files:"
puts "   RTL:           sdm_hls_project/solution1/syn/verilog/"
puts "   IP package:    sdm_hls_project/solution1/impl/ip/"
puts "   PWL output:    sdm_hls_project/solution1/csim/build/pdm_output.pwl"
puts "==============================================="

exit
