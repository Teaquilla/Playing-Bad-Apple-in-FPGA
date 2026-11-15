# vivado/build_variants.tcl
# Membangun SATU varian orientasi OLED SSD1306 (atau baseline tanpa -generic)
# dalam proses Vivado terisolasi tanpa berbagi status lintas varian.
# Penggunaan:
#   vivado -mode batch -nojournal -nolog -source vivado/build_variants.tcl -tclargs <SEG|BASELINE> <COM|BASELINE> <OUTDIR>
# Target: Digilent Basys 3 (Artix-7 xc7a35tcpg236-1)
# Menggunakan XDC proyek (constraints/basys3.xdc) + XDC usulan (constraints/basys3_m4_pmod.proposed.xdc)

if {$argc < 3} {
    error "Argumen kurang: -tclargs <SEG|BASELINE> <COM|BASELINE> <OUTDIR>"
}

set seg_arg [string trim [lindex $argv 0]]
set com_arg [string trim [lindex $argv 1]]
set vdir    [file normalize [string trim [lindex $argv 2]]]
set vname   [file tail $vdir]

proc normalize_hex_generic {val} {
    if {[regexp {^[0-9A-Fa-f]{2}$} $val]} {
        return "8'h[string toupper $val]"
    }
    return $val
}

set root [file normalize [file join [file dirname [info script]] ..]]
set part "xc7a35tcpg236-1"
file mkdir $vdir

set is_baseline 0
if {[string equal -nocase $seg_arg "BASELINE"] || $seg_arg eq ""} {
    set is_baseline 1
} else {
    set seg_val [normalize_hex_generic $seg_arg]
    set com_val [normalize_hex_generic $com_arg]
}

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
    "$root/hdl/top.vhd" \
]

set xdc_files [list \
    "$root/constraints/basys3.xdc" \
    "$root/constraints/basys3_m4_pmod.proposed.xdc" \
]

puts "=================================================================="
if {$is_baseline} {
    puts "  BUILD VARIAN TERISOLASI: $vname (BASELINE TANPA -generic)"
} else {
    puts "  BUILD VARIAN TERISOLASI: $vname (OLED_REMAP_SEG=$seg_val, OLED_REMAP_COM=$com_val)"
}
puts "=================================================================="
puts "Root dir   : $root"
puts "Output dir : $vdir"

create_project -in_memory -part $part
read_vhdl -vhdl2008 $hdl_files
read_xdc $xdc_files

if {$is_baseline} {
    synth_design -top top -part $part -flatten_hierarchy rebuilt
} else {
    synth_design -top top -part $part -flatten_hierarchy rebuilt \
        -generic "OLED_REMAP_SEG=$seg_val" \
        -generic "OLED_REMAP_COM=$com_val"
}

opt_design
place_design
route_design

write_checkpoint -force "$vdir/top_routed_${vname}.dcp"
report_utilization -file "$vdir/utilization_${vname}.rpt"
report_utilization -hierarchical -file "$vdir/utilization_hierarchical_${vname}.rpt"
report_timing_summary -file "$vdir/timing_summary_${vname}.rpt"
report_drc -file "$vdir/drc_${vname}.rpt"

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force -bin_file "$vdir/top_${vname}_compressed.bit"

close_project
puts "  SELESAI VARIAN TERISOLASI: $vname -> $vdir/top_${vname}_compressed.bit"
