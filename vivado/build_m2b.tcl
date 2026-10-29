# vivado/build_m2b.tcl
# Skrip batch Vivado untuk sintesis, implementasi, dan pembuatan bitstream M2b (top)
# Part target: Basys 3 (xc7a35tcpg236-1)

set root [file normalize [file join [file dirname [info script]] ..]]
set part "xc7a35tcpg236-1"
set output_dir "$root/vivado/build_m2b"

file mkdir $output_dir

puts "=========================================================="
puts "  MEMULAI BUILD BATCH VIVADO M2B (STREAMING + TOP INTEGRATION)"
puts "=========================================================="
puts "Root directory : $root"
puts "Output dir     : $output_dir"

# 1. Baca source HDL VHDL-2008
puts "\n[1/6] Membaca berkas VHDL-2008..."
read_vhdl -vhdl2008 [list \
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
    "$root/hdl/top.vhd" \
]

# 2. Baca constraints Basys 3
puts "\n[2/6] Membaca constraints constraints/basys3.xdc..."
read_xdc [list "$root/constraints/basys3.xdc"]

# 3. Sintesis Desain
puts "\n[3/6] Menjalankan sintesis desain (synth_design)..."
synth_design -top top -part $part -flatten_hierarchy rebuilt

# 4. Implementasi (opt, place, route)
puts "\n[4/6] Menjalankan implementasi (opt_design, place_design, route_design)..."
opt_design
place_design
route_design

# 5. Laporan Timing & Utilisasi
puts "\n[5/6] Membuat laporan timing summary dan utilisasi..."
report_timing_summary -file "$output_dir/timing_summary.rpt"
report_utilization -file "$output_dir/utilization.rpt"
report_utilization -hierarchical -file "$output_dir/utilization_hierarchical.rpt"

# 6. Pembuatan Bitstream
puts "\n[6/6] Menghasilkan bitstream..."

# a. Bitstream Terkompresi
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force -bin_file "$output_dir/top_compressed.bit"

# b. Bitstream Tidak Terkompresi
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
write_bitstream -force -bin_file "$output_dir/top_uncompressed.bit"

puts "\n=========================================================="
puts "  BUILD VIVADO M2B SELESAI DENGAN SUKSES!                "
puts "=========================================================="
