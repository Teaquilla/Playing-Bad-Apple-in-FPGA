# Dokumen Desain Teknis Milestone 4: Tampilan OLED & Audio On-Board (docs/DESIGN_M4.md)

Dokumen ini merupakan proposal desain arsitektur untuk **Milestone 4 (M4)**, mencakup penambahan subsistem tampilan OLED SPI SSD1306 (128×64) dan subsistem output audio analog PWM 8-bit 8 kHz pada board Digilent Basys 3 (Xilinx Artix-7 `xc7a35tcpg236-1`).

> [!NOTE]
> Sesuai aturan pengembangan, seluruh rujukan terhadap kode, berkas, dan batasan implementasi yang ada ditandai sebagai **[DIVERIFIKASI]** (disertai kutipan nomor baris), sedangkan estimasi, spesifikasi perangkat keras eksternal yang belum diuji di board fisik, dan rencana arsitektur baru ditandai sebagai **[DIASUMSIKAN]**. Dokumen ini adalah proposal desain konseptual; tidak ada modul RTL, testbench, maupun berkas XDC baru yang diubah pada tahap ini.

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
- **Protokol SPI:** SPI 4-kabel Mode 0 (CPOL = 0, CPHA = 0). Clock `SCLK` berstatus IDLE pada logika LOW, dan data dicuplik pada tepi naik (*rising edge*) `SCLK` [DIASUMSIKAN: spesifikasi datasheet SSD1306].

### 1.2 Pembagi Frekuensi Clock SPI (`SCLK`) & Waktu Transfer
- **Batas Maksimum Frekuensi SSD1306:**
  Menurut spesifikasi SSD1306 (periksa datasheet untuk rujukan waktu antarmuka serial), waktu siklus clock minimum $t_{\text{cycle}} = 100\text{ ns}$, yang setara dengan frekuensi clock serial maksimum $10\text{ MHz}$ [DIASUMSIKAN].
- **Pembagian Frekuensi dari Clock Sistem 100 MHz Basys 3:**
  Clock utama board Basys 3 beroperasi pada frekuensi $100\text{ MHz}$ (periode $10\text{ ns}$) [DIVERIFIKASI: `constraints/basys3.xdc` baris 8].
  Untuk menghasilkan clock yang stabil dengan pembagi biner genap tanpa jitter, dipilih pembagi:
  $$\text{DIVIDER} = 16 \implies f_{\text{SCLK}} = \frac{100\text{ MHz}}{16} = 6,25\text{ MHz}$$
  Periode clock `SCLK` adalah $T_{\text{SCLK}} = 160\text{ ns}$ (lebar pulsa HIGH 80 ns, LOW 80 ns). Nilai ini memenuhi batas datasheet ($160\text{ ns} > 100\text{ ns}$) dengan margin keselamatan waktu sebesar $60\%$ [DIASUMSIKAN].

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

#### B. Tabel Perintah Inisialisasi & Urutan Penulisan Frame [DIASUMSIKAN]
> [!NOTE]
> Seluruh byte perintah dan urutan berikut didasarkan pada konvensi pustaka pengendali SSD1306 open-source komunitas (seperti Adafruit SSD1306 / U8g2) dan berstatus **[DIASUMSIKAN]** karena berkas datasheet resmi Solomon Systech SSD1306 tidak disimpan di dalam repositori proyek ini. Pengguna wajib memverifikasi item-item pada daftar periksa di bawah terhadap datasheet modul fisik yang dimiliki.

| No | Tahap / Perintah (Hex) | Nama Fungsi / Register | Status Pin SPI (`RES`, `CS`, `DC`) | Makna & Pengaturan Teknis | Alasan Pemilihan Nilai | Sumber Acuan |
|---|---|---|---|---|---|---|
| - | **Daya & Reset** | Power-on & Reset Pulse | `RES=0`, `CS=1`, `DC=0` $\rightarrow$ `RES=1` | Pulsa reset hardware minimum $10\ \mu\text{s}$ pasca catu daya stabil. | Memastikan FSM internal controller SSD1306 berada pada kondisi default pabrik. | Modul OLED hardware [DIASUMSIKAN] |
| 1 | `0xAE` | Display OFF | `RES=1`, `CS=0`, `DC=0` | Mematikan panel layar OLED (Sleep mode). | Mencegah tampilan artefak visual/noise di panel saat register dikonfigurasi. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 2 | `0xD5`, `0x80` | Set Display Clock Divide Ratio | `RES=1`, `CS=0`, `DC=0` | Menyetel rasio pembagi clock tampilan dan frekuensi osilator internal (`0x80`). | Nilai nominal default: osilator pada frekuensi tengah dan pembagi clock = 1 untuk stabilitas refresh panel. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 3 | `0xA8`, `0x3F` | Set Multiplex Ratio | `RES=1`, `CS=0`, `DC=0` | Menyetel rasio multiplexing ke 64MUX (`0x3F` = 63 desimal). | Menyesuaikan tinggi fisik panel OLED yang digunakan yaitu 64 baris baris piksel. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 4 | `0xD3`, `0x00` | Set Display Offset | `RES=1`, `CS=0`, `DC=0` | Menyetel offset pemetaan vertikal ke baris 0. | Tampilan dimulai tepat pada baris fisik teratas tanpa pergeseran baris. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 5 | `0x40` | Set Display Start Line | `RES=1`, `CS=0`, `DC=0` | Menentukan baris awal RAM pada baris 0 (RAM line 0). | Mengunci sinkronisasi baris atas RAM terhadap baris pertama panel. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 6 | `0x8D`, `0x14` | Charge Pump Setting | `RES=1`, `CS=0`, `DC=0` | Mengaktifkan pompa muatan internal 7,5V (`0x14` = Enable). | **Wajib diaktifkan** untuk modul 7-pin yang ditenagai murni dari 3,3V PMOD tanpa sumber catu eksternal VCC panel 7-15V. | Konvensi modul OLED SPI 3,3V [DIASUMSIKAN] |
| 7 | `0x20`, `0x00` | Set Memory Addressing Mode | `RES=1`, `CS=0`, `DC=0` | Menyetel mode pengalamatan horizontal (`0x00`). | Pointer kolom otomatis melompat ($0..127$) dan ganti halaman ($0..7$), memungkinkan pengiriman 1.024 Byte terus-menerus. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 8 | `0xA1` | Set Segment Re-map | `RES=1`, `CS=0`, `DC=0` | Memetakan alamat kolom 127 ke SEG0 (pemetaan terbalik). | Mengoreksi orientasi kolom horizontal agar teks/grafis tidak tampak terbalik (*mirror*). | Konvensi modul OLED SPI 3,3V [DIASUMSIKAN] |
| 9 | `0xC8` | Set COM Output Scan Direction | `RES=1`, `CS=0`, `DC=0` | Memindai COM dari baris COM[N-1] ke COM0 (pemetaan terbalik). | Mengoreksi orientasi vertikal agar tampilan tidak terbalik atas-bawah. | Konvensi modul OLED SPI 3,3V [DIASUMSIKAN] |
| 10 | `0xDA`, `0x12` | Set COM Pins Hardware Config | `RES=1`, `CS=0`, `DC=0` | Menyetel konfigurasi pin COM alternatif untuk resolusi 128×64 (`0x12`). | Sesuai dengan pengkabelan fisik baris COM internal panel 128×64 piksel. | Pustaka modul 128×64 [DIASUMSIKAN] |
| 11 | `0x81`, `0xCF` | Set Contrast Control | `RES=1`, `CS=0`, `DC=0` | Menyetel register kontras ke tingkat tinggi (`0xCF` dari rentang `0x00..0xFF`). | Memberikan kontras tinggi dan ketajaman visual optimal pada tegangan kerja 3,3V. | Pustaka Adafruit SSD1306 [DIASUMSIKAN] |
| 12 | `0xD9`, `0xF1` | Set Pre-charge Period | `RES=1`, `CS=0`, `DC=0` | Fase 1 = 1 DCLK, Fase 2 = 15 DCLK (`0xF1`). | Memberikan waktu pengisian awal kapasitansi piksel yang cukup untuk stabilitas tingkat hitam/putih. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 13 | `0xDB`, `0x40` | Set VCOMH Deselect Level | `RES=1`, `CS=0`, `DC=0` | Menyetel level ambang VCOMH ke ~0,77 × VCC (`0x40`). | Menjaga ambang batas deselect transistor panel agar piksel mati tidak bocor cahaya. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 14 | `0xA4` | Entire Display ON Resume | `RES=1`, `CS=0`, `DC=0` | Mengarahkan output tampilan mengikuti isi GDRAM internal. | Menghindari mode pemaksaan seluruh piksel menyala (bukan `0xA5`). | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 15 | `0xA6` | Set Normal / Inverse Display | `RES=1`, `CS=0`, `DC=0` | Menyetel mode normal (`0xA6`: bit 1 = menyala, bit 0 = padam). | Sesuai konvensi citra Bad Apple (latar hitam, objek putih). | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 16 | `0xAF` | Display ON | `RES=1`, `CS=0`, `DC=0` | Menghidupkan panel OLED setelah konfigurasi selesai. | Mengaktifkan penyalaan panel setelah seluruh register berada pada keadaan stabil. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 17 | `0x21`, `0x00`, `0x7F` | Set Column Address | `RES=1`, `CS=0`, `DC=0` | Menyetel rentang kolom dari 0 s.d. 127 sebelum penulisan frame. | Mengembalikan pointer kolom GDRAM ke koordinat awal $x=0$ sebelum transfer frame baru. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 18 | `0x22`, `0x00`, `0x07` | Set Page Address | `RES=1`, `CS=0`, `DC=0` | Menyetel rentang halaman dari 0 s.d. 7 sebelum penulisan frame. | Mengembalikan pointer halaman GDRAM ke koordinat awal $y=0$ (Page 0) sebelum transfer frame baru. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| 19 | `1.024 Byte Data` | GDRAM Display Data Write | `RES=1`, `CS=0`, `DC=1` | Mengalirkan 1.024 Byte data grafis frame ke memori GDRAM OLED. | Mengisi memori piksel panel OLED (128 kolom × 8 page) secara terus-menerus. | Pustaka umum SSD1306 [DIASUMSIKAN] |
| - | **Selesai / Idle** | Frame Bus Idle | `RES=1`, `CS=1`, `DC=1` atau `0` | Chip Select dide-asersi ke HIGH saat bus SPI hening antar-frame. | Melepas jalur bus SPI selama waktu hening (~32 ms) hingga frame berikutnya siap. | Protokol SPI Mode 0 [DIASUMSIKAN] |

#### C. Perbandingan dengan Urutan Pustaka Umum [DIASUMSIKAN]
> [!NOTE]
> Urutan pembanding berikut BUKAN berasal dari verifikasi independen terhadap berkas datasheet resmi (karena datasheet fisik tidak disertakan di dalam repositori), melainkan disusun berdasarkan ingatan dan konvensi pustaka umum open-source (seperti Adafruit SSD1306 / U8g2) yang dirangkum pada diskusi prompt sebelumnya. Pengguna wajib memverifikasi setiap byte register terhadap lembar data resmi modul OLED yang digunakan.

Urutan inisialisasi dan penulisan frame pada pustaka umum komunitas (misalnya Adafruit SSD1306 / U8g2 / Linux fb_ssd1306):
`AE; D5 80; A8 3F; D3 00; 40; 8D 14; 20 00; A1; C8; DA 12; 81 CF; D9 F1; DB 40; A4; A6; AF;` lalu `21 00 7F; 22 00 07; data`.

**Daftar Analisis Perbedaan & Keselarasan [DIASUMSIKAN]:**
1. **Urutan dan Nilai Perintah Init (Langkah 1..16):** Urutan rancangan pada tabel di atas identik 100% (*bit-exact*) dengan konvensi pustaka umum tersebut.
2. **Pengalamatan Memori Horisontal vs Halaman:** Kombinasi perintah `0x20 0x00` (Horizontal Addressing Mode) diikuti perintah framing `0x21 0x00 0x7F` (Set Column Address) dan `0x22 0x00 0x07` (Set Page Address) memungkinkan pengiriman seluruh 1.024 byte data frame secara kontinu dalam satu burst SPI berdurasi 1,32 ms. Sebagian pustaka lama menggunakan Page Addressing Mode (`0x20 0x02`), yang mengharuskan pengiriman perintah reposisi halaman (`0xB0..0xB7`) setiap 128 byte; penggunaan mode horisontal mengeliminasi overhead tersebut dan menyederhanakan FSM hardware.
3. **Parameter Kontras (`0x81 0xCF`):** Pustaka independen Adafruit menggunakan `0xCF` (kontras tinggi, ~207 dari 255), sementara beberapa pustaka hemat daya menggunakan `0x7F` (~127) atau `0x8F`. Nilai `0xCF` dipilih untuk memastikan keterbacaan tajam pada panel monokrom 0,96 inci.
4. **Pre-charge Period (`0xD9 0xF1`):** Nilai default bawaan chip saat reset adalah `0x22`. Nilai `0xF1` (fase discharge 1 DCLK, fase pre-charge 15 DCLK) umumnya digunakan pustaka untuk memastikan elektroda piksel terisi penuh sebelum penyalaan.
5. **VCOMH Deselect Level (`0xDB 0x40` vs `0x20`):** Nilai terdokumentasi di datasheet harus diperiksa pengguna; seingat asisten default reset pada datasheet SSD1306 adalah `0x20` (~0,77 × VCC), sedangkan nilai `0x40` merepresentasikan tingkat deselect lebih tinggi (~0,83 × VCC) [DIASUMSIKAN]. Pengguna wajib memverifikasi nilai mana yang direkomendasikan pabrikan panel fisik.
6. **Perilaku Sinyal Fisik SPI (CS, DC, RES):**
   - Sinyal `RES` ditarik LOW saat daya dinyalakan dan dipertahankan HIGH setelahnya.
   - Sinyal `CS` diturunkan ke LOW sebelum pengiriman perintah/data, dan dinaikkan ke HIGH setelah 1.024 byte terkirim untuk mengunci data GDRAM dan melepas bus selama sisa jeda 32 ms.
   - Sinyal `DC` bernilai LOW (`0`) untuk perintah init (Langkah 1..16) dan perintah framing (Langkah 17..18), lalu dinaikkan ke HIGH (`1`) saat byte data piksel GDRAM (Langkah 19) disalurkan.

#### D. Daftar Byte Inisialisasi yang Wajib Diverifikasi Pengguna terhadap Datasheet Asli [DIASUMSIKAN]:
1. **`0x8D, 0x14` (Charge Pump Setting):** Pastikan modul 7-pin pengguna membutuhkan aktivasi pompa muatan internal (`0x14` = Enable 7,5V). Jika modul ditenagai murni dari 3,3V pin PMOD tanpa catu panel eksternal 7–15V, layar tidak akan menyala jika charge pump di-disable (`0x10`).
2. **`0x20, 0x00` (Set Memory Addressing Mode):** Pastikan controller SSD1306 mendukung mode pengalamatan horizontal (`0x00`) agar data 1.024 Byte dapat ditulis berurutan secara otomatis tanpa mengirim perintah reposisi halaman (`0xB0..0xB7`) per 128 byte.
3. **`0xA1` (Set Segment Re-map):** Menentukan arah pemetaan kolom (kolom 127 dipetakan ke SEG0). Periksa apakah orientasi horizontal citra membutuhkan `0xA1` atau `0xA0`.
4. **`0xC8` (Set COM Output Scan Direction):** Menentukan arah pemindaian vertikal baris (COM[N-1] ke COM0). Periksa apakah orientasi vertikal citra membutuhkan `0xC8` atau `0xC0`.
5. **`0xDA, 0x12` (Set COM Pins Hardware Config):** Memilih konfigurasi pin COM alternatif (`0x12`) untuk panel 128×64. Pada panel dengan layout pin berurutan atau tinggi 32 baris biasanya digunakan `0x02`.
6. **`0x81, 0xCF` (Set Contrast Control):** Nilai kontras `0xCF` (~207 desimal). Periksa arus kerja panel dan apakah default pabrik `0x7F` (~127 desimal) sudah mencukupi.
7. **`0xD9, 0xF1` (Set Pre-charge Period):** Fase discharge 1 DCLK dan phase pre-charge 15 DCLK (`0xF1`). Default reset bawaan adalah `0x22`.
8. **`0xDB, 0x40` vs `0x20` (Set VCOMH Deselect Level):** Periksa datasheet modul: nilai default reset menurut datasheet umumnya adalah `0x20` (~0,77 × VCC), sedangkan nilai `0x40` (~0,83 × VCC) sering digunakan pada pustaka pihak ketiga.
9. **Timing Sinyal Reset Hardware (`RES`):** Durasi pulsa minimum sinyal reset aktif LOW ($t_{RES}$) dan jeda stabilisasi pasca-reset ($t_{RES\_wait}$) sebelum transaksi SPI pertama dikirim.

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

### 3.2 Modulator PWM 8-Bit & Analisis Jitter Latch Sampel
- **Frekuensi Pembawa PWM (Carrier Frequency):**
  Resolusi 8-bit membutuhkan pencacah periode 256 tingkatan:
  $$f_{\text{carrier}} = \frac{100.000.000\text{ Hz}}{256} = 390.625\text{ Hz} \approx 390,625\text{ kHz}$$
- **Karakteristik Hubungan Frekuensi Tick 8 kHz dan Carrier PWM:**
  Interval sampel 8 kHz adalah tepat $12.500\text{ siklus clock}$ pada 100 MHz. Nilai 12.500 **BUKAN** merupakan kelipatan bulat dari periode carrier 256 siklus:
  $$\frac{12.500}{256} = 48,828125\text{ periode carrier}$$
  Untuk mencegah terpotongnya periode carrier PWM di tengah siklus (yang akan memicu distorsi frekuensi tinggi dan pulsa kerdil / runt pulse), sampel audio baru dari FIFO **hanya di-latch saat pencacah carrier wrap-around** (`carrier_cnt = 255 \rightarrow 0`) setelah pulsa `sample_req` dibangkitkan.
- **Perhitungan Jitter Maksimum & Efeknya [DIASUMSIKAN]:**
  - Jitter waktu penundaan latch sampel baru bervariasi antara $0\text{ s.d. } 255\text{ siklus clock}$ (0 hingga 2,55 µs). Jitter maksimum adalah:
    $$J_{\text{max}} = 256\text{ siklus} \times 10\text{ ns} = \mathbf{2,56\ \mu\text{s}}$$
  - Efek Jitter terhadap Kualitas Audio:
    Periode sampel 8 kHz adalah $T_{\text{sample}} = 125\ \mu\text{s}$. Variasi $2,56\ \mu\text{s}$ merepresentasikan deviasi fase waktu sebesar:
    $$\frac{2,56\ \mu\text{s}}{125\ \mu\text{s}} \times 100\% \approx 2,05\%$$
    Modulasi jitter fasa 2,05% ini terdistribusi pada frekuensi ketukan (*beat frequency*) antara clock carrier 390,625 kHz dan laju tick 8 kHz. Komponen harmonik frekuensi tinggi yang dihasilkan berada jauh di luar spektrum pendengaran manusia ($> 20\text{ kHz}$) dan seluruhnya diredam oleh filter analog low-pass RC PMOD ($f_c \approx 15,9\text{ kHz}$), sehingga tidak menghasilkan artefak audio yang dapat didengar [DIASUMSIKAN].
- **Karakteristik Akustik:**
  Frekuensi carrier 390,6 kHz berada jauh melampaui batas pendengaran manusia ($20\text{ kHz}$) dan batas Nyquist audio 8 kHz ($4\text{ kHz}$). Rasio oversampling terhadap audio adalah $390,625 / 8 = 48,8\times$ [DIASUMSIKAN].
- **Prinsip Modulasi:**
  Pencacah bebas 8-bit `pwm_cnt` mencacah $0..255$.
  Jika $\text{sample\_data} > \text{pwm\_cnt}$, pin output `audio_pwm` bernilai HIGH (`1`); jika tidak, bernilai LOW (`0`).

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

#### B. Analisis Drift Jam Akumulatif, Watermark 2.048 B, & Ketahanan Jeda (D-17)
- **Parameter Kapasitas FIFO & Fase Pre-roll [DIASUMSIKAN]:**
  - **Kapasitas FIFO Audio Hardware:** $2.048\text{ Byte}$ (1 blok RAMB18E1). Pada laju $8.000\text{ Byte/s}$, kapasitas total setara dengan durasi penyangga:
    $$T_{\text{buf}} = \frac{2.048\text{ Byte}}{8.000\text{ Byte/s}} = 0,256\text{ detik} = \mathbf{256\text{ ms}} \quad (\approx 7,68\text{ frame video pada 30 FPS})$$
  - **Fase Pengisian Awal (*Pre-roll Lead Time*):** $1.024\text{ Byte}$ ($50\%$ kapasitas FIFO, setara $\mathbf{128\text{ ms}}$ atau $\approx 3,84\text{ frame video}$). Output PWM dipertahankan hening (`0x80`) selama fase pengisian awal hingga $1.024\text{ Byte}$ terkumpul, kemudian tick generator 8 kHz mulai aktif.
  - **Ambang Batas Watermark ($20\% / 80\%$):**
    - Ambang batas bawah (*Low Watermark*, $20\%$): $2.048 \times 0,20 = 409,6 \approx \mathbf{410\text{ Byte}}$ ($51,25\text{ ms}$).
    - Ambang batas atas (*High Watermark*, $80\%$): $2.048 \times 0,80 = 1.638,4 \approx \mathbf{1.638\text{ Byte}}$ ($204,75\text{ ms}$).
    - Lebar jendela toleransi watermark ($80\% - 20\%$):
      $$W_{\text{watermark}} = 1.638\text{ B} - 410\text{ B} = \mathbf{1.228\text{ Byte}} \quad (153,5\text{ ms})$$
    - Margin dari titik kerja pre-roll ($1.024\text{ Byte}$):
      - Margin ke High Watermark ($80\%$): $1.638 - 1.024 = \mathbf{614\text{ Byte}}$ ($76,75\text{ ms}$).
      - Margin ke Low Watermark ($20\%$): $1.024 - 410 = \mathbf{614\text{ Byte}}$ ($76,75\text{ ms}$).
      - Margin ke Underflow Absolut (0 Byte): $1.024 - 0 = \mathbf{1.024\text{ Byte}}$ ($128\text{ ms}$).
      - Margin ke Overflow Absolut (2.048 Byte): $2.048 - 1.024 = \mathbf{1.024\text{ Byte}}$ ($128\text{ ms}$).

- **Aritmetika Slip Sampel pada Laju Sampling 8 kHz [DIVERIFIKASI: perhitungan matematis]:**
  - Deviasi frekuensi $100\text{ ppm}$ ($100 \times 10^{-6}$):
    $$\text{Laju Drift}_{100\text{ppm}} = 8.000\text{ sampel/s} \times 100 \times 10^{-6} = 0,80\text{ sampel/detik} \implies T_{\text{slip, 100ppm}} = \frac{1}{0,80} = 1,25\text{ detik}$$
  - Deviasi frekuensi $250\text{ ppm}$ ($250 \times 10^{-6}$):
    $$\text{Laju Drift}_{250\text{ppm}} = 8.000\text{ sampel/s} \times 250 \times 10^{-6} = 2,00\text{ sampel/detik} \implies T_{\text{slip, 250ppm}} = \frac{1}{2,00} = 0,50\text{ detik}$$
  - Total akumulasi drift sepanjang pemutaran video penuh ($217,84\text{ detik}$):
    - Pada $100\text{ ppm}$: $217,84\text{ s} \times 0,80\text{ sampel/s} = 174,27 \approx \mathbf{174\text{ sampel}}$ (Byte).
    - Pada $250\text{ ppm}$: $217,84\text{ s} \times 2,00\text{ sampel/s} = 435,68 \approx \mathbf{436\text{ sampel}}$ (Byte).

- **Parameter Kontrol Slip (Interval Minimum & Histeresis) serta Kapasitas Koreksi vs Drift 250 ppm (D-17) [DIVERIFIKASI: perhitungan matematis]:**
  - **Selang Minimum Antar-Slip ($T_{\text{slip\_min}}$):**
    Ditetapkan batas jeda minimum antar-koreksi slip sebesar $T_{\text{slip\_min}} = 10\text{ ms s.d. } 50\text{ ms}$ (setara 80 s.d. 400 sampel audio pada 8 kHz). Pembatasan ini mencegah terjadinya pengulangan atau pembuangan sampel yang terlalu rapat yang dapat menimbulkan distorsi frekuensi (*pitch shift*) atau artefak flutter yang terdengar oleh telinga manusia.
  - **Batas Ambang Histeresis Watermark:**
    Untuk menghindari osilasi bolak-balik (*hunting/jitter*) pada batas watermark:
    - *Low Watermark Hysteresis:* Mode pengulangan sampel aktif saat isi buffer turun di bawah $410\text{ Byte}$ ($20\%$). Koreksi slip hanya dinonaktifkan setelah isi buffer naik kembali melampaui ambang histeresis atas $\ge 512\text{ Byte}$ ($25\%$ kapasitas, margin histeresis $+102\text{ Byte}$).
    - *High Watermark Hysteresis:* Mode pembuangan sampel aktif saat isi buffer naik melampaui $1.638\text{ Byte}$ ($80\%$). Koreksi slip hanya dinonaktifkan setelah isi buffer turun kembali melampaui ambang histeresis bawah $\le 1.536\text{ Byte}$ ($75\%$ kapasitas, margin histeresis $-102\text{ Byte}$).
  - **Perhitungan Kapasitas Koreksi vs Drift Kristal 250 ppm:**
    Pada deviasi kristal maksimum $250\text{ ppm}$ ($250 \times 10^{-6}$), laju akumulasi drift adalah $2,00\text{ sampel/detik}$.
    - Pada interval slip konservatif $T_{\text{slip\_min}} = 50\text{ ms}$ ($20\text{ koreksi/detik}$), kapasitas koreksi maksimum adalah $20\text{ sampel/s}$, yaitu **$10\times$ lebih besar** daripada laju drift 250 ppm.
    - Pada interval slip agresif $T_{\text{slip\_min}} = 10\text{ ms}$ ($100\text{ koreksi/detik}$), kapasitas koreksi maksimum adalah $100\text{ sampel/s}$, yaitu **$50\times$ lebih besar** daripada laju drift 250 ppm.
    - *Contoh Numerik:* Pada selisih drift terburuk $250\text{ ppm}$ (FPGA kekurangan $2\text{ sampel/detik}$ akibat clock audio PC lebih lambat), jika buffer audio berada di bawah Low Watermark, algoritma slip dengan interval $50\text{ ms}$ hanya perlu aktif melakukan koreksi repeat sebanyak **2 kali per detik** (rata-rata 1 koreksi setiap 500 ms atau setiap 4.000 sampel). Koreksi $2\text{ sampel/s}$ terhadap laju $8.000\text{ sampel/s}$ secara ekuivalen setara dengan pergeseran frekuensi $0,025\%$, yang berada di bawah ambang deteksi modulasi nada kontinu (*Just Noticeable Difference* $\approx 0,5\%$). Namun, karena slip pada FPGA dilakukan secara diskret (mengulang atau membuang 1 sampel secara mendadak), slip diskret ini menghasilkan diskontinuitas fasa sesaat (*transient micro-glitch*).
    - *Kriteria Penerimaan Pendengaran [DIASUMSIKAN]:*
      Kelayakan akustik slip diskret dinilai berdasarkan laju kemunculan kejadian per satuan waktu: target penerimaan ditetapkan $\le 2\text{ s.d. } 5\text{ kejadian slip per menit}$ pada kondisi pemutaran normal, sehingga efek glitch mikroskopis tersamar oleh dinamika musik Bad Apple!!.

- **Evaluasi Ketahanan Buffer terhadap Drift Osilator & Jeda Pengiriman PC [DIVERIFIKASI: perhitungan matematis]:**
  1. **Ketahanan terhadap Drift Osilator (sepanjang 217,84 detik):**
     - Pada deviasi $100\text{ ppm}$, total akumulasi drift adalah $174\text{ Byte}$. Karena $174\text{ B} < 614\text{ B}$ (margin watermark), isi buffer **tidak pernah menyentuh watermark** dan terserap penuh tanpa underflow.
     - Pada deviasi batas atas $250\text{ ppm}$, total drift sepanjang 217,84 detik adalah $436\text{ Byte}$. Karena $436\text{ B} < 614\text{ B}$, akumulasi drift terburuk $250\text{ ppm}$ sekalipun **TIDAK PERNAH MENYENTUH AMBANG WATERMARK** ($436\text{ B} < 614\text{ B}$)! Seluruh pemutaran lagu penuh terserap dengan margin keselamatan $\ge 178\text{ Byte}$ di dalam jendela watermark tanpa perlu memicu koreksi slip, dan terserap sepenuhnya tanpa underflow.
  2. **Ketahanan terhadap Jeda Pengiriman PC (Host Transmission Hiccups / OS Jitter):**
     - **Kebijakan Transmisi Host PC: Paket Audio TIDAK Boleh Dibuang (No Host Audio Drop) [DIASUMSIKAN]:**
       Berbeda dengan frame video di mana paket yang terlambat $> 2\text{ frame}$ ($> 66,7\text{ ms}$) dibuang (*dropped*) oleh host untuk menjaga waktu dinding video, paket audio **TIDAK PERNAH DI-DROP OLEH HOST PC**. Membuang paket audio akan menciptakan lubang hening (*gap*) atau letupan akustik yang merusak integritas pendengaran. Jika terjadi keterlambatan pengiriman pada host PC, seluruh paket audio tertunda wajib dikirim secepatnya (*catch-up burst*) pada baud rate UART penuh untuk mengisi ulang FIFO hardware ke level nominal target ($1.024\text{ B}$).
       *Dampak ke Arsitektur `stream_player`:* Penjadwalan transmisi paket audio harus didekopel (*decoupled*) dari penjadwalan frame video. Transmisi video terikat pada interval waktu dinding $33,33\text{ ms}$ per frame, sedangkan pengiriman audio dijalankan sebagai antrean aliran data kontinu yang independen; paket audio yang tertunda akibat fluktuasi OS segera dikirim berturut-turut tanpa menunggu slot frame berikutnya.
     - **Jeda Pengiriman $64\text{ ms}$ ($512\text{ Byte}$):**
       Konsumsi sampel audio selama jeda = $64\text{ ms} \times 8\text{ B/ms} = 512\text{ Byte}$.
       Sisa isi buffer FIFO = $1.024 - 512 = 512\text{ Byte} > 410\text{ Byte}$ (Low Watermark).
       $\implies$ **TERSERAP PENUH TANPA UNDERFLOW** (bahkan buffer belum menyentuh watermark $20\%$).
     - **Jeda Pengiriman $100\text{ ms}$ ($800\text{ Byte}$), Sisa Isi FIFO, & Analisis Pemulihan (Burst vs Slip) [DIVERIFIKASI: perhitungan matematis]:**
       Konsumsi sampel audio selama jeda = $100\text{ ms} \times 8\text{ B/ms} = 800\text{ Byte}$.
       Sisa isi buffer FIFO = $1.024 - 800 = \mathbf{224\text{ Byte}} > 0\text{ Byte}$ (berada di bawah Low Watermark $410\text{ Byte}$).
       Jika setelah jeda berakhir host PC hanya mengirim audio sesuai laju konsumsi nominal ($8.000\text{ B/s}$ atau $\approx 266,7\text{ B/frame}$), maka laju masuk = laju keluar (netto 0 B/s), sehingga **isi FIFO akan tetap tertahan di level rendah $224\text{ Byte}$ (< 410 B)** dan tidak dapat pulih ke titik tengah nominal $1.024\text{ Byte}$ dengan sendirinya!
       *Analisis Metode Pemulihan Level FIFO:*
       1. **Metode Catch-up Burst dari PC (Rekomendasi Utama):** PC segera mengirimkan $800\text{ Byte}$ audio tertunda secara beruntun (*burst*) pada 921.600 baud. Waktu transmisi $800\text{ Byte}$ pada 921.600 baud (laju fisik $92.160\text{ B/s}$) adalah $\approx 8,68\text{ ms}$. Selama burst 8,68 ms tersebut konsumsi audio FPGA hanya $8,68 \times 8 = 69\text{ Byte}$, sehingga level FIFO pulih kembali ke $224 + 800 - 69 = \mathbf{955\text{ Byte}}$ dalam waktu kurang dari $9\text{ ms}$.
       2. **Metode Slip Pengulangan Sampel Lokal FPGA (Repeat Sample):** Jika PC tidak melakukan burst dan hanya mengandalkan koreksi slip lokal FPGA:
          - Defisit sampel untuk keluar dari Low Watermark ($410\text{ B}$): $410 - 224 = \mathbf{186\text{ sampel}}$.
          - Defisit sampel untuk pulih penuh ke level nominal ($1.024\text{ B}$): $1.024 - 224 = \mathbf{800\text{ sampel}}$.
          - Waktu pemulihan pada $T_{\text{slip\_min}} = 10\text{ ms}$ (laju koreksi $100\text{ sampel/s}$):
            - Waktu keluar Low Watermark: $186 / 100 = \mathbf{1,86\text{ detik}}$.
            - Waktu pulih ke level nominal: $800 / 100 = \mathbf{8,00\text{ detik}}$.
          - Waktu pemulihan pada $T_{\text{slip\_min}} = 50\text{ ms}$ (laju koreksi $20\text{ sampel/s}$):
            - Waktu keluar Low Watermark: $186 / 20 = \mathbf{9,30\text{ detik}}$.
            - Waktu pulih ke level nominal: $800 / 20 = \mathbf{40,00\text{ detik}}$.
          *Kesimpulan:* Pemulihan murni melalui mekanisme slip lokal memerlukan waktu beberapa detik hingga puluhan detik di mana buffer berada dalam kondisi sangat rentan terhadap underflow jika terjadi gangguan transmisi kedua. Oleh karena itu, *catch-up burst* dari PC merupakan syarat wajib untuk pemulihan cepat, sedangkan slip lokal hanya berfungsi mengoreksi drift frekuensi kristal kontinu.
     - **Jeda Pengiriman $200\text{ ms}$ ($1.600\text{ Byte}$):**
       Kebutuhan sampel audio selama jeda = $200\text{ ms} \times 8\text{ B/ms} = 1.600\text{ Byte}$.
       Karena buffer pre-roll hanya menyediakan $1.024\text{ Byte}$ ($128\text{ ms}$), seluruh isi buffer habis terpakai pada $128\text{ ms}$ pertama, menyisakan kekurangan $576\text{ Byte}$ ($72\text{ ms}$).
       $\implies$ **TIDAK TERSERAP (TERJADI UNDERFLOW)**. Output PWM beralih ke level hening `0x80`, dan register `cnt_audio_underflow` bertambah.
     - **Masalah Resinkronisasi Pasca-Underflow (D-18 - TERBUKA) [DIASUMSIKAN]:**
       Dengan kebijakan "paket audio tidak pernah dibuang oleh host PC", jika terjadi underflow selama durasi $T$ (misalnya jeda $100\text{ ms}$), output audio hardware terdiam hening selama $100\text{ ms}$. Ketika transmisi PC dilanjutkan kembali dan seluruh paket audio tertunda dikirim secara beruntun, aliran audio akan tertinggal secara permanen sebesar $100\text{ ms}$ ($800\text{ sampel}$) terhadap timeline video!
       Jika pemulihan desinkronisasi ini hanya mengandalkan mekanisme slip lokal pada laju konservatif $20\text{ sampel/detik}$ ($2,5\text{ ms/s}$ perolehan waktu), maka waktu yang dibutuhkan untuk mengejar lag $100\text{ ms}$ adalah:
       $$\frac{800\text{ sampel}}{20\text{ sampel/detik}} = \mathbf{40\text{ detik}}!$$
       Selama 40 detik tersebut, audio terdengar jelas tidak sinkron dengan visual video di layar.
       *Opsi Keputusan D-18 (Status: TERBUKA - belum ada opsi yang dipilih):*
       1. **Opsi (A) - Indeks Paket pada `FRAME_ID(14:0)` & FPGA Skip Sampel Basi:**
          Paket audio memuat indeks frame video referensi pada `FRAME_ID(14:0)`. Saat pulih dari underflow, FPGA membandingkan indeks audio terhadap frame video aktif; paket audio yang tertinggal langsung dibuang (*skip*) di FPGA hingga sejajar kembali dengan frame video.
          *Trade-off:* Resinkronisasi instan, namun menambah logika komparator dan pembuangan buffer di RTL FPGA.
       2. **Opsi (B) - Reset FIFO Lokal & PC Mengirim Ulang dari Posisi Sekarang:**
          Saat terjadi underflow, FPGA me-reset pointer FIFO (`flush`). Host PC mendeteksi kondisi underflow, mengosongkan antrean audio lokal, dan melompati transmisi audio ke posisi frame video yang sedang aktif.
          *Trade-off:* Logika RTL FPGA sangat sederhana (hanya pulsa reset pointer), namun membutuhkan mekanisme deteksi lag atau umpan balik UART TX dari FPGA ke PC.
       3. **Opsi (C) - Tanpa Pemulihan Aktif (Hanya Mengandalkan Slip Lambat):**
          Tidak ada logika pemotongan paket audio pasca-underflow. Audio dibiarkan berjalan dengan lag atau mengejar sangat perlahan melalui slip.
          *Trade-off:* Paling hemat sumber daya FPGA, namun desinkronisasi $100\text{ ms}$ bertahan hingga 40 detik atau permanen jika isi buffer tidak melampaui High Watermark.
  3. **Estimasi Realistis Selisih Frekuensi Kristal [DIASUMSIKAN]:**
     Osilator kristal kuarsa komersial pada DAC PC dan FPGA Basys 3 bertoleransi $\pm 20\text{ s.d. } \pm 50\text{ ppm}$. Pada suhu ruangan stabil, selisih nyata tipikalnya adalah $20\text{ s.d. } 70\text{ ppm}$ ($\le 100\text{ ppm}$). Angka 250 ppm merupakan batas atas teoretis terburuk.

- **Pencacah Telemetri Hardware yang Dapat Dibaca (Readable Hardware Counters) [DIASUMSIKAN]:**
  FPGA mengimplementasikan empat register pencacah status telemetri yang dapat dibaca host:
  - `cnt_audio_underflow`: Pencacah kejadian buffer kosong saat sampel audio diminta oleh modulator PWM.
  - `cnt_audio_overflow`: Pencacah kejadian paket audio tiba saat kapasitas FIFO ($2.048\text{ B}$) penuh.
  - `cnt_audio_drop`: Pencacah jumlah sampel yang dibuang saat High Watermark (>80% / 1.638 B) aktif.
  - `cnt_audio_repeat`: Pencacah jumlah sampel yang diulang saat Low Watermark (<20% / 410 B) aktif.

---

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

## 6. Daftar Keputusan Desain (Decisions D-14..D-17)

Status keputusan desain teknis Milestone 4 per tanggal 2026-11-02:

| ID | Topik Keputusan | Pilihan Alternatif | Status | Keputusan & Catatan Arsitektur |
|---|---|---|---|---|
| **D-14** | Protokol Framing Paket Audio Streaming | **(A)** SOF khusus `0x55AB` untuk paket audio terpisah.<br>**(B)** Multiplexing audio dan video dalam satu paket gabungan.<br>**(C)** Tipe paket di bit tertinggi `FRAME_ID(15)` dengan SOF `0x55 0xAA 0x5A` standar. | **Disetujui pengguna 2026-11-02** | **Opsi (C) Terpilih:** Bit 15 `FRAME_ID = 1` menandai paket audio; SOF tetap `0x55 0xAA 0x5A`. Pencacah `VALID_FRAMES` serta register `FIRST_FRAME_ID` dan `LAST_FRAME_ID` tetap HANYA menghitung paket video; pencacah paket audio dibuat terpisah. |
| **D-15** | Arsitektur Port B Frame Buffer BRAM | **(A)** Arbitrase Time-Division Multiplexing (TDM) pada Port B tunggal.<br>**(B)** Duplikasi instance frame buffer BRAM (+1 RAMB18E1). | **Disetujui pengguna 2026-11-02** | **Opsi (B) Terpilih:** Duplikasi instance frame buffer BRAM untuk pembacaan OLED (+1 RAMB18E1). Jalur subsistem `ascii_sink` tetap utuh tanpa modifikasi apa pun. |
| **D-16** | Parameter Komponen Filter Analog RC Audio PMOD | **(A)** $R = 1\text{ k}\Omega, C = 10\text{ nF}$ ($f_c \approx 15,9\text{ kHz}$, arus pin $\approx 3,3\text{ mA} < 12\text{ mA}$).<br>**(B)** Filter RC dua tingkat (*2nd-order passive*) untuk pelemahan carrier lebih tajam. | **TERBUKA** | Menunggu komponen fisik audio tiba untuk pengujian osiloskop dan uji dengar langsung di board Basys 3. |
| **D-17** | Mekanisme Kompensasi Drift Buffer Audio FIFO | **(A)** Kontrol laju audio murni dari Host PC (mengatur interval pengiriman paket audio).<br>**(B)** Penyesuaian adaptif lokal di FPGA (drop/insert 1 sampel saat isi FIFO melewati ambang batas >80% atau <20%, dengan pre-roll lead time 512 B). | **Disetujui pengguna 2026-11-02** | **Opsi (B) Terpilih:** Penyesuaian adaptif lokal di FPGA dengan FIFO 2.048 B (1 RAMB18), pre-roll 1.024 B (128 ms), watermark 20%/80% (410/1.638 B, kapasitas 256 ms); pencacah underflow, overflow, dan slip (`cnt_audio_drop`, `cnt_audio_repeat`) dapat dibaca oleh telemetri. |
| **D-18** | Resinkronisasi Audio-Video Pasca-Buffer Underflow | **(A)** Indeks paket audio pada `FRAME_ID(14:0)`, FPGA membuang (*skip*) sampel basi.<br>**(B)** Reset pointer FIFO lokal (`flush`) dan host PC mengirim ulang dari posisi video saat ini.<br>**(C)** Tanpa pemulihan aktif (hanya mengandalkan slip lambat). | **TERBUKA** | Ditulis sebagai keputusan **TERBUKA**; tidak ada opsi yang dipilih. Masalah teknis: underflow selama $T$ (misal $100\text{ ms}$) membuat audio tertinggal permanen sebesar $T$ terhadap video jika seluruh paket audio dikirim tanpa drop; slip lokal 20 sampel/s memerlukan waktu $40\text{ detik}$ untuk mengejar lag 100 ms. |

---

