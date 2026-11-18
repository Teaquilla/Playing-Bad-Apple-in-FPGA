# Bad Apple!! — Digilent Basys 3 (VHDL-2008 + OLED SPI + ASCII UART)

Implementasi pemutar animasi **Bad Apple!!** (resolusi **128×64** monokrom @ **30 FPS**) pada FPGA **Digilent Basys 3 (`xc7a35tcpg236-1`)** dengan dua mode pemutaran:

- **Mode 1 (`SW0 = 0`) — Klip ROM Standalone:** Memutar klip **90 frame** langsung dari memori internal FPGA tanpa pengirim PC.
- **Mode 2 (`SW0 = 1`) — Streaming UART RX + RLE:** Menerima aliran paket terkompresi RLE dari PC pada **921.600 baud (8N1)** untuk memutar video penuh (6.532 frame) beserta audio sinkron dari laptop (**WASAPI**).

Keluaran tampilan berjalan paralel ke:
1. **Terminal PC (ASCII VT100 64×16)** melalui pin UART `RsTx` (`A18`), dan
2. **Layar OLED SSD1306 0,96" SPI 7-pin (6,25 MHz)** pada header **Pmod JA**.

---

## Struktur Singkat Repo

| Folder / File | Fungsi |
|---|---|
| `hdl/` | Seluruh modul VHDL-2008 (`top.vhd`, `uart_rx/tx`, `rx_fifo`, `packet_parser`, `rle_decoder`, `frame_buffer`, `oled_spi`, `ascii_sink`, dll.) |
| `sim/` | 19 testbench behavioral RTL + `tb_top_funcsim.vhd` (khusus netlist M1) |
| `constraints/` | `basys3.xdc` (pin resmi Basys 3) & `basys3_m4_pmod.proposed.xdc` (pin usulan OLED Pmod JA) |
| `data/golden/` | Vektor uji siap pakai (`clip_bram_32bit.hex`, `stream_clip.bin` 90 frame, `ascii.hex/bin`, dll.) |
| `python/` | Skrip streamer PC (`stream_player.py`, `auto_player.py`, `board_check.py`, `make_full_stream.py`, `calibrate_av.py`) |
| `tests/` | Unit test `pytest` untuk seluruh pipeline Python |
| `vivado/` | Skrip simulasi CLI (`sim_all.ps1`), generator proyek GUI (`create_project.tcl`), dan build bitstream (`build_variants.tcl`) |
| `AutoPlay_SW0.bat` | Peluncur klik-2× mode standby di PC (otomatis mulai memutar saat `SW0` digeser `0 -> 1`) |

> **Catatan file media besar:** Berkas video sumber (`media/*.mp4`), audio (`*.wav`), dan stream penuh (`data/stream_full.bin`) **tidak ikut tersimpan di Git** (diabaikan oleh `.gitignore`). Untuk uji coba cepat setelah *clone*, langsung gunakan klip bawaan **`data/golden/stream_clip.bin`** (90 frame). Untuk video penuh, letakkan file MP4/WAV sendiri lalu generate `data/stream_full.bin` dengan `python/make_full_stream.py`.

---

## 1. Coba Cepat di PC (Tanpa Board FPGA & Tanpa Vivado)

Kamu bisa langsung mencoba pipeline streamer + tampilan ASCII di terminal memakai simulator Python **`FakeFPGA`**:

```powershell
# 1. Buat virtual environment & install dependensi
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r python\requirements.txt

# 2. Jalankan seluruh unit test Python
.\.venv\Scripts\python.exe -m pytest -q

# 3. Putar klip uji 90 frame lewat FakeFPGA di terminal
.\.venv\Scripts\python.exe python\stream_player.py --fake-fpga --clip data\golden\stream_clip.bin
```

---

## 2. Simulasi & Build di Xilinx/AMD Vivado

### Prasyarat & Estimasi Penyimpanan
- **Vivado** dengan dukungan **VHDL-2008** (diuji pada Vivado 2026.1).
- **Simulasi CLI (`-R`)**: sangat ringan (hitungan MB, selesai cepat).
- **Simulasi GUI dengan waveform (`.wdb`)**: testbench full-system berjalan ratusan ms hingga detik (puluhan juta siklus clock 100 MHz). Siapkan **ruang kosong disk minimal ~15–30 GB** (untuk file `.wdb`, cache `%TEMP%` Vivado, dan `pagefile.sys` Windows).

### Opsi A — Simulasi Cepat via CLI (Disarankan, Hemat Disk)

Jalankan dari PowerShell di folder root repo:

```powershell
powershell -ExecutionPolicy Bypass -File vivado\sim_all.ps1
```

Skrip ini otomatis mendeteksi lokasi Vivado (atau gunakan `$env:VIVADO_SETTINGS = "C:\Xilinx\Vivado\2024.2\settings64.bat"` jika terpasang di folder lain), mengompilasi dengan `xvhdl -2008`, dan menjalankan seluruh 19 testbench.

Untuk melihat **waveform GUI hanya untuk 1 testbench** (misalnya `tb_top_oled`):
```powershell
. .\vivado\env.ps1
xsim snap_tb_top_oled -gui
```
Di *Tcl Console* `xsim`, jalankan `log_wave -r /*` lalu `run 40 ms` (atau `run -all`).

### Opsi B — Buka Proyek Lengkap di Vivado GUI (`.xpr`)

Repo tidak melacak file `.xpr`, tetapi sudah disediakan skrip generator yang otomatis membuat proyek, mengaktifkan **`VHDL 2008`** untuk semua `.vhd`, dan menyalin `data/golden/` ke folder `sim_1` dan `synth_1`:

```powershell
powershell -ExecutionPolicy Bypass -File vivado\env.ps1 vivado -mode batch -nojournal -nolog -source vivado\create_project.tcl
```

1. Buka **`vivado/project_gui/BadApple.xpr`** di Vivado.
2. *(Opsional)* Di panel **Simulation Sources**, klik kanan testbench pilihan $\rightarrow$ **Set as Top** (bawaan: `tb_top_oled`).
3. Klik **Simulation $\rightarrow$ Run Simulation $\rightarrow$ Run Behavioral Simulation**, lalu di *Tcl Console* ketik `run -all` (atau `run 50 ms` untuk uji singkat yang hemat disk).

> **Catatan `Reset Run`:** Jika kamu menekan *Reset Run* pada `synth_1` atau *Reset Simulation* di Vivado GUI, Vivado menghapus folder sementara beserta salinan `data/golden/` di dalamnya. Jalankan ulang `create_project.tcl` atau salin folder `data\` ke subfolder `.runs\synth_1\` / `.sim\sim_1\behav\xsim\` jika muncul error gagal membuka `data/golden/...`.

### Generate Bitstream untuk Basys 3 (Batch)

```powershell
powershell -ExecutionPolicy Bypass -File vivado\env.ps1 vivado -mode batch -nojournal -nolog -source vivado\build_variants.tcl -tclargs BASELINE BASELINE vivado\build_m4
```
Hasil bitstream tersimpan di `vivado\build_m4\top_build_m4_compressed.bit`.

---

### Daftar Testbench Utama (`sim/`)

| Testbench | Cakupan Pengujian |
|---|---|
| `tb_top_oled` | Sistem penuh `top.vhd` + OLED SPI (`mem` & `mem2`, Mode Clip `SW0=0` & Streaming `SW0=1`) |
| `tb_top_stream` | Pipeline streaming UART RX $\rightarrow$ FIFO $\rightarrow$ Parser $\rightarrow$ RLE $\rightarrow$ Frame Buffer $\rightarrow$ ASCII TX |
| `tb_top` | Integrasi M1 Klip ROM 90 frame byte-exact (`95.310 B`) |
| `tb_stream_rx` | Rantai penerima serial + dekoder RLE + uji vektor galat |
| `tb_oled_spi` | Protokol SPI Mode 0 (6,25 MHz), reset, urutan inisialisasi, & rekonstruksi piksel |
| `tb_frame_buffer_dual` | Dual-BRAM (`mem` & `mem2`), swap atomik, & proteksi `read_busy` |
| Lainnya (`tb_*`) | Unit test tiap modul + modul daun audio opsional (`tb_audio_pwm`, `tb_audio_fifo`, `tb_parser_audio`) |

---

## 3. Menjalankan di Board Fisik Digilent Basys 3 + OLED

### Pemasangan Modul OLED SSD1306 SPI 7-Pin ke Header Pmod JA
Matikan daya (`SW16 = OFF`) dan cabut kabel USB sebelum merangkai kabel jumper. Pemetaan di [constraints/basys3_m4_pmod.proposed.xdc](constraints/basys3_m4_pmod.proposed.xdc) *(verifikasi kecocokan posisi fisik pin dengan Tabel 6 Basys 3 Reference Manual dan silkscreen modul OLED sebelum menyalakan)*:

| Pin Modul OLED | Nama Umum Lain | Header Pmod JA Basys 3 | Pin FPGA |
|---|---|---|---|
| **GND** | `GND` | Pin 5 (atau Pin 11) | `GND` |
| **VCC** | `VCC` / `3V3` | Pin 6 (atau Pin 12) | `3,3 V` |
| **RES** | `RST` | **JA1** (Pin 1) | `J1` |
| **DC** | `D/C` | **JA2** (Pin 2) | `L2` |
| **CS** | `SS` | **JA3** (Pin 3) | `J2` |
| **D0** | `SCLK` / `SCK` / `CLK` | **JA4** (Pin 4) | `G2` |
| **D1** | `MOSI` / `SDIN` / `SDA` | **JA7** (Pin 7) | `H1` |

### Kontrol Saklar, Tombol & Indikator LED di Basys 3
- **`SW16`** (pojok kiri atas): Daya utama board (`ON`/`OFF`).
- **`SW0`** (saklar paling kanan, pin `V17`): **`0` (bawah)** = Mode Klip ROM 90 frame standalone; **`1` (atas)** = Mode Streaming UART dari PC.
- **5 Tombol Pushbutton** *(kendali aktif pada Mode Streaming `SW0 = 1` bersama `AutoPlay_SW0.bat`)*:
  - **`btnC`** (tengah, `U18`): Reset FPGA *(saat `SW0 = 1` juga mengirim perintah Restart Video + Audio ke `00:00`)*.
  - **`btnU`** (atas, `T18`): **Play / Pause**.
  - **`btnR`** (kanan, `T17`): **Forward +5 detik** (+150 frame).
  - **`btnL`** (kiri, `W19`): **Backward -5 detik** (-150 frame).
  - **`btnD`** (bawah, `U17`): **Stop** & kembali ke mode standby.
- **`LED[0]`**: Heartbeat (~6 Hz, menandakan FPGA aktif).
- **`LED[1]`**: Indikator posisi `SW0` (`0` = Mode Klip, `1` = Mode Streaming).
- **`LED[2]`**: TX serial ASCII aktif; **`LED[3..7]`**: Indikator latch galat (underrun, overrun, checksum, panjang/timeout, stream overrun).

### Langkah Uji di Hardware
1. **Atur FTDI Latency Timer (Windows):** Di *Device Manager $\rightarrow$ Ports (COM & LPT) $\rightarrow$ USB Serial Port (COMx) $\rightarrow$ Port Settings $\rightarrow$ Advanced*, ubah **Latency Timer** dari `16 ms` menjadi **`1 ms`** (atau `2 ms`) agar transfer 30 FPS tidak patah-patah.
2. **Program bitstream** ke Basys 3 lewat Vivado Hardware Manager (`SW16 = ON`).
3. **Tes Mode Standalone (`SW0 = 0`):** Animasi klip 90 frame langsung berjalan di OLED; hubungkan PuTTY/Tera Term pada **921.600 baud (8N1)** untuk melihat tampilan ASCII-nya.
4. **Tes Mode Streaming (`SW0 = 1`):** **Tutup PuTTY/Tera Term** terlebih dahulu (port COM Windows hanya bisa dibuka satu program), geser `SW0` ke `1`, lalu cek koneksi:
   ```powershell
   .\.venv\Scripts\python.exe python\board_check.py --frames 5
   ```
   Jika `PASS`, putar klip uji ke board:
   ```powershell
   .\.venv\Scripts\python.exe python\stream_player.py --clip data\golden\stream_clip.bin
   ```

### Cara Praktis Video Penuh: Mode Standby `AutoPlay_SW0.bat`
Untuk memutar video penuh (+ audio laptop) otomatis begitu saklar `SW0` digeser `0 -> 1` tanpa mengetik perintah berulang kali:
1. Pastikan MP4 sumber ada di `media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4` dan audio WAV di `data/audio/bad_apple.wav` *(atau generate manual lewat `python/make_full_stream.py`)*.
2. Setel `SW0 = 0`, tutup terminal serial lain, lalu **klik dua kali [AutoPlay_SW0.bat](AutoPlay_SW0.bat)**.
3. Begitu kamu menaikkan **`SW0` ke `1`**, streaming video penuh dan audio WASAPI otomatis dimulai.

---

Dokumentasi teknis lengkap tersedia di [docs/BRINGUP.md](docs/BRINGUP.md), [docs/SPEC.md](docs/SPEC.md), [docs/DESIGN_M4.md](docs/DESIGN_M4.md), dan [docs/STATUS.md](docs/STATUS.md).
