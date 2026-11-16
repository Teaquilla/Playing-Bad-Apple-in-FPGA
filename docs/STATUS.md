# Status Proyek: Bad Apple di Basys 3 (STATUS.md)

Dokumen ringkasan eksekutif status terkini proyek, metrik implementasi, keputusan arsitektur, dan daftar tunggu perangkat keras.

---

## 1. Status Milestone

| Milestone | Deskripsi | Status | Catatan |
|---|---|---|---|
| **M0** | Riset, Pipeline Kompresi Python, & Spesifikasi Audio | **SELESAI** | 36 unit test pytest lulus (100% PASS), video 2:1 native (6.532 frame), RLE 8-bit, 3 varian WAV audio. |
| **M1** | Klip ROM On-Chip, Dekoder RLE, Pipeline ASCII Terminal, & Bitstream | **SELESAI\*** | Seluruh modul HDL M1 terverifikasi *byte-exact* 90 frame (95.310 B) di RTL & Netlist Pasca-Sintesis (`tb_top_funcsim` khusus M1: 7 berkas M1, 5 port `top`). Bitstream terkompresi 4,40 Mbit. <br>\**Catatan: Pengujian fisik di board Basys 3 tertunda ketersediaan hardware.* |
| **M2a** | Jalur Data Penerima Serial Streaming & Dekoder RLE (UART RX, FIFO 2KB, Parser, RLE Decoder) | **SELESAI** | 4 modul HDL lolos sintesis OOC (total 374 LUT, 320 FF, 1x RAMB18E1). 12 testbench xsim PASS (100%), termasuk tb_stream_rx byte-exact 90 frame & pengujian vektor galat. Integrasi ke top dijadwalkan pada M2b. |
| **M2b** | Integrasi Top (`STREAMING_MODE`), Buffer Swap Tertunda, & Host Streamer PC | **tag m2b-boardless dibuat di aa81787 (2026-11-01); verifikasi independen pengguna 2026-11-01: sim_all.ps1 13 PASS dan pytest 44 lulus dijalankan pada tree yang python/stream_player.py-nya termodifikasi (belum di-commit); verifikasi Python pada tag persis: belum** | Seluruh 13 testbench xsim lolos (100% PASS), integrasi top.vhd streaming & delayed swap terverifikasi byte-exact 90 frame dan vektor galat. Catatan integritas berkas: tag `m2b-boardless` memuat `data/golden/ascii.bin` versi LF (93.870 B di git object store) [DIVERIFIKASI: `git cat-file -s`]; membutuhkan `core.autocrlf=true` di lingkungan Windows untuk menghasilkan 95.310 B [DIASUMSIKAN: butuh autocrlf=true untuk lulus]. Pada cabang `m3-wip`, `.gitattributes` telah dinormalisasi ke 95.310 B [DIVERIFIKASI]. |
| **M3** | Output Audio Laptop (A1) & Status Audio FPGA (A2) | **Audio FPGA DIBATALKAN; Audio Laptop SINKRON (A1)** | Berdasarkan keputusan pengguna 2026-11-14 ("karena keterbatasan alat dan waktu, kami memutuskan untuk tidak jadi menggunakan speaker, jadi audio hanya dari laptop"), audio FPGA (A2) dibatalkan. Audio diputar eksklusif dari laptop (A1; stream_player.py, WASAPI + disiplin on). Modul daun audio_pwm dan audio_fifo berstatus "di luar lingkup (pengembangan lanjut), tidak diintegrasikan ke top". |
| **M4** | Integrasi Menyeluruh, Demonstrasi Penuh, & Finalisasi Laporan | **DALAM PROSES (BAGIAN 4u: BUILD TERISOLASI M4 — belum terverifikasi pengguna)** | Integrasi OLED SPI SSD1306 pada `top.vhd` dan `frame_buffer.vhd` (duplikasi BRAM Port B2, `mem2`) terverifikasi di build terisolasi 5 konfigurasi (`baseline`, `A0_C0`, `A0_C8`, `A1_C0`, `A1_C8`; 3.266 LUT, 833 FF, WNS +1,345 ns). Audio FPGA (A2) dibatalkan / di luar lingkup; board fisik belum diuji. |

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
| `tb_top_funcsim` | `top_funcsim.vhd` (**khusus M1**) | Netlist Pasca-Sintesis (Gate-level M1) | **PASS** (M1 saja) | Hanya berlaku untuk M1 (`vivado/gen_funcsim.tcl` membaca 7 berkas M1 tanpa `uart_rx`, `rx_fifo`, `packet_parser`, `rle_decoder`, `oled_spi`; `sim/tb_top_funcsim.vhd` memetakan 5 port saja). Tidak ada uji gate-level untuk M4. |
| `tb_uart_rx` | `uart_rx.vhd` | Uji baud dipercepat & 921.600 baud asli | **PASS** | Sampling tengah bit 8N1 & sinkronisasi 2-FF terverifikasi |
| `tb_rx_fifo` | `rx_fifo.vhd` | BRAM FIFO 2048x8, commit & rollback | **PASS** | Pointer spekulatif rollback ke SOF+1 pada galat |
| `tb_packet_parser` | `packet_parser.vhd` | FSM HUNT..CHK, timeout, error counters | **PASS** | Validasi header, footer, checksum, & penolakan korupsi |
| `tb_rle_decoder` | `rle_decoder.vhd` | Dekoder RLE per baris ke format kanonik | **PASS** | 1.024 B per frame, deteksi run overflow (>128 px) |
| `tb_stream_rx` | Pipeline gabungan M2a | Rantai UART RX $\rightarrow$ FIFO $\rightarrow$ Parser $\rightarrow$ RLE | **PASS** | 90 frame byte-exact vs `frames.bin` (0 mismatch); vektor galat sesuai `stream_expected.txt` |
| `tb_top_stream` | Integrasi Penuh Streaming Top | End-to-end streaming, delayed swap, sink ASCII, 25 MHz & 921.600 baud | **PASS** | 90 frame byte-exact (95.310 B) vs `ascii.hex`, penolakan checksum korup, resinkronisasi false SOF & byte insertion, uji real-time 921.600 baud |
| `tb_audio_pwm` | `audio_pwm.vhd` (Varian B) | Modulator PWM 400 kHz, laju 8 kHz, 100 MHz clock | **PASS** | Seluruh 8 pengujian lolos: 22 tick presisi 12.500 siklus, duty cycle 0x00/0x80/0xFF, ramp 256 nilai, disable duty 50%, carrier stabil 250 siklus, kekebalan perubahan enable & sampel di tengah periode, ketepatan latch 1-siklus |
| `tb_audio_fifo` | `audio_fifo.vhd` | FIFO audio 2048 B (1x RAMB18E1), FWFT, speculative write, slip 2-arah | **PASS** | Seluruh 8 pengujian lolos: kapasitas 2048 B & pointer wrap, rollback vs commit 266 B, evaluasi wr_reject & cnt_overflow, pre-roll 0x80 (L >= 1024), underflow saat playing, slip 2-arah terakselerasi (dwell & cooldown), tulis-baca simultan 100 MHz, rantai audio_fifo -> audio_pwm bebas underflow |

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

#### 2. Sintesis Out-Of-Context (OOC) Modul Daun Audio M4 (audio_pwm & audio_fifo)
Diukur secara terisolasi per modul (`synth_design -mode out_of_context` pada `xc7a35tcpg236-1`):

| Modul | Total Slice LUTs | Logic LUTs | Slice Registers (FF) | Block RAM Tile | RAMB18E1 | Catatan Desain |
|---|---|---|---|---|---|---|
| `audio_pwm` | **33** (0,16%) | 33 | **27** (0,06%) | 0 (0,00%) | 0 | Varian B: carrier 250 siklus (400 kHz), sample tick 12.500 siklus (8 kHz), zero jitter, latch selaras periode |
| `audio_fifo` | **175** (0,84%) | 175 | **196** (0,47%) | **0,5** (1,00%) | **1** | BRAM simple dual-port 2048 B murni VHDL-2008, pointer 12-bit, speculative commit & rollback, FWFT output mux, underflow counter, slip dua arah |
| **Total Daun Audio** | **208** (1,00%) | **208** | **223** (0,54%) | **0,5** (1,00%) | **1** | Selesai pada simulasi unit; belum terintegrasi ke top/parser |

#### 3. Implementasi Penuh Bitstream M1 (Klip ROM On-Chip)

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

#### 4. Implementasi Penuh Bitstream M4 Integrasi OLED & Varian Orientasi (`xc7a35tcpg236-1`)

**Status verifikasi:** **belum terverifikasi pengguna** (dibangun menggunakan `vivado/build_variants.ps1` + `vivado/build_variants.tcl` dalam satu proses Vivado terpisah per konfigurasi; menggunakan `constraints/basys3.xdc` dan usulan `constraints/basys3_m4_pmod.proposed.xdc` [DIASUMSIKAN; Pmod JA belum terverifikasi di board]; audio FPGA dibatalkan / tidak disertakan).

| Konfigurasi | Slice LUTs | Slice FF | F7 Muxes | F8 Muxes | RAMB18 (Tile) | WNS (ns) | WHS (ns) | DRC / CW | `.bit` Terkompresi (B) |
|---|---|---|---|---|---|---|---|---|---|
| `baseline` (tanpa `-generic`, bawaan `A1`/`C8`) | **3.266** (15,70%) | **833** (2,00%) | 242 | 97 | **3** (1,5) | **+1,345** | **+0,078** | 0 / 0 | **722.856** |
| `A0_C0` (`OLED_REMAP_SEG=8'hA0`, `COM=8'hC0`) | **3.266** (15,70%) | **833** (2,00%) | 242 | 97 | **3** (1,5) | **+1,345** | **+0,078** | 0 / 0 | **722.856** |
| `A0_C8` (`OLED_REMAP_SEG=8'hA0`, `COM=8'hC8`) | **3.266** (15,70%) | **833** (2,00%) | 242 | 97 | **3** (1,5) | **+1,345** | **+0,078** | 0 / 0 | **722.856** |
| `A1_C0` (`OLED_REMAP_SEG=8'hA1`, `COM=8'hC0`) | **3.266** (15,70%) | **833** (2,00%) | 242 | 97 | **3** (1,5) | **+1,345** | **+0,078** | 0 / 0 | **722.856** |
| `A1_C8` (`OLED_REMAP_SEG=8'hA1`, `COM=8'hC8`) | **3.266** (15,70%) | **833** (2,00%) | 242 | 97 | **3** (1,5) | **+1,345** | **+0,078** | 0 / 0 | **722.856** |

- **Kesetaraan `baseline` vs `A1_C8`:** Identik di seluruh metrik utilisasi/timing (`3.266 LUT`, `833 FF`, `242 F7`, `97 F8`, `3 RAMB18` / `1,5 tile`, `WNS +1,345 ns`, `WHS +0,078 ns`), identik dengan metrik build 4s (`3.266 LUT / 833 FF / 722.856 B`), serta `.bin` mentah identik bit-per-bit (`722.648 B`).
- **Utilisasi Hierarkis M4 (`utilization_hierarchical_*.rpt`, identik di kelima konfigurasi):** `u_source` (`frame_source`) = **2.607 LUT, 191 FF** (ROM klip utuh; pembanding M1 ROM = `2.606 LUT`); `u_rle_dec` = **152 LUT, 61 FF**; `u_oled` (`oled_spi`) = **127 LUT, 210 FF**; `u_parser` = **126 LUT, 126 FF**; `u_timer` = **64 LUT, 32 FF**; `u_fifo` (`rx_fifo`) = **59 LUT, 44 FF, 1 RAMB18**; `u_sink` = **49 LUT, 61 FF**; `(top)` = **2 LUT, 39 FF** (sisa LUT/FF dan `2 RAMB18` merupakan modul ter-*flatten* `u_buf`, `u_uart_rx`, `u_uart_tx`, `u_dec`).
- **Cakupan Simulasi Gate-Level (`funcsim`):** Untuk M4 **tidak ada uji gate-level** (`funcsim`); `sim/tb_top_funcsim.vhd` dan `vivado/gen_funcsim.tcl` hanya berlaku untuk M1 (hanya membaca 7 berkas M1 tanpa `uart_rx`, `rx_fifo`, `packet_parser`, `rle_decoder`, `oled_spi` dan hanya memetakan 5 port `clk`, `btnC`, `RsRx`, `RsTx`, `led`).

---

### C. Catatan Teknis & Audit Implementasi M2b

1. **Perbaikan Evaluasi Stop Bit UART RX (`STOP_BIT = CLKS_PER_BIT - 1`):**
   - **Kondisi:** Pada modul `hdl/uart_rx.vhd`, evaluasi `START_BIT` tetap pada titik tengah bit `clk_cnt = HALF_BIT - 1` [DIVERIFIKASI: baris 77], sedangkan evaluasi `STOP_BIT` diubah menjadi `clk_cnt = CLKS_PER_BIT - 1` [DIVERIFIKASI: baris 109].
   - **Mekanisme & Alasan:** FSM masuk STOP_BIT tepat setelah mencuplik bit data ke-7 di tengah bit itu (8,5 bit dari tepi start). Menunggu HALF_BIT mencuplik pada batas data/stop (9,0 bit); menunggu CLKS_PER_BIT - 1 mencuplik di tengah stop bit (9,5 bit). Terverifikasi xsim pada periode 1055..1115 ns (+-2,76%). Batas teoretis hitungan tangan kira-kira P dalam (1036, 1150) ns [DIASUMSIKAN]. Pada 31a1007, batas lambat sekitar -0,4% baud [DIVERIFIKASI oleh matriks xsim].
   - **Verifikasi Laju Uji 25 MHz:** Pada laju 25 MHz (`CLKS_PER_BIT = 4`), stop bit dievaluasi pada siklus ke-4 (`clk_cnt = 3`), sehingga FSM tidak keluar lebih awal ke `IDLE` dan menyinkronkan seluruh 347 byte vektor galat secara deterministik (0 dropped byte) [DIVERIFIKASI: xsim].

2. **Pembagi Baud Rate & Galat Nominal:**
   - **Formula:** `constant CLKS_PER_BIT : integer := (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;` [DIVERIFIKASI: `hdl/uart_rx.vhd` baris 27, `hdl/uart_tx.vhd` baris 26].
   - **Nilai Terhitung:** Pada clock 100 MHz dan baud 921.600, formula pembulatan terdekat menghasilkan `CLKS_PER_BIT = 109`.
   - **Galat Baud:** Baud aktual adalah $100.000.000 / 109 = 917.431,19\text{ baud}$, dengan galat **-0,452%** [DIVERIFIKASI: perhitungan matematis]. Catatan: nilai +0,085% pada dokumen lama adalah keliru dan dikoreksi di sini; laporan Bagian 2b juga keliru menyebutkan nilai 108.

3. **Waktu Muat Flash SPI Onboard & Ukuran Bitstream:**
   - Klaim "~15 ms" dihapus [DIVERIFIKASI].
   - Waktu muat bitstream flash onboard hanya disajikan sebagai rumus dengan syarat nilai `CONFIGRATE`:
     $$\text{Waktu Muat} = \frac{\text{Ukuran Bitstream (bit)}}{\text{CONFIGRATE (Hz)} \times \text{SPI\_BUSWIDTH (bit/siklus)}}$$
     Pada `SPI_BUSWIDTH = 4`:
     - Jika `CONFIGRATE = 3 MHz` (nilai default Artix-7 [DIASUMSIKAN]): bitstream terkompresi M2b (618.468 B = 4.947.744 bit, naik +4,77% dari 590.304 B [penyebab: variasi penempatan dan routing memengaruhi kompresibilitas [DIASUMSIKAN]]) membutuhkan waktu $\approx 0,412\text{ detik}$; uncompressed (2.192.012 B = 17.536.096 bit) membutuhkan waktu $\approx 1,461\text{ detik}$.
     - Jika `CONFIGRATE = 33 MHz` (opsi master SPI Basys 3): bitstream terkompresi M2b membutuhkan waktu $\approx 37,5\text{ ms}$.
   - **Bitstream M2b & Sisa Margin Flash Standalone (D-5 / D-9):**
     - Bitstream M2b terkompresi sebelum perbaikan adalah 590.304 B, sesudah perbaikan 618.468 B (+4,77%, selisih LUT hanya +2); penyebab [DIASUMSIKAN] variasi placement/routing memengaruhi kompresibilitas frame konfigurasi bitstream; sisa margin flash standalone 72.358 B tidak boleh dianggap stabil.
     - Total kebutuhan memori flash standalone = Video RLE (14,09 Mbit) + Audio PCM 8 kHz 8-bit (13,94 Mbit) + Bitstream terkompresi M2b (4,95 Mbit) = **32,98 Mbit** (4.121.946 B). Pada chip SPI Flash onboard Basys 3 (Spansion S25FL032P berkapasitas 32 Mibit = 33,55 Mbit = 4.194.304 B), alokasi ini menyisakan margin **72.358 Byte** (**70,6 KB** / 1,72%) [DIVERIFIKASI: perhitungan matematis]. Catatan: terhadap batas desimal nominal 32,00 Mbit, nilainya melebihi 0,98 Mbit.

4. **Utilisasi Hardware Top-Level (Routed):**
   - **Total Terukur [DIVERIFIKASI: `vivado/build_m2b/utilization.rpt`]:**
     - **LUT (Logic):** **3.128** / 20.800 (15,04%)
     - **Flip-Flop (FF):** **618** / 41.600 (1,49%)
     - **Block RAM Tile:** **1,0 Tile** (2x RAMB18E1) / 50 Tile (2,00%)
   - **Catatan Laporan Hierarkis [DIVERIFIKASI: `vivado/build_m2b/utilization_hierarchical.rpt`]:** Selisih antara total top (3.128 LUT, 618 FF, 2 RAMB18) dan jumlah baris anak (3.062 LUT, 549 FF, 1 RAMB18) adalah tepat **66 LUT**, **69 FF**, dan **1 RAMB18**. Perbedaan ini merupakan logika flattened/unassigned dari modul `u_buf` (`frame_buffer`), `u_uart_rx`, `u_uart_tx`, dan `decoder` yang tidak tercantum sebagai baris terpisah pada tabel hierarkis Vivado.
   - **Perbandingan FF OOC vs Terintegrasi:**
     - `packet_parser`: 182 FF (OOC) $\rightarrow$ **123 FF** (terintegrasi) [DIVERIFIKASI: laporan OOC vs hierarki].
     - `rx_fifo`: 45 FF (OOC) $\rightarrow$ **44 FF** (terintegrasi) [DIVERIFIKASI].
     - `rle_decoder`: 62 FF (OOC) $\rightarrow$ **61 FF** (terintegrasi) [DIVERIFIKASI].
     Penyebab reduksi register pada modul-modul ini: [DIASUMSIKAN] akibat optimasi sintesis boundary logic top-level oleh Vivado.

5. **Riwayat Pengujian Baud Rate Lambat (1100 ns) di `tb_uart_rx`:**
   - Commit `d7f6738`: Menambahkan uji cepat 2 byte pada periode 1100 ns (+1,38% baud rate error) untuk memvalidasi toleransi sampling.
   - Commit `3a6b7e8`: Menggantikan uji 2 byte tersebut dengan rangkaian pengujian 4 byte back-to-back berturutan `{0x00, 0x55, 0x80, 0xFF}` pada baud deviasi +2% (1107 ns) dan +3% (1118 ns) serta -2% (1064 ns) dan -3% (1053 ns). Pengujian 4 byte dengan byte ber-MSB=0 (`0x00`, `0x55`) adalah pengujian kritis yang memverifikasi bahwa stop bit dievaluasi pada durasi penuh tanpa framing error prematur.

6. **Catatan Kritis Batas Pengujian & Penjaga Regresi:**
   - *(a)* Testbench `tb_top_stream` **TIDAK mendeteksi** kelemahan stop bit (lulus pada RTL commit `31a1007` sebelum perbaikan `STOP_BIT`); satu-satunya penjaga regresi adalah uji baud lambat dengan byte MSB=0 di `tb_uart_rx`—jangan pernah melonggarkannya!
   - *(b)* Kegagalan Uji 2 pada tag `m2a-boardless` pada periode 40 ns (laju percepatan 25 MHz) hanya muncul pada fase start `REL|0` (matriks tepi kritis); mekanisme kegagalan tersebut adalah race delta-cycle [DIASUMSIKAN]; perubahan `START_BIT` praktis tidak berpengaruh pada laju operasional 921.600 baud.

7. **Protokol Streaming, Penjadwalan, & Penanganan FRAME_ID:**
   - **Penjadwalan Host PC (`python/stream_player.py`):** Frame $n$ dijadwalkan dan dikirim pada $t_{\text{sched}} = t_0 + n/\text{FPS} + \text{av\_offset\_sec}$ (default $\text{FPS}=30$, `--av-offset-ms` default 0 [DIASUMSIKAN]).
   - **Mekanisme Drop Frame:** Jika terjadi keterlambatan pemrosesan di PC sehingga $t_{\text{now}} > t_{\text{sched}} + 2/\text{FPS}$ (> 2 frame terlambat), frame tersebut dibuang (drop) tanpa dikirim ke UART untuk mencegah penumpukan antrean (*burst lag*).
   - **Penanganan FRAME_ID Berlubang di FPGA [DIVERIFIKASI: `PROTOCOL.md` & `packet_parser.vhd`]:** FPGA tidak memeriksa kontinuitas urutan `FRAME_ID` (tidak ada counter yang memvalidasi bahwa frame berikutnya harus `FRAME_ID + 1`). Setiap paket diperlakukan secara independen. Jika ada frame yang hilang/dibuang, double buffer di FPGA mempertahankan frame sebelumnya di layar hingga frame valid berikutnya berhasil diterima dan didekode secara lengkap tanpa glitch visual.
   - **Penerimaan Dupleks RsTx Non-Blocking:** FPGA memancarkan data karakter ASCII ke PC pada laju ~31,8 KB/s via RsTx (1.059 B/frame pada 30 FPS). Skrip `stream_player.py` menjalankan thread pembaca latar belakang non-blocking agar penerimaan ASCII tidak memblokir laju transmisi frame video UART RX.

8. **Prosedur Pengujian Hardware Streaming Basys 3 [DIASUMSIKAN]:**
   - **Saklar SW0 (Pin V17):** Geser SW0 ke posisi '1' (`ON`) untuk mengaktifkan Mode Streaming UART RX (M2). Bila SW0 = '0', sistem berada pada Mode Klip BRAM (M1).
   - **Driver FTDI:** Setel Latency Timer pada port COM FTDI Basys 3 ke 1 ms atau 2 ms melalui Device Manager Windows untuk meminimalkan jitter paket USB [DIASUMSIKAN].
   - **Parameter Serial:** 921.600 baud, 8-bit data, No parity, 1 stop bit (8N1), tanpa flow control.
   - **Perintah Eksekusi Pemutar:**
     ```powershell
     .\.venv\Scripts\python.exe python/stream_player.py --port COM3 --baud 921600 --clip data/golden/stream_clip.bin --fps 30 --av-offset-ms 0 --no-audio
     ```

---

9. **Evaluasi Host API Audio PC & Karakteristik Jam Audio (M3 Jalur A1):**
   - **Kondisi Pengujian [DIVERIFIKASI]:** Seluruh pengukuran tolok ukur audio dijalankan menggunakan `FakeTransport` pada lingkungan laptop tanpa perangkat keras serial fisik riil dan tanpa beban rendering visual terminal.
   - **Distingsi Metrik Jam Audio [DIVERIFIKASI]:**
     - *Overshoot Jam Audio:* Keterlambatan bangun fungsi `sleep_until` terhadap target waktu pada domain jam audio fisik (`clock.now() - target_time`).
     - *Penyimpangan Selang Kirim:* Deviasi selang waktu nyata antar-pengiriman frame pada domain waktu monotonik sistem (`mono_time[k] - mono_time[k-1] - 1/FPS`, interval frame ke-0 diabaikan).
   - **Dukungan WASAPI `auto_convert` [DIVERIFIKASI]:** Modul `SoundDeviceAudio` pada `python/audio_player.py` berhasil membuka dan memutar berkas WAV 44.100 Hz pada hardware DAC Realtek (frekuensi native 48.000 Hz) menggunakan `extra_settings=sounddevice.WasapiSettings(auto_convert=True)` tanpa galat PortAudio `-9997 Invalid sample rate`.
   - **Latensi Hardware Terendah [DIVERIFIKASI]:** Mode WASAPI melaporkan latensi hardware output terendah yaitu **9,25 ms** (dibandingkan DirectSound 46,44 ms dan MME 178,56 ms).
   - **Hasil Perbandingan Performa Disiplin Jam per Host API (OFF vs ON) Lintas 3 Run [DIVERIFIKASI: benchmark 4h]:**
     - **Windows WASAPI (20s, 3 Run):**
       - Disiplin OFF: Std deviasi selang kirim median `2,49 ms` (min `2,46 ms`, maks `2,49 ms`); P99 |dev| median `4,88 ms` (min `4,60 ms`, maks `5,14 ms`); Maks |dev| median `6,04 ms` (min `5,43 ms`, maks `6,04 ms`); 0 frame dengan |dev| > 16,7 ms; 0 buffer underflow.
       - Disiplin ON: Std deviasi selang kirim median `0,36 ms` (min `0,36 ms`, maks `0,41 ms`); P99 |dev| median `0,98 ms` (min `0,86 ms`, maks `1,01 ms`); Maks |dev| median `3,29 ms` (min `2,46 ms`, maks `4,70 ms`); 0 frame dengan |dev| > 16,7 ms; 0 buffer underflow.
       - Disiplin ON secara konsisten menekan deviasi selang kirim ke tingkat sub-milidetik (P99 |dev| < 1,01 ms) dan stabil antar-run. Dalam hal jitter selang kirim, performa WASAPI ON (std 0,36 ms; P99 0,98 ms) setara dengan MME ON (std 0,31 ms; P99 1,12 ms).
     - **Windows MME (20s, 3 Run):**
       - Disiplin OFF: Std deviasi selang kirim median `0,34 ms` (min `0,32 ms`, maks `0,38 ms`); P99 |dev| median `1,02 ms` (min `0,92 ms`, maks `1,79 ms`); Maks |dev| median `1,94 ms` (min `1,88 ms`, maks `2,52 ms`); 0 frame dengan |dev| > 16,7 ms; 0 buffer underflow.
       - Disiplin ON: Std deviasi selang kirim median `0,31 ms` (min `0,31 ms`, maks `0,38 ms`); P99 |dev| median `1,12 ms` (min `0,87 ms`, maks `1,33 ms`); Maks |dev| median `1,92 ms` (min `1,42 ms`, maks `1,98 ms`); 0 frame dengan |dev| > 16,7 ms; 0 buffer underflow.
       - Pada pengujian 3 x 20 s, disiplin tidak berpengaruh nyata terhadap selang kirim (std 0,34 -> 0,31 ms). Lonjakan 23,8 ms pada pengujian terdahulu hanya terjadi pada satu run 60 s dan tidak terulang pada 3 run 20 s (pengujian 4h tidak mengulang run 60 s, melainkan hanya menguji run 20 s). MME memiliki latensi hardware yang sangat tinggi (~177-178 ms).
     - **Windows DirectSound (20s, 3 Run) - TIDAK DIREKOMENDASIKAN (VOLATILE):**
       - DirectSound menunjukkan timing yang sangat volatil dan tidak stabil:
         - Disiplin OFF: Std deviasi selang kirim median `9,50 ms` (min `9,37 ms`, maks `9,74 ms`); P99 |dev| median `26,82 ms` (min `26,17 ms`, maks `27,13 ms`); Maks |dev| median `31,66 ms` (min `28,74 ms`, maks `35,65 ms`); sebanyak `67 s.d. 82 frame` (median 77 frame) per 20 detik mengalami deviasi selang kirim > 16,7 ms (> 0,5 frame video)!
         - Disiplin ON: Std deviasi selang kirim median `2,35 ms` (min `2,34 ms`, maks `2,54 ms`); P99 |dev| median `4,86 ms` (min `4,85 ms`, maks `6,00 ms`); Maks |dev| melonjak hingga `42,02 s.d. 43,86 ms` (median `43,25 ms`) dengan 1 s.d. 3 frame per run mengalami deviasi > 16,7 ms.
         - Status Buffer Underrun: Pada pengujian batch 4f tercatat 13 buffer underruns per 20 detik, namun pada keenam run batch 4h seluruhnya melaporkan 0 underflow (`underflow=0`). Label UNDERRUNS dihapus karena 0 underrun terbukti pada pengujian 4h.
         - Rentang hasil tiga batch pengujian:
           - Mode ON: std `1,62 ms` (batch 4e) / `5,35 ms` (batch 4f) / `2,34 s.d. 2,54 ms` (batch 4h).
           - Mode OFF: std `8,74 ms` (batch 4e, P99 `22,27 ms`, maks `66,72 ms`) / `8,66 ms` (batch 4f) / `9,37 s.d. 9,74 ms` (batch 4h).
         - Penyebab volatilitas timing DirectSound: **TIDAK DIKETAHUI**.
   - **Karakteristik Langkah Pembaruan Jam Audio per Host API [DIVERIFIKASI: analisis CSV 4h]:**
     Pengukuran selisih penunjuk audio (`frames_played`) antar-baris berturutan pada CSV tolok ukur 4h:
     - **WASAPI:** Langkah pembaruan per-baris tidak pernah 0 ms (0% zero-diff dari 1.797 baris). Penunjuk waktu maju mulus setiap frame: min `20,00 ms`, median `30,00 ms`, maks `40,00 s.d. 50,00 ms`.
     - **MME:** Langkah pembaruan per-baris tidak pernah 0 ms (0% zero-diff dari 1.797 baris). Penunjuk waktu maju teratur dalam kelipatan buffer: min `25,76 ms`, median `25,76 ms`, maks `154,56 s.d. 180,32 ms`.
     - **DirectSound:** Sebanyak `45,5% s.d. 47,4%` selisih baris bernilai tepat `0,00 ms` (penunjuk waktu membeku selama satu siklus frame), lalu melompat pada pembaruan berikutnya dengan langkah non-nol median `60,00 ms` (maks `80,00 s.d. 130,00 ms`).
     - Hubungan Granularitas terhadap Volatilitas: [DIASUMSIKAN] bahwa granularitas pembaruan jam DirectSound yang kasar (~46% frame tertahan 0 ms lalu melompat 60 ms) berkaitan erat dengan tingginya fluktuasi selang kirim dan volatilitas timing DirectSound.
   - **Konfigurasi A1 yang Direkomendasikan di Dokumen untuk Laptop Ini [DIVERIFIKASI: keputusan tim 2026-11-03 & Bagian 4h]:**
     `--audio-hostapi wasapi --audio-discipline on` (alasan rekomendasi: latensi terendah 9,25 ms dan penilaian pengguna "sudah sinkron"; dalam jitter selang kirim WASAPI ON setara MME ON; default CLI tetap off).
   - **Status Penilaian Pengguna [DIVERIFIKASI: keputusan tim Bagian 4h]:** penilaian pengguna, mata dan telinga: sinkron. Kondisi: laptop, --fake-fpga, --audio-hostapi wasapi --audio-discipline on, tanpa board/OLED/UART.

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
- **D-5:** TIDAK BERLAKU: audio FPGA dibatalkan (keputusan pengguna 2026-11-14). Audio laptop (A1) tetap aktif.
- **D-13:** Evaluasi stop bit UART RX pada `clk_cnt = CLKS_PER_BIT - 1` untuk toleransi baud penuh.
- **D-Ramp / D-Bin:** Ramp ASCII A (`" .:-=+*#@"`) & Binerisasi Ambang Tetap (128).

### B. Keputusan Terbuka (Open)
- **D-10 (Kontainer Media):** Struktur paket streaming audio/video (diputuskan di M2: video frame RLE mandiri, audio stream disisipkan atau interleave).
- **D-14:** TIDAK BERLAKU: audio FPGA dibatalkan (keputusan pengguna 2026-11-14). Ekstensi audio pada packet_parser.vhd berstatus di luar lingkup (pengembangan lanjut), port audio dibiarkan open di top.vhd.
- **D-15:** DITUTUP pada Opsi (b) (duplikasi PENYIMPANAN BRAM untuk OLED, kendali bank dan swap tunggal) (keputusan tim 2026-11-02 & 2026-11-14).
- **D-16:** TIDAK BERLAKU: audio FPGA dibatalkan (keputusan pengguna 2026-11-14).
- **D-17:** TIDAK BERLAKU: audio FPGA dibatalkan (keputusan pengguna 2026-11-14).
- **D-18:** TIDAK BERLAKU: audio FPGA dibatalkan (keputusan pengguna 2026-11-14).

---

## 4. Status Modul Daun Milestone 4 (Simulasi Selesai, Menunggu Integrasi Top & Board)
1. **`hdl/packet_parser.vhd` (Ekstensi Audio):**
   - Status: **SELESAI DI SIMULASI** (`sim/tb_parser_audio.vhd`, 7 skenario uji mixed stream lolos 100%, 6 mutasi tertangkap).
   - Port baru berpelindung kompatibilitas mundur (nilai default aman untuk instansiasi lama).
   - Belum terintegrasi ke `top.vhd`, belum diuji di board fisik Basys 3.
2. **`hdl/audio_fifo.vhd` & `hdl/audio_pwm.vhd`:**
   - Status: **SELESAI DI SIMULASI** (`tb_audio_fifo`, `tb_audio_pwm`). Belum terintegrasi ke `top.vhd`, belum diuji di board fisik Basys 3.
3. **`hdl/oled_spi.vhd`:**
   - Status: **TERINTEGRASI KE `top.vhd` & SELESAI DI BUILD TERISOLASI** (`tb_oled_spi`, `tb_top_oled`; 127 LUT / 210 FF pada `utilization_hierarchical_*.rpt`; build terisolasi 5 konfigurasi selesai 0 DRC / 0 critical warning; konstrain `constraints/basys3_m4_pmod.proposed.xdc` masih usulan dan belum terverifikasi pengguna di board fisik Basys 3).

---

## 5. Pekerjaan Tertunda Menunggu Board Fisik Basys 3
1. **Pemrograman Bitstream:** Validasi pemrograman flash / SRAM via Vivado Hardware Manager (`top_compressed.bit`).
2. **Koneksi UART Fisik:** Verifikasi komunikasi baud rate 921.600 baud melalui jembatan USB-UART FTDI FT2232HQ pada Basys 3.
3. **Capture & Display Real-Time:** Menjalankan `python/uart_capture.py` dan terminal VT100 lokal pada port COM fisik untuk memastikan 90 frame klip berputar tanpa glitch visual atau dropped byte.
4. **Validasi Tombol Reset:** Menguji fungsionalitas tombol tengah (`btnC`) untuk reset sinkron sistem.
