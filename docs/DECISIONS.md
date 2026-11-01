# Log Keputusan Desain (DECISIONS.md)

Dokumen ini mencatat setiap keputusan arsitektur dan desain proyek "Bad Apple di Basys 3".
Sesuai aturan SPEC bagian 2 (aturan 7), setiap keputusan desain baru wajib dicatat di sini beserta alasannya.

## Format Catatan Keputusan

| ID | Keputusan | Alasan | Tanggal |
|---|---|---|---|
| *contoh: D-0* | *Deskripsi keputusan yang diambil* | *Alasan teknis, kompromi, dan pertimbangan* | *YYYY-MM-DD* |

---

## Daftar Keputusan

| ID | Keputusan | Alasan | Tanggal |
|---|---|---|---|
| D-1 | Bahasa HDL yang digunakan adalah **VHDL**. Simulator yang digunakan adalah **xsim** bawaan Vivado (tidak memerlukan iverilog/ghdl). | Tugas Proyek 1 mata kuliah Sistem Digital Lanjut mewajibkan penggunaan VHDL pada board Digilent Basys 3. Simulator menggunakan xsim bawaan Vivado untuk integrasi langsung tanpa dependensi toolchain eksternal. | 2026-10-23 |
| D-2 | Laju frame target ditetapkan pada **30 FPS**, dengan `FPS` diimplementasikan sebagai parameter generic pada modul HDL. | Standar pemutaran video halus untuk Bad Apple; parameter generic memungkinkan penyesuaian jika terjadi kendala bandwidth UART atau refresh rate di kemudian hari. | 2026-10-23 |
| D-8 | Tool synthesis & implementation menggunakan **Vivado 2026.1** di Windows host (lokasi instalasi `D:\Vivado\2026.1\Vivado`). Akses toolchain dilakukan via skrip pembantu `vivado/env.ps1` tanpa memodifikasi PATH sistem secara global. Target part diverifikasi: `xc7a35tcpg236-1`. | Memanfaatkan instalasi Vivado 2026.1 resmi yang sudah terlisensi di lingkungan kerja lokal dengan isolasi variabel lingkungan. | 2026-10-23 |
| D-10 | Struktur kontainer media: keputusan apakah segmen video dan audio disimpan terpisah atau di-interleave per frame dijadikan keputusan terbuka baru, ditutup pada M2 bersamaan dengan D-9. | Menunggu hasil evaluasi kompresi video M0 dan penentuan kebutuhan bandwidth/pola pembacaan memori flash SPI onboard. | 2026-10-23 |
| D-4 | Pilihan codec video: **Ditutup pada RLE per baris (Fixed 8-bit)**. | Memberikan rasio kompresi 3,80x yang sederhana, deterministik, dan sangat hemat sumber daya di hardware FPGA (estimasi ~30 LUT [DIASUMSIKAN]). Data video penuh (1,76 MB) sangat mudah ditransmisikan via streaming UART RX. | 2026-10-24 |
| D-11 | Penanganan rasio aspek video sumber: **Ditutup**. Menggunakan video sumber rasio 2:1 (`media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4`, 1280×640) yang terverifikasi bebas bilah hitam tertanam. Kanvas 128×64 diisi langsung menggunakan *area resize* tanpa crop, letterbox, atau distorsi. | Sumber 2:1 memiliki geometri native yang identik dengan kanvas FPGA 128×64 (faktor skala 10:1 sempurna, 6.532 frame pada 30 fps). | 2026-10-24 |
| D-Ramp | Pilihan Ramp ASCII terminal ditetapkan pada **Ramp A (Default SPEC 5.1: `" .:-=+*#@"`)**. | Memberikan persepsi kepadatan kecerahan linier yang paling seimbang untuk font terminal monospaced standar. | 2026-10-24 |
| D-Bin | Metode binerisasi citra ditetapkan pada **Ambang Tetap (Threshold 128)**. | Ambang tetap menghasilkan kontur siluet yang tajam dan bersih, serta bebas dari noise bintik catur (stippling artifacts) yang dihasilkan oleh error-diffusion dithering, sehingga mengoptimalkan efisiensi kompresi RLE. | 2026-10-24 |
| D-9 | Pemutaran standalone dari flash onboard Basys 3: **Ditutup sebagai target lanjutan**. | Jalur arsitektur utama dialihkan ke mode streaming dari PC (D-12 opsi b). Standalone dari flash tetap menjadi opsi lanjutan jika seluruh alur streaming telah stabil dan terverifikasi. | 2026-10-24 |
| D-12 | Jalur arsitektur video penuh: **Ditutup**. Jalur utama adalah **(b) Streaming data RLE dari PC lewat UART RX dengan PC sebagai pemegang waktu**. Opsi **(a) Standalone dari flash SPI onboard** dijadikan target lanjutan / pilihan alternatif. | Mengeliminasi keterbatasan kapasitas flash onboard dan kerumitan kontrol QSPI/STARTUPE2 pada tahap awal; analisis menunjukkan frame RLE terpadat (707 B) hanya memakan 23% dari periode 33,3 ms pada 921.600 baud, dan hanya butuh 1–2 BRAM FIFO di FPGA. | 2026-10-24 |
| D-5 | Parameter audio: **Ditutup pada PCM 8-bit 8 kHz mono** [DIVERIFIKASI: keputusan tertulis dari pengguna pada 2026-10-31: "aku ingin menggunakan audio 8 kHz 8-bit PCM"]. Format data: resample 44,1 kHz -> 8 kHz mono dengan low-pass (ffmpeg); 8-bit unsigned, titik tengah 128; ukuran data 217,84 s x 8.000 B = 1.742.720 B (13,94 Mbit). Jalur keluaran A2: 1 pin PMOD (PWM atau sigma-delta) + filter RC + earphone; rangkaian harus diperiksa manusia dan batas arus pin diverifikasi dari datasheet [DIASUMSIKAN sampai ada]. Jalur keluaran A1 (pemutaran audio PC) menggunakan audio asli dan tidak terpengaruh D-5. | Mengeliminasi logika dekoder ADPCM di hardware FPGA, menghasilkan audio deterministik, dan hemat sumber daya logika. Konsekuensi ukuran dan bandwidth: (1) Standalone flash (D-9) = video 14,09 + audio 13,94 + bitstream terkompresi M2b sebelum perbaikan 590.304 B, sesudah perbaikan 618.468 B (+4,77%, selisih LUT hanya +2); penyebab DIASUMSIKAN (variasi penempatan dan routing memengaruhi kompresibilitas); sisa flash standalone 72.358 B tidak boleh dianggap stabil (total 32,98 Mbit terhadap 33,55 Mbit kapasitas fisik chip SPI flash onboard 32 Mibit = 4.194.304 B); (2) Bandwidth streaming puncak (D-12b) = 707 B x 30 + 8.000 B/s = 29.210 B/s terhadap 92.160 B/s (31,7% dari 921.600 baud). | 2026-10-31 |
| D-13 | Evaluasi stop bit pada modul `uart_rx` ditetapkan pada `clk_cnt = CLKS_PER_BIT - 1` (titik penuh periode bit), sedangkan `START_BIT` tetap pada `clk_cnt = HALF_BIT - 1`. | FSM masuk STOP_BIT tepat setelah mencuplik bit data ke-7 di tengah bit itu (8,5 bit dari tepi start). Menunggu HALF_BIT mencuplik pada batas data/stop (9,0 bit); menunggu CLKS_PER_BIT - 1 mencuplik di tengah stop bit (9,5 bit). Terverifikasi xsim pada periode 1055..1115 ns (+-2,76%). Batas teoretis hitungan tangan kira-kira P dalam (1036, 1150) ns [DIASUMSIKAN]. Pada 31a1007, batas lambat sekitar -0,4% baud [DIVERIFIKASI oleh matriks xsim]. | 2026-11-01 |
| D-3 | Pemegang waktu: **Ditutup untuk mode streaming (PC sebagai Master)**. | Pada mode streaming UART (D-12 opsi b), PC bertindak sebagai timekeeper utama yang mengatur laju pengiriman frame (30 FPS) mengikuti jam audio. FPGA menyinkronkan swap buffer saat frame selesai diterima secara lengkap. | 2026-10-25 |

## Catatan Status Hardware
- **Board Basys 3:** Belum ada (pengujian hardware fisik ditunda sampai board tersedia; seluruh M0 dan M1 awal diverifikasi via simulasi xsim Vivado dan pengukuran bitstream offline).


