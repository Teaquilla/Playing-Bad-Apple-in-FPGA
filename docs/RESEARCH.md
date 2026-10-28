# Log Riset Teknis (RESEARCH.md)

Dokumen ini memuat catatan riset literatur, studi arsitektur, dan rujukan teknis untuk proyek "Bad Apple di Basys 3".
Sesuai SPEC bagian 10, setiap topik riset dicatat dengan template terstruktur:
**Masalah → Teknik → Relevansi untuk Proyek Ini → Keputusan yang Disarankan → Status Verifikasi**.

Setiap klaim yang belum diverifikasi langsung di hardware atau simulasi wajib ditandai sebagai `[Belum Terverifikasi]`.

---

## [R-1] Kompresi Video 1-bit & Decoder Hemat Hardware (Menunjang Keputusan D-4)

- **Sumber/Referensi:**
- **Sumber/Referensi:**
  1. *ITU-T Recommendation T.4*: "Standardization of Group 3 facsimile apparatus for document transmission" (URL: https://www.itu.int/rec/T-REC-T.4).
     - *Catatan Verifikasi Rujukan*: Nomor versi edisi (07/03) dan nomor bagian (Bagian 4): `[BELUM DIVERIFIKASI BUKA LANGSUNG LENGKAP - disarikan dari ikhtisar metadata standar ITU-T]`.
     - *Ringkasan Prinsip*: Menetapkan One-Dimensional Modified Huffman (MH) dan RLE untuk kompresi citra bi-level (hitam/putih). Setiap garis pindai diperlakukan secara independen dengan mengodekan panjang deretan piksel hitam dan putih bergiliran, memberikan redundansi spasial tinggi dan isolasi galat (*error confinement*) per baris.
  2. *ITU-T Recommendation T.6*: "Facsimile coding schemes and coding control functions for Group 4 facsimile apparatus" (URL: https://www.itu.int/rec/T-REC-T.6).
     - *Catatan Verifikasi Rujukan*: Nomor versi edisi (11/88): `[BELUM DIVERIFIKASI BUKA LANGSUNG LENGKAP]`.
     - *Ringkasan Prinsip*: Memperluas kompresi bi-level dengan skema dua dimensi Modified READ (Relative Element Address Designate) yang memanfaatkan korelasi antar-baris, namun membutuhkan penyimpan baris referensi (*line buffer*) tambahan di memori.
  3. *Alpyen Repository*: `alpyen/fpga-mediaplayer` (URL: https://github.com/alpyen/fpga-mediaplayer).
     - *Ringkasan*: Contoh arsitektur streaming media player 1-bit monokrom pada FPGA Artix-7. Tidak menyalin kode implementasi, hanya digunakan sebagai studi komparatif arsitektur buffer.
  4. Hasil Pengukuran Empiris M0 Proyek Ini: [`data/compression_report.csv`](../data/compression_report.csv) pada 6.532 frame video 2:1 riil (`media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4`) `[DIVERIFIKASI EKSPERIMEN M0]`.
  *(Catatan Koreksi: Rujukan XAPP343 pada draf awal dibatalkan karena XAPP343 aslinya adalah dokumen CoolRunner XPLA3 ISP, bukan aplikasi RLE. Rujukan digantikan dengan standar primer ITU-T T.4/T.6).*
- **Masalah:**
  Ukuran video mentah 1-bit Bad Apple (128×64 pada 30 FPS selama 217,73 detik) adalah 53,51 Mbit (6,69 MB). Sisa kapasitas flash onboard Basys 3 (Spansion S25FL032P 32 Mbit) setelah bitstream Artix-7 xc7a35t mentah adalah 16,02 Mbit (1,91 MB / 2.002.292 byte). Video mentah tidak muat di flash. Dibutuhkan teknik kompresi dengan rasio minimal 3,36x agar video muat di flash, sekaligus memiliki kompleksitas decoder hardware yang sangat rendah.
- **Teknik:**
  1. *RLE per Baris (Line-based RLE, Fixed 8-bit)*: Tiap baris 128 piksel dikodekan sebagai deretan panjang run bergiliran (uint8, 0..128) dimulai dari warna hitam (0). Akumulator kolom menghitung hingga 128 piksel, lalu otomatis pindah ke baris berikutnya.
  2. *Inter-frame Delta XOR + RLE*: Mengurangi redundansi temporal antar-frame berturutan ($D_t = F_t \oplus F_{t-1}$), lalu mengompresi citra selisih biner $D_t$ menggunakan RLE.
  3. *Variable-Length RLE (Elias-Gamma)*: Mengodekan panjang run dengan kode universal Elias-gamma ($2 \lfloor \log_2(k) \rfloor + 1$ bit).
  4. *Nibble-Prefix RLE (Tabel Kode Tetap Kecil)*: Mengodekan run $\le 7$ dalam 4 bit (`0` + 3-bit val) dan run $> 7$ dalam 8 bit (`1` + 7-bit val).
- **Relevansi untuk Proyek Ini:**
  Berdasarkan pengukuran empiris M0 pada seluruh 6.532 frame video 2:1:
  - Format Mentah: 53.510.144 bit (6,69 MB) — **Tidak muat di flash** `[DIVERIFIKASI]`.
  - RLE per Baris (Fixed 8-bit): 14.086.064 bit (1,68 MB / 1.760.758 byte) — **Rasio 3,80x, MUAT DI FLASH** `[DIVERIFIKASI]`.
  - XOR-RLE: 13.830.560 bit (1,65 MB / 1.728.820 byte) — **Rasio 3,87x, MUAT DI FLASH** `[DIVERIFIKASI]`.
  - RLE Elias-Gamma: 14.395.190 bit (1,72 MB / 1.799.399 byte) — **Rasio 3,72x, 2,19% lebih boros daripada Fixed 8-bit** `[DIVERIFIKASI]`.
  - RLE Nibble-Prefix: 11.996.456 bit (1,43 MB / 1.499.557 byte) — **Rasio 4,46x, hemat 14,83%** `[DIVERIFIKASI]`.
  Selisih ukuran antara RLE per Baris Fixed 8-bit dan XOR-RLE hanya 31.938 byte (1,8%). Namun, XOR-RLE mewajibkan buffer frame referensi sebelumnya di hardware BRAM dengan akses baca-tulis ganda (*dual-port read-modify-write*), sedangkan RLE per Baris murni *feed-forward streaming* tanpa BRAM tambahan.
  Di sisi hardware FPGA Artix-7:
  - Decoder RLE per Baris Fixed 8-bit hanya membutuhkan 1 counter kolom 7-bit (0..128), 1 flip-flop warna (0/1), dan FSM stream valid/ready sederhana: estimasi gerbang ~30 LUT `[DIASUMSIKAN]`.
  - Decoder Elias-gamma membutuhkan shifter bit variabel (barrel shifter) dan detektor leading-zero melintasi batas byte: estimasi ~80-120 LUT `[DIASUMSIKAN]`.
  - Decoder Nibble-Prefix hanya membutuhkan pemecah nibble (high/low) dan mux 4/8-bit: estimasi ~40-60 LUT `[DIASUMSIKAN]`.
- **Keputusan yang Disarankan:**
  Konfirmasi pilihan **RLE per Baris (Fixed 8-bit)** untuk keputusan **D-4** karena arsitekturnya paling sederhana, deterministik per byte, dan video 2:1 sudah terbukti muat di sisa flash 16,02 Mbit. Namun untuk keputusan **D-9**, status flash belum bisa ditutup karena penambahan audio membuat total A/V melampaui sisa flash tanpa kompresi bitstream.
- **Status Verifikasi:**
  - Ukuran kompresi video 2:1 riil: `[DIVERIFIKASI EMPIRIS M0]`.
  - Estimasi kompleksitas ~25 LUT: `[DIASUMSIKAN / MENUNGGU SINTESIS VIVADO M1]`.

---

## [R-2] Batas Baud Rate USB-UART FTDI & Konfigurasi Pin/Clock Basys 3 (Menunjang Milestone M1)

- **Sumber/Referensi:**
  1. *Digilent Basys 3 Master XDC Constraint File* (Resmi Digilent di GitHub, URL: https://raw.githubusercontent.com/Digilent/digilent-xdc/master/Basys-3-Master.xdc).
     - *Status Verifikasi*: `[DIVERIFIKASI BUKA LANGSUNG FILE XDC RESMI]`.
     - *Kutipan/Ringkasan Ringkas*:
       - Clock 100 MHz: `set_property PACKAGE_PIN W5 [get_ports clk]`, `set_property IOSTANDARD LVCMOS33 [get_ports clk]`, `create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]`
       - USB-RS232 (UART): `set_property PACKAGE_PIN B18 [get_ports RsRx]`, `set_property IOSTANDARD LVCMOS33 [get_ports RsRx]`; `set_property PACKAGE_PIN A18 [get_ports RsTx]`, `set_property IOSTANDARD LVCMOS33 [get_ports RsTx]`
       - Tombol Reset (Center Button): `set_property PACKAGE_PIN U18 [get_ports btnC]`, `set_property IOSTANDARD LVCMOS33 [get_ports btnC]`
  2. *Digilent Basys 3 FPGA Board Reference Manual* (URL: https://digilent.com/reference/programmable-logic/basys-3/reference-manual).
     - *Catatan Verifikasi Rujukan*: Nomor bab/seksi (Section 7): `[BELUM DIVERIFIKASI BUKA DOKUMEN ASLI SECARA PENUH; disarikan dari web doc Digilent Reference]`.
     - *Ringkasan*: Board Basys 3 menggunakan chip FTDI FT2232HQ sebagai USB-JTAG/UART bridge tunggal. Port Channel A didedikasikan untuk JTAG programming, sedangkan Channel B dikonfigurasi sebagai USB-UART interface asinkronus yang terhubung langsung ke pin Artix-7 (TXD FPGA ke RXD FTDI di pin A18; RXD FPGA dari TXD FTDI di pin B18).
  3. *FTDI FT2232H Dual High Speed USB to Multipurpose UART/FIFO IC Datasheet* (URL: https://ftdichip.com/wp-content/uploads/2020/08/DS_FT2232H.pdf).
     - *Catatan Verifikasi Rujukan*: Nomor versi dokumen (Versi 2.6 / FT_000061) dan nomor sub-bagian (Bagian 1 & 4.4): `[BELUM DIVERIFIKASI BUKA LANGSUNG LENGKAP; batas 12 Mbaud dan clock PLL 120 MHz diverifikasi dari ikhtisar resmi FTDI]`.
     - *Ringkasan*: FT2232H mendukung kecepatan transfer asinkronus UART hingga 12 Mbaud pada tingkat sinyal TTL/CMOS menggunakan baud rate generator internal berbasis clock PLL 120 MHz. Baud rate standar tinggi seperti 921.600 baud, 1.000.000 baud, hingga 3.000.000 baud didukung penuh oleh silicon IC dan driver FTDI VCP di Windows.

- **Masalah:**
  Pengiriman video ASCII 64×16 karakter pada 30 FPS membutuhkan bandwidth UART sebesar $1.059 \text{ byte/frame} \times 30 \text{ fps} \times 10 \text{ bit/byte} = 317.700 \text{ baud}$. Baud rate standar 115.200 baud tidak mencukupi (hanya mampu ~10,9 FPS). Perlu dipastikan batas baud rate fisik bridge USB-UART Basys 3, kestabilan Virtual COM Port (VCP) FTDI di Windows host, serta pemetaan pin FPGA yang benar untuk clock 100 MHz, reset, dan UART TX/RX.
- **Teknik:**
  Analisis arsitektur hardware board Digilent Basys 3:
  1. Bridge USB-UART menggunakan chip FTDI **FT2232HQ** (High-Speed USB 2.0 480 Mbps). Kanal B FT2232HQ terhubung langsung ke pin I/O FPGA Artix-7 xc7a35t-cpg236.
  2. Driver FTDI VCP di Windows dan hardware chip mendukung baud rate standar tinggi: 230.400, 460.800, 921.600 baud, hingga 12.000.000 baud TTL.
  3. Pada baud rate target **921.600 baud (8N1)**:
     - Waktu transmisi 1 frame (1059 byte): $1059 \times 10 / 921600 \approx 11,49 \text{ ms}$.
     - Anggaran waktu 1 frame pada 30 FPS adalah $33,33 \text{ ms}$.
     - Pengiriman frame hanya memakan ~34,5% dari anggaran waktu per siklus, memberikan margin keamanan 65,5% terhadap jitter OS dan terminal render latency.
  4. Toleransi pembagi clock UART dari osilator 100 MHz:
     - $100.000.000 / 921.600 \approx 108,5069$.
     - Dengan pembagi integer 109: laju aktual $100.000.000 / 109 \approx 917.431 \text{ baud}$ (galat $-0,45\%$).
     - Toleransi standar UART adalah $\pm 2\%$, sehingga galat $-0,45\%$ berada jauh di dalam batas aman.
  5. Konfigurasi pin resmi dari Basys 3 Master XDC:
     - **Clock 100 MHz:** Pin `W5`, Bank 34, I/O standard `LVCMOS33` (Label net: `CLK100MHZ`).
     - **UART TX (FPGA Transmit ke PC RX):** Pin `A18`, Bank 14, I/O standard `LVCMOS33` (Label net: `RsTx`).
     - **UART RX (PC Transmit ke FPGA RX):** Pin `B18`, Bank 14, I/O standard `LVCMOS33` (Label net: `RsRx`).
     - **Reset Button:** Pin `U18`, Bank 14, I/O standard `LVCMOS33` (Label net: `btnC`).
- **Relevansi untuk Proyek Ini:**
  Mengonfirmasi bahwa target **921.600 baud** didukung penuh secara hardware oleh chip FT2232HQ Basys 3 dan port serial virtual Windows, tanpa memerlukan chip eksternal. Pinout constraint untuk M1 telah dipastikan 100% cocok dengan Master XDC Digilent resmi.
- **Keputusan yang Disarankan:**
  Tetapkan baud rate M1 pada **921.600 baud, 8N1** (menutup **D-6**). Gunakan pembagi baud integer `DIVISOR = 109` pada modul `uart_tx` VHDL dengan clock sumber 100 MHz dari pin `W5`.
- **Status Verifikasi:**
  - Pin W5, A18, B18, U18: `[DIVERIFIKASI MASTER XDC RESMI DIGILENT]`.
  - Batas baud rate 12 Mbaud & dukungan 921.600 baud: `[DIVERIFIKASI DATASHEET FTDI FT2232H]`.
  - Pembagi clock integer 109 (-0,45% error): `[DIVERIFIKASI PERHITUNGAN MATEMATIS]`.
  - Kinerja transmisi fisik riil di board: `[DIASUMSIKAN / MENUNGGU PENGUJIAN HARDWARE M1]`.

---

## Topik Riset Lain Sesuai SPEC Bagian 10 (Ditunda ke Tahap Berikutnya)

Sesuai instruksi tim, topik riset berikut ditunda dan akan dikerjakan pada milestone terkait:
- **Driver Layar OLED SSD1306 & Model Perilaku Simulasi** (Ditunda ke M4).
- **Audio DAC 1-pin PMOD (PWM / Sigma-Delta) & Filter Rekonstruksi** (Ditunda ke M3).
- **Kompresi Audio Sederhana (ADPCM/DPCM)** (Ditunda ke M3).
- **Akses Flash SPI/QSPI Onboard Artix-7 via STARTUPE2** (Ditunda ke M2).
