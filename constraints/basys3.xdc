## constraints/basys3.xdc
## Berdasarkan Digilent Basys 3 Master XDC resmi:
## https://raw.githubusercontent.com/Digilent/digilent-xdc/master/Basys-3-Master.xdc

# Clock signal 100 MHz oscillator
set_property PACKAGE_PIN W5 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

# Center Button (Reset / Restart Video saat SW0 = 1)
set_property PACKAGE_PIN U18 [get_ports btnC]
set_property IOSTANDARD LVCMOS33 [get_ports btnC]

# Directional Push Buttons (Media Control Streaming PC saat SW0 = 1)
set_property PACKAGE_PIN T18 [get_ports btnU]
set_property IOSTANDARD LVCMOS33 [get_ports btnU]

set_property PACKAGE_PIN W19 [get_ports btnL]
set_property IOSTANDARD LVCMOS33 [get_ports btnL]

set_property PACKAGE_PIN T17 [get_ports btnR]
set_property IOSTANDARD LVCMOS33 [get_ports btnR]

set_property PACKAGE_PIN U17 [get_ports btnD]
set_property IOSTANDARD LVCMOS33 [get_ports btnD]

# Switch SW0 (Mode Selector: 0 = M1 BRAM Clip, 1 = M2 PC Streaming)
set_property PACKAGE_PIN V17 [get_ports {sw[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw[0]}]

# USB-RS232 Interface
set_property PACKAGE_PIN B18 [get_ports RsRx]
set_property IOSTANDARD LVCMOS33 [get_ports RsRx]

set_property PACKAGE_PIN A18 [get_ports RsTx]
set_property IOSTANDARD LVCMOS33 [get_ports RsTx]

# LEDs (8 LED status)
set_property PACKAGE_PIN U16 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]

set_property PACKAGE_PIN E19 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]

set_property PACKAGE_PIN U19 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]

set_property PACKAGE_PIN V19 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

set_property PACKAGE_PIN W18 [get_ports {led[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[4]}]

set_property PACKAGE_PIN U15 [get_ports {led[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[5]}]

set_property PACKAGE_PIN U14 [get_ports {led[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[6]}]

set_property PACKAGE_PIN V14 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[7]}]

# Configuration Bank Voltage Select & SPI properties for Basys 3
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
