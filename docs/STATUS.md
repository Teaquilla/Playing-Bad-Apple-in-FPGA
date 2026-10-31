# Status Proyek: Bad Apple di Basys 3 (STATUS.md)

Dokumen ringkasan eksekutif status terkini proyek, metrik implementasi, keputusan arsitektur, dan daftar tunggu perangkat keras.

---

## 1. Status Milestone

| Milestone | Deskripsi | Status | Catatan |
|---|---|---|---|
| **M0** | Riset, Pipeline Kompresi Python, & Spesifikasi Audio | **SELESAI** | 36 unit test pytest lulus (100% PASS), video 2:1 native (6.532 frame), RLE 8-bit, 3 varian WAV audio. |
| **M1** | Klip ROM On-Chip, Dekoder RLE, Pipeline ASCII Terminal, & Bitstream | **SELESAI\*** | Seluruh modul HDL terverifikasi *byte-exact* 90 frame (95.310 B) di RTL & Netlist Pasca-Sintesis. Bitstream terkompresi 4,40 Mbit. <br>\**Catatan: Pengujian fisik di board Basys 3 tertunda ketersediaan hardware.* |
| **M2a** | Jalur Data Penerima Serial Streaming & Dekoder RLE (UART RX, FIFO 2KB, Parser, RLE Decoder) | **SELESAI** | 4 modul HDL lolos sintesis OOC (total 374 LUT, 320 FF, 1x RAMB18E1). 12 testbench xsim PASS (100%), termasuk tb_stream_rx byte-exact 90 frame & pengujian vektor galat. Integrasi ke top dijadwalkan pada M2b. |
| **M2b** | Integrasi Top (`STREAMING_MODE`), Buffer Swap Tertunda, & Host Streamer PC | **SELESAI (Boardless)** | Integrasi penuh top.vhd (M1 BRAM clip + M2 streaming), delayed buffer swap, bitstream routed (3.126 LUT, 618 FF, 2x RAMB18E1, WNS +1,285 ns). 13 testbench xsim PASS (100%), byte-exact 90 frame & vektor galat. |
| **M3** | Output Audio PWM / PDM & Pengkabelan Mono | **BELUM DIMULAI** | Menunggu evaluasi pendengaran D-5 dan penyelesaian M2. |
| **M4** | Integrasi Menyeluruh, Demonstrasi Penuh, & Finalisasi Laporan | **BELUM DIMULAI** | Menunggu integrasi M2 + M3 di board fisik. |

---

## 2. Tabel Hasil Verifikasi & Implementasi

### A. Hasil Verifikasi Testbench (xsim Vivado 2026.1)
Semua testbench berjalan secara otomatis dan memverifikasi keluaran secara deterministik:

| Testbench | Modul yang Diuji | Mode Pengujian | Hasil | Keterangan |
|---|---|---|---|---|
| `tb_frame_timer` | `frame_timer.vhd` | 100 MHz clock, 30 FPS tick | **PASS** | Periode presisi 3.333.333 siklus clock |
| `tb_uart_tx` | `uart_tx.vhd` | 921.600 baud serial transmission | **PASS** | Bit framing 8N1 terverifikasi byte-exact |
| `tb_decoder` | `decoder.vhd` | RLE per baris ke stream uncompressed | **PASS** | Verifikasi dekompresi data baris |
| `tb_frame_buffer` | `frame_buffer.vhd` | Ping-pong BRAM buffer 2048x8 | **PASS** | Swap atomic aman, proteksi read_busy |
| `tb_ascii_sink` | `ascii_sink.vhd` | Bit-unpacking, Ramp A, frame wrapping | **PASS** | Byte-exact 90 frame (95.310 B) vs `ascii.bin` |
| `tb_top` | `top.vhd` (RTL) | Integrasi penuh top-level | **PASS** | Byte-exact 90 frame (95.310 B) vs `ascii.hex` |
| `tb_top_funcsim` | `top_funcsim.vhd` | Netlist Pasca-Sintesis (Gate-level) | **PASS** | Byte-exact 90 frame (95.310 B), sintesis lossless |
| `tb_uart_rx` | `uart_rx.vhd` | Uji baud dipercepat & 921.600 baud asli | **PASS** | Sampling tengah bit 8N1 & sinkronisasi 2-FF terverifikasi |
| `tb_rx_fifo` | `rx_fifo.vhd` | BRAM FIFO 2048x8, commit & rollback | **PASS** | Pointer spekulatif rollback ke SOF+1 pada galat |
| `tb_packet_parser` | `packet_parser.vhd` | FSM HUNT..CHK, timeout, error counters | **PASS** | Validasi header, footer, checksum, & penolakan korupsi |
| `tb_rle_decoder` | `rle_decoder.vhd` | Dekoder RLE per baris ke format kanonik | **PASS** | 1.024 B per frame, deteksi run overflow (>128 px) |
| `tb_stream_rx` | Pipeline gabungan M2a | Rantai UART RX $\rightarrow$ FIFO $\rightarrow$ Parser $\rightarrow$ RLE | **PASS** | 90 frame byte-exact vs `frames.bin` (0 mismatch); vektor galat sesuai `stream_expected.txt` |
| `tb_top_stream` | Integrasi Penuh Streaming Top | End-to-end streaming, delayed swap, sink ASCII, 25 MHz & 921.600 baud | **PASS** | 90 frame byte-exact (95.310 B) vs `ascii.hex`, penolakan checksum korup, resinkronisasi false SOF & byte insertion, uji real-time 921.600 baud |

### B. Metrik Implementasi Hardware (Target: Xilinx Artix-7 `xc7a35tcpg236-1`)

#### 1. Sintesis Out-Of-Context (OOC) Modul M2a (Jalur Data Penerima Streaming)
Diukur secara terisolasi per modul (`synth_design -mode out_of_context`):

| Modul | Total Slice LUTs | Logic LUTs | Slice Registers (FF) | Block RAM Tile | RAMB18E1 | Catatan Desain |
|---|---|---|---|---|---|---|
| `uart_rx` | **30** (0,14%) | 30 | **31** (0,07%) | 0 (0,00%) | 0 | 2-FF sync, oversampling 16x baud clock |
| `rx_fifo` | **56** (0,27%) | 56 | **45** (0,11%) | **0,5** (1,00%) | **1** | Inferensi 1x RAMB18E1 murni tanpa peringatan Synth 8-6040 |
| `packet_parser` | **133** (0,64%) | 133 | **182** (0,44%) | 0 (0,00%) | 0 | FSM protokol paket, watchdog timeout, counter galat |
| `rle_decoder` | **155** (0,75%) | 155 | **62** (0,15%) | 0 (0,00%) | 0 | Run expander 8-bit, deteksi overflow baris (>128 px) |
| **Total M2a** | **374** (1,80%) | **374** | **320** (0,77%) | **0,5** (1,00%) | **1** | Seluruh modul siap dihubungkan ke top |

#### 2. Implementasi Penuh Bitstream M1 (Klip ROM On-Chip)

| Parameter | Hasil Terukur | Batas Perangkat | Utilisasi (%) | Status |
|---|---|---|---|---|
| **Clock Freq** | 100,000 MHz (10,000 ns) | - | - | Sesuai osilator Basys 3 |
| **Worst Negative Slack (WNS)** | **+1,485 ns** | $\ge 0,000\text{ ns}$ | - | **TIMING MET** (Slack aman) |
| **Worst Hold Slack (WHS)** | **+0,080 ns** | $\ge 0,000\text{ ns}$ | - | **TIMING MET** |
| **LUT (Logic)** | **2.750** (ROM 2.606, Timer 62, Sink 46, Top 1) | 20.800 | **13,22%** | Sangat longgar |
| **Flip-Flop (FF)** | **348** | 41.600 | **0,84%** | Sangat hemat |
| **Block RAM Tile** | **0,5 Tile** (1x RAMB18E1 ping-pong buffer) | 50 Tile (100 RAMB18) | **1,00%** | 49,5 tile sisa untuk M2/M3 |
| **I/O Pin** | **4 Pin** (`clk`, `btnC`, `RsTx`, `RsRx`) | 106 Pin | **3,77%** | Pemasangan pin sesuai Basys 3 |
| **Ukuran Bitstream (Uncompressed)** | **2.192.221 Byte** (~17,54 Mbit) | 32 Mbit SPI Flash | 54,8% | Muat di flash Basys 3 |
| **Ukuran Bitstream (Compressed)** | **549.964 Byte** (**~4,40 Mbit**) | 32 Mbit SPI Flash | **13,7%** | Kompresi bitstream 3,98x |

---

## 3. Matriks Keputusan Desain (DECISIONS.md)

### A. Keputusan Ditutup (Closed)
- **D-1:** Bahasa HDL VHDL-2008, simulator Vivado xsim.
- **D-2:** Laju frame 30 FPS (generic `TARGET_FPS`).
- **D-3:** PC sebagai timekeeper utama pada mode streaming.
- **D-4:** Codec video RLE per baris 8-bit (Fixed 8-bit run-length).
- **D-8:** Vivado 2026.1 via skrip isolasi `env.ps1`, part `xc7a35tcpg236-1`.
- **D-9:** Pemutaran standalone dari SPI flash ditutup sebagai target lanjutan.
- **D-11:** Rasio aspek video 2:1 native (1280x640), resize 10:1 tanpa bilah hitam.
- **D-12:** Jalur arsitektur video penuh utama adalah **Streaming UART RX dari PC**.
- **D-Ramp / D-Bin:** Ramp ASCII A (`" .:-=+*#@"`) & Binerisasi Ambang Tetap (128).

### B. Keputusan Terbuka (Open)
- **D-5 (Audio):** Parameter audio final (laju sampel 8 kHz vs 6 kHz IMA ADPCM mono) menunggu evaluasi tim terhadap berkas contoh audio di `data/preview/`.
- **D-10 (Kontainer Media):** Struktur paket streaming audio/video (diputuskan di M2: video frame RLE mandiri, audio stream disisipkan atau interleave).

---

## 4. Pekerjaan Tertunda Menunggu Board Fisik Basys 3
1. **Pemrograman Bitstream:** Validasi pemrograman flash / SRAM via Vivado Hardware Manager (`top_compressed.bit`).
2. **Koneksi UART Fisik:** Verifikasi komunikasi baud rate 921.600 baud melalui jembatan USB-UART FTDI FT2232HQ pada Basys 3.
3. **Capture & Display Real-Time:** Menjalankan `python/uart_capture.py` dan terminal VT100 lokal pada port COM fisik untuk memastikan 90 frame klip berputar tanpa glitch visual atau dropped byte.
4. **Validasi Tombol Reset:** Menguji fungsionalitas tombol tengah (`btnC`) untuk reset sinkron sistem.
