# vivado/synth_ooc_m2a.tcl
# Sintesis Out-Of-Context untuk modul-modul M2a pada Artix-7 xc7a35tcpg236-1

set part "xc7a35tcpg236-1"
set modules [list \
    [list "uart_rx" [list "hdl/uart_rx.vhd"]] \
    [list "rx_fifo" [list "hdl/rx_fifo.vhd"]] \
    [list "packet_parser" [list "hdl/packet_parser.vhd"]] \
    [list "rle_decoder" [list "hdl/rle_decoder.vhd"]] \
]

foreach mod $modules {
    set top [lindex $mod 0]
    set files [lindex $mod 1]
    puts "\n================================================================="
    puts "  SINTESIS OOC: $top"
    puts "================================================================="
    create_project -in_memory -part $part
    read_vhdl -vhdl2008 $files
    synth_design -top $top -part $part -mode out_of_context
    puts "\n=== UTILIZATION REPORT: $top ==="
    report_utilization -no_primitives
    close_project
}
