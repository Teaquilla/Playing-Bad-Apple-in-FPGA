# vivado/create_project.tcl
# Skrip pembangkit proyek GUI Vivado (.xpr) portabel untuk simulasi & sintesis Bad Apple! Basys 3
# Penggunaan (dari root repo):
#   powershell -ExecutionPolicy Bypass -File vivado\env.ps1 vivado -mode batch -nojournal -nolog -source vivado\create_project.tcl
# Atau dari Vivado Tcl Console:
#   source {<path_repo>/vivado/create_project.tcl}

set root     [file normalize [file join [file dirname [info script]] ..]]
set proj_dir "$root/vivado/project_gui"
set part     "xc7a35tcpg236-1"

puts "=========================================================="
puts "  MEMBUAT PROYEK GUI VIVADO: BadApple ($part)"
puts "=========================================================="
puts "Root repo   : $root"
puts "Proyek dir  : $proj_dir"

file mkdir $proj_dir
create_project -force BadApple $proj_dir -part $part
set_property target_language VHDL [current_project]

# 1. Design Sources (seluruh modul HDL aktif M1-M4 + modul daun audio untuk unit TB)
set hdl_files [list \
    "$root/hdl/frame_timer.vhd" \
    "$root/hdl/uart_tx.vhd" \
    "$root/hdl/frame_source.vhd" \
    "$root/hdl/decoder.vhd" \
    "$root/hdl/frame_buffer.vhd" \
    "$root/hdl/ascii_sink.vhd" \
    "$root/hdl/uart_rx.vhd" \
    "$root/hdl/rx_fifo.vhd" \
    "$root/hdl/packet_parser.vhd" \
    "$root/hdl/rle_decoder.vhd" \
    "$root/hdl/oled_spi.vhd" \
    "$root/hdl/audio_pwm.vhd" \
    "$root/hdl/audio_fifo.vhd" \
    "$root/hdl/top.vhd" \
]
add_files -norecurse -fileset sources_1 $hdl_files
set_property top top [get_filesets sources_1]

# 2. Constraints Basys 3 + PMOD JA (OLED)
add_files -norecurse -fileset constrs_1 [list \
    "$root/constraints/basys3.xdc" \
    "$root/constraints/basys3_m4_pmod.proposed.xdc" \
]

# 3. Simulation Sources (seluruh testbench behavioral RTL, kecuali tb_top_funcsim khusus netlist M1)
set sim_files [list \
    "$root/sim/tb_frame_timer.vhd" \
    "$root/sim/tb_uart_tx.vhd" \
    "$root/sim/tb_frame_source.vhd" \
    "$root/sim/tb_decoder.vhd" \
    "$root/sim/tb_frame_buffer.vhd" \
    "$root/sim/tb_frame_buffer_dual.vhd" \
    "$root/sim/tb_ascii_sink.vhd" \
    "$root/sim/tb_top.vhd" \
    "$root/sim/tb_uart_rx.vhd" \
    "$root/sim/tb_rx_fifo.vhd" \
    "$root/sim/tb_packet_parser.vhd" \
    "$root/sim/tb_rle_decoder.vhd" \
    "$root/sim/tb_stream_rx.vhd" \
    "$root/sim/tb_top_stream.vhd" \
    "$root/sim/tb_audio_pwm.vhd" \
    "$root/sim/tb_audio_fifo.vhd" \
    "$root/sim/tb_parser_audio.vhd" \
    "$root/sim/tb_oled_spi.vhd" \
    "$root/sim/tb_top_oled.vhd" \
]
add_files -norecurse -fileset sim_1 $sim_files
set_property top tb_top_oled [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# 4. Wajib: Set seluruh berkas .vhd menjadi VHDL 2008
set_property file_type {VHDL 2008} [get_files *.vhd]

# 5. Pengaturan simulasi default (run -all saat dipicu dari GUI)
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# 6. Salin vektor golden data/golden ke direktori simulasi xsim & sintesis synth_1 agar path relatif "data/golden/..." terbaca di GUI
set xsim_data_dir  "$proj_dir/BadApple.sim/sim_1/behav/xsim/data/golden"
set synth_data_dir "$proj_dir/BadApple.runs/synth_1/data/golden"
file mkdir $xsim_data_dir
file mkdir $synth_data_dir
foreach f [glob -nocomplain "$root/data/golden/*"] {
    file copy -force $f $xsim_data_dir
}
if {[file exists "$root/data/golden/clip_bram_32bit.hex"]} {
    file copy -force "$root/data/golden/clip_bram_32bit.hex" $synth_data_dir
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "\n=========================================================="
puts "  PROYEK GUI VIVADO BERHASIL DIBUAT!"
puts "  Buka file : $proj_dir/BadApple.xpr"
puts "  Top Sim   : tb_top_oled (ubah via klik kanan 'Set as Top' di Simulation Sources)"
puts "  VHDL 2008 : Aktif untuk semua berkas .vhd"
puts "  Golden    : Tersalin ke $xsim_data_dir"
puts "=========================================================="
close_project
