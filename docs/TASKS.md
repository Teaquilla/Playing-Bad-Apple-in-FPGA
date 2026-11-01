# TASKS: Bad Apple di Basys 3

**Status:** DRAF v0.1. Turunan dari `SPEC.md` dan `ARCHITECTURE.md`.

Cara memakai:
- Kerjakan berurutan per milestone. Satu tugas selesai hanya jika **kriteria verifikasinya dijalankan dan lulus**, dan hasilnya dilaporkan (bukan sekadar "sudah ditulis").
- Tugas bertanda **GATE** berhenti untuk menunggu keputusan atau review manusia.
- Jika sebuah tugas terhalang keputusan terbuka (SPEC bagian 9), berhenti dan tanyakan.
- Kolom "Dikerjakan oleh" dan status diisi saat berjalan.

Legenda status: `[ ]` belum, `[~]` berjalan, `[x]` selesai dan terverifikasi.

---

## Tugas awal (sebelum M0)

| ID | Tugas | Verifikasi | Status |
|---|---|---|:---:|
| T-1 | **GATE:** tim menutup D-1 (bahasa HDL dan simulator), D-2 (FPS), D-8 (versi Vivado dan OS) | Jawaban dicatat di `DECISIONS.md` | [x] |
| T-2 | Siapkan repo sesuai tata letak ARCHITECTURE bagian 6, `.gitignore` untuk media besar | Struktur folder ada; media sumber tidak ikut commit | [x] |
| T-3 | Tim menyediakan file video dan audio sumber secara manual | Lokasi file dicatat (`media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4` sudah siap) | [x] |

---

## M0: Golden model (Python, tanpa FPGA)

| ID | Tugas | Verifikasi | Status |
|---|---|---|:---:|
| T0.1 | Lingkungan Python (venv, daftar dependensi, perintah tes) | `pytest` berjalan (22 passed) | [x] |
| T0.2 | Fungsi pack/unpack format kanonik (SPEC bagian 3) | Tes round-trip; tes bit 7 = piksel paling kiri; panjang frame 1024 byte | [x] |
| T0.3 | Ekstraktor frame: video → frame 128×64 1-bit (ambang binerisasi sebagai parameter) → `frames.bin` | Ukuran file = jumlah frame × 1024; contoh frame diperiksa visual di `data/preview/` (video 2:1 native tanpa bilah hitam) | [x] |
| T0.4 | Renderer ASCII referensi sesuai SPEC bagian 5.1 | Frame hitam semua → seluruh spasi; putih semua → seluruh `@`; satu pola yang dihitung tangan cocok; panjang keluaran 1059 byte per frame | [x] |
| T0.5 | Pemutar terminal (ASCII, braille, half-block), parameter fps | Berjalan tanpa flicker yang mengganggu pada terminal tim | [x] |
| T0.6 | Kandidat codec: mentah, RLE per baris, XOR antar-frame + RLE; encoder dan decoder Python | Tes round-trip bit-exact pada seluruh frame; evaluasi varian panjang variabel (Elias-gamma & Nibble-prefix) | [x] |
| T0.7 | Laporan ukuran: total bit dan bit per frame per kandidat (tabel/CSV) | Tabel dihasilkan dari data Bad Apple asli 2:1 di `data/compression_report.csv` | [x] |
| T0.8 | Ekspor golden: N frame pertama (N dapat diatur) ke `data/golden/frames.bin` dan `ascii.bin`, serta `clip_bram.hex` | `ascii.bin` identik dengan keluaran T0.4 untuk frame yang sama; hex untuk inisialisasi BRAM (3 detik klip gerak representatif t=10s) | [x] |
| T0.9 | Penyetelan ramp ASCII di terminal tim; catat ramp terpilih | Ramp A dipilih oleh tim | [x] |
| T0.10 | **GATE:** tinjau laporan M0, putuskan D-4 (codec), D-9 (standalone), D-11 (aspect ratio), ramp, dan binerisasi | Ditutup resmi oleh tim: D-11, binerisasi ambang tetap 128, dan ramp A ditutup; D-4 sementara RLE 8-bit; D-9 terbuka; D-12 ditambahkan | [x] |


---

## M1: FPGA ke terminal

| ID | Tugas | Verifikasi | Status |
|---|---|---|---|
| T1.1 | Proyek Vivado (skrip), XDC clock, reset, dan UART disalin dari file XDC resmi Digilent | Sintesis lolos; 8 pin diverifikasi 100% cocok terhadap Basys-3-Master.xdc resmi Digilent | [x] |
| T1.2 | `frame_timer` dan testbench | Rata-rata periode tepat setelah N tick; jitter ≤ 1 siklus; uji hardware 100 MHz / 30 FPS selama 10 juta siklus lulus | [x] |
| T1.3 | `uart_tx` dan testbench dengan model UART | Byte yang ditangkap model sama dengan yang dikirim; uji pada baud 921.600 dan 25.000.000 lulus | [x] |
| T1.4 | `frame_source` (klip BRAM dari `frames.bin`) dan testbench | 1024 byte per frame, `last` di byte terakhir, klip berputar; prefetch pipeline 1 byte/siklus | [x] |
| T1.5 | `decoder` lurus | Keluaran = masukan, teruji di simulasi dan rantai top | [x] |
| T1.6 | `frame_buffer` double buffer dan testbench | Sink tidak pernah membaca frame setengah tertimpa; `read_busy` menolak swap; `underrun` dan `overrun` teruji | [x] |
| T1.7 | `ascii_sink` dan testbench | Keluaran 90 frame (95.310 byte) byte-exact cocok 100% terhadap `ascii.bin`/`ascii.hex`; uji pola non-uniform lulus | [x] |
| T1.8 | Integrasi `top` dan simulasi end-to-end | Mode dipercepat 90 frame (95.310 byte) dan mode real-time 921.600 baud lulus byte-exact di RTL dan funcsim | [x] |
| T1.9 | Sintesis, implementasi, laporan timing dan sumber daya | Tidak ada pelanggaran timing (WNS = +1.485 ns, TNS = 0); utilisasi LUT 13,22%, BRAM 0,5 tile; bitstream 4,40 Mbit | [x] |
| T1.10 | Uji hardware: skrip pyserial menangkap N byte dan membandingkan dengan `ascii.bin` | Uji offline pyserial `loop://` 4 kasus lulus pytest; **Uji di board fisik tertunda** (menunggu ketersediaan board) | [ ] (uji board tertunda) |
| T1.11 | **GATE:** tinjau laporan M1, tutup M1 setelah uji board | Seluruh RTL, simulasi pasca-sintesis, timing, dan bitstream M1 selesai; GATE formal menunggu uji board fisik | [ ] (menunggu board) |

---

## M2: Streaming UART RX dari PC & Dekoder RLE (M2a: Jalur Data Penerima; M2b: Integrasi Top)

| ID | Tugas | Verifikasi | Status |
|---|---|---|---|
| T2.1 | `stream_encoder.py` (protokol paket, evaluasi stream, manifest `stream_expected.txt`, batasan format `PAYLOAD_LEN_MAX = 1024`, deteksi galat) | 36 unit test pytest lulus (100% PASS); manifest terverifikasi bit-exact | [x] |
| T2.2 | `uart_rx` dan `tb_uart_rx` (sinkronisasi 2-FF, mid-bit sampling, baud 921.600) | `tb_uart_rx` PASS; Sintesis OOC: 30 LUTs (0,14%), 31 FFs (0,07%), 0 BRAM | [x] |
| T2.3 | `rx_fifo` dan `tb_rx_fifo` (FIFO 2 KB, 1x RAMB18E1, pointer komit & spekulatif) | `tb_rx_fifo` PASS; Sintesis OOC: 56 LUTs (0,27%), 45 FFs (0,11%), 0,5 BRAM Tile (1x RAMB18E1) | [x] |
| T2.4 | `packet_parser` dan `tb_packet_parser` (FSM HUNT, HDR, PAYLOAD, EOF, CHK, validasi format, timeout watchdog) | `tb_packet_parser` PASS; Sintesis OOC: 133 LUTs (0,64%), 182 FFs (0,44%), 0 BRAM | [x] |
| T2.5 | `rle_decoder` dan `tb_rle_decoder` (ekspansi RLE 8-bit ke 1.024 byte kanonik, deteksi run overflow & length error) | `tb_rle_decoder` PASS; Sintesis OOC: 155 LUTs (0,75%), 62 FFs (0,15%), 0 BRAM | [x] |
| T2.6 | Testbench gabungan `tb_stream_rx` (`uart_rx` $\rightarrow$ `rx_fifo` $\rightarrow$ `packet_parser` $\rightarrow$ `rle_decoder`) | `tb_stream_rx` PASS: 90 frame byte-exact vs `frames.bin` (0 ketidakcocokan); vektor galat checksum, truncation timeout, dan run overflow 100% cocok vs `stream_expected.txt` | [x] |
| T2.7 | Integrasi ke `top.vhd` (`STREAMING_MODE`, `frame_buffer` swap tertunda, mux sumber data) | `tb_top_stream` PASS (90 frame byte-exact vs `ascii.hex`, simulasi 25 MHz & 921.600 baud, penolakan korupsi), implementasi routed bitstream `build_m2b` lolos timing WNS = +1,387 ns | [x] |
| T2.8 | Skrip host pengirim PC `python/stream_player.py` (transmisi frame 30 FPS simultan dengan pembacaan terminal) | 6 unit test pytest deterministik di `tests/test_stream_player.py` PASS (100%), 90 frame klip byte-exact vs `ascii.bin` (95.310 B), penanganan lag/drop frame (> 2 frame) & pembacaan RsTx non-blocking | [x] |
| T2.9 | Pengujian streaming video penuh 6.532 frame di board fisik Basys 3 | Menunggu ketersediaan hardware Basys 3 (panduan prosedur bringup siap di `BRINGUP.md`) | [ ] (menunggu board) |

> [!NOTE]
> **Catatan Kritis Verifikasi M2b:**
> 1. `tb_top_stream` TIDAK mendeteksi kelemahan stop bit (lulus pada RTL `31a1007`); satu-satunya penjaga regresi adalah uji baud lambat dengan byte MSB=0 di `tb_uart_rx`, jangan pernah melonggarkannya.
> 2. Kegagalan Uji 2 pada `m2a-boardless` di 40 ns hanya muncul pada fase start `REL|0` (matriks tepi kritis); mekanisme race delta-cycle [DIASUMSIKAN]; perubahan `START_BIT` praktis tidak berpengaruh pada 921.600 baud.

---

## M3: Audio

| ID | Tugas | Verifikasi | Status |
|---|---|---|---|
| T3.1 | **GATE:** tutup D-3 (pemegang waktu) dan D-5 (parameter audio) | Dicatat | [x] |
| T3.2 | A1: pemutar audio PC yang dimulai sinkron dengan video | diuji di PC nyata (Realtek, MME, 20 s, tanpa board); sinkron audio-video: sinkron (penilaian pengguna). [DIASUMSIKAN]: celah 1.470 sampel ada di timeline kontainer dan tidak diisi ffmpeg (WAV = 9.380 x 1.024 sampel kontigu); sampel ke-k (k >= 1.024) berada di waktu kontainer k/44100 + 33,33 ms; frame n di 33,33 ms + n/30; maka frame n sejajar WAV pada n/30 [DIASUMSIKAN]; default --av-offset-ms = 0. Video tampil di terminal sekitar [waktu kirim paket + waktu keluaran ASCII ~11,5 ms + latensi render terminal] setelah dikirim, sehingga offset kalibrasi di board kemungkinan negatif [DIASUMSIKAN sampai ada board]. | [x] |
| T3.3 | Riset dan usulan rangkaian A2 (resistor seri, kapasitor DC-blocking, filter RC) | Skema dan nilai komponen diajukan | [ ] |
| T3.4 | **GATE:** review manusia atas rangkaian sebelum dihubungkan | Persetujuan tercatat | [ ] |
| T3.5 | `audio_out` (PWM/sigma-delta) dan testbench | Spektrum/keluaran simulasi sesuai sampel masukan | [ ] |
| T3.6 | Uji A2 di hardware dengan earphone | Terdengar benar; tidak ada pemanasan atau distorsi parah | [ ] |

---

## M4: OLED SSD1306 (saat layar tersedia)

| ID | Tugas | Verifikasi | Status |
|---|---|---|---|
| T4.1 | **GATE:** tutup D-7 (SPI atau I2C) sesuai modul yang dibeli | Dicatat | [ ] |
| T4.2 | Model perilaku SSD1306 di simulasi (rekonstruksi gambar dari byte) | Model menghasilkan gambar yang benar dari urutan inisialisasi dan data uji | [ ] |
| T4.3 | Master SPI/I2C dan testbench | Waktu dan protokol sesuai | [ ] |
| T4.4 | `oled_sink`: urutan inisialisasi dan konversi ke page-addressing | Gambar rekonstruksi di model sama dengan golden | [ ] |
| T4.5 | Uji gambar statis lalu video di layar fisik | Tampil benar | [ ] |

---

## Selalu berlaku

- Setiap perubahan desain dicatat di `DECISIONS.md` dengan alasan.
- Tiap laporan milestone memisahkan **yang diverifikasi** dari **yang diasumsikan**.
- Jika ada konflik antara kode dan `SPEC.md`, berhenti dan laporkan.
