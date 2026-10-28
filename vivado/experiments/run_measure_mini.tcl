set_param general.maxThreads 4
set part "xc7a35tcpg236-1"

puts "=== MEMULAI EKSPERIMEN 1: MINI LED UART ==="
read_vhdl "vivado/experiments/mini_led_uart.vhd"
read_xdc "vivado/experiments/mini_led_uart.xdc"

puts "--- Menjalankan Synth Design ---"
synth_design -top mini_led_uart -part $part

puts "--- Menjalankan Implementation (Opt, Place, Route) ---"
opt_design
place_design
route_design

puts "--- Menghasilkan Bitstream Uncompressed ---"
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
write_bitstream -force -raw_bitfile -bin_file "vivado/experiments/mini_uncompressed.bit"

puts "--- Menghasilkan Bitstream Compressed ---"
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force -raw_bitfile -bin_file "vivado/experiments/mini_compressed.bit"

puts "--- Menghasilkan File CFGMEM Flash SPIx4 32 Mbit (4MB) ---"
write_cfgmem -format bin -size 4 -interface SPIx4 -loadbit "up 0x0 vivado/experiments/mini_uncompressed.bit" -file "vivado/experiments/mini_uncompressed_cfgmem.bin" -force
write_cfgmem -format bin -size 4 -interface SPIx4 -loadbit "up 0x0 vivado/experiments/mini_compressed.bit" -file "vivado/experiments/mini_compressed_cfgmem.bin" -force
write_cfgmem -format mcs -size 4 -interface SPIx4 -loadbit "up 0x0 vivado/experiments/mini_compressed.bit" -file "vivado/experiments/mini_compressed_cfgmem.mcs" -force

puts "=== EKSPERIMEN 1 SELESAI ==="
exit 0
