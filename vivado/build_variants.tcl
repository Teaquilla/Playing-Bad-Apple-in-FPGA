# vivado/build_variants.tcl
# Membangun 4 varian orientasi OLED SSD1306: (OLED_REMAP_SEG A0/A1) x (OLED_REMAP_COM C0/C8)
# Target: Digilent Basys 3 (Artix-7 xc7a35tcpg236-1)
# Menggunakan XDC proyek (constraints/basys3.xdc) + XDC usulan (constraints/basys3_m4_pmod.proposed.xdc)
# Seluruh keluaran ditulis ke scratch/build_variants/<VARIAN>/ (tanpa mengubah constraints/)

set root [file normalize [file join [file dirname [info script]] ..]]
set part "xc7a35tcpg236-1"
set out_root "$root/scratch/build_variants"

file mkdir $out_root

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

# Daftar varian: {NamaVarian OLED_REMAP_SEG OLED_REMAP_COM}
# Catatan: format VHDL hex untuk generic Vivado std_logic_vector(7 downto 0) menggunakan X".." atau 8'h..
set variants [list \
    [list "A0_C0" "8'hA0" "8'hC0"] \
    [list "A0_C8" "8'hA0" "8'hC8"] \
    [list "A1_C0" "8'hA1" "8'hC0"] \
    [list "A1_C8" "8'hA1" "8'hC8"] \
]

puts "=================================================================="
puts "  MEMULAI BUILD 4 VARIAN ORIENTASI OLED (BASYS 3 xc7a35tcpg236-1)"
puts "=================================================================="
puts "Root dir   : $root"
puts "Output dir : $out_root"

foreach v $variants {
    set vname [lindex $v 0]
    set seg_val [lindex $v 1]
    set com_val [lindex $v 2]
    set vdir "$out_root/$vname"
    file mkdir $vdir

    puts "\n------------------------------------------------------------------"
    puts "  VARIAN: $vname | OLED_REMAP_SEG=$seg_val | OLED_REMAP_COM=$com_val"
    puts "------------------------------------------------------------------"

    create_project -in_memory -part $part
    read_vhdl -vhdl2008 $hdl_files
    read_xdc $xdc_files

    synth_design -top top -part $part -flatten_hierarchy rebuilt \
        -generic "OLED_REMAP_SEG=$seg_val" \
        -generic "OLED_REMAP_COM=$com_val"

    opt_design
    place_design
    route_design

    report_utilization -file "$vdir/utilization_${vname}.rpt"
    report_timing_summary -file "$vdir/timing_summary_${vname}.rpt"
    report_drc -file "$vdir/drc_${vname}.rpt"

    set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
    write_bitstream -force -bin_file "$vdir/top_${vname}_compressed.bit"

    close_project
    puts "  SELESAI VARIAN: $vname -> $vdir/top_${vname}_compressed.bit"
}

puts "\n=================================================================="
puts "  SELURUH 4 VARIAN ORIENTASI OLED SELESAI DIBANGUN!               "
puts "=================================================================="
