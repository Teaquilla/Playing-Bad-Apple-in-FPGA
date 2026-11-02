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
  Menurut datasheet SSD1306 Bagian 13.3 (Serial Interface Timing Characteristics), waktu siklus clock minimum $t_{\text{cycle}} = 100\text{ ns}$, yang setara dengan frekuensi clock serial maksimum $10\text{ MHz}$ [DIASUMSIKAN].
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
Modul hardware `oled_controller.vhd` akan mengimplementasikan State Machine (FSM) inisialisasi deterministik [DIASUMSIKAN]:
1. **Hardware Reset Pulse (`RES`):** Ditarik LOW selama minimal $10\ \mu\text{s}$ (1.000 siklus 100 MHz), lalu dikembalikan HIGH. Menunggu $10\ \mu\text{s}$ sebelum perintah SPI pertama dikirim.
2. **Urutan Perintah Konfigurasi (DC = 0, CS = 0):**
   - `0xAE` : Display OFF (Sleep mode).
   - `0xD5`, `0x80` : Set Display Clock Divide Ratio / Oscillator Frequency ke nilai tengah nominal.
   - `0xA8`, `0x3F` : Set Multiplex Ratio ke 64MUX (tinggi 64 piksel).
   - `0xD3`, `0x00` : Set Display Offset ke 0 (tanpa pergeseran vertikal).
   - `0x40` : Set Display Start Line ke baris 0.
   - `0x8D`, `0x14` : Aktifkan Internal Charge Pump (regulator tegangan internal 7,5V untuk panel OLED).
   - `0x20`, `0x00` : Set Memory Addressing Mode ke Horizontal Addressing Mode (pointer kolom bertambah otomatis $0..127$, lalu berganti page $0..7$).
   - `0xA1` : Set Segment Re-map (kolom 127 dipetakan ke SEG0 untuk orientasi normal).
   - `0xC8` : Set COM Output Scan Direction (remap mode COM[N-1] ke COM0).
   - `0xDA`, `0x12` : Set COM Pins Hardware Configuration (konfigurasi pin alternatif 128×64).
   - `0x81`, `0xCF` : Set Contrast Control ke tingkat kontras tinggi (0xCF).
   - `0xD9`, `0xF1` : Set Pre-charge Period (Phase 1 = 1 DCLK, Phase 2 = 15 DCLK).
   - `0xDB`, `0x40` : Set VCOMH Deselect Level (~0,77 × VCC).
   - `0xA4` : Entire Display ON resume to GDRAM.
   - `0xA6` : Set Normal Display (`1` = piksel menyala/putih, `0` = piksel padam/hitam).
   - `0xAF` : Display ON (menghidupkan panel).

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
  Rangkaian `oled_controller.vhd` melakukan transposisi *on-the-fly* saat membaca BRAM:
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
    Menggunakan satu port Port B secara bergantian antara `ascii_sink` dan `oled_controller`. `oled_controller` hanya memerlukan 1,32 ms per frame, sementara `ascii_sink` membaca secara periodik sesuai laju baud UART 921.600. Multiplexer arbitrase memprioritaskan transfer burst OLED atau menyelingi pembacaan.
  - **Alternatif 2.3B (Duplikasi Frame Buffer BRAM - Rekomendasi Terpilih):**
    Menginstansiasi 2 blok frame buffer independen (`fb_ascii` dan `fb_oled`) yang menerima data tulis yang sama dari dekoder pada Port A.
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

### 3.2 Modulator PWM 8-Bit
- **Frekuensi Pembawa PWM (Carrier Frequency):**
  Resolusi 8-bit membutuhkan pencacah periode 256 tingkatan:
  $$f_{\text{carrier}} = \frac{100.000.000\text{ Hz}}{256} = 390.625\text{ Hz} \approx 390,625\text{ kHz}$$
- **Karakteristik Akustik:**
  Frekuensi carrier 390,6 kHz berada jauh melampaui batas pendengaran manusia ($20\text{ kHz}$) dan batas Nyquist audio 8 kHz ($4\text{ kHz}$). Rasio oversampling terhadap audio adalah $390,625 / 8 = 48,8\times$ [DIASUMSIKAN].
- **Prinsip Modulasi:**
  Pencacah bebas 8-bit `pwm_cnt` mencacah $0..255$.
  Jika $\text{sample\_data} > \text{pwm\_cnt}$, pin output `audio_pwm` bernilai HIGH (`1`); jika tidak, bernilai LOW (`0`).

### 3.3 Protokol Framing Streaming UART untuk Video & Audio
- **Analisis Kebutuhan Bandwidth Total pada 921.600 Baud (8N1):**
  - Kapasitas efektif bus serial: $921.600 / 10 = 92.160\text{ Byte/detik}$.
  - Kebutuhan laju streaming audio: $8.000\text{ Byte/detik}$.
  - Kebutuhan laju streaming video rata-rata (30 FPS $\times$ rata-rata 270 B/frame): $\approx 8.100\text{ Byte/detik}$.
  - Total laju rata-rata: $\approx 16.100\text{ Byte/detik}$ ($17,5\%$ kapasitas UART) [DIVERIFIKASI: perhitungan matematis D-5].
  - Skenario terburuk (Frame video terpadat 707 B + audio per frame $8.000 / 30 = 267\text{ B}$):
    Total payload per frame = $707 + 267 = 974\text{ Byte}$.
    Waktu transfer UART = $974 / 92.160\text{ s} \approx 10,57\text{ ms} < 33,33\text{ ms}$ ($31,7\%$ kapasitas) [DIVERIFIKASI: `docs/DECISIONS.md` baris 28].
- **Pilihan Format Protokol Framing [DIASUMSIKAN]:**
  - **Opsi Framing Terpisah (Tipe Paket Berbeda):**
    Paket Video RLE tetap menggunakan SOF `0x55AA` [DIVERIFIKASI: `hdl/packet_parser.vhd` baris 23].
    Paket Audio menggunakan SOF baru `0x55AB`:
    `[SOF 2B: 0x55AB] [LEN 2B: 267] [DATA ... 267B PCM] [CHK 2B] [EOF 2B: 0x55AA]`
    *Keunggulan:* Modul `packet_parser.vhd` yang sudah ada dapat dengan mudah diperluas untuk mendeteksi byte SOF kedua dan merutekan data audio ke `audio_fifo` tanpa mengganggu state machine video.

### 3.4 Ukuran FIFO Audio & Analisis Drift Jam
- **Ukuran FIFO Audio Hardware:**
  Menggunakan 1 blok RAMB18E1 (konfigurasi $1024 \times 8$).
  Pada laju 8.000 B/s, kapasitas 1.024 byte setara dengan penyangga audio selama:
  $$T_{\text{buf}} = \frac{1.024\text{ Byte}}{8.000\text{ Byte/s}} = 128\text{ ms} \quad (\approx 3,84\text{ frame video pada 30 FPS})$$
- **Analisis Drift Akumulatif Sepanjang Video Penuh (217,84 detik):**
  - Toleransi osilator kristal 100 MHz Basys 3: $\pm 50\text{ ppm}$ [DIASUMSIKAN: datasheet Basys 3].
  - Toleransi clock audio host PC: $\approx \pm 200\text{ ppm}$ [DIVERIFIKASI: pengujian empiris `test_stream_player.py` dan tolok ukur WASAPI/MME].
  - Deviasi drift terburuk antar-osilator: $\Delta f \approx 250\text{ ppm}$.
  - Akumulasi selisih sampel sepanjang 217,84 detik:
    $$\Delta N_{\text{sample}} = 217,84\text{ s} \times 8.000\text{ B/s} \times 250 \times 10^{-6} \approx 435,7\text{ Byte}$$
    Jika deviasi rata-rata berada pada kisaran $\sim 100\text{ ppm}$, drift hanya mencapai $\approx 174\text{ Byte}$ [DIASUMSIKAN].
  - *Mitigasi Drift:* Kapasitas FIFO 1.024 Byte cukup besar untuk menyerap drift tanpa overflow jika streamer PC mengalirkan audio terkunci pada cadence frame video, atau streamer memantau watermark FIFO via sinyal status balik RsTx [DIASUMSIKAN].

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

### 5.1 Model Perilaku OLED Controller (`sim/tb_oled_controller.vhd`)
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

## 6. Daftar Keputusan Desain Terbuka (Open Decisions D-14..D-17)

Keputusan desain teknis berikut dicatat sebagai keputusan terbuka yang tetap menunggu persetujuan tim sebelum implementasi RTL M4 dimulai:

| ID | Topik Keputusan | Pilihan Alternatif | Status | Rekomendasi Awal |
|---|---|---|---|---|
| **D-14** | Protokol Framing Paket Audio Streaming | **(A)** SOF khusus `0x55AB` untuk paket audio terpisah.<br>**(B)** Multiplexing audio dan video dalam satu paket gabungan. | **TERBUKA** | Direkomendasikan **(A)** karena tidak mengubah struktur paket video RLE yang sudah stabil di M2b. |
| **D-15** | Arsitektur Port B Frame Buffer BRAM | **(A)** Arbitrase Time-Division Multiplexing (TDM) pada Port B tunggal.<br>**(B)** Duplikasi instance frame buffer BRAM (+1 RAMB18E1). | **TERBUKA** | Direkomendasikan **(B)** karena BRAM Basys 3 tersisa 49 Tile ($98\%$) dan mengeliminasi kerumitan logika arbitrase. |
| **D-16** | Parameter Komponen Filter Analog RC Audio PMOD | **(A)** $R = 1\text{ k}\Omega, C = 10\text{ nF}$ ($f_c \approx 15,9\text{ kHz}$, arus pin $\approx 3,3\text{ mA} < 12\text{ mA}$).<br>**(B)** Filter RC dua tingkat (*2nd-order passive*) untuk pelemahan carrier lebih tajam. | **TERBUKA** | Direkomendasikan **(A)** untuk kemudahan perakitan awal di breadboard dengan earphone 32 ohm via kapasitor kopling DC $10\ \mu\text{F}$. |
| **D-17** | Mekanisme Kompensasi Drift Buffer Audio FIFO | **(A)** Kontrol laju audio murni dari Host PC (mengatur interval pengiriman paket audio).<br>**(B)** Logika drop/duplicate sampel adaptif di RTL FPGA saat watermark FIFO mendekati batas ekstrim. | **TERBUKA** | Direkomendasikan **(A)** mengikuti prinsip PC sebagai pemegang waktu utama (D-3). |

---
