# SPEC: Bad Apple di Basys 3

**Status:** DRAF v0.1, belum disetujui tim.
**Board:** Digilent Basys 3 (Artix-7 xc7a35t).
**Tahap sekarang:** tampil di terminal laptop lewat UART. Layar OLED SSD1306 0.96" belum tersedia, jadi tahap OLED ditunda.

Dokumen ini adalah sumber kebenaran proyek. Jika kode dan spec bertentangan, hentikan pekerjaan dan laporkan, jangan memilih sendiri.

---

## 1. Tujuan dan cakupan

**Tujuan:** memutar video Bad Apple di FPGA dengan audio, sambil mempelajari desain FPGA yang modular (HDL, testbench, codec sederhana).

**Dalam cakupan**
- Golden model di Python: encoder, pemutar terminal, laporan ukuran kompresi.
- HDL: decoder, display sink (ASCII lewat UART), UART TX, kontrol waktu frame.
- Audio dengan dua opsi: (A1) diputar PC, (A2) PWM/sigma-delta di 1 pin PMOD ke earphone.
- Driver OLED SSD1306 (tahap akhir, M4).

**Di luar cakupan (untuk sekarang)**
- Video warna atau grayscale. Frame dasar adalah 1-bit.
- Pemutaran dari kartu SD atau USB.
- Resolusi selain 128×64 (tetap dibuat sebagai parameter, tetapi tidak diuji).

---

## 2. Aturan kerja untuk agen

1. Jangan menebak. Jika spec ambigu atau ada "keputusan terbuka" (bagian 9) yang menghalangi, berhenti dan tanyakan.
2. Setiap modul HDL harus punya testbench. Jangan menyatakan modul "selesai" tanpa testbench yang lulus.
3. Golden model Python dibuat lebih dulu. Hasil HDL diverifikasi terhadap golden model, bukan terhadap asumsi.
4. Bedakan jelas antara yang **diverifikasi** (hasil simulasi/hardware yang benar-benar dijalankan) dan yang **diasumsikan**. Jangan mengklaim sesuatu berjalan di hardware jika hanya diuji di simulasi.
5. Repo referensi `alpyen/fpga-mediaplayer` hanya dipakai untuk mempelajari arsitektur dan keputusan desain. Jangan menyalin kode sebelum lisensinya dicek dan tim menyetujui.
6. File video/audio sumber disediakan manual oleh tim. Jangan mengunduh media sendiri.
7. Catat setiap keputusan desain baru beserta alasannya di `DECISIONS.md`.
8. Untuk rangkaian di luar FPGA (filter audio, koneksi earphone), usulkan skema dan nilai komponen, lalu minta persetujuan manusia sebelum dihubungkan ke hardware.

---

## 3. Format frame kanonik (kontrak utama)

Semua modul bertukar frame dalam format ini. Display (terminal, OLED) hanya mengonsumsi format ini.

| Properti | Nilai |
|---|---|
| Ukuran | `WIDTH=128`, `HEIGHT=64` (parameter/generic, jangan di-hardcode) |
| Kedalaman | 1 bit per piksel. `1` = putih, `0` = hitam |
| Urutan piksel | row-major: indeks = `y * WIDTH + x` |
| Pengemasan byte | 8 piksel berurutan sepanjang x per byte, bit 7 = piksel paling kiri |
| Ukuran frame | `WIDTH*HEIGHT/8` = 1024 byte |
| Laju frame | `FPS` parameter, target awal 30 (lihat D-2) |

Konversi ke format khusus layar (misalnya page-addressing SSD1306) dilakukan di driver layar, bukan di decoder.

Jumlah frame aktual: tepat **6.532 frame** (durasi 217,733 detik × 30 fps) dari video sumber 2:1 riil (`media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4`). Ukuran mentah: 53,51 Mbit (6.688.768 byte).

---

## 4. Arsitektur

```
[Source] -> [Decoder] -> [Frame buffer] -> [Display sink] -> UART TX -> PC (terminal)
                                       \-> [OLED sink]    -> SSD1306   (M4)
[Frame timer] memberi frame_tick ke seluruh jalur
[Audio source] -> [Audio out]  (A2: PWM/sigma-delta ke PMOD)
```

- **Source** menghasilkan aliran byte lewat antarmuka valid/ready yang sama untuk semua sumber: pola uji/BRAM (M1), flash onboard (opsional, setelah M2), atau UART RX dari PC. Decoder dan sink tidak boleh tahu sumbernya.
- **Frame timer:** satu modul memegang `frame_tick` pada `FPS`. Tidak boleh ada dua pemilik waktu.
- **Frame buffer:** double buffer agar sink tidak membaca frame yang sedang ditulis. Ukuran dihitung dan dicek terhadap BRAM xc7a35t.
- Modul dibuat kecil dan lokal: satu fungsi per modul, antarmuka eksplisit, parameter lewat generic.

---

## 5. Display sink

### 5.1 ASCII sink (di FPGA, M1)
Mengubah frame kanonik menjadi karakter ASCII dan mengirimnya lewat UART sehingga terminal serial apa pun bisa menampilkan.

- **Blok:** 2 piksel lebar × 4 piksel tinggi per karakter. Sel `(cx, cy)` mencakup `x = 2cx..2cx+1`, `y = 4cy..4cy+3`. Hasil: 64 kolom × 16 baris.
- **Level:** jumlah piksel putih dalam blok (0 sampai 8) menjadi indeks ke ramp. Ramp default: `" .:-=+*#@"` (9 karakter, dari kosong ke padat). Disetel ke font terminal nanti. Parameter `INVERT` membalik pemetaan.
- **Urutan keluaran per frame:** `ESC [ H` (3 byte, kursor ke pojok), lalu 16 baris masing-masing 64 karakter + `\r\n`. Total 1059 byte per frame.
- **Karakter:** hanya ASCII yang bisa dicetak (0x20 sampai 0x7E) selain `ESC` dan `\r\n` di atas.
- **Bandwidth:** 1059 byte × 30 fps ≈ 31,8 KB/s, setara minimal sekitar 318 kbaud pada UART 8N1. Target awal 921600 baud (lihat D-6).

### 5.2 Sink sisi PC (Python, M0)
Pemutar terminal di Python dengan tiga mode untuk membandingkan: ASCII (sama dengan 5.1, jadi dijadikan golden), braille (2×4 piksel per sel), dan half-block. Gunakan pemindahan kursor ke pojok (bukan clear screen) dan tulis satu frame penuh per `write` agar tidak flicker.

### 5.3 OLED sink (ditunda, M4)
SSD1306 128×64. Layar belum tersedia, jadi kembangkan dulu dengan model perilaku di simulasi (testbench yang menangkap byte SPI/I2C dan merekonstruksi gambar). Pilihan SPI vs I2C ditentukan oleh modul yang akhirnya dibeli (D-7). Konversi dari format kanonik ke page-addressing dilakukan di sini.

---

## 6. Penyimpanan dan codec

Tahap awal tidak memerlukan kompresi: M1 memakai klip pendek di BRAM. Keputusan codec diambil setelah M0 melaporkan angka nyata.

**Kandidat (diukur di M0, dibandingkan pada frame Bad Apple asli):** mentah, RLE per baris, XOR antar-frame + RLE. Pertimbangkan juga kesederhanaan decoder di hardware.

**Anggaran flash (diverifikasi di Vivado 2026.1):** 
- Bitstream Artix-7 mentah tanpa kompresi berukuran tepat 17.536.096 bit dari flash 32 Mbit, menyisakan 16.018.336 bit (sekitar 1,9 MB) untuk data.
- Bitstream dengan kompresi (`BITSTREAM.GENERAL.COMPRESS TRUE`):
  - Desain uji mini logika dasar (tanpa BRAM) berukuran **2.018.464 bit** (252.308 byte) — ini adalah **batas bawah sebenarnya**.
  - Desain uji dengan 90 frame klip BRAM (92.160 byte / 737.280 bit data) menghasilkan bitstream terkompresi **6.311.040 bit** (788.880 byte). Data yang diinisialisasi di BRAM menambah ukuran bitstream terkompresi sekitar **5,8 kali ukuran datanya** ($(6.311.040 - 2.018.464) / (92.160 \times 8) \approx 5,82\times$).
  - Ukuran bitstream desain standalone akhir belum diukur, sehingga angka di atas tidak boleh diekstrapolasi tanpa dasar.

**Arsitektur Aliran Video Penuh (Streaming PC vs Standalone Flash):**
- Sesuai keputusan **D-12**, jalur utama adalah **(b) Streaming data RLE dari PC lewat UART RX**. Board Basys 3 hanya menghubungkan pin TX dan RX antara chip FTDI FT2232HQ dan FPGA (tidak ada pin flow-control perangkat keras RTS/CTS ke FPGA, dan kontrol perangkat lunak XON/XOFF tidak digunakan).
- Pada mode streaming, PC bertindak sebagai **pemegang waktu (timekeeper)** yang mengirim paket frame RLE sesuai laju frame 30 FPS mengikuti format paket resmi di `docs/PROTOCOL.md`.
- **Format Paket & Buffer RX Streaming (M2):** Format paket streaming didefinisikan secara tunggal di `docs/PROTOCOL.md` (`SOF 0x55 0xAA 0x5A`, `FRAME_ID 2B`, `PAYLOAD_LEN 2B`, `PAYLOAD N B`, `EOF 0xED`, `CHECKSUM 1B`). Sisi penerima FPGA mengalokasikan **FIFO RX sebesar 2.048 Byte (2 KB)** menggunakan 1x RAMB18E1 (0,5 tile BRAM) `[DIASUMSIKAN]`, yang mampu menampung seluruh paket maksimum teoretis (1.033 B) dan mendukung mekanisme pointer baca spekulatif dengan pembatalan (rollback). Komunikasi berjalan secara simpleks tanpa flow control (RTS/CTS / XON/XOFF) karena dekoder FPGA menguras FIFO dalam < 0,015 ms, jauh lebih cepat daripada laju transmisi UART (7,77 ms per paket).
- Karena satu antarmuka UART fisik membawa data masuk (RLE ke FPGA RX) dan data keluar (ASCII dari FPGA TX), dibutuhkan **skrip host Python** yang berjalan *full-duplex* untuk mengirim data frame terkompresi secara periodik sekaligus membaca dan menampilkan karakter ASCII ke terminal.
- Opsi **(a) Standalone dari flash onboard** ditutup sebagai target lanjutan (D-9) jika seluruh fungsionalitas streaming telah selesai dan diverifikasi.

**Kontainer file (diputuskan di ARCHITECTURE.md saat M0):** header minimal berisi signature, versi, lebar, tinggi, fps, jumlah frame, serta ukuran dan parameter segmen video dan audio. Struktur data video dan audio (apakah segmen terpisah atau di-interleave per frame) dijadikan keputusan terbuka baru D-10 yang akan diputuskan saat M2 bersamaan dengan D-9.

---

## 7. Audio

| Opsi | Cara kerja | Catatan |
|---|---|---|
| **A1** | PC memutar audio sendiri; FPGA hanya menampilkan video | Paling mudah. Perlu sinkronisasi dengan frame timer FPGA. |
| **A2** | FPGA memutar audio di 1 pin PMOD (PWM atau sigma-delta) ke earphone bekas | Perlu penyimpanan audio dan filter RC. |

- **Parameter awal (usulan):** mono, 8 kHz atau 6 kHz. Kedalaman 4-bit ditentukan setelah mendengarkan hasil (D-5). Dekoder hardware yang dimaksud untuk audio adalah **IMA ADPCM 4-bit**; codec G.726 (2-bit) hanya diuji di PC sebagai pembanding kualitas dan **tidak direncanakan di hardware** karena kerumitan komputasinya yang tinggi.
- **Selisih Durasi Audio vs Video & Aturan Pemangkasan:** Durasi video sumber adalah 217,733 detik (6.532 frame pada 30 fps), sedangkan durasi audio sumber adalah 217,800 detik (selisih +0,067 detik atau ~560 sampel pada 8 kHz). Aturan pemangkasan: data audio dipangkas (*trimmed*) tepat pada akhir frame video ke-6.532 ($N_{\text{samples}} = 6.532 \times 8.000 / 30 = 1.741.866 \text{ sampel}$). Sisa ~560 sampel di akhir dibuang dan diterapkan linear fade-out singkat 10 ms (80 sampel) untuk mencegah distorsi/bunyi klik (*click/pop*).
- **Keselamatan hardware (A2):** jangan menghubungkan earphone langsung ke pin FPGA. Perlu resistor seri dan kapasitor DC-blocking, dan nilainya diusulkan agen lalu direview manusia sebelum dihubungkan (aturan 8). Pin PMOD berlogika 3,3 V. Angka batas arus pin I/O FPGA (maksimum per pin dan total bank) serta nilai komponen rangkaian harus diverifikasi langsung dari datasheet resmi Digilent Basys 3 dan Xilinx Artix-7 (DS181 / UG475) sebelum rangkaian dihubungkan ke hardware.
- **Sinkronisasi (D-3):** kriteria penerimaan awal, selisih audio-video tidak lebih dari 2 frame (±66 ms) selama pemutaran penuh. Jika terjadi drift, pertimbangkan sinyal sinkronisasi periodik.

---

## 8. Milestone dan kriteria penerimaan

**M0: Golden model (Python, tanpa FPGA)**
- [x] Ekstraksi frame ke format kanonik dari file sumber yang disediakan tim (video 2:1 native, 6.532 frame).
- [x] Pemutar terminal (ASCII, braille, half-block) berjalan tanpa flicker yang mengganggu.
- [x] Laporan ukuran: mentah vs tiap kandidat codec (total bit dan bit per frame).
- [x] Frame hasil dumped ke file sebagai referensi (golden) untuk simulasi HDL (`frames.bin`, `ascii.bin`, `clip_bram.hex`).

**M1: FPGA ke terminal**
- [ ] UART TX dan ASCII sink punya testbench; keluaran byte-exact terhadap golden M0 untuk frame uji.
- [ ] Klip pendek di BRAM berdurasi sekitar 1 sampai 3 detik (30–90 frame, disesuaikan kapasitas BRAM) diputar berulang secara kontinu di terminal laptop selama minimal 60 detik tanpa karakter rusak atau kehilangan sinkron.
- [ ] Laju frame stabil; baud rate akhir tercatat (D-6).

**M2: Decoder HDL**
- [ ] Decoder bit-exact terhadap golden untuk seluruh frame di simulasi (atau subset yang disepakati jika terlalu lambat).
- [ ] Sumber data dari kodek terpilih (D-4) masuk lewat antarmuka valid/ready.
- [ ] Penggunaan BRAM/LUT dilaporkan dari Vivado.

**M3: Audio**
- [ ] A1: audio PC diputar bersama video, selisih sesuai bagian 7.
- [ ] A2: audio keluar di 1 pin PMOD dengan filter yang sudah direview; didengarkan lewat earphone.

**M4: OLED (saat layar tersedia)**
- [ ] Driver SSD1306 lulus testbench dengan model perilaku.
- [ ] Gambar statis, lalu video, tampil di layar fisik.

---

## 9. Keputusan terbuka (perlu jawaban tim)

| ID | Pertanyaan | Catatan |
|---|---|---|
| D-1 | Bahasa HDL (VHDL / Verilog / SystemVerilog) dan simulator | Ditutup: VHDL, simulator xsim (Vivado 2026.1). |
| D-2 | FPS: 30, 24, atau lebih rendah | Ditutup: 30 FPS (sebagai parameter generic). |
| D-3 | Pemegang waktu: FPGA atau PC sebagai master untuk sinkron audio-video | Putuskan setelah M3 mengukur drift. |
| D-4 | Pilihan codec | Ditutup: RLE per baris (Fixed 8-bit). |
| D-5 | Parameter audio: sample rate dan kedalaman bit | Belum diputuskan: Menunggu evaluasi pendengaran WAV. Target hardware: IMA ADPCM 4-bit (8 kHz / 6 kHz). |
| D-6 | Baud rate UART | Minimal ±318 kbaud untuk ASCII 30 fps; target 921600. Batas maksimum FTDI di Basys 3 terverifikasi 12 Mbaud. Uji fisik ditunda sampai board tersedia. |
| D-7 | OLED: SPI atau I2C | Menunggu modul yang dibeli. |
| D-8 | Versi Vivado dan OS | Ditutup: Vivado 2026.1 di Windows. |
| D-9 | Apakah pemutaran standalone dari flash masuk target | Ditutup sebagai target lanjutan: Prioritas utama streaming PC (D-12). |
| D-10 | Struktur stream media: terpisah atau interleave per frame | Ditutup saat M2 bersamaan dengan implementasi streaming PC. |
| D-11 | Penanganan rasio aspek video sumber ke kanvas 128×64 | Ditutup: Sumber rasio 2:1 (1280×640) tanpa bilah hitam; resize area langsung 10:1. |
| D-12 | Jalur arsitektur video penuh: Standalone flash vs PC UART Streaming | Ditutup: (b) Streaming RLE dari PC lewat UART RX sebagai jalur utama; (a) Standalone flash sebagai target lanjutan. |


---

## 10. Riset yang diminta dari agen

 rieset bisa di lakukan Elsevier menggunakan API key Elsevier yang ada di sistem atau melalui situs resmi. Untuk tiap paper atau sumber, tulis dalam `RESEARCH.md` dengan format: **masalah → teknik → relevansi untuk proyek ini → keputusan yang disarankan**. Topik:

- Kompresi video 1-bit (RLE, XOR antar-frame, run-length per baris) dan decoder yang murah di hardware.
- Driver SSD1306 di FPGA dan model simulasinya.
- Sigma-delta / PWM DAC untuk audio di FPGA, serta filter rekonstruksi dan keselamatan keluaran ke earphone.
- Kompresi audio sederhana (misalnya ADPCM) pada sample rate rendah.
- Akses flash QSPI Artix-7 setelah konfigurasi.
- Referensi arsitektur: `github.com/alpyen/fpga-mediaplayer` (FIFO audio/video, struktur modul, testbench, skrip encoder). Cek lisensi sebelum menyalin apa pun.

Jika sebuah klaim tidak bisa diverifikasi, tandai sebagai belum terverifikasi.

---

## 11. Definition of Done (MVP)

- M0 sampai M2 lulus kriteria penerimaannya.
- Video tampil di terminal laptop dari FPGA, stabil sepanjang durasi yang disepakati.
- Semua modul HDL punya testbench yang lulus, dan hasil dibandingkan dengan golden model.
- `DECISIONS.md` berisi seluruh keputusan terbuka yang sudah ditutup.
