# Bad Apple!! — Digilent Basys 3 (VHDL-2008 + OLED SPI + ASCII UART)

Implementasi pemutar animasi **Bad Apple!!** (128×64 monokrom @ 30 FPS) pada FPGA **Digilent Basys 3 (`xc7a35tcpg236-1`)** dengan dua mode masukan (**M1 Klip ROM 90 Frame** dan **M2 Streaming UART RX 921.600 baud + RLE**), keluaran **ASCII VT100 via UART (`RsTx`)**, keluaran **OLED SSD1306 SPI 6,25 MHz** di Pmod JA, dan pemutar audio sinkron di laptop (**A1 WASAPI**).

---

## Prasyarat

- **Xilinx/AMD Vivado** (diuji di Vivado 2026.1; mendukung simulasi `xsim` dengan **VHDL-2008**).
- **Python 3.10+** *(opsional, hanya untuk unit test PC, ekstraksi video, dan streamer serial)*.
- **Ruang penyimpanan & RAM:**
  - Simulasi **CLI (`-R`)**: sangat ringan (hitungan MB, selesai cepat).
  - Simulasi **Vivado GUI dengan waveform (`.wdb`)**: untuk testbench full-system berdurasi ratusan milidetik sampai detik (puluhan juta siklus clock 100 MHz), siapkan **ruang kosong disk minimal ~15–30 GB** (termasuk `pagefile.sys` Windows dan cache `%TEMP%` Vivado).

---

## Cara Simulasi di Vivado (Pilih Salah Satu)

### Opsi A — Simulasi Cepat via CLI (Paling Ringan & Direkomendasikan)

Buka PowerShell di folder root repo:

```powershell
# Jalankan seluruh 19 testbench HDL secara otomatis (tanpa merekam .wdb raksasa)
powershell -ExecutionPolicy Bypass -File vivado\sim_all.ps1
```

> Jika Vivado terpasang di lokasi non-standar (misalnya `C:\Xilinx\Vivado\2024.2`), set environment variable dulu sebelum menjalankan skrip:
> ```powershell
> $env:VIVADO_SETTINGS = "C:\Xilinx\Vivado\2024.2\settings64.bat"
> powershell -ExecutionPolicy Bypass -File vivado\sim_all.ps1
> ```

Untuk membuka **waveform GUI hanya untuk 1 testbench** setelah snapshot dibuat (atau compile manual dari root repo agar path `data/golden/` langsung terbaca):

```powershell
. .\vivado\env.ps1
xsim snap_tb_top_oled -gui
```
Di jendela `xsim` GUI, ketik di *Tcl Console*: `log_wave -r /*` lalu `run 40 ms` (atau `run -all`).

---

### Opsi B — Buka & Simulasi di Vivado IDE Lengkap (`.xpr`)

Repo ini tidak menyimpan file `.xpr` agar Git tetap bersih, tetapi sudah disediakan generator 1 perintah yang otomatis:
- membuat proyek `BadApple.xpr` (`xc7a35tcpg236-1`),
- mengatur **seluruh file `.vhd` ke `VHDL 2008`**, dan
- menyalin `data/golden/*` ke direktori simulasi `xsim` agar testbench bisa membuka file `.hex`.

1. Jalankan di PowerShell dari root repo:
   ```powershell
   powershell -ExecutionPolicy Bypass -File vivado\env.ps1 vivado -mode batch -nojournal -nolog -source vivado\create_project.tcl
   ```
2. Buka **`vivado/project_gui/BadApple.xpr`** di Vivado.
3. *(Opsional)* Di panel **Simulation Sources**, klik kanan testbench yang diinginkan $\rightarrow$ **Set as Top** (bawaan: `tb_top_oled`).
4. Klik **Flow Navigator $\rightarrow$ Simulation $\rightarrow$ Run Simulation $\rightarrow$ Run Behavioral Simulation**.
5. Di *Tcl Console*, ketik `run -all` (atau batasi misalnya `run 50 ms` jika ingin melihat waveform tanpa menghabiskan puluhan GB disk).

---

## Daftar Testbench Utama (`sim/`)

| Testbench | Cakupan Pengujian |
|---|---|
| `tb_top_oled` | Sistem penuh `top.vhd` + OLED SPI (`mem` & `mem2`, Mode Clip `SW0=0` & Streaming `SW0=1`) |
| `tb_top_stream` | Pipeline streaming UART RX $\rightarrow$ FIFO $\rightarrow$ Parser $\rightarrow$ RLE $\rightarrow$ Frame Buffer $\rightarrow$ ASCII TX |
| `tb_top` | Integrasi M1 Klip ROM 90 frame byte-exact (`95.310 B`) |
| `tb_stream_rx` | Rantai penerima serial + dekoder RLE + uji vektor galat |
| `tb_oled_spi` | Protokol SPI Mode 0 (6,25 MHz), reset, urutan inisialisasi, & rekonstruksi piksel |
| `tb_frame_buffer_dual` | Dual-BRAM (`mem` & `mem2`), swap atomik, & proteksi `read_busy` |
| Lainnya (`tb_*`) | Unit test tiap modul (`uart_rx`, `uart_tx`, `rx_fifo`, `packet_parser`, `rle_decoder`, `frame_timer`, `frame_source`, `decoder`, `frame_buffer`, `ascii_sink`, serta modul daun opsional `audio_pwm`, `audio_fifo`, `tb_parser_audio`) |

> Catatan: `sim/tb_top_funcsim.vhd` hanya untuk simulasi netlist pasca-sintesis khusus konfigurasi M1 (via `vivado/gen_funcsim.tcl`), bukan untuk `sim_all.ps1` / `create_project.tcl`.

---

## Setup Python & Unit Test PC (Opsional)

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r python\requirements.txt
.\.venv\Scripts\python.exe -m pytest -q
```

Panduan bring-up perangkat keras Basys 3 & OLED tersedia di [docs/BRINGUP.md](docs/BRINGUP.md), spesifikasi teknis di [docs/SPEC.md](docs/SPEC.md), dan status terkini proyek di [docs/STATUS.md](docs/STATUS.md).
