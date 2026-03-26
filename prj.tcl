# Set the reference directory for source file relative paths (by default the value is script directory path)
set origin_dir "."


# Set the project name
set _xil_proj_name_ "project_1"

# Set the directory path for the original project from where this script was exported
set orig_proj_dir "[file normalize "$origin_dir/project_1"]"



# Create project
create_project ${_xil_proj_name_} ./${_xil_proj_name_} -part xc7a100tcsg324-1

# Set the directory path for the new project
set proj_dir [get_property directory [current_project]]

# Set project properties
set obj [current_project]
set_property -name "board_part" -value "digilentinc.com:arty-a7-100:part0:1.1" -objects $obj
set_property -name "default_lib" -value "xil_defaultlib" -objects $obj
set_property -name "enable_resource_estimation" -value "0" -objects $obj
set_property -name "enable_vhdl_2008" -value "1" -objects $obj
set_property -name "ip_cache_permissions" -value "read write" -objects $obj
set_property -name "ip_output_repo" -value "$proj_dir/${_xil_proj_name_}.cache/ip" -objects $obj
set_property -name "mem.enable_memory_map_generation" -value "1" -objects $obj
set_property -name "platform.board_id" -value "arty-a7-100" -objects $obj
set_property -name "revised_directory_structure" -value "1" -objects $obj
set_property -name "sim.central_dir" -value "$proj_dir/${_xil_proj_name_}.ip_user_files" -objects $obj
set_property -name "sim.ip.auto_export_scripts" -value "1" -objects $obj
set_property -name "simulator_language" -value "Mixed" -objects $obj
set_property -name "sim_compile_state" -value "1" -objects $obj
set_property -name "target_language" -value "VHDL" -objects $obj
set_property -name "webtalk.activehdl_export_sim" -value "52" -objects $obj
set_property -name "webtalk.modelsim_export_sim" -value "52" -objects $obj
set_property -name "webtalk.questa_export_sim" -value "52" -objects $obj
set_property -name "webtalk.riviera_export_sim" -value "52" -objects $obj
set_property -name "webtalk.vcs_export_sim" -value "52" -objects $obj
set_property -name "webtalk.xcelium_export_sim" -value "2" -objects $obj
set_property -name "webtalk.xsim_export_sim" -value "52" -objects $obj
set_property -name "webtalk.xsim_launch_sim" -value "142" -objects $obj


#add simulation sources
set_property SOURCE_SET sources_1 [get_filesets sim_1]
add_files -fileset sim_1 -norecurse ./sd_dac_8k.v ./sine_gen.v ./tb_sd_dac.sv ./top.v

#add design sources
#add_files -norecurse {./clocked_comparator_25bit.vhd ./mux2to1_32bit.vhd ./sinewave_generator.vhd}
#update_compile_order -fileset sources_1





