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
| D-5 | Parameter audio: **Ditutup pada 8 kHz 8-bit PCM** [DIVERIFIKASI: keputusan tim M2]. Output via audio PWM 8-bit mono pada pin mono/jack. | Dipilih berdasarkan keputusan eksplisit tim: mengeliminasi kompleksitas logika dekoder ADPCM di hardware, menghasilkan fidelitas suara yang memadai dan deterministik, serta sangat hemat sumber daya FPGA. | 2026-10-29 |
| D-3 | Pemegang waktu: **Ditutup untuk mode streaming (PC sebagai Master)**. | Pada mode streaming UART (D-12 opsi b), PC bertindak sebagai timekeeper utama yang mengatur laju pengiriman frame (30 FPS) mengikuti jam audio. FPGA menyinkronkan swap buffer saat frame selesai diterima secara lengkap. | 2026-10-25 |

## Catatan Status Hardware
- **Board Basys 3:** Belum ada (pengujian hardware fisik ditunda sampai board tersedia; seluruh M0 dan M1 awal diverifikasi via simulasi xsim Vivado dan pengukuran bitstream offline).


