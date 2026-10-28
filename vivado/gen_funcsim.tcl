# vivado/gen_funcsim.tcl
# Menghasilkan netlist fungsional pasca-sintesis untuk top.vhd
# Dikonfigurasi dengan generic mode dipercepat (BAUD_RATE=25MHz, TARGET_FPS=1500)
# agar seluruh 90 frame dapat disimulasikan secara byte-exact dalam hitungan menit.

set root [file normalize [file join [file dirname [info script]] ..]]
set part "xc7a35tcpg236-1"
set output_dir "$root/vivado/funcsim"

file mkdir $output_dir

puts "=========================================================="
puts "  GENERATE POST-SYNTHESIS FUNCTIONAL NETLIST (FUNCSIM)   "
puts "=========================================================="

read_vhdl -vhdl2008 [list \
    "$root/hdl/frame_timer.vhd" \
    "$root/hdl/uart_tx.vhd" \
    "$root/hdl/frame_source.vhd" \
    "$root/hdl/decoder.vhd" \
    "$root/hdl/frame_buffer.vhd" \
    "$root/hdl/ascii_sink.vhd" \
    "$root/hdl/top.vhd" \
]

read_xdc [list "$root/constraints/basys3.xdc"]

synth_design -top top -part $part -flatten_hierarchy rebuilt -generic BAUD_RATE=25000000 -generic TARGET_FPS=1500

write_vhdl -mode funcsim -force "$output_dir/top_funcsim.vhd"

puts "=========================================================="
puts "  NETLIST FUNCSIM BERHASIL DIHASILKAN                    "
puts "=========================================================="
