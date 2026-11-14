# Dokumen Desain Teknis Milestone 4: Tampilan OLED & Audio On-Board (docs/DESIGN_M4.md)

Dokumen ini merupakan proposal desain arsitektur untuk **Milestone 4 (M4)**, mencakup penambahan subsistem tampilan OLED SPI SSD1306 (128×64) dan subsistem output audio analog PWM 8-bit 8 kHz pada board Digilent Basys 3 (Xilinx Artix-7 `xc7a35tcpg236-1`).

> [!NOTE]
> Sesuai aturan pengembangan, seluruh rujukan terhadap kode, berkas, dan batasan implementasi yang ada ditandai sebagai **[DIVERIFIKASI]** (disertai kutipan nomor baris), sedangkan estimasi, spesifikasi perangkat keras eksternal yang belum diuji di board fisik, dan rencana arsitektur baru ditandai sebagai **[DIASUMSIKAN]**.
> 
> **Status Implementasi Modul Daun Audio (Bagian 4l):**
> Modul daun `audio_pwm.vhd` (Varian B: carrier 250 siklus / 400 kHz, latch selaras periode) dan `audio_fifo.vhd` (FIFO BRAM 2048 B, speculative commit/rollback, underflow counter, slip dua arah) telah diimplementasikan dan diverifikasi lewat testbench unit `sim/tb_audio_pwm.vhd` dan `sim/tb_audio_fifo.vhd` (keduanya 100% PASS di Vivado xsim). Status: **Selesai pada simulasi; belum terintegrasi ke pipeline top-level / `packet_parser`; belum diuji di board fisik**.
> Modul `oled_spi.vhd` tetap **DITUNDA** sampai pemeriksaan tabel inisialisasi selesai.
> Keputusan D-16 (komponen fisik rangkaian filter audio) dan D-18 (resinkronisasi underflow) tetap berstatus **TERBUKA** (tidak ada opsi yang dipilih secara sepihak).

---

## 1. Antarmuka Layar OLED SSD1306 (SPI 4-Kabel Mode 0)

### 1.1 Spesifikasi Perangkat Keras OLED
- **Modul Pengguna:** Modul OLED monokrom 0,96 inci berbasis chip controller Solomon Systech SSD1306 resolusi 128×64 piksel [DIVERIFIKASI: keputusan tim 2026-11-02].
- **Antarmuka Fisik:** SPI 7-pin:
  1. `GND` (Ground daya & sinyal)
  2. `VCC` (Catu daya 3,3V)
  3. `D0` / `SCLK` (SPI Serial Clock)
  4. `D1` / `MOSI` (SPI Master Output Slave Input / SDIN)
  5. `RES` (Hardware Reset, aktif LOW)
  6. `DC` (Data / Command Selection: `0` = Command, `1` = Display Data)
  7. `CS` (Chip Select, aktif LOW)
- **Protokol SPI:** Datasheet SSD1306 Rev 1.1 (Halaman 17, Table 8-3 dan Halaman 52, Figure 13-3) hanya menyebutkan bahwa data serial pada pin `SDIN` dicuplik pada tepi naik (*rising edge*) `SCLK` dan bit paling signifikan (MSB) dikirim lebih dulu. Pengaturan mode 0 (CPOL=0, CPHA=0) konsisten tetapi diuji di board [DIASUMSIKAN]. Clock `SCLK` berstatus IDLE pada logika LOW, dan data dicuplik pada tepi naik (*rising edge*) `SCLK`.

### 1.2 Pembagi Frekuensi Clock SPI (`SCLK`) & Karakteristik Timing AC

#### A. Pembagian Frekuensi Clock dari 100 MHz Basys 3
Clock utama board Basys 3 beroperasi pada frekuensi $100\text{ MHz}$ (periode $10\text{ ns}$) [DIVERIFIKASI: `constraints/basys3.xdc` baris 8].
Untuk menghasilkan clock yang stabil dengan pembagi biner genap tanpa jitter, dipilih pembagi:
$$\text{DIVIDER} = 16 \implies f_{\text{SCLK}} = \frac{100\text{ MHz}}{16} = 6,25\text{ MHz}$$
Periode clock `SCLK` adalah $T_{\text{SCLK}} = 160\text{ ns}$ (lebar pulsa HIGH 80 ns, LOW 80 ns).

#### B. Evaluasi Karakteristik Timing AC (Datasheet SSD1306 Rev 1.1 vs FSM SPI Modul oled_spi)
Berikut adalah perbandingan parameter timing AC terhadap perancangan FSM master SPI FPGA pada modul daun `oled_spi.vhd`. Sesuai keputusan tim pada Bagian 4q, seluruh nilai parameter timing SPI 4-kabel pada Tabel 13-4 telah **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52, baris 5655–5729)** pada rentang tegangan $V_{\text{DD}} - V_{\text{SS}} = 1,65\text{V} - 3,3\text{V}, T_{\text{A}} = 25^\circ\text{C}$. Pulsa reset fisik hardware (`RES#`) dan durasi tunggu setelah reset naik tetap berstatus **TIDAK TERVERIFIKASI** (bacaan pengguna menyusul):

| Simbol Parameter | Nama Parameter Timing | Batas Datasheet (Rev 1.1) | Rujukan di `ssd1306_raw.txt` | Karakteristik FSM Master SPI FPGA (Klaim RTL, diukur `tb_oled_spi`) | Status Verifikasi Datasheet (Bagian 4q) | Margin Keamanan |
|---|---|:---:|---|---|:---:|:---:|
| `tcycle` | Clock Cycle Time | Min $100\text{ ns}$ | Baris 5665–5669 (Hal. 52, Table 13-4) | Periode $T_{\text{SCLK}} = 160\text{ ns}$ (16 siklus clock 100 MHz). | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | $+60\%$ ($+60\text{ ns}$) |
| `tCLKL` | Clock Low Time | Min $20\text{ ns}$ | Baris 5706–5711 (Hal. 52, Table 13-4) | Pulsa LOW `SCLK` adalah 8 siklus clock = $80\text{ ns}$. | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | $+300\%$ ($+60\text{ ns}$) |
| `tCLKH` | Clock High Time | Min $20\text{ ns}$ | Baris 5712–5717 (Hal. 52, Table 13-4) | Pulsa HIGH `SCLK` adalah 8 siklus clock = $80\text{ ns}$. | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | $+300\%$ ($+60\text{ ns}$) |
| `tCSS` | Chip Select Setup Time | Min $20\text{ ns}$ | Baris 5682–5687 (Hal. 52, Table 13-4) | Sinyal `CS#` di-assert LOW 3 siklus clock ($30\text{ ns}$) sebelum tepi pertama `SCLK`. | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | $+50\%$ ($+10\text{ ns}$) |
| `tCSH` | Chip Select Hold Time | Min $10\text{ ns}$ | Baris 5688–5693 (Hal. 52, Table 13-4) | Sinyal `CS#` ditahan LOW 2 siklus clock ($20\text{ ns}$) setelah tepi terakhir `SCLK` sebelum naik. | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | $+100\%$ ($+10\text{ ns}$) |
| `tAS` | Address Setup Time (`D/C#`) | Min $15\text{ ns}$ | Baris 5670–5675 (Hal. 52, Table 13-4) | Sinyal `D/C#` disetel bersamaan dengan `CS#` assert, mendahului tepi naik `SCLK` pertama $\ge 30\text{ ns}$. | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | $+100\%$ ($+15\text{ ns}$) |
| `tAH` | Address Hold Time (`D/C#`) | Min $15\text{ ns}$ | Baris 5676–5681 (Hal. 52, Table 13-4) | Sinyal `D/C#` dipertahankan stabil setelah tepi turun `SCLK` minimal 8 siklus clock = $80\text{ ns}$. | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | $+433\%$ ($+65\text{ ns}$) |
| `tDSW` | Write Data Setup Time (`SDIN`) | Min $15\text{ ns}$ | Baris 5694–5699 (Hal. 52, Table 13-4) | Data `MOSI` disiapkan pada tepi turun `SCLK`, memberikan setup time 8 siklus clock = $80\text{ ns}$. | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | $+433\%$ ($+65\text{ ns}$) |
| `tDHW` | Write Data Hold Time (`SDIN`) | Min $15\text{ ns}$ | Baris 5700–5705 (Hal. 52, Table 13-4) | Data `MOSI` dipertahankan stabil selama fase HIGH = 8 siklus clock = $80\text{ ns}$. | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | $+433\%$ ($+65\text{ ns}$) |
| `tR` | SCLK / SDIN Rise Time | Max $40\text{ ns}$ | Baris 5718–5723 (Hal. 52, Table 13-4) | Waktu transisi naik keluaran I/O Artix-7 (standar LVCMOS33 12mA Fast) $\le 3\text{ ns}$. | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | Terpenuhi ($\ll 40\text{ ns}$) |
| `tF` | SCLK / SDIN Fall Time | Max $40\text{ ns}$ | Baris 5724–5729 (Hal. 52, Table 13-4) | Waktu transisi turun keluaran I/O Artix-7 (standar LVCMOS33 12mA Fast) $\le 3\text{ ns}$. | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** | Terpenuhi ($\ll 40\text{ ns}$) |
| `RES#` | Reset Low Pulse Width | Min $3\ \mu\text{s}$ | Hal. 49, Table 13-1 (penanda "=== PAGE 49 ===", "P 49/59") | Pulsa reset hardware LOW dibangkitkan selama 1.000 siklus clock 100 MHz = $10\ \mu\text{s}$. | **DIVERIFIKASI OLEH PENGGUNA (Tabel 13-1, halaman 49, Rev 1.1, VDD 1,65-3,3 V)** | $+233\%$ ($+7\ \mu\text{s}$) |

> [!NOTE]
> **Catatan Status Reset & Refresh Internal SSD1306 (Tabel 13-1, Hal. 49, Rev 1.1):**
> 1. **Durasi Pulsa Reset:** Batas $t_{\text{RES}} \ge 3\ \mu\text{s}$ pada $V_{\text{DD}} = 1,65\text{ s.d. } 3,3\text{ V}$ telah **DIVERIFIKASI OLEH PENGGUNA** dari Tabel 13-1 halaman 49. Namun, waktu tunggu pemulihan sesudah `RES#` naik kembali ke HIGH **tetap TIDAK TERVERIFIKASI** (Rev 1.1 halaman 49 tidak memuat nilai tersebut; jeda $1\text{ ms}$ pada FSM `oled_spi` adalah usulan desain).
> 2. **Frekuensi Osilator Internal & Laju Frame Layar (Tabel 13-1):**
>    Tabel 13-1 mencantumkan frekuensi osilator internal $F_{\text{OSC}}$: min $333\text{ kHz}$, tipikal $370\text{ kHz}$, maks $407\text{ kHz}$ (pada $V_{\text{DD}} = 2,8\text{ V}$).
>    Laju frame pemindaian panel internal OLED dihitung dengan formula:
>    $$F_{\text{FRM}} = F_{\text{OSC}} \times \frac{1}{D \times K \times 64}$$
>    Datasheet baris 792 menyatakan bahwa pada kondisi power-on reset, nilai $K = \text{Phase 1} + \text{Phase 2} + \text{BANK0 pulse width} = 2 + 2 + 50 = 54$. Pada kondisi reset default ini ($D=1, K=54$):
>    $$F_{\text{FRM, reset}} = \frac{370.000\text{ Hz}}{1 \times 54 \times 64} = \frac{370.000}{3.456} \approx 107,06\text{ Hz}\quad (\text{periode refresh internal } \approx 9,34\text{ ms})$$
>    Namun, pada inisialisasi yang menggunakan perintah `0xD9, 0xF1` (Phase 1 = 1 DCLK, Phase 2 = 15 DCLK):
>    $$K = 1 + 15 + 50 = 66\quad \mathbf{[DIASUMSIKAN:\ perluasan\ rumus]}$$
>    Sehingga laju refresh frame aktual panel internal menjadi:
>    - Tipikal ($F_{\text{OSC}} = 370\text{ kHz}$):
>      $$F_{\text{FRM, typ}} = \frac{370.000\text{ Hz}}{1 \times 66 \times 64} = \frac{370.000}{4.224} \approx 87,59\text{ Hz} \approx 87,6\text{ Hz}\quad (\text{periode refresh } \approx 11,42\text{ ms} \approx 11,4\text{ ms})$$
>    - Minimum ($F_{\text{OSC}} = 333\text{ kHz}$): $F_{\text{FRM}} = \frac{333.000}{4.224} \approx 78,84\text{ Hz} \approx 78,8\text{ Hz}$ (periode $\approx 12,68\text{ ms}$).
>    - Maksimum ($F_{\text{OSC}} = 407\text{ kHz}$): $F_{\text{FRM}} = \frac{407.000}{4.224} \approx 96,35\text{ Hz} \approx 96,4\text{ Hz}$ (periode $\approx 10,38\text{ ms}$).
>    [Perhitungan; DIASUMSIKAN]. Catatan: Nilai `0xD9, 0xF1` adalah konvensi pustaka modul, bukan kebutuhan datasheet.
> 3. **Risiko Efek Robek Citra (Tearing Risk pada GDDRAM):**
>    Penulisan burst SPI dari FPGA membutuhkan durasi $\approx 1,38\text{ ms}$ per frame (pada interval 30 FPS = $33,33\text{ ms}$). Durasi transfer $1,38\text{ ms}$ tersebut setara dengan $\approx 12\%$ dari periode refresh internal panel ($11,4\text{ ms}$) [DIASUMSIKAN]. Karena penulisan SPI dilakukan secara asinkron tanpa pin sinkronisasi pemindaian (`FR` atau `TE` tidak tersedia pada header SPI 7-pin modul SSD1306 standar), penulisan data grafis ke GDDRAM berpotensi beririsan dengan pemindaian refresh internal panel (~11,4 ms), memunculkan potensi *frame tearing* [DIASUMSIKAN; pembuktian dilakukan saat uji board fisik].

### 1.3 Analisis Anggaran Waktu Transfer per Frame (Frame Budget)
- **Ukuran Data Grafis Layar 128×64:**
  Total memori tampilan GDRAM SSD1306 adalah:
  $$128\text{ kolom} \times \frac{64\text{ baris}}{8\text{ bit/baris}} = 1.024\text{ Byte}$$
- **Overhead Protokol Perintah (Command Overhead):**
  Sebelum transfer data grafis per frame, modul mengirimkan instruksi reposisi pointer GDRAM (Set Page Address $0..7$ dan Set Column Address $0..127$), membutuhkan sekitar $6\text{ Byte}$ perintah.
  Total muatan transfer per frame $\approx 1.030\text{ Byte}$ ($8.240\text{ bit}$) [DIASUMSIKAN].
- **Waktu Transfer pada 6,25 MHz:**
  $$T_{\text{transfer}} = \frac{8.240\text{ bit}}{6.250.000\text{ bit/s}} \approx 1,3184\text{ ms}$$
- **Rasio Utilisasi Waktu Frame 30 FPS:**
  Pada laju video 30 FPS, interval periode antar-frame adalah $33,333\text{ ms}$ [DIVERIFIKASI: `hdl/frame_timer.vhd` baris 26].
  Rasio beban transfer SPI terhadap periode frame adalah:
  $$\text{Utilisasi Transfer} = \frac{1,32\text{ ms}}{33,33\text{ ms}} \times 100\% \approx 3,96\%$$
  Artinya, bus SPI hanya sibuk selama $\approx 4\%$ dari waktu frame, menyisakan waktu hening (*idle time*) $\approx 96\%$ ($32\text{ ms}$). Hal ini sepenuhnya mengeliminasi risiko perebutan bus dan *frame tearing* [DIASUMSIKAN].
- **Catatan Pembanding Antarmuka I2C [DIVERIFIKASI: keputusan tim]:**
  Jika modul dipasang pada mode I2C (Fast Mode 400 kHz), transfer 1.024 byte memerlukan waktu $\approx 23,04\text{ ms}$ (memakan $69,1\%$ dari anggaran frame 33,33 ms), sedangkan SPI 4-kabel 6,25 MHz hanya memerlukan $\approx 1,32\text{ ms}$ ($3,96\%$).

### 1.4 Urutan Inisialisasi Register SSD1306 (FSM Init)
Modul hardware `oled_spi.vhd` akan mengimplementasikan State Machine (FSM) inisialisasi deterministik [DIASUMSIKAN]:

#### A. Urutan Daya & Sinyal Reset Hardware (Power-On Sequence) [DIASUMSIKAN]
1. **Pemberian Daya (VCC 3,3V):** Tegangan 3,3V dari pin PMOD Basys 3 dialirkan ke pin VCC modul OLED dan dibiarkan stabil ($> 10\text{ ms}$).
2. **Hardware Reset Pulse (`RES`):** Pin `RES` ditarik LOW selama minimal $10\ \mu\text{s}$ (1.000 siklus 100 MHz), lalu ditarik kembali ke HIGH [DIASUMSIKAN]. Modul menunggu jeda de-asersi minimal $10\ \mu\text{s}$ sebelum transaksi SPI pertama dikirim.
3. **Pengiriman Urutan Perintah Konfigurasi:** Dikirim secara serial dengan sinyal `DC = 0` dan `CS = 0`.
4. **Display ON:** Perintah `0xAF` dikirim di akhir urutan konfigurasi untuk menghidupkan panel layar.

#### B. Tabel Perintah Inisialisasi Register SSD1306 Byte demi Byte [DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt) / SEBAGIAN TIDAK TERVERIFIKASI]

Tabel berikut mencantumkan setiap byte perintah konfigurasi inisialisasi FSM modul `oled_spi.vhd` yang diperbarui berdasarkan **BACAAN PENGGUNA dari `ssd1306_raw.txt`** (dengan nomor halaman diverifikasi dari penanda `=== PAGE n ===` terdekat sebelumnya). Status verifikasi dibedakan secara tegas:

| No | Byte (Hex) | Arti / Fungsi Register | Rujukan Halaman & Baris di `ssd1306_raw.txt` | Status Verifikasi Datasheet (Bagian 4q) |
|---|---|---|---|---|
| 1 | `0xAE` | Display OFF (Sleep Mode) | Hal. 28 (Table 9-1 baris 1176–1180) & Hal. 37 (§10.1.12 baris 2623) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** |
| 2 | `0xD5`, `0x80` | Set Display Clock Divide Ratio & Oscillator Frequency | Hal. 40 (§10.1.16 baris 4603) & Hal. 32 (Table 9-1 baris 2039–2048) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** (§10.1.16: pembagi reset 1, osilator default 1000b, jadi 0x80 = nilai bawaan) |
| 3 | `0xA8`, `0x3F` | Set Multiplex Ratio (64MUX) | Hal. 31 (Table 9-1 baris 1911–1915) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** |
| 4 | `0xD3`, `0x00` | Set Display Offset (Offset 0) | Hal. 31 (Table 9-1 baris 1975–1977) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** |
| 5 | `0x40` | Set Display Start Line (Line 0) | Hal. 31 (Table 9-1 baris 1861–1864) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** |
| 6 | `0x8D`, `0x14` | Charge Pump Setting (Enable 7,5V) | Tidak ada di Rev 1.1 (pin VBAT, C1N, C1P, C2N, C2P terdaftar Hal. 15–16) | **TIDAK TERVERIFIKASI** (tidak ada di Rev 1.1; silikon memiliki pin VBAT, C1N, C1P, C2N, C2P; sumber lain: contoh kode penjual modul atau revisi datasheet baru) |
| 7 | `0x20`, `0x00` | Set Memory Addressing Mode (Horizontal Addressing) | Hal. 30 (Table 9-1 baris 1665–1670), Hal. 34 (§10.1.3 baris 2284), Hal. 35 (baris 2382–2388) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt)** (A[1:0]=00b horizontal, 10b = RESET mode halaman; setelah kolom terakhir penunjuk kembali ke kolom awal dan halaman naik; setelah halaman terakhir keduanya kembali ke awal) |
| 8 | `0xA1` | Set Segment Re-map (Kolom 127 ke SEG0) | Hal. 31 (Table 9-1 baris 1886–1889) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** |
| 9 | `0xC8` | Set COM Output Scan Direction (COM[N-1] ke COM0) | Hal. 31 (Table 9-1 baris 1939–1941) & Hal. 37 (§10.1.14 baris 2637) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** |
| 10 | `0xDA`, `0x12` | Set COM Pins Hardware Configuration (Alternative PIN, Disable L/R Remap) | Hal. 31 (Table 9-1 baris 2008–2017) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** (A[4]=1b RESET, A[5]=0b RESET, jadi 0x12 = nilai reset) |
| 11 | `0x81`, `0xCF` | Set Contrast Control (Tingkat kontras `0xCF`) | Hal. 28 (Table 9-1 baris 1098–1101) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** (reset 7Fh, rentang 00..FF) |
| 12 | `0xD9`, `0xF1` | Set Pre-charge Period (Phase 1 = 1 DCLK, Phase 2 = 15 DCLK) | Hal. 32 (Table 9-1 baris 2113–2119) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** (0 tidak valid; reset 2h) |
| 13 | `0xDB`, `0x20` | Set VCOMH Deselect Level (~0,77 x VCC) | Hal. 32 (Table 9-1 baris 2140) & Hal. 43 (§10.1.19 baris 4828) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** (00h ~0,65, 20h ~0,77 RESET, 30h ~0,83) |
| 14 | `0xA4` | Entire Display ON (Resume to RAM Content) | Hal. 28 (Table 9-1 baris 1113) & Hal. 37 (§10.1.9 baris 2606) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** (pada tampilan normal data RAM 1 = piksel menyala) |
| 15 | `0xA6` | Set Normal Display | Hal. 28 (Table 9-1 baris 1140) & Hal. 37 (§10.1.10 baris 2612) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** (pada tampilan normal data RAM 1 = piksel menyala) |
| 16 | `0xAF` | Display ON (Normal Mode) | Hal. 28 (Table 9-1 baris 1176–1180) & Hal. 37 (§10.1.12 baris 2623) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** |
| 17 | `0x21`, `0x00`, `0x7F` | Set Column Address (Rentang kolom $0..127$) | Hal. 30 (Table 9-1 baris 1712–1717) & Hal. 35 (§10.1.4 baris 2483) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** |
| 18 | `0x22`, `0x00`, `0x07` | Set Page Address (Rentang halaman $0..7$) | Hal. 31 (Table 9-1 baris 1785–1790) & Hal. 36 (§10.1.5 baris 2504) | **DIVERIFIKASI OLEH PENGGUNA (ekstraksi ssd1306_raw.txt)** |

#### C. Catatan Khusus Verifikasi & Koreksi Register

1. **Koreksi Register VCOMH Deselect Level (`0xDB`):**
   - Pada lembar data resmi Rev 1.1 (Hal. 32, Table 9-1 Subtabel 5), opsi register `0xDB` terdokumentasi sebagai berikut:
     - `A[6:4] = 000b` (`0x00`): $\sim 0,65 \times V_{\text{CC}}$
     - `A[6:4] = 010b` (`0x20`): $\sim 0,77 \times V_{\text{CC}}$ (**Kondisi RESET Default**)
     - `A[6:4] = 011b` (`0x30`): $\sim 0,83 \times V_{\text{CC}}$
   - Nilai `0x40` **TIDAK TERDOKUMENTASI DI DALAM PDF REV 1.1**.
   - Pernyataan pada catatan Bagian 4i sebelumnya yang menyebutkan bahwa "nilai `0x40` merepresentasikan $\sim 0,83 \times V_{\text{CC}}$" adalah keliru dan **RESMI DIHAPUS**. Nilai resmi untuk $\sim 0,83 \times V_{\text{CC}}$ menurut datasheet adalah `0x30`.
   - Modul `oled_spi` menggunakan nilai standar datasheet `0x20` ($\sim 0,77 \times V_{\text{CC}}$).

2. **Konfigurasi Pin COM (`0xDA`) & Analisis Kesalahan Penataan Baris:**
   - Pertahankan nilai `0x12` (`A[4]=1, A[5]=0`: *Alternative COM pin configuration*, *Disable Left/Right remap*) sebagai nilai generic default modul.
   - *Koreksi terhadap Pernyataan Sebelumnya:* Pernyataan lama yang menduga bahwa kesalahan nilai `0xDA` menyebabkan "layar hanya tampil 32 baris" adalah **SALAH**. Gejala nyata jika nilai konfigurasi pin COM salah pada panel 128×64 adalah tampilan **baris bergantian atau teracak (*interleaved / scrambled rows*)** karena perataan nomor baris ganjil/genap tertukar antara pin COM atas dan COM bawah.
   - *Rujukan Contoh Penggunaan `0x02` pada Datasheet:* Pada Halaman 40, Table 10-3 (*COM Pins Hardware Configuration*), Kondisi 1 dan Kondisi 2 menampilkan konfigurasi `DAh A[4]=0` (yaitu `0x02` jika `A[5]=0`). Contoh ini berlaku spesifik untuk panel 128×64 yang tata letak fisiknya memiliki pengkabelan pad COM berurutan secara blok (*Sequential COM pin configuration*, di mana COM0..COM31 berada di satu sisi dan COM32..COM63 di sisi sebaliknya), bukan layout interleaved.

3. **Status Perintah Charge Pump Setting (`0x8D 0x14`):**
   - Silikon chip SSD1306 memiliki pin fisik untuk rangkaian charge pump (pin `VBAT`, `C1N`, `C1P`, `C2N`, `C2P` secara eksplisit terdaftar pada deskripsi pin Rev 1.1 Halaman 15-16). Namun, perintah konfigurasinya (`0x8D 0x14`) dan urutan power-on pengaktifan pengali tegangan internal sama sekali tidak terdokumentasi di dalam lembar data dasar Rev 1.1 (April 2008).
   - Berdasarkan KEPUTUSAN TIM 1 ("belum ada revisi baru"), status perintah `8Dh` dan urutan inisialisasi charge pump ditandai secara resmi sebagai **TIDAK TERVERIFIKASI**. Perintah ini dipertahankan sebagai konvensi modul industri komersial 0,96" 7-pin yang ditenagai 3,3V tunggal, namun memerlukan pengujian empiris langsung pada hardware fisik atau rujukan lembar data pelengkap (*Application Note / SSD1306B*).

4. **Catatan Perilaku Mode Pengalamatan Horisontal (§10.1.3, Halaman 30, 34, 35):**
   - Berdasarkan Tabel 9-1 baris 1665–1670 (Halaman 30), §10.1.3 baris 2284 (Halaman 34), dan teks mode horizontal baris 2382–2388 (Halaman 35): pada mode horizontal (`0x20 0x00`), setelah membaca atau menulis data satu kolom RAM, penunjuk alamat kolom (*column address pointer*) secara otomatis bertambah ke kolom berikutnya.
   - Jika penunjuk kolom telah mencapai batas kolom akhir (kolom 127 / `0x7F`), penunjuk kolom secara otomatis kembali (*reset/wrap*) ke kolom awal (kolom 0 / `0x00`), dan penunjuk baris/halaman (*page address pointer*) otomatis bertambah (+1) ke halaman berikutnya.
   - Ketika kedua penunjuk (kolom dan halaman) mencapai batas akhir (kolom 127, halaman 7), kedua penunjuk secara otomatis kembali (*wrap-around*) ke kolom awal (kolom 0) dan halaman awal (halaman 0) [DIVERIFIKASI OLEH PENGGUNA: teks baris 2386–2388].
   - Karakteristik ini memungkinkan FSM `oled_spi` menyemburkan 1.024 byte data frame secara kontigu dan linier (Page 0 Kolom 0..127 $\to$ Page 1 Kolom 0..127 $\to \dots \to$ Page 7 Kolom 0..127) tanpa perlu mengirimkan ulang instruksi penataan alamat di sela-sela pergantian halaman.

### 1.5 Mekanisme Buffer Swap & Sinkronisasi Frame
- Pembaruan tampilan OLED dilakukan tepat setelah frame baru selesai didekode ke BRAM frame buffer dan sinyal swap bank BRAM aktif [DIVERIFIKASI: konsep `swap_ready` pada `hdl/frame_buffer.vhd` baris 41].
- Saat swap terjadi, FSM OLED membaca 1.024 byte data dari bank BRAM yang sedang diam (*stable bank*) dan mentransmisikannya secara berurutan ke OLED via SPI dalam waktu 1,32 ms. Sisa waktu frame (32 ms) dihabiskan dalam status IDLE menunggu frame berikutnya [DIASUMSIKAN].

---

## 2. Transposisi Format Citra (Raster Horisontal ke Page Vertikal)

### 2.1 Perbedaan Representasi Memori
- **Format Kanonik Citra (Frame Buffer BRAM FPGA & ASCII Sink):**
  Disusun secara raster horisontal (*row-major*): 128 kolom × 64 baris.
  Satu frame terdiri dari 64 baris, dengan tiap baris memuat $128 / 8 = 16\text{ Byte}$ data terkemas (MSB = piksel paling kiri $x=0$, LSB = $x=7$) [DIVERIFIKASI: `python/canonical.py` baris 32-45].
  Piksel pada koordinat $(x, y)$ terletak pada:
  $$\text{Alamat BRAM} = y \times 16 + \lfloor x / 8 \rfloor, \quad \text{Bit Posisi} = 7 - (x \bmod 8)$$
- **Format GDRAM SSD1306 (Page-Oriented Vertical):**
  Disusun dalam 8 Halaman (*Page* $0..7$). Tiap page memiliki tinggi 8 baris piksel vertikal dan lebar 128 kolom.
  Satu byte data pada Page $p$ dan Kolom $x$ merepresentasikan 8 piksel vertikal dari baris $y = 8p$ (bit 0 / LSB) sampai baris $y = 8p + 7$ (bit 7 / MSB) [DIASUMSIKAN: datasheet SSD1306].

### 2.2 Evaluasi Lokasi Transposisi: Host PC vs Hardware RTL FPGA
- **Evaluasi Opsi 1 (Transposisi di Host PC):**
  Jika Host PC mentransposisikan frame ke format page sebelum kompresi RLE dan pengiriman:
  - Format RLE per-baris (D-4) menjadi tidak berlaku karena kompresi dilakukan per-halaman vertikal, merusak rasio kompresi RLE yang sudah optimal [DIVERIFIKASI: rasio 3,80x pada D-4, `docs/DECISIONS.md` baris 22].
  - Modul `ascii_sink.vhd` yang mengirim karakter VT100 ke terminal PC via RsTx membutuhkan pembacaan raster horisontal baris-per-baris [DIVERIFIKASI: `hdl/ascii_sink.vhd` baris 70-110]. Jika BRAM berisi format page vertikal, `ascii_sink` harus memiliki rangkaian transposisi rumit di FPGA.
- **Evaluasi Opsi 2 (Transposisi On-The-Fly di Hardware RTL FPGA - Opsi Terpilih):**
  Frame buffer BRAM tetap menyimpan data dalam format raster kanonik 128×64 (1.024 byte per bank) yang identik dengan pipeline M1, M2a, dan M2b [DIVERIFIKASI].
  Rangkaian `oled_spi.vhd` melakukan transposisi *on-the-fly* saat membaca BRAM:
  - Untuk membentuk satu byte keluaran OLED pada Page $p$ dan Kolom $x$:
    Modul membaca 8 byte dari BRAM pada alamat raster:
    $$\text{Addr}(b) = (8p + b) \times 16 + \lfloor x / 8 \rfloor \quad \text{untuk } b = 0, 1, \dots, 7$$
    Lalu bit ke-$(7 - (x \bmod 8))$ dari tiap byte dirangkai menjadi bit ke-$b$ byte keluaran OLED.
  - Membaca 8 siklus BRAM pada clock 100 MHz hanya membutuhkan waktu $8 \times 10\text{ ns} = 80\text{ ns}$.
  - Karena waktu transmisi 1 byte SPI pada 6,25 MHz adalah $8 \times 160\text{ ns} = 1.280\text{ ns}$, pembacaan 80 ns selesai jauh sebelum byte SPI berikutnya dibutuhkan. Tidak diperlukan memori intermediate tambahan [DIASUMSIKAN].

### 2.3 Arbitrase Port Baca BRAM Frame Buffer
- Modul `frame_buffer.vhd` saat ini diimplementasikan menggunakan blok memori True Dual-Port RAM Artix-7 (RAMB18E1) [DIVERIFIKASI: `hdl/frame_buffer.vhd` baris 79-99]:
  - **Port A:** Digunakan secara eksklusif untuk penulisan data frame hasil decode dekoder RLE (`decoder` / `rle_decoder`).
  - **Port B:** Digunakan untuk pembacaan data tampilan oleh `ascii_sink.vhd` [DIVERIFIKASI: `hdl/top.vhd` baris 178-195].
- Jika tampilan terminal ASCII (RsTx) dan tampilan OLED (PMOD JA) aktif secara bersamaan, terdapat dua alternatif arsitektur [DIASUMSIKAN]:
  - **Alternatif 2.3A (Time-Division Multiplexing / Arbitrase Port B):**
    Menggunakan satu port Port B secara bergantian antara `ascii_sink` dan `oled_spi`. `oled_spi` hanya memerlukan 1,32 ms per frame, sementara `ascii_sink` membaca secara periodik sesuai laju baud UART 921.600. Multiplexer arbitrase memprioritaskan transfer burst OLED atau menyelingi pembacaan.
  - **Alternatif 2.3B (Duplikasi Penyimpanan BRAM Frame Buffer - Disetujui Pengguna [DIVERIFIKASI: keputusan tim 2026-11-02]):**
    Yang diduplikasi adalah **PENYIMPANAN FISIK BRAM** (`fb_mem_ascii` dan `fb_mem_oled`), sedangkan **KENDALI SWAP TETAP TUNGGAL DAN BERSAMA** (pointer bank aktif `bank_ptr` dan sinyal jabat tangan `swap_done` digunakan secara bersama-sama oleh kedua jalur).
    Kedua instance BRAM menerima penulisan data frame kanonik yang sama persis pada Port A dari dekoder RLE saat pengisian frame baru.
    *Syarat Integritas Bebas Tearing:* Pembacaan frame oleh `oled_spi` (durasi transfer burst $\approx 1,32\text{ ms}$) dijamin selesai sebelum swap bank berikutnya terjadi, karena modul `ascii_sink` membaca secara serial dan menahan proses swap selama transmisi karakter VT100 UART RX ($T_{\text{ascii}} \approx 1.059\text{ B} \times 10 / 921.600 \approx 11,48\text{ ms}$). Karena $1,32\text{ ms} \ll 11,48\text{ ms}$, pembacaan OLED selesai jauh sebelum swap berikutnya dapat dipicu.
    *Asersi Testbench Integrasi (Deteksi Tearing):*
    ```vhdl
    -- Asersi pada tb_top_stream / tb_oled_spi untuk memastikan tidak ada swap saat OLED aktif membaca
    assert not (swap_req = '1' and oled_busy = '1')
      report "VIOLATION: Frame buffer swap requested while OLED SPI is actively reading stable bank!"
      severity failure;
    ```
    *Perilaku pada Mode Klip BRAM (M1, STREAMING_MODE = false):*
    Pada mode klip ROM internal, timer onboard memicu swap frame setiap $33,33\text{ ms}$ (30 FPS). Karena pembacaan OLED ($1,32\text{ ms}$) dan transfer ASCII ($11,48\text{ ms}$) keduanya selesai jauh sebelum tick frame 33,33 ms berikutnya, kedua subsistem membaca frame yang sama secara sinkron tanpa perebutan BRAM maupun glitch visual.
    *Biaya Hardware:* Penambahan 1 blok RAMB18E1 (0,5 BRAM Tile). Berdasarkan utilisasi implementasi M2b, FPGA Basys 3 saat ini hanya menggunakan 1,0 BRAM Tile dari 50 Tile yang tersedia (utilisasi hanya $2,00\%$, tersisa 49 Tile / 98 RAMB18) [DIVERIFIKASI: `docs/STATUS.md` baris 97]. Menambah 1 blok RAMB18E1 sepenuhnya menghilangkan logika arbitrase, meminimalkan latensi, dan menjaga independensi kedua subsistem [DIASUMSIKAN].

### 2.4 Perancangan RTL Modul Daun `oled_spi.vhd` (Implementasi Milestone 4)

Modul `oled_spi.vhd` dirancang sebagai modul daun (*leaf module*) mandiri yang mengemudikan layar OLED SSD1306 via antarmuka serial SPI 4-kabel Mode 0 pada clock sistem 100 MHz [DIVERIFIKASI: `hdl/oled_spi.vhd`].

#### A. Antarmuka Port Entity (`oled_spi`)
| Port | Arah | Tipe | Deskripsi Sinyal |
|---|:---:|:---:|---|
| `clk` | In | `std_logic` | Clock sistem utama FPGA (100 MHz). |
| `rst` | In | `std_logic` | Sinyal reset sinkron aktif-tinggi. |
| `start` | In | `std_logic` | Pulsa pemicu pengiriman 1 frame baru (1 siklus clock). |
| `busy` | Out | `std_logic` | Status sibuk ('1' saat fase reset/init atau transmisi frame berlangsung). |
| `rd_addr` | Out | `std_logic_vector(9 downto 0)` | Alamat baca memori BRAM frame buffer raster ($0..1023$). |
| `rd_data` | In | `std_logic_vector(7 downto 0)` | Data byte piksel raster dari memori frame buffer. |
| `oled_res` | Out | `std_logic` | Sinyal reset fisik hardware SSD1306 (RES#, aktif-rendah). |
| `oled_dc` | Out | `std_logic` | Sinyal pemilih Data/Command SSD1306 (D/C#; '0' = Perintah, '1' = Data). |
| `oled_cs` | Out | `std_logic` | Sinyal Chip Select SSD1306 (CS#, aktif-rendah). |
| `oled_sclk` | Out | `std_logic` | Serial Clock SPI Mode 0 (diam rendah, cuplik pada tepi naik). |
| `oled_mosi` | Out | `std_logic` | Serial Data Output (SDIN / MOSI, MSB duluan). |
| `init_done` | Out | `std_logic` | Status selesai inisialisasi hardware ('1' setelah 25 byte terkirim). |

#### B. Parameter Generics Modul
| Generic | Tipe | Nilai Default | Deskripsi & Dasar Pertimbangan |
|---|:---:|:---:|---|
| `CLK_DIV` | `natural` | `16` | Pembagi clock SPI. Nilai 16 menghasilkan $f_{\text{SCLK}} = 6,25\text{ MHz}$ ($T = 160\text{ ns}$), memenuhi $t_{\text{cycle}} \ge 100\text{ ns}$. |
| `REMAP_SEG` | `std_logic_vector(7 downto 0)` | `x"A1"` | Perintah pemetaan kolom segmen (`0xA0` normal, `0xA1` remapped $0 \to 127$). |
| `REMAP_COM` | `std_logic_vector(7 downto 0)` | `x"C8"` | Perintah arah pemindaian baris (`0xC0` normal, `0xC8` remapped $0 \to N-1$). |
| `CONTRAST` | `std_logic_vector(7 downto 0)` | `x"CF"` | Nilai kecerahan kontras tampilan register `0x81`. |
| `INVERT_DATA` | `boolean` | `false` | Inversi polaritas piksel kanonik. Default `false`: piksel kanonik bit 1 = menyala/terang (RAM 1 pada normal mode `0xA6`). |
| `READ_LATENCY` | `natural` | `1` | Siklus tunda pembacaan sinkron BRAM frame buffer (latensi 1 siklus). |
| `RES_LOW_CYCLES` | `natural` | `1000` | Siklus clock pulsa LOW sinyal `oled_res` ($1.000\text{ siklus} = 10\ \mu\text{s} \ge 3\ \mu\text{s}$). |
| `RES_WAIT_CYCLES` | `natural` | `100000` | Siklus tunggu pasca-reset fisik sebelum SPI aktif ($100.000\text{ siklus} = 1\text{ ms}$) [DIASUMSIKAN]. |
| `CS_SETUP_CYCLES` | `natural` | `3` | Waktu tunggu `CS#` LOW sebelum tepi naik pertama SCLK ($30\text{ ns} \ge 20\text{ ns}$). |
| `CS_HOLD_CYCLES` | `natural` | `2` | Waktu tunggu `CS#` LOW setelah tepi turun terakhir SCLK ($20\text{ ns} \ge 10\text{ ns}$). |

#### C. Diagram Waktu Teks (ASCII Timing Diagram - SPI Mode 0 Transmisi Byte)
```text
Clock 100 MHz   : __|~|__|~|__|~|__|~|__|~|__|~|__|~|__|~|__|~|__|~|__|~|__|~|__|~|__|~|__|~|__|~|__
                   |<-- tCSS -->|                                   |<-- tCSH -->|
oled_cs (CS#)   : ~~~~~~~~~~~~~~\________________________________________________/~~~~~~~~~~~~~~~~~
                                 |<----------- 8 Siklus SCLK (1 Byte) ---------->|
oled_sclk (SCLK): ______________|~~~|___|~~~|___|~~~|___|~~~|___ ... ___|~~~|___________________
                   |<-- tAS --->|   |       |
oled_dc (D/C#)  : ======X================================================================X=========
                        |        D/C stabil (0 = Perintah, 1 = Data)
oled_mosi (SDIN): ======X=======< Bit 7 >< Bit 6 >< Bit 5 > ... < Bit 0 >=================X=========
                        |<tDSW->|<-tDHW->|
                                ^        ^
                                Cuplik 1 Cuplik 2
```

#### D. Hitungan Margin Timing terhadap Batas Datasheet SSD1306
| Parameter | Nilai Batas Datasheet (Table 13-4) | Karakteristik Terukur FSM `oled_spi` (Klaim RTL, diukur `tb_oled_spi`) | Margin Keamanan | Status Verifikasi Datasheet (Bagian 4q) |
|---|:---:|:---:|:---:|:---:|
| $t_{\text{cycle}}$ | Min $100\text{ ns}$ | $160\text{ ns}$ | $+60\%$ ($+60\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{CLKL}}$ | Min $20\text{ ns}$ | $80\text{ ns}$ | $+300\%$ ($+60\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{CLKH}}$ | Min $20\text{ ns}$ | $80\text{ ns}$ | $+300\%$ ($+60\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{CSS}}$ | Min $20\text{ ns}$ | $30\text{ ns}$ | $+50\%$ ($+10\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{CSH}}$ | Min $10\text{ ns}$ | $20\text{ ns}$ | $+100\%$ ($+10\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{AS}}$ | Min $15\text{ ns}$ | $30\text{ ns}$ | $+100\%$ ($+15\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{AH}}$ | Min $15\text{ ns}$ | $\ge 80\text{ ns}$ | $+433\%$ ($+65\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{DSW}}$ | Min $15\text{ ns}$ | $80\text{ ns}$ | $+433\%$ ($+65\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{DHW}}$ | Min $15\text{ ns}$ | $80\text{ ns}$ | $+433\%$ ($+65\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{R}}$ | Max $40\text{ ns}$ | $\le 3\text{ ns}$ | Terpenuhi ($\ll 40\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{F}}$ | Max $40\text{ ns}$ | $\le 3\text{ ns}$ | Terpenuhi ($\ll 40\text{ ns}$) | **DIVERIFIKASI OLEH PENGGUNA (ssd1306_raw.txt, halaman 52)** |
| $t_{\text{RES}}$ | Min $3\ \mu\text{s}$ | $10\ \mu\text{s}$ | $+233\%$ ($+7\ \mu\text{s}$) | **TIDAK TERVERIFIKASI (bacaan pengguna menyusul)** |

> [!NOTE]
> Modul `oled_spi.vhd` belum diintegrasikan ke `top.vhd` dan batasan pin `basys3.xdc` belum ditambahkan pada tahap ini. Keputusan D-16 (filter audio) dan D-18 (resinkronisasi underflow) tetap berstatus **TERBUKA** dan tidak ditutup.

---

## 3. Jalur Audio On-Board A2 (PWM 8-Bit 8 kHz & Protokol Streaming)

### 3.1 Parameter Audio & Clock Tick Generator
- **Spesifikasi Sesuai Keputusan D-5 [DIVERIFIKASI: `docs/DECISIONS.md` baris 28]:**
  - Format data: PCM 8-bit unsigned mono.
  - Frekuensi sampling: $8.000\text{ Hz}$ (8 kHz).
  - Titik tengah hening (*silence midpoint*): `128` (`0x80`).
  - Total durasi lagu: 217,84 detik $\times$ 8.000 B/s = 1.742.720 Byte (13,94 Mbit).
- **Pembangkit Tick Sampel Audio (Sample Tick Generator):**
  Dari clock sistem 100 MHz, interval sampel 8 kHz adalah:
  $$\text{DIVIDER}_{\text{audio}} = \frac{100.000.000\text{ Hz}}{8.000\text{ Hz}} = 12.500\text{ siklus clock}$$
  Sebuah pencacah 14-bit menghasilkan pulsa stroba 1 siklus setiap 12.500 siklus untuk memajukan sampel berikutnya dari FIFO audio ke modulator PWM [DIASUMSIKAN].

### 3.2 Modulator PWM 8-Bit & Evaluasi Dua Varian Arsitektur (Varian A vs Varian B)

Terdapat dua pendekatan arsitektur untuk modulator PWM audio 8-bit 8 kHz pada clock sistem 100 MHz [DIASUMSIKAN]:

#### A. Varian A: Latch Sampel Saat Pencacah Carrier 256 Siklus Wrap-Around (~390,625 kHz) [DIASUMSIKAN]
- **Karakteristik Carrier:**
  Pencacah carrier bebas 8-bit mencacah $0..255$ ($256\text{ siklus clock} = 2,56\ \mu\text{s}$). Frekuensi carrier:
  $$f_{\text{carrier}} = \frac{100.000.000\text{ Hz}}{256} = 390.625\text{ Hz} \approx 390,625\text{ kHz}$$
- **Karakteristik Latch & Jitter Waktu Penundaan:**
  Interval sampel 8 kHz adalah tepat $12.500\text{ siklus clock}$ ($125\ \mu\text{s}$). Nilai 12.500 **bukan** kelipatan bulat dari 256 siklus:
  $$\frac{12.500}{256} = 48,828125\text{ periode carrier}$$
  Untuk mencegah terpotongnya periode PWM di tengah siklus, sampel audio baru dari FIFO hanya di-latch saat pencacah carrier berputar (*wrap-around* dari 255 ke 0). Hal ini memperkenalkan jitter waktu penundaan sampel sebesar $0\text{ s.d. } 256\text{ siklus clock}$ ($0\text{ s.d. } 2,56\ \mu\text{s}$), dengan jitter puncak $t_j = 2,56\ \mu\text{s}$.
- **Koreksi Terhadap Klaim Redaman Filter RC:**
  Klaim sebelumnya bahwa "jitter waktu penundaan PWM sepenuhnya diredam oleh filter analog low-pass RC" adalah **KELIRU**. Pembaruan sampel pada laju 8 kHz yang termodulasi oleh jitter $2,56\ \mu\text{s}$ membangkitkan derau fasa/apertur di dalam pita audio yang terdengar (*in-band noise*). Karena filter low-pass RC pasif satu tingkat yang diusulkan memiliki frekuensi cut-off $f_c \approx 3,29\text{ kHz}$ ($R = 2,2\text{ k}\Omega, C = 22\text{ nF}$), derau yang berada di dalam pita dengar ($< 3,3\text{ kHz}$) **TIDAK DAPAT** disaring oleh filter analog tersebut dan akan lolos ke transduser audio.
- **Perhitungan Kuantitatif SNR Akibat Jitter Sampling (Varian A):**
  Jika jitter waktu dimodelkan berdistribusi seragam $U(0, t_j)$, standar deviasi waktu jitter (RMS jitter) adalah:
  $$\sigma_t = \frac{t_j}{\sqrt{12}} = \frac{2,56\ \mu\text{s}}{\sqrt{12}} \approx 0,7390\ \mu\text{s}$$
  Untuk sinyal nada sinusoidal skala penuh (*full-scale*) pada frekuensi $f_{\text{in}}$, rasio signal-to-noise teoretis akibat jitter dihitung dengan rumus:
  $$\text{SNR}_{\text{jitter}} = -20 \log_{10}(2\pi f_{\text{in}} \sigma_t)$$
  Contoh perhitungan pada beberapa frekuensi uji audio yang relevan:
  - Pada $f_{\text{in}} = 1\text{ kHz}$:
    $$\text{SNR}_{\text{jitter}} = -20 \log_{10}(2\pi \times 1.000 \times 0,7390 \times 10^{-6}) = -20 \log_{10}(4,643 \times 10^{-3}) \approx \mathbf{46,66\text{ dB}}$$
  - Pada $f_{\text{in}} = 2\text{ kHz}$:
    $$\text{SNR}_{\text{jitter}} = -20 \log_{10}(2\pi \times 2.000 \times 0,7390 \times 10^{-6}) = -20 \log_{10}(9,287 \times 10^{-3}) \approx \mathbf{40,64\text{ dB}}$$
  - Pada $f_{\text{in}} = 3\text{ kHz}$:
    $$\text{SNR}_{\text{jitter}} = -20 \log_{10}(2\pi \times 3.000 \times 0,7390 \times 10^{-6}) = -20 \log_{10}(1,393 \times 10^{-2}) \approx \mathbf{37,12\text{ dB}}$$
  *Perbandingan dengan Kuantisasi 8-Bit:*
  Derau kuantisasi ideal PCM 8-bit adalah $\text{SNR}_{\text{quant}} \approx 6,02 \times 8 + 1,76 \approx \mathbf{49,92\text{ dB}} \approx 50\text{ dB}$.
  Pada frekuensi 1–3 kHz, $\text{SNR}_{\text{jitter}}$ ($37,1\text{ s.d. } 46,7\text{ dB}$) berada di bawah kualitas kuantisasi 8-bit ($50\text{ dB}$). Dengan demikian, pada Varian A derau jitter latch menjadi faktor pembatas kualitas (*dominant noise floor*) pada frekuensi menengah dan tinggi.

#### B. Varian B: Carrier 250 Siklus (400 kHz), Tick 12.500 = Tepat 50 Periode Carrier [DIASUMSIKAN]
- **Karakteristik Carrier & Sinkronisasi Sempurna:**
  Pencacah carrier mencacah modulo 250 ($0..249$, periode $2,50\ \mu\text{s}$). Frekuensi pembawa PWM:
  $$f_{\text{carrier}} = \frac{100.000.000\text{ Hz}}{250} = \mathbf{400.000\text{ Hz}} = \mathbf{400\text{ kHz}}$$
  Interval tick sampel 8 kHz adalah tepat $12.500\text{ siklus clock}$. Hubungan frekuensi:
  $$\frac{12.500\text{ siklus}}{250\text{ siklus}} = \mathbf{50\text{ periode carrier penuh}}$$
  Karena interval 8 kHz merupakan kelipatan bilangan bulat eksak dari periode carrier 250 siklus, tick sampel selalu bertepatan persis pada batas awal siklus carrier. Sampel baru dapat langsung di-latch tanpa penundaan sehingga **jitter waktu latch adalah nol ($\Delta t = 0$, $\text{SNR}_{\text{jitter}} \rightarrow \infty$)**.
- **Pemetaan Ambang Duty Cycle (Skala 0..250):**
  Sampel audio 8-bit ($0..255$) dipetakan ke ambang pembanding duty cycle ($0..250$) menggunakan operasi aritmetika:
  $$\text{duty\_threshold} = (\text{sample} \times 250) \gg 8 = \lfloor \frac{\text{sample} \times 250}{256} \rfloor$$
  Di hardware FPGA, perhitungan ini membutuhkan pengali $8\text{ bit} \times 8\text{ bit}$ konstanta 250 diikuti pemotongan 8 bit terbawah.
- **Analisis Gain Error & Duty Cycle Maksimum:**
  - *Gain Error:* Faktor pengali efektif adalah $\frac{250}{256} \approx 0,9765625 \approx \mathbf{0,9766}$. Hal ini menimbulkan penurunan gain linier sebesar $-0,206\text{ dB}$ (atenuasi $\approx 2,34\%$). Atenuasi $0,2\text{ dB}$ berada jauh di bawah ambang pendengaran manusia (*inaudible*) dan dapat dikompensasi secara sepele pada gain penguat eksternal jika diinginkan.
  - *Titik Hening:* Untuk sampel hening nominal `128` (`0x80`), ambang duty $= \lfloor 128 \times 250 / 256 \rfloor = 125$, menghasilkan duty cycle tepat $125 / 250 = \mathbf{50,0\%}$.
  - *Duty Maksimum:* Untuk sampel puncak maksimum `255` (`0xFF`), ambang duty $= \lfloor 255 \times 250 / 256 \rfloor = \lfloor 249,023 \rfloor = \mathbf{249}$. Duty cycle maksimum adalah $\frac{249}{250} = \mathbf{99,6\%}$.
- **Status Evaluasi:** Kedua varian di atas ditandai sebagai **[DIASUMSIKAN]**, dievaluasi secara objektif, dan **TIDAK ADA OPSI YANG DIPILIH SECARA SEPIHAK** pada tahap ini (menunggu pengisian keputusan tim).

#### C. Usulan Filter Pasif Low-Pass RC Analog PMOD JB [DIASUMSIKAN]
Untuk mengubah deret pulsa PWM 400 kHz (atau 390,6 kHz) menjadi sinyal audio analog yang dapat didengar:
- **Nilai Komponen yang Diusulkan:**
  $$R = 2,2\text{ k}\Omega, \quad C = 22\text{ nF}$$
- **Frekuensi Cut-off (-3 dB):**
  $$f_c = \frac{1}{2\pi R C} = \frac{1}{2\pi \times 2.200\ \Omega \times 22 \times 10^{-9}\text{ F}} \approx \mathbf{3.288,5\text{ Hz}} \approx \mathbf{3,29\text{ kHz}}$$
  Frekuensi $3,29\text{ kHz}$ membatasi spektrum audio mendekati batas Nyquist audio 8 kHz ($4\text{ kHz}$), sekaligus memberikan atenuasi carrier PWM ($400\text{ kHz}$) sebesar:
  $$\text{Atenuasi Carrier} \approx -20 \log_{10}\left(\frac{400\text{ kHz}}{3,29\text{ kHz}}\right) \approx \mathbf{-41,7\text{ dB}}$$
- **Arus Beban Pin PMOD FPGA:**
  Pada tegangan logika LVCMOS33 ($3,3\text{ V}$), arus beban maksimum pin PMOD Artix-7 adalah:
  $$I_{\text{pin\_max}} = \frac{3,3\text{ V}}{2.200\ \Omega} \approx \mathbf{1,5\text{ mA}} \ll 8\text{ mA}$$
  Nilai 1,5 mA berada jauh di bawah batas kemampuan drive standar pin Artix-7 ($8\text{ mA}$), menjamin keselamatan kelistrikan pin PMOD Basys 3.
- **Peringatan Verifikasi Perangkat Keras:** Nilai komponen $R = 2,2\text{ k}\Omega$ dan $C = 22\text{ nF}$ ini adalah **usulan desain [DIASUMSIKAN]**, **bukan nilai final**, dan **wajib diverifikasi oleh pengguna manusia sebelum rangkaian fisik dihubungkan ke board Basys 3**.

#### D. Karakteristik Reset dan Lonjakan DC pada Kopling AC (Audio Pop) [TERBUKA]
- **Kondisi Saat Reset:**
  Pada implementasi `audio_pwm.vhd` saat ini, ketika `rst = '1'`, keluaran ter-register `pwm_out <= '0'`.
- **Dampak pada Jalur Audio AC-Coupled:**
  Kapasitor pemblokir DC pada rangkaian keluaran audio analog mengumpulkan muatan berdasarkan nilai tegangan rata-rata sinyal.
  Ketika sistem berada dalam status reset, tegangan rata-rata adalah $0\text{ V}$.
  Saat reset dilepaskan dan modul mulai menghasilkan sinyal modulasi audio pada duty nominal 50% ($125 / 250$ siklus), tegangan rata-rata seketika melompat menjadi:
  $$V_{\text{DC}} = 3,3\text{ V} \times 50\% = 1,65\text{ V}$$
  Langkah transien DC sebesar $\Delta V = +1,65\text{ V}$ ini diteruskan oleh kapasitor kopling AC ke penguat/earphone sebagai bunyi letupan tajam (*loud audio pop/thump*).
- **Usulan Alternatif Mitigasi (Belum Diterapkan, Keputusan TERBUKA):**
  1. *Alternatif 1 (Gating / Mute Switch Eksternal pada Top-Level):*
     Menahan pin keluaran audio PMOD pada kondisi *high-impedance* (tri-state) atau menggunakan gerbang kendali *mute* analog di level atas sampai siklus pre-roll selesai dan buffer audio terisi stabil.
  2. *Alternatif 2 (Duty 50% Selama Status Reset):*
     Memodifikasi proses reset `audio_pwm.vhd` agar saat `rst = '1'`, modul tetap menghasilkan gelombang kotak carrier 400 kHz dengan duty cycle tepat 50% (125 siklus HIGH, 125 siklus LOW). Dengan demikian, tegangan DC rata-rata sudah berada di $1,65\text{ V}$ sejak reset aktif, sehingga tidak ada lonjakan DC ketika reset dilepas.
- **Status Keputusan:** Tetap **TERBUKA** (tidak ada perubahan RTL yang diterapkan pada Bagian 4m).

### 3.3 Protokol Framing Streaming UART untuk Video & Audio

#### A. Analisis Kebutuhan Bandwidth (Rata-rata vs Puncak) terhadap Kapasitas 92.160 B/s
Kapasitas transmisi fisik serial pada $921.600\text{ baud}$ dengan format 8N1 (1 start, 8 data, 1 stop bit = 10 bit per karakter) adalah tepat:
$$C_{\text{UART}} = \frac{921.600\text{ bit/s}}{10\text{ bit/Byte}} = 92.160\text{ Byte/detik}$$

Kebutuhan laju streaming audio PCM 8 kHz 8-bit mono adalah konstan $8.000\text{ Byte/detik}$ [DIVERIFIKASI: D-5].

**1. Angka Rata-rata (Dihitung dari Berkas Aliran Data Nyata):**
- **Berdasarkan Klip Golden 90 Frame (`data/golden/stream_clip.bin`):**
  - Total ukuran berkas: $18.909\text{ Byte}$ untuk 90 paket frame video.
  - Ukuran paket rata-rata = $18.909 / 90 = 210,10\text{ Byte/frame}$ (payload video rata-rata $201,10\text{ B}$ + overhead framing $9\text{ B}$: 3B SOF, 2B FID, 2B LEN, 1B EOF, 1B CHK).
  - Laju video rata-rata pada 30 FPS = $210,10 \times 30 = 6.303,00\text{ Byte/detik}$ ($6,84\%$ dari 92.160 B/s).
  - Ditambah audio $8.000\text{ B/s}$:
    $$\text{Total Bandwidth Rata-rata (Klip 90 frame)} = 6.303,00 + 8.000 = 14.303,00\text{ Byte/detik} \quad (\mathbf{15,52\%} \text{ dari } 92.160\text{ B/s})$$
- **Berdasarkan Aliran Video Penuh 1.000 Frame (`data/stream_full.bin`):**
  - Total ukuran berkas: $249.349\text{ Byte}$ untuk 1.000 paket frame video.
  - Ukuran paket rata-rata = $249.349 / 1000 = 249,35\text{ Byte/frame}$ (payload video rata-rata $240,35\text{ B}$ + framing $9\text{ B}$).
  - Laju video rata-rata pada 30 FPS = $249,35 \times 30 = 7.480,47\text{ Byte/detik}$ ($8,12\%$ dari 92.160 B/s).
  - Ditambah audio $8.000\text{ B/s}$:
    $$\text{Total Bandwidth Rata-rata (1.000 frame)} = 7.480,47 + 8.000 = 15.480,47\text{ Byte/detik} \quad (\mathbf{16,80\%} \text{ dari } 92.160\text{ B/s})$$

**2. Angka Puncak (Worst-Case Frame):**
- Frame video terpadat memiliki payload $707\text{ Byte}$ (+ framing $9\text{ B} = 716\text{ B/paket}$) [DIVERIFIKASI: `docs/DECISIONS.md` baris 27-28].
- Jika 30 frame puncak dikirim berturut-turut: laju video puncak = $716 \times 30 = 21.480\text{ Byte/detik}$.
- Ditambah audio per detik ($8.000\text{ B/s}$, atau dengan framing terpisah $\sim 8.270\text{ B/s}$):
  $$\text{Total Bandwidth Puncak} = 21.480 + 8.270 = 29.750\text{ Byte/detik} \quad (\mathbf{32,28\%} \text{ dari } 92.160\text{ B/s})$$
- *Kesimpulan Bandwidth:* Dalam skenario terpadat sekalipun, bus UART masih memiliki cadangan kapasitas (*headroom*) sebesar $\approx 67,7\%$, sehingga sama sekali bebas dari risiko saturasi [DIASUMSIKAN].

#### B. Analisis Pilihan Protokol Framing Audio & Dampak RTL (D-14)
Terdapat tiga opsi arsitektur framing audio streaming:

- **Opsi (A) SOF Audio Terpisah (`0x55AB`):**
  Paket audio menggunakan SOF baru `0x55 0xAB` [DIASUMSIKAN].
  *Perilaku terhadap `packet_parser.vhd` saat ini (tanpa modifikasi):*
  Pada modul [packet_parser.vhd](../hdl/packet_parser.vhd#L171-L205):
  1. Byte `0x55` diterima di `HUNT_SOF_0` (baris 172) $\rightarrow$ FSM maju ke `HUNT_SOF_1`.
  2. Byte `0xAB` tiba di `HUNT_SOF_1`. Karena baris 183 hanya mengecek `cur_byte = x"AA"` dan baris 186 `cur_byte = x"55"`, byte `0xAB` jatuh ke cabang `else` (baris 190-194):
     `had_garbage <= '1'; return_state <= HUNT_SOF_0; state <= FETCH_BYTE;`
  3. Seluruh paket audio dibuang sebagai data sampah (*garbage*).
  4. Ketika paket video berikutnya tiba dengan SOF valid `0x55 0xAA 0x5A`, baris 201-204 mendeteksi `had_garbage = '1'`:
     `res_cnt <= res_cnt + 1; had_garbage <= '0';`
  *Konsekuensi:* Setiap paket audio akan memicu pertambahan penghitung kesalahan resinkronisasi (`cnt_resyncs` bertambah 1 per paket audio). Untuk mendukung Opsi A, FSM `packet_parser.vhd` wajib diubah secara struktural pada cabang SOF.

- **Opsi (B) Multiplexing Audio dan Video dalam Satu Paket Gabungan:**
  Setiap frame video memuat segmen audio tetap $266..267\text{ Byte}$ di awal payload diikuti aliran data RLE video.
  *Konsekuensi:* Mengubah struktur payload RLE secara menyeluruh dan membatalkan seluruh berkas uji golden biner M2b (`stream_clip.bin`, `stream_expected.txt`) yang sudah lulus verifikasi [DIVERIFIKASI].

- **Opsi (C) Tipe Paket di Bit Tertinggi `FRAME_ID` (`FRAME_ID(15)`) - Disetujui Pengguna [DIVERIFIKASI: keputusan tim 2026-11-02]:**
  Menggunakan pola SOF standar yang sama persis: `0x55 0xAA 0x5A`, EOF `0xED`, dan Checksum XOR [DIASUMSIKAN].
  Tipe muatan dibedakan melalui bit tertinggi `FRAME_ID`:
  - `FRAME_ID(15) = '0'` : Paket Video RLE (`FRAME_ID` bernilai $0..6531$).
  - `FRAME_ID(15) = '1'` : Paket Audio PCM (`FRAME_ID` bernilai `0x8000 | frame_idx`).
  - Panjang payload audio per paket: $266..267\text{ Byte}$ (pada 30 FPS, $8.000 / 30 = 266,67\text{ sampel/frame}$).
  *Analisis Dampak & Kompatibilitas:*
  1. **Validasi Panjang (`CHECK_LEN`):** Batas generic `PAYLOAD_LEN_MIN` = 64 dan `PAYLOAD_LEN_MAX` = 1024 [DIVERIFIKASI: `hdl/packet_parser.vhd` baris 13-14]. Payload audio 266-267 Byte berada di dalam rentang ini ($64 \le 267 \le 1024$), sehingga lolos validasi pada baris 243 tanpa modifikasi parameter atau generic!
  2. **Perhitungan Checksum:** Checksum XOR pada baris 219 (`READ_FID_H`) dan baris 225 (`READ_FID_L`) sudah mencakup kedua byte `FRAME_ID`. Integritas deteksi galat checksum tetap bekerja 100% tanpa perubahan logika akumulator [DIVERIFIKASI].
  3. **Dampak ke RTL `packet_parser.vhd`:** Cukup menambahkan demux rute pada `DISPATCH_PAYLOAD` (baris 258-271): jika `frame_id_reg(15) = '1'`, aliran data diarahkan ke `audio_fifo_wr_data` / `audio_fifo_wr_en`, sedangkan jika `'0'`, diarahkan ke `m_axis_data` dekoder RLE.
  4. **Pencacah Frame Video vs Audio:**
     Pada modul [packet_parser.vhd](../hdl/packet_parser.vhd#L307), `val_cnt <= val_cnt + 1;` mencacah paket yang valid. Sesuai keputusan tim, pencacah `VALID_FRAMES` (`cnt_valid_frames`) serta register `FIRST_FRAME_ID` dan `LAST_FRAME_ID` **HANYA** menghitung dan mencatat paket video (`frame_id_reg(15) = '0'`). Paket audio (`frame_id_reg(15) = '1'`) dicatat pada pencacah telemetri terpisah (`cnt_valid_audio_packets`).
  5. **Dampak ke Manifest `stream_expected.txt` & Golden Tests:**
     Pada [stream_expected.txt](../data/golden/stream_expected.txt#L18-L19), pengujian memeriksa `FIRST_FRAME_ID: 0`, `LAST_FRAME_ID: 89`, dan `VALID_FRAMES: 90`. Karena seluruh paket video pada berkas golden eksisting memiliki `FRAME_ID` $0..89$ (bit 15 selalu `'0'`), seluruh vektor uji golden (`stream_clip`, `stream_byte_insertion`, dll) dan testbench M2b (`tb_packet_parser`, `tb_stream_rx`, `tb_top_stream`) dijamin tetap **LULUS 100% (Bit-Exact)** tanpa perubahan berkas golden!

### 3.4 Arsitektur Audio FIFO & Kompensasi Drift Jam (D-17)

#### A. Analisis Kebutuhan Arsitektur Commit/Rollback pada Audio FIFO
- **Perilaku Transaksi Spekulatif pada `packet_parser.vhd` dan `rx_fifo.vhd`:**
  Pada [packet_parser.vhd](../hdl/packet_parser.vhd#L199), saat SOF `0x55 0xAA 0x5A` terdeteksi, modul mengasertifkan `fifo_mark_sof <= '1'`, yang mengunci posisi pointer awal paket pada [rx_fifo.vhd](../hdl/rx_fifo.vhd#L116) (`r_ptr_sof <= r_ptr_spec`).
  Selanjutnya, pada fase `DISPATCH_PAYLOAD` ([packet_parser.vhd](../hdl/packet_parser.vhd#L258-L283)), byte muatan disalurkan ke subsistem pemroses secara langsung saat dibaca dari FIFO RX. Penyaluran ini terjadi **SEBELUM** byte `EOF` (`0xED`) dan byte `CHECKSUM` diperiksa pada baris 286-318.
  Jika pada tahap akhir `READ_CHECKSUM` (baris 312) ditemukan ketidakcocokan checksum, `packet_parser` mengasertifkan `fifo_rollback <= '1'` (baris 315), yang memerintahkan `rx_fifo.vhd` (baris 108-109) membatalkan seluruh transaksi dan mengembalikan pointer baca (`r_ptr_spec <= r_ptr_sof + 1; r_ptr_commit <= r_ptr_sof + 1`).
- **Masalah pada Penyaluran Audio:**
  Jika payload audio dialirkan langsung ke FIFO audio standar saat `DISPATCH_PAYLOAD`, seluruh byte dari paket audio yang cacat/korup sudah terlanjur tersimpan di dalam memori FIFO audio dan akan diputar ke earphone/speaker sebagai letupan noise akustik (*audio pop/glitch*), karena FIFO biasa tidak memiliki mekanisme pembatalan data yang sudah ditulis.
- **Solusi Arsitektur FIFO Audio dengan Pointer Spekulatif (Commit / Rollback):**
  1. Modul `audio_fifo.vhd` wajib mengimplementasikan struktur pointer tulis spekulatif ganda: `w_ptr_spec` dan `w_ptr_commit`, serta pointer baca `r_ptr` menggunakan lebar **12 bit** (11 bit alamat BRAM + 1 bit wrap / MSB) [DIVERIFIKASI: analog dengan struktur FIFO circular buffer]. Bit ke-11 berfungsi sebagai penanda putaran memori sehingga kondisi buffer **Penuh (Full)** dan **Kosong (Empty)** dapat dibedakan secara tegas tanpa ambiguitas modulo.
  2. Saat `DISPATCH_PAYLOAD`, byte audio ditulis ke memori BRAM pada alamat `w_ptr_spec(10 downto 0)` dan pointer bertambah `w_ptr_spec <= w_ptr_spec + 1` (modulo 4.096).
  3. Jika verifikasi checksum lolos dan `packet_parser` mengasertifkan `packet_valid <= '1'` dan `fifo_commit <= '1'`, maka `audio_fifo` mengomit data: `w_ptr_commit <= w_ptr_spec`.
  4. Jika checksum gagal dan `packet_parser` mengasertifkan `fifo_rollback <= '1'`, `audio_fifo` seketika membatalkan paket cacat: `w_ptr_spec <= w_ptr_commit`. Data korup tidak pernah dapat dibaca oleh pembaca audio.
  5. Sisi pembacaan audio (tick generator 8 kHz) membaca memori pada alamat `r_ptr(10 downto 0)` dan hanya membaca hingga batas `w_ptr_commit`.
  6. **Proteksi Overflow per Paket (Per-Packet Overflow) [DIASUMSIKAN]:**
     Saat awal penerimaan paket audio (SOF terdeteksi dan bit 15 `FRAME_ID = 1`), `packet_parser` membaca panjang muatan `PAYLOAD_LEN` (266 s.d. 267 Byte). Pada saat itu juga, logika pengendali `audio_fifo` mengevaluasi sisa ruang bebas BRAM menggunakan aritmetika pointer 12-bit:
     $$\text{Occupied} = (\text{w\_ptr\_commit} - \text{r\_ptr}) \pmod{4.096}$$
     $$\text{Free Space} = 2.048 - \text{Occupied}$$
     (Kondisi Kosong: $\text{Occupied} = 0$; Kondisi Penuh: $\text{Occupied} = 2.048$).
     Jika $\text{Free Space} < \text{PAYLOAD\_LEN}$, penulisan seluruh paket audio tersebut langsung dibatalkan (rollback otomatis), byte muatan yang masuk diabaikan tanpa ditulis ke memori BRAM, register telemetri `cnt_audio_overflow` dinaikkan (+1), dan pointer tulis spekulatif dikunci pada `w_ptr_spec <= w_ptr_commit`.
     *Dampak ke Arsitektur Commit/Rollback:* Mekanisme proteksi overflow berbasis per-paket ini menjamin sifat atomik (*all-or-nothing*) transaksi paket: sebuah paket audio hanya akan ditulis ke memori FIFO jika seluruh byte muatannya dijamin muat tanpa memicu pemotongan muatan (*partial write*) atau korupsi penimpaan pointer (*overrun*).
- **Dampak terhadap Utilisasi Blok RAMB18E1:**
  Kapasitas FIFO audio ditetapkan sebesar **2.048 Byte** ($2\text{ K} \times 8$) menggunakan **1 blok RAMB18E1** (0,5 BRAM Tile) [DIASUMSIKAN: konfigurasi True Dual-Port $2048 \times 8$]. Utilisasi ini identik dengan modul `rx_fifo` ($2\text{ K} \times 8$) yang terbukti memetakan ke tepat 1 blok RAMB18E1 pada hasil sintesis Vivado [DIVERIFIKASI: `vivado/build_m2b.log` baris 288, `u_fifo/mem_reg | 2 K x 8 | 1 RAMB18`]. Seluruh register pointer spekulatif (`w_ptr_spec`, `w_ptr_commit`, `r_ptr`) serta komparator rollback dibangun menggunakan logika fabric FPGA (LUT dan Flip-Flop), sehingga penambahan mekanisme commit/rollback pada audio FIFO **TIDAK** membutuhkan penambahan blok RAMB18E1 baru.

#### B. Analisis Drift Jam Akumulatif, Watermark 2.048 B, & Ketahanan Jeda (D-17 / D-18)

- **Formulasi Persamaan Indeks Aliran Audio ($S, C, L$):**
  Didefinisikan variabel status aliran audio pada domain waktu kontinu $t$:
  - $S(t)$: Jumlah total sampel audio yang telah berhasil dikirim oleh Host PC dan masuk ke FIFO audio FPGA sejak awal pemutaran ($t_0$).
  - $C(t)$: Jumlah total sampel audio yang telah diputar (dikonsumsi) oleh modulator PWM DAC hardware FPGA sejak output audio diaktifkan.
  - $L(t) = S(t) - C(t)$: Tingkat keterisian (*occupancy level*) buffer audio FIFO pada saat $t$ (dalam satuan byte/sampel).
  - *Syarat Kesinkronan Sempurna Audio-Video:*
    Video diputar mengikuti laju nominal 30 FPS berdasarkan jam waktu dinding $t$. Aliran audio berada dalam kondisi **sinkron sempurna dengan video** jika dan hanya jika:
    $$C(t) = 8.000 \times (t - t_0)$$
    **Perhatikan bahwa $C(t)$ sama sekali TIDAK BERGANTUNG pada nilai $L(t)$, selama $L(t) > 0$** (buffer tidak mengalami kekosongan/underflow)!

- **Parameter Kapasitas FIFO & Fase Pre-roll [DIASUMSIKAN]:**
  - **Kapasitas FIFO Audio Hardware:** $2.048\text{ Byte}$ (1 blok RAMB18E1). Pada laju $8.000\text{ Byte/s}$, kapasitas total setara durasi $256\text{ ms}$ (7,68 frame video).
  - **Fase Pengisian Awal (*Pre-roll Lead Time*):** $1.024\text{ Byte}$ ($50\%$ kapasitas FIFO, setara $\mathbf{128\text{ ms}}$ atau $3,84\text{ frame video}$). Output PWM dipertahankan hening (`0x80`) selama fase pengisian awal hingga $1.024\text{ Byte}$ terkumpul, kemudian pemutaran audio dimulai ($C(t)$ mulai bertambah).
  - **Ambang Batas Watermark ($20\% / 80\%$):**
    - Ambang batas bawah (*Low Watermark*, $20\%$): $2.048 \times 0,20 = \mathbf{410\text{ Byte}}$ ($51,25\text{ ms}$).
    - Ambang batas atas (*High Watermark*, $80\%$): $2.048 \times 0,80 = \mathbf{1.638\text{ Byte}}$ ($204,75\text{ ms}$).
    - Margin dari titik kerja nominal ($1.024\text{ Byte}$) ke kedua watermark: $1.024 - 410 = 1.638 - 1.024 = \mathbf{614\text{ Byte}}$ ($76,75\text{ ms}$).
    - Margin ke Underflow Absolut ($L=0$): $\mathbf{1.024\text{ Byte}}$ ($128\text{ ms}$).

- **Koreksi Penalaran Jeda Transmisi Host 100 ms (Mengapa Pemulihan Lewat Slip Salah):**
  Misalkan terjadi jeda transmisi sesaat pada Host PC sebesar $T_{\text{stall}} = 100\text{ ms}$ ($800\text{ sampel}$):
  1. Selama jeda $100\text{ ms}$, host tidak mengirim paket audio ($S(t)$ tidak bertambah).
  2. Karena buffer memiliki cadangan pre-roll $1.024\text{ Byte}$, konsumsi FPGA tetap berjalan normal tanpa terputus: $C(t)$ terus bertambah secara mulus tepat pada laju $8.000\text{ sampel/detik}$.
  3. Isi buffer $L(t)$ turun dari $1.024\text{ B}$ ke:
     $$L = 1.024 - 800 = \mathbf{224\text{ Byte}} > 0\text{ Byte}$$
  4. **Status Kesinkronan:** Karena $L = 224\text{ Byte} > 0$, pembacaan audio tidak mengalami underflow ($C(t)$ tidak terputus). Oleh karena itu, **AUDIO TETAP SINKRON SEMPURNA DENGAN VIDEO!** Yang berkurang hanyalah cadangan toleransi (*headroom*) buffer terhadap jitter transmisi berikutnya (margin tersisa $224\text{ B} = 28\text{ ms}$).
  5. **Kekeliruan Konsep "Pemulihan Level Lewat Slip":**
     Jika level buffer $L$ dinaikkan kembali ke $1.024\text{ B}$ dengan mengulang sampel (slip repeat) lokal FPGA sebanyak 800 sampel:
     Setiap sampel yang diulang menghentikan pertambahan $C(t)$ selama 1 periode sampel ($125\ \mu\text{s}$). Mengulang 800 sampel akan menahan $C(t)$ selama $800 \times 125\ \mu\text{s} = \mathbf{100\text{ ms}}$, sehingga **AUDIO TERTINGGAL SECARA PERMANEN SEBESAR 100 MS TERHADAP VIDEO!**
     Artinya, pemulihan level buffer melalui slip lokal justru **MERUSAK SINKRONISASI AUDIO-VIDEO** yang sebelumnya masih utuh!
  6. **Solusi Pemulihan yang Benar: Host Catch-up Burst (8,68 ms):**
     Pemulihan level $L$ dari $224\text{ B}$ ke $1.024\text{ B}$ **HANYA BOLEH DILAKUKAN MELALUI CATCH-UP BURST DARI HOST PC**. Begitu jeda berakhir, host segera mengirimkan 800 byte tertunda pada kecepatan penuh UART 921.600 baud ($92.160\text{ B/s}$). Transmisi 800 B ini selesai hanya dalam:
     $$T_{\text{burst}} = rac{800\text{ B}}{92.160\text{ B/s}} pprox \mathbf{8,68\text{ ms}}$$
     Selama 8,68 ms tersebut konsumsi FPGA hanya $8,68 \times 8 = 69\text{ B}$, sehingga level buffer pulih ke $224 + 800 - 69 = \mathbf{955\text{ Byte}}$ dalam waktu $< 9\text{ ms}$ tanpa menggeser timeline $C(t)$ sama sekali. Seluruh klaim lama mengenai pemulihan lewat 800 slip selama 40 detik resmi **DIHAPUS**.

- **Peran Sebenarnya dari Slip & Syarat Persistensi Dwell Time (D-17):**
  - **Fungsi Eksklusif Slip:** Mekanisme penyesuaian adaptif lokal FPGA (slip repeat / drop 1 sampel) **HANYA BERFUNGSI MENGOREKSI DRIFT FREKUENSI OSILATOR KRISTAL JANGKA PANJANG**, bukan untuk merespons fluktuasi level buffer sesaat akibat jeda pengiriman host!
  - **Aturan Dwell Time (Waktu Tinggal Minimum):**
    Aturan "repeat saat $L < 410\text{ B}$" **DILARANG LANGSUNG AKTIF** begitu buffer turun sesaat akibat jeda host. Algoritma slip hanya boleh aktif apabila level buffer berada di luar rentang watermark $[410\text{ B}, 1.638\text{ B}]$ **SECARA PERSISTEN** selama waktu tinggal minimum (*dwell time*):
    $$\tau_{\text{dwell}} \ge \mathbf{3\text{ detik}} \quad (\text{usulan rentang } 2\text{ s.d. } 5\text{ detik})$$
    *Alasan Pemilihan Nilai $\tau_{\text{dwell}} = 3\text{ detik}$:*
    Pada selisih drift kristal terburuk $250\text{ ppm}$, laju pergeseran buffer sangat lambat ($2\text{ sampel/detik}$). Untuk berpindah sejauh 100 sampel dibutuhkan waktu 50 detik. Sebaliknya, gangguan transmisi host atau OS jitter umumnya berlangsung $< 200\text{ ms}$ dan disusul oleh *catch-up burst* dalam $< 10\text{ ms}$. Memberikan jeda persistensi 3 detik menjamin bahwa penurunan buffer sesaat akibat jeda host memiliki waktu lebih dari cukup untuk dipulihkan oleh host burst tanpa memicu slip lokal yang dapat mendistorsi fasa audio.
  - **Penurunan Ulang Kriteria Penerimaan Slip:**
    - *Pada Pemutaran Normal Kontinu:* Akumulasi drift kristal maksimum $250\text{ ppm}$ sepanjang 217,84 detik adalah $436\text{ Byte}$. Karena margin pre-roll ke watermark adalah $614\text{ Byte}$ ($436 < 614$), buffer tidak pernah menyentuh watermark $\implies$ target penerimaan: **0 slip (NOL)**.
    - *Pada Jeda Transmisi Host Singkat/Sedang ($< 128\text{ ms}$):* Host segera mengirimkan catch-up burst dalam $< 10\text{ ms}$, timer dwell tidak pernah kedaluwarsa, tidak ada slip yang dibangkitkan, dan kesinkronan $C(t)$ tetap terjaga 100%.

- **Underflow Total (Jeda Transmisi Host $> 128\text{ ms}$) & Masalah Keputusan D-18:**
  - Jika jeda transmisi host melebihi cadangan pre-roll ($T_{\text{stall}} > 128\text{ ms}$), buffer $L(t)$ turun hingga mencapai $0\text{ Byte}$ (buffer kosong total).
  - Selama durasi kekosongan:
    $$T_{\text{silence}} = T_{\text{stall}} - 128\text{ ms}$$
    modulator PWM DAC tidak menerima sampel baru sehingga beralih hening (`0x80`), dan pertambahan $C(t)$ terhenti selama $T_{\text{silence}}$.
  - Ketika transmisi host dilanjutkan kembali, aliran audio mengalami **lag desinkronisasi permanen sebesar persis durasi hening $T_{\text{silence}}$** terhadap video.
  - Pemecahan masalah lag pasca-underflow total ini merupakan subjek dari **Keputusan D-18 (Resinkronisasi Audio-Video Pasca-Buffer Underflow)**.
  - *Status Keputusan D-18:* **Tetap TERBUKA** (tidak ada opsi yang dipilih sepihak; evaluasi mencakup Opsi A skip paket basi di FPGA, Opsi B flush FIFO dan PC restart dari posisi sekarang, atau Opsi C tanpa pemulihan aktif).

- **Pencacah Telemetri Hardware yang Dapat Dibaca (Readable Hardware Counters) [DIASUMSIKAN]:**
  - `cnt_audio_underflow`: Pencacah kejadian buffer kosong saat sampel audio diminta oleh modulator PWM.
  - `cnt_audio_overflow`: Pencacah kejadian paket audio tiba saat kapasitas FIFO ($2.048\text{ B}$) penuh.
  - `cnt_audio_drop`: Pencacah jumlah sampel yang dibuang saat High Watermark (>80% / 1.638 B) aktif secara persisten.
  - `cnt_audio_repeat`: Pencacah jumlah sampel yang diulang saat Low Watermark (<20% / 410 B) aktif secara persisten.

### 3.5 Model Sinkronisasi Audio Jalur A2, Invarian Host Catch-up, & Protokol Tulis FIFO

#### A. Model Matematis Aliran Audio ($S, C, L$) & Ambang Pre-roll
- **Definisi Variabel Status Aliran:**
  - $S(t)$: Jumlah total sampel audio yang berhasil dikirim oleh Host PC dan masuk ke FIFO audio FPGA sejak awal pemutaran ($t_0$).
  - $C(t)$: Jumlah total sampel audio yang telah diputar (dikonsumsi) oleh modulator audio PWM hardware FPGA sejak awal pemutaran ($t_0$).
  - $L(t) = S(t) - C(t)$: Tingkat keterisian (*occupancy level*) buffer audio FIFO pada waktu $t$ (dalam satuan byte/sampel).
- **Syarat Kesinkronan Sempurna Audio terhadap Video:**
  Laju audio nominal adalah $8.000\text{ Hz}$ ($1\text{ sampel per } 125\ \mu\text{s}$), selaras dengan video 30 FPS ($266,666\dots\text{ sampel per frame}$). Aliran audio berada dalam kondisi **sinkron sempurna dengan video** jika dan hanya jika:
  $$C(t) = 8.000 \times (t - t_0)$$
  Selama buffer tidak underflow ($L(t) > 0$), $C(t)$ bertambah kontinu tepat $8.000\text{ sampel/detik}$ berdasarkan clock osilator 100 MHz Basys 3. Fluktuasi $L(t)$ akibat variasi interval kirim PC sama sekali tidak memengaruhi laju pemutaran $C(t)$ selama $L(t) > 0$.
- **Syarat Awal Pemutaran (Pre-roll Lead Time 1.024 Sampel):**
  - Modul hardware `audio_fifo.vhd` menahan status `playing = '0'` dan menyajikan level hening `0x80` sampai tingkat keterisian buffer mencapai ambang batas pre-roll:
    $$L(t) \ge 1.024\text{ Byte}$$
  - Oleh karena itu, Host PC **WAJIB** mengirimkan minimal 1.024 sampel audio awal sebelum atau tepat saat frame video 0 dipicu.
  - Dengan pola paket streaming audio 3 frame ($267, 267, 266\text{ Byte}$), pengiriman 4 paket awal menghasilkan total:
    $$267 + 267 + 266 + 267 = 1.067\text{ Byte} \ge 1.024\text{ Byte}$$
    sehingga fase pre-roll tuntas tepat saat frame video pertama dimulai.

#### B. Invarian Host Catch-up
- **Aturan Integritas Paket Audio Host:**
  Host PC **DILARANG MEMBUANG PAKET AUDIO** (*no host audio drop*). Paket audio tidak pernah di-skip atau di-drop di sisi perangkat lunak PC selama pemutaran normal.
- **Invarian Pemulihan Pasca-Jeda Transmisi:**
  Jika terjadi penundaan (*stall* / jeda pengiriman) pada Host PC akibat penjadwalan OS, garbage collection, atau variasi I/O:
  1. Selama jeda transmisi, pengiriman paket audio tertunda sesaat.
  2. Begitu jeda berakhir, Host PC **WAJIB** mentransmisikan seluruh paket audio yang tertunda secara berurutan dan beruntun (*burst*) pada kecepatan penuh UART 921.600 baud tanpa jeda artifisial, hingga antrean host kembali menyusul (*catch-up*).
  3. Transmisi burst ini memulihkan level FIFO $L(t)$ kembali ke titik kerja nominal ($1.024\text{ Byte}$) dalam waktu sangat singkat ($< 10\text{ ms}$ untuk jeda $100\text{ ms}$) tanpa menggeser timeline $C(t)$.

#### C. Dampak Jeda Transmisi Tanpa Burst terhadap Slip Bawah (Phase Shift Calculation)
Misalkan terjadi jeda transmisi sesaat sebesar $T_{\text{stall}} = 100\text{ ms}$ di mana Host PC **TIDAK** melakukan burst catch-up (hanya melanjutkan pengiriman pada laju nominal 8.000 Hz):
1. **Penurunan Level FIFO:**
   Selama $100\text{ ms}$, konsumsi FPGA $C(t)$ berjalan terus menghabiskan:
   $$\Delta C = 100\text{ ms} \times 8\text{ sampel/ms} = 800\text{ sampel}$$
   Level buffer turun dari titik nominal $1.024\text{ Byte}$ ke:
   $$L = 1.024 - 800 = \mathbf{224\text{ Byte}}$$
2. **Aktivasi Logika Low Slip (Repeat):**
   Karena $L = 224 < 410$ (ambang batas low watermark $20\%$), kondisi low slip terpenuhi. Jika level ini bertahan secara kontinu selama $\tau_{\text{dwell}} \ge 3\text{ detik}$, modul `audio_fifo` mengaktifkan `slip_low_mode = '1'`.
3. **Kompensasi Slip Lambat:**
   Dalam mode repeat slip, FPGA mengulang 1 sampel (tidak memajukan `r_ptr`) paling banyak 1 kali setiap $\tau_{\text{SLIP\_MIN}} = 50\text{ ms}$ (laju 20 sampel/detik).
   Pengulangan sampel menaikkan level buffer secara perlahan hingga mencapai ambang batas keluar histeresis:
   $$L_{\text{exit}} = \mathbf{512\text{ Byte}}$$
4. **Perhitungan Jumlah Sampel Diulang & Pergeseran Fasa Audio (Lag):**
   Jumlah sampel yang harus diulang untuk menaikkan buffer dari 224 ke 512 adalah:
   $$\Delta L = 512 - 224 = \mathbf{288\text{ sampel}}$$
   Setiap sampel yang diulang menahan penambahan $C(t)$ selama 1 periode sampel ($125\ \mu\text{s}$), sehingga menggeser fasa audio mundur terhadap video:
   $$\Delta t_{\text{shift}} = 288 \times 125\ \mu\text{s} = 288 \times 0,000125\text{ s} = \mathbf{0,036\text{ detik}} = \mathbf{36\text{ ms}}$$
   Waktu yang dibutuhkan FPGA untuk pemulihan lambat ini adalah:
   $$T_{\text{recovery}} = 288 \times 50\text{ ms} = 14.400\text{ ms} = \mathbf{14,4\text{ detik}}$$
   *Kesimpulan Teknis:* Jika PC tidak melakukan burst catch-up dan mengandalkan slip bawah untuk memulihkan buffer, audio akan mengalami **pergeseran fasa (desinkronisasi permanen) sebesar persis $36\text{ ms}$** terhadap video. Hal ini menegaskan mengapa invarian burst catch-up pada Host PC wajib dipatuhi.

#### D. Protokol Jabat Tangan Tulis & Analisis Hazard Waktu (Berdasarkan Hasil Uji C.4)
Berdasarkan hasil pengujian empiris timing protokol pada `tb_audio_fifo` (Test 10):
1. **Aturan `wr_start` (Wajib Mendahului 1 Siklus):**
   Sinyal `wr_start` wajib berupa pulsa aktif HIGH tepat 1 siklus clock mendahului byte `wr_valid` pertama, bersamaan dengan nilai `wr_len` yang valid (`wr_start` wajib mendahului `wr_valid` pertama satu siklus). Hal ini memberi waktu bagi register `reject_latch` untuk aktif pada siklus berikutnya jika ruang bebas BRAM tidak mencukupi.
2. **Aturan Jeda `wr_commit` (Wajib Minimal 1 Siklus):**
   Sinyal pengesahan paket `wr_commit` **WAJIB DIBERIKAN MINIMAL 1 SIKLUS CLOCK SETELAH `wr_valid` TERAKHIR** (`wr_valid <= '0'`, tunggu 1 siklus clock, lalu `wr_commit <= '1'`).
   *Hazard Jika Bersamaan (Sifat Inheren Modul):*
   Hazard `wr_commit` bersamaan dengan `wr_valid` terakhir adalah sifat inheren modul (evaluasi sekuensial sinkron): jika `wr_commit` di-assert pada siklus clock yang persis sama dengan `wr_valid` terakhir, di dalam proses sekuensial synchronous `w_spec <= w_spec + 1` dan `w_commit <= w_spec` dievaluasi serentak, sehingga register `w_commit` mengambil nilai `w_spec` saat itu (sebelum inkremen byte terakhir berlaku). Akibatnya, **byte terakhir paket hilang dari commit** (tercatat level hanya bertambah $N-1$ bukan $N$). Oleh karena itu, arsitektur integrasi parser wajib memberi jeda minimal 1 siklus sebelum asersi `wr_commit`.

#### E. Perilaku Sinyal `wr_reject` & Proteksi Kapasitas BRAM
1. **Evaluasi Kombinasional:**
   Keluaran `wr_reject` dievaluasi secara kombinasional instan saat `wr_start = '1'`:
   $$\text{wr\_reject} = '1' \iff (2.048 - \text{level\_spec}) < \text{wr\_len}$$
   Sinyal ini langsung bernilai '1' pada siklus yang sama dengan `wr_start`, memungkinkan logika pengirim mendeteksi penolakan secara instan.
2. **Penguncian Sekuensial (`reject_latch`) & Telemetri:**
   Pada siklus berikutnya, register internal `reject_latch <= '1'` aktif dan pencacah telemetri saturasi 16-bit `cnt_overflow` bertambah (+1). Selama `reject_latch = '1'`, penulisan spekulatif ke BRAM diblokir total (`mem` tidak diubah, `w_spec` tidak bertambah).
3. **Penyelesaian Transaksi:**
   Ketika paket yang ditolak selesai, parser mengasertifkan `wr_commit` atau `wr_rollback`, yang secara otomatis mereset `reject_latch <= '0'` dan mengembalikan `w_spec <= w_commit`, menjaga integritas memori BRAM tanpa data korup.

### 3.6 Implementasi Ekstensi Audio pada `packet_parser.vhd` (Milestone M4)
- **Status Implementasi:** **SELESAI DI SIMULASI** (`sim/tb_parser_audio.vhd`, 7 skenario pengujian lolos 100% byte-exact, 6 uji mutasi tertangkap).
- **Status Integrasi:** Modul daun mandiri; **BELUM TERINTEGRASI KE `top.vhd`** dan **BELUM DIUJI DI BOARD FISIK BASYS 3**. Seluruh keputusan terbuka (D-16, D-18) **TETAP TERBUKA**.
- **Kompatibilitas Mundur:** Seluruh port baru memiliki nilai default aman (`'0'` atau `(others => '0')`), sehingga instansiasi lama pada `hdl/top.vhd` dan testbench lama tidak terpengaruh sama sekali.

#### A. Antarmuka Port Baru Ekstensi Audio
| Port | Arah | Tipe | Nilai Default | Deskripsi & Protokol |
|---|---|---|---|---|
| `aud_start` | out | `std_logic` | `'0'` | Pulsa aktif HIGH tepat 1 siklus clock saat state `CHECK_LEN` mengidentifikasi paket audio (`FRAME_ID(15) = '1'`). Mendahului byte data payload pertama minimal 1 siklus clock. |
| `aud_len` | out | `unsigned(10 downto 0)` | `(others => '0')` | Panjang payload audio dalam byte (rentang 64 s.d. 1024 B). Valid bersamaan dengan pulsa `aud_start`. |
| `aud_valid` | out | `std_logic` | `'0'` | Stroba valid 1 siklus clock per byte payload spekulatif saat state `DISPATCH_AUDIO`. Tidak pernah aktif bila `aud_reject` terlatch. |
| `aud_data` | out | `std_logic_vector(7 downto 0)` | `(others => '0')` | Bus data sampel audio 8-bit PCM (spekulatif) yang dialirkan ke `audio_fifo.wr_data`. |
| `aud_commit` | out | `std_logic` | `'0'` | Pulsa pengesahan 1 siklus clock setelah EOF (0xED) dan checksum XOR valid. Terbit minimal 1 siklus clock setelah `aud_valid` terakhir. |
| `aud_rollback` | out | `std_logic` | `'0'` | Pulsa pembatalan 1 siklus clock jika EOF salah, checksum mismatch, atau timeout watchdog terjadi saat paket audio aktif. |
| `cnt_audio_packets` | out | `unsigned(15 downto 0)` | `(others => '0')` | Pencacah saturasi 16-bit jumlah paket audio yang sukses diterima dan dikomit. Tidak bertambah untuk paket yang ditolak (`aud_reject`). |
| `aud_reject` | in | `std_logic` | `'0'` | Sinyal masukan dari `audio_fifo.wr_reject`. Disampel pada siklus clock saat `aud_start = '1'`. Jika aktif, payload dikonsumsi spekulatif tetapi tidak diteruskan ke FIFO (`aud_valid = '0'`) dan `cnt_audio_packets` tidak bertambah [DIASUMSIKAN]. |

#### B. Diagram Waktu Teks (ASCII Timing Diagrams)

##### 1. Penerimaan Paket Audio Normal & Valid (Commit)
```text
Siklus Clock:     | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10| 11| 12| 13| 14| 15|
------------------+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
State FSM:        |LEN|CHK|FTC|DISPATCH_AUDIO |FTC|EOF|FTC|CHK|IDL|...
frame_id_reg:     |             0x8000 (bit 15 = '1')                         |
aud_start:        |___/---\___________________________________________________|
aud_len:          |===<      267 B (11-bit)       >===========================|
aud_valid:        |___________/---\___/---\.../---\___________________________|
aud_data:         |===========<D0 >===<D1 >...<Dn >===========================|
aud_commit:       |___________________________________________/---\___________|
aud_rollback:     |___________________________________________________________|
cnt_audio_packets:| N                                         | N + 1         |
```
*Aturan Invarian:*
- `aud_start` mendahului `aud_valid` pertama minimal 1 siklus clock.
- `aud_commit` terbit minimal 1 siklus clock setelah `aud_valid` terakhir (pada state `READ_CHECKSUM` setelah verifikasi lolos).
- `aud_valid` tidak pernah bocor ke antarmuka video (`m_axis_valid = '0'`, `packet_valid = '0'`).

##### 2. Penolakan Paket Audio Akibat Buffer Penuh (`aud_reject = '1'`)
```text
Siklus Clock:     | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10| 11| 12| 13| 14| 15|
------------------+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
State FSM:        |LEN|CHK|FTC|DISPATCH_AUDIO |FTC|EOF|FTC|CHK|IDL|...
aud_start:        |___/---\___________________________________________________|
aud_reject (in):  |___/---\___________________________________________________|
aud_rejected_reg: |_______/-----------------------------------\_______________|
aud_valid:        |___________________________________________________________| (Ditekan: '0')
aud_data:         |___________________________________________________________|
aud_commit:       |___________________________________________________________| (Ditekan: '0')
aud_rollback:     |___________________________________________________________|
rx_fifo commit:   |___________________________________________/---\___________| (Konsumsi bus)
cnt_audio_packets:| N                                                         | N (Tetap)
```
*Perilaku:*
- Ketika `aud_reject = '1'` saat `aud_start = '1'`, register `aud_rejected_reg` aktif mengunci status penolakan.
- Payload tetap dibaca dari `rx_fifo` agar sinkronisasi bus serial tidak macet, namun `aud_valid` ditekan tetap '0'.
- Setelah verifikasi EOF dan checksum valid, `rx_fifo` dikomit agar paket terbuang bersih, tetapi `aud_commit` tidak dipancarkan ke `audio_fifo` dan `cnt_audio_packets` tidak bertambah.

##### 3. Pembatalan Paket Audio (Galat Checksum / Timeout Watchdog)
```text
Siklus Clock:     | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10| 11| 12| 13| 14| 15|
------------------+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
State FSM:        |LEN|CHK|FTC|DISPATCH_AUDIO |FTC|EOF|FTC|CHK|IDL|...
aud_start:        |___/---\___________________________________________________|
aud_valid:        |___________/---\___/---\.../---\___________________________|
aud_commit:       |___________________________________________________________|
aud_rollback:     |___________________________________________/---\___________|
fifo_rollback:    |___________________________________________/---\___________|
cnt_chk_errors:   | M                                         | M + 1         |
cnt_audio_packets:| N                                                         | N (Tetap)
```
*Perilaku:*
- Jika checksum tidak cocok, atau watchdog timer (50 ms pada 100 MHz, generic `TIMEOUT_CYCLES`) habis saat transmisi terpotong, pulsa `aud_rollback <= '1'` dipancarkan serentak dengan `fifo_rollback <= '1'`.
- `audio_fifo` memulihkan penunjuk tulis spekulatif (`w_spec <= w_commit`), membuang seluruh sampel korup/parsial.

##### 4. Analisis Risiko Penolakan Paket Audio (Tautan Isu D-18)
- **Perilaku Discard:** Paket audio yang ditolak (`aud_reject = '1'` saat `aud_start = '1'`) tetap dikonsumsi dari `rx_fifo` agar sinkronisasi framing bus serial tidak macet, namun seluruh byte muatannya dibuang (`aud_valid` ditekan '0', `aud_commit` tidak diterbitkan).
- **Risiko Desinkronisasi AV (Audio Melompat Maju):** Pembuangan paket yang ditolak ini menyebabkan aliran audio melompat maju terhadap aliran video (*audio skips forward relative to video*).
- **Deteksi:** Kondisi ini di sisi perangkat keras hanya dapat terdeteksi melalui pencacah overflow/reject (`cnt_overflow` atau selisih paket audio).
- **Kewajiban Host (Flow Control):** Host pengirim (perangkat lunak streaming) wajib menjaga agar total byte muatan audio yang dikirimkan tidak pernah melebihi sisa ruang kosong FIFO audio (merujuk pada mitigasi desain D-18). Belum ada keputusan penambahan port backpressure perangkat keras ke host UART.

## 4. Alokasi Pin PMOD (Rencana Pinout `basys3.xdc`)

### 4.1 Header PMOD yang Tersedia pada Digilent Basys 3
Board Digilent Basys 3 memiliki 4 header ekspansi PMOD 12-pin bertegangan logika 3,3V: `JA`, `JB`, `JC`, dan `JXADC` [DIASUMSIKAN: Digilent Basys 3 Reference Manual].
Setiap konektor PMOD 12-pin terdiri dari dua baris 6-pin standar:
- Baris 1 (Pin 1..4 = Sinyal, Pin 5 = GND, Pin 6 = VCC 3,3V)
- Baris 2 (Pin 7..10 = Sinyal, Pin 11 = GND, Pin 12 = VCC 3,3V)

### 4.2 Pemetaan Pin yang Diusulkan

#### A. Header PMOD JA: Antarmuka Modul OLED SSD1306 (SPI 7-Pin)
Modul OLED SPI 7-pin dapat dipasang secara langsung menggunakan kabel jumper atau soket ke header PMOD JA [DIASUMSIKAN]:

| Pin PMOD JA | Package Pin Artix-7 | Nama Sinyal OLED | Fungsi Sinyal | Standar I/O | Keterangan |
|---|---|---|---|---|---|
| **JA1** | `J1` | `oled_res` | Hardware Reset (Active LOW) | LVCMOS33 | Dikontrol oleh FSM Reset OLED [DIASUMSIKAN] |
| **JA2** | `L2` | `oled_dc` | Data / Command Select | LVCMOS33 | `0` = Command, `1` = Display Data [DIASUMSIKAN] |
| **JA3** | `J2` | `oled_cs_n` | Chip Select (Active LOW) | LVCMOS33 | `0` saat transmisi SPI aktif [DIASUMSIKAN] |
| **JA4** | `G2` | `oled_sclk` | SPI Serial Clock (D0) | LVCMOS33 | Clock 6,25 MHz Mode 0 [DIASUMSIKAN] |
| **JA5** | `GND` | `GND` | Ground Tegangan | - | Pin Ground Fisik PMOD JA [DIVERIFIKASI] |
| **JA6** | `VCC` | `VCC` | Catu Daya 3,3V | - | Pin VCC Fisik 3,3V PMOD JA [DIVERIFIKASI] |
| **JA7** | `H1` | `oled_mosi` | SPI Serial Data (D1 / SDIN) | LVCMOS33 | Data serial Master Out [DIASUMSIKAN] |
| **JA8..JA10** | `K2`, `H2`, `G3` | `NC` | Tidak Terhubung | - | Cadangan ekspansi masa depan [DIASUMSIKAN] |

#### B. Header PMOD JB: Antarmuka Audio Analog A2 (PWM 8-Bit Mono)
Sinyal PWM audio dialokasikan pada header PMOD JB [DIASUMSIKAN]:

| Pin PMOD JB | Package Pin Artix-7 | Nama Sinyal Audio | Fungsi Sinyal | Standar I/O | Keterangan |
|---|---|---|---|---|---|
| **JB1** | `A14` | `audio_pwm` | Output PWM 8-bit | LVCMOS33 (Drive 8mA) | Frekuensi carrier 390,6 kHz [DIASUMSIKAN] |
| **JB2** | `A16` | `audio_sd_n` | Audio Shutdown / Mute | LVCMOS33 | `1` = Aktif, `0` = Hening (opsional) [DIASUMSIKAN] |
| **JB5** | `GND` | `GND` | Ground Audio Acuan | - | Ground filter RC & earphone [DIVERIFIKASI] |
| **JB6** | `VCC` | `VCC` | Catu Daya 3,3V | - | Pasokan amplifier eksternal (jika ada) [DIVERIFIKASI] |

### 4.3 Verifikasi Bebas Konflik Pin (`constraints/basys3.xdc`)
Berdasarkan berkas batasan implementasi aktif `constraints/basys3.xdc`:
- `clk` menggunakan pin `W5` [DIVERIFIKASI: baris 6].
- `btnC` menggunakan pin `U18` [DIVERIFIKASI: baris 11].
- `sw[0]` menggunakan pin `V17` [DIVERIFIKASI: baris 15].
- `RsRx` menggunakan pin `B18` [DIVERIFIKASI: baris 19].
- `RsTx` menggunakan pin `A18` [DIVERIFIKASI: baris 22].
- `led[0..7]` menggunakan pin `U16`, `E19`, `U19`, `V19`, `W18`, `U15`, `U14`, `V14` [DIVERIFIKASI: baris 26-48].

**Kesimpulan Audit Pin:**
Seluruh pin PMOD JA (`J1`, `L2`, `J2`, `G2`, `H1`) dan PMOD JB (`A14`, `A16`) berada di Bank I/O yang terpisah dan sama sekali tidak berbenturan dengan pin yang telah dialokasikan pada `basys3.xdc`. Tingkat konflik pin = **0 (Bebas Konflik 100%)** [DIVERIFIKASI].

---

## 5. Rencana Verifikasi Simulasi (Model Perilaku SPI & PWM)

Sebelum pengujian di board fisik Basys 3 dilakukan, seluruh fungsionalitas modul baru akan diverifikasi secara otomatis di simulator Vivado xsim:

### 5.1 Model Perilaku OLED Controller (`sim/tb_oled_spi.vhd`)
1. **Model Perilaku Slave SSD1306 (`sim/model_ssd1306.vhd`):**
   - Mengemulasikan antarmuka SPI 4-kabel slave SSD1306 di VHDL.
   - Mengumpulkan bit data pada setiap rising edge `SCLK` saat `CS = 0`.
   - Menguji keabsahan urutan inisialisasi register saat `DC = 0` (memverifikasi nilai byte inisialisasi).
   - Menuliskan bit data ke matriks internal virtual $128 \times 64$ saat `DC = 1`.
2. **Kriteria Asersi Otomatis (Pass/Fail Criteria):**
   - Membaca matriks virtual yang diterima dan membandingkannya secara *bit-exact* terhadap representasi kanonik 90 frame `data/golden/frames.bin`.
   - Menghitung waktu transmisi per frame harus berada pada rentang $1,30\text{ ms} \le T_{\text{transfer}} \le 1,35\text{ ms}$.

### 5.2 Model Perilaku PWM Audio (`sim/tb_audio_pwm.vhd`)
1. **Model Filter Low-Pass Analog Diskrit:**
   - Testbench mengimplementasikan filter integrasi rataan bergerak diskrit (*moving average window* 256 siklus clock) untuk mensimulasikan respons tegangan keluaran filter RC analog:
     $$V_{\text{out}}(t) = \frac{1}{256} \sum_{i=0}^{255} \text{pwm\_pin}(t - i) \times 3,3\text{ V}$$
2. **Kriteria Asersi Otomatis:**
   - Diberikan vektor uji sampel tangga: `0`, `64`, `128`, `192`, `255`.
   - Tegangan rata-rata terintegrasi harus merefleksikan nilai sampel input dengan toleransi kesalahan integrasi $\le 1\text{ LSB}$ ($0,39\%$).
   - Memverifikasi timing penarikan sampel dari FIFO audio tepat setiap 12.500 siklus clock (8 kHz).

---

## 6. Daftar Keputusan Desain (Decisions D-14..D-18)

Status keputusan desain teknis Milestone 4 per tanggal 2026-11-02:

| ID | Topik Keputusan | Pilihan Alternatif | Status | Keputusan & Catatan Arsitektur |
|---|---|---|---|---|
| **D-14** | Protokol Framing Paket Audio Streaming | **(A)** SOF khusus `0x55AB` untuk paket audio terpisah.<br>**(B)** Multiplexing audio dan video dalam satu paket gabungan.<br>**(C)** Tipe paket di bit tertinggi `FRAME_ID(15)` dengan SOF `0x55 0xAA 0x5A` standar. | **Disetujui pengguna 2026-11-02** | **Opsi (C) Terpilih:** Bit 15 `FRAME_ID = 1` menandai paket audio; SOF tetap `0x55 0xAA 0x5A`. Pencacah `VALID_FRAMES` serta register `FIRST_FRAME_ID` dan `LAST_FRAME_ID` tetap HANYA menghitung paket video; pencacah paket audio dibuat terpisah. |
| **D-15** | Arsitektur Port B Frame Buffer BRAM | **(A)** Arbitrase Time-Division Multiplexing (TDM) pada Port B tunggal.<br>**(B)** Duplikasi instance frame buffer BRAM (+1 RAMB18E1). | **Disetujui pengguna 2026-11-02** | **Opsi (B) Terpilih:** Duplikasi instance frame buffer BRAM untuk pembacaan OLED (+1 RAMB18E1). Jalur subsistem `ascii_sink` tetap utuh tanpa modifikasi apa pun. |
| **D-16** | Parameter Komponen Filter Analog RC Audio PMOD | **(A)** Usulan filter RC satu tingkat: $R = 2,2\text{ k}\Omega, C = 22\text{ nF}$ ($f_c \approx 3,29\text{ kHz}$, arus pin $3,3\text{ V} / 2,2\text{ k}\Omega \approx 1,5\text{ mA} \ll 8\text{ mA}$).<br>**(B)** Filter RC dua tingkat (*2nd-order passive*) untuk pelemahan carrier lebih tajam. | **TERBUKA** | Menunggu komponen fisik audio tiba untuk pengujian osiloskop dan uji dengar langsung di board Basys 3. Usulan $R = 2,2\text{ k}\Omega, C = 22\text{ nF}$ berstatus usulan desain [DIASUMSIKAN], bukan final, dan wajib diverifikasi pengguna manusia sebelum koneksi fisik. |
| **D-17** | Mekanisme Kompensasi Drift Buffer Audio FIFO | **(A)** Kontrol laju audio murni dari Host PC (mengatur interval pengiriman paket audio).<br>**(B)** Penyesuaian adaptif lokal di FPGA (drop/insert 1 sampel saat isi FIFO melewati ambang batas >80% atau <20%, dengan pre-roll lead time 512 B). | **Disetujui pengguna 2026-11-02** | **Opsi (B) Terpilih:** Penyesuaian adaptif lokal di FPGA dengan FIFO 2.048 B (1 RAMB18), pre-roll 1.024 B (128 ms), watermark 20%/80% (410/1.638 B, kapasitas 256 ms); pencacah underflow, overflow, dan slip (`cnt_audio_drop`, `cnt_audio_repeat`) dapat dibaca oleh telemetri. |
| **D-18** | Resinkronisasi Audio-Video Pasca-Buffer Underflow | **(A)** Indeks paket audio pada `FRAME_ID(14:0)`, FPGA membuang (*skip*) sampel basi.<br>**(B)** Reset pointer FIFO lokal (`flush`) dan host PC mengirim ulang dari posisi video saat ini.<br>**(C)** Tanpa pemulihan aktif (hanya mengandalkan slip lambat). | **TERBUKA** | Ditulis sebagai keputusan **TERBUKA**; tidak ada opsi yang dipilih. Masalah teknis: underflow selama $T$ (misal $100\text{ ms}$) membuat audio tertinggal permanen sebesar $T$ terhadap video jika seluruh paket audio dikirim tanpa drop; slip lokal 20 sampel/s memerlukan waktu $40\text{ detik}$ untuk mengejar lag 100 ms. |

---

## 7. Referensi Teknis yang Wajib Diverifikasi Pengguna Manusia

Dokumen desain konseptual ini mengacu pada sejumlah spesifikasi perangkat keras eksternal. Karena verifikasi saat ini dilakukan secara simulasi dan analisis offline tanpa board fisik, pengguna manusia **WAJIB** membuka dan memverifikasi dokumen-dokumen rujukan resmi berikut sebelum merakit perangkat keras fisik atau menerapkan modul RTL:

1. **Datasheet Chip Controller Solomon Systech SSD1306 (Revisi Resmi Acuan: Rev 1.1, April 2008):**
   - **Sumber Acuan Dokumen:** Berkas ekstraksi teks lembar data resmi Solomon Systech SSD1306 Revision 1.1 (April 2008) yang tersimpan di luar repositori proyek pada path:
     `ssd1306_raw.txt` (salinan referensi lokal di luar repositori)
   - **Pernyataan Revisi Dokumen:** Analisis teknis pada dokumen desain ini diverifikasi secara langsung terhadap lembar data **Rev 1.1**. Pengguna wajib memperhatikan bahwa revisi lembar data yang lebih baru (misalnya Rev 1.2 ke atas) atau addendum modul terpisah dapat memuat perbedaan parameter, penambahan perintah (seperti charge pump `0x8D`), atau toleransi waktu.
   - **Tindakan Wajib Pengguna:** Pengguna wajib membuka berkas rujukan tersebut dan memverifikasi:
     - Urutan byte perintah register konfigurasi pada tabel inisialisasi FSM (khususnya perintah `0x8D 0x14` charge pump setting, mode pengalamatan memori `0x20 0x00`, konfigurasi pin COM `0xDA 0x12`, dan level VCOMH `0xDB 0x20`).
     - Batas waktu siklus minimum clock antarmuka serial SPI ($t_{\text{cycle}} = 100\text{ ns}$, Hal. 52, Table 13-4) untuk memastikan clock $6,25\text{ MHz}$ ($T_{\text{SCLK}} = 160\text{ ns}$) memenuhi batas minimum datasheet.
     - Durasi pulsa minimum sinyal reset hardware ($t_{\text{RES}} = 3\ \mu\text{s}$, Hal. 49, Table 13-1) dan jeda stabilisasi pasca-reset sebelum transaksi SPI pertama dikirim.

2. **Halaman Vendor / Dokumentasi Teknis Modul Display OLED 0,96" SPI 7-Pin:**
   - **Sumber Acuan:** Halaman produk / dokumentasi teknis vendor penjual modul display OLED fisik yang dimiliki pengguna.
   - **Tindakan Wajib Pengguna:** Pengguna wajib memeriksa:
     - Urutan pin fisik header 7-pin (`GND`, `VCC`, `D0/SCLK`, `D1/MOSI`, `RES`, `DC`, `CS`).
     - Keberadaan rangkaian regulator tegangan onboard dan komponen pasif (memastikan pin VCC dan logika I/O bekerja pada tingkat 3,3V PMOD Basys 3 tanpa beban berlebih).
     - Kebutuhan konfigurasi charge pump internal (memastikan apakah modul 7-pin yang ditenagai catu 3,3V membutuhkan pengaktifan charge pump 7,5V `0x8D 0x14`).

3. **Digilent Basys 3 FPGA Board Reference Manual:**
   - **Sumber Acuan:** Manual referensi resmi Digilent Basys 3 (Tabel 6: *PMOD Pinout*).
   - **Tindakan Wajib Pengguna:** Pengguna wajib memeriksa:
     - Penomoran pin fisik konektor PMOD JA dan JB (baris atas pin 1..6 vs baris bawah pin 7..12).
     - Pemetaan pin PMOD terhadap pin package Artix-7 `xc7a35tcpg236-1` (JA: `J1`, `L2`, `J2`, `G2`, `H1`, `K2`, `H2`, `G3`; JB: `A14`, `A16`, `B15`, `B16`, `A15`, `A17`, `C15`, `C16`).
     - Kemampuan pasokan arus catu 3,3V pada header PMOD dan batas arus keluaran maksimum per pin I/O FPGA.

4. **Master XDC Digilent Basys 3 (`Basys-3-Master.xdc`):**
   - **Sumber Acuan:** Repositori GitHub resmi Digilent (`digilent-xdc/Basys-3-Master.xdc`).
   - **Tindakan Wajib Pengguna:** Pengguna wajib memeriksa:
     - Penamaan label pin sinyal dan penetapan `PACKAGE_PIN` untuk header PMOD JA dan JB pada berkas template batasan master asli pabrikan.
     - Atribut standar I/O (`IOSTANDARD LVCMOS33`) sebelum dimasukkan ke dalam berkas batasan aktif proyek `constraints/basys3.xdc`.
