# ==============================================================================
# PIN USULAN MODUL OLED SSD1306 SPI 7-PIN PADA HEADER PMOD JA BASYS 3
# Berkas: constraints/basys3_m4_pmod.proposed.xdc
# Status: DIASUMSIKAN: belum dicocokkan dengan Tabel 6 manual Basys 3; pengguna memverifikasi.
# Catatan Daya: Modul OLED 7-pin membutuhkan suplai GND (Pin 5/11) dan VCC 3,3V (Pin 6/12)
#               yang disediakan secara bawaan oleh header Pmod JA Basys 3
#               (DIASUMSIKAN: pengguna memeriksa di manual hardware).
# ==============================================================================

# Sinyal Kontrol & Serial SPI OLED pada Header JA (Pmod Standar)
# JA1 (Pin 1) - OLED Reset (RES#)
set_property PACKAGE_PIN J1 [get_ports oled_res]
set_property IOSTANDARD LVCMOS33 [get_ports oled_res]

# JA2 (Pin 2) - OLED Data/Command (D/C#)
set_property PACKAGE_PIN L2 [get_ports oled_dc]
set_property IOSTANDARD LVCMOS33 [get_ports oled_dc]

# JA3 (Pin 3) - OLED Chip Select (CS#)
set_property PACKAGE_PIN J2 [get_ports oled_cs]
set_property IOSTANDARD LVCMOS33 [get_ports oled_cs]

# JA4 (Pin 4) - OLED Serial Clock (SCLK / D0)
set_property PACKAGE_PIN G2 [get_ports oled_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports oled_sclk]

# JA7 (Pin 7) - OLED Serial Data (MOSI / SDIN / D1)
set_property PACKAGE_PIN H1 [get_ports oled_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports oled_mosi]
