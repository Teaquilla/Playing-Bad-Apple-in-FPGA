set_param general.maxThreads 4
set part "xc7a35tcpg236-1"

puts "=== MEMULAI EKSPERIMEN 2: MINI BRAM CLIP 90 FRAME ==="
read_vhdl "vivado/experiments/mini_bram_clip.vhd"
read_xdc "vivado/experiments/mini_led_uart.xdc"

puts "--- Menjalankan Synth Design ---"
synth_design -top mini_bram_clip -part $part

puts "--- Menjalankan Implementation (Opt, Place, Route) ---"
opt_design
place_design
route_design

puts "--- Laporan Utilisasi BRAM ---"
report_utilization -file "vivado/experiments/bram_utilization.rpt"

puts "--- Menghasilkan Bitstream Uncompressed (dengan BRAM 90 frame) ---"
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
write_bitstream -force -raw_bitfile -bin_file "vivado/experiments/bram_clip_uncompressed.bit"

puts "--- Menghasilkan Bitstream Compressed (dengan BRAM 90 frame) ---"
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force -raw_bitfile -bin_file "vivado/experiments/bram_clip_compressed.bit"

puts "--- Menghasilkan File CFGMEM Flash SPIx4 32 Mbit (4MB) ---"
write_cfgmem -format bin -size 4 -interface SPIx4 -loadbit "up 0x0 vivado/experiments/bram_clip_compressed.bit" -file "vivado/experiments/bram_clip_compressed_cfgmem.bin" -force

puts "=== EKSPERIMEN 2 SELESAI ==="
exit 0
