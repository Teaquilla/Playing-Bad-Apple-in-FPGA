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
| D-5 | Parameter audio: **TIDAK BERLAKU: audio FPGA dibatalkan (keputusan pengguna 2026-11-14, "karena keterbatasan alat dan waktu, kami memutuskan untuk tidak jadi menggunakan speaker, jadi audio hanya dari laptop")**. Jalur pemutaran audio laptop (A1; stream_player.py, WASAPI + disiplin on) tetap aktif dan tidak berubah. | Mengeliminasi jalur PWM/speaker FPGA (A2), filter RC analog, dan alokasi pin audio PMOD. | 2026-11-14 |
| D-13 | Evaluasi stop bit pada modul `uart_rx` ditetapkan pada `clk_cnt = CLKS_PER_BIT - 1` (titik penuh periode bit), sedangkan `START_BIT` tetap pada `clk_cnt = HALF_BIT - 1`. | FSM masuk STOP_BIT tepat setelah mencuplik bit data ke-7 di tengah bit itu (8,5 bit dari tepi start). Menunggu HALF_BIT mencuplik pada batas data/stop (9,0 bit); menunggu CLKS_PER_BIT - 1 mencuplik di tengah stop bit (9,5 bit). Terverifikasi xsim pada periode 1055..1115 ns (+-2,76%). Batas teoretis hitungan tangan kira-kira P dalam (1036, 1150) ns [DIASUMSIKAN]. Pada 31a1007, batas lambat sekitar -0,4% baud [DIVERIFIKASI oleh matriks xsim]. | 2026-11-01 |
| D-3 | Pemegang waktu: **Ditutup untuk mode streaming (PC sebagai Master)**. | Pada mode streaming UART (D-12 opsi b), laptop/PC bertindak sebagai timekeeper utama yang mengatur laju pengiriman frame (30 FPS) mengikuti jam audio laptop. FPGA menyinkronkan swap buffer saat frame selesai diterima secara lengkap. | 2026-10-25 |
| D-14 | Protokol framing paket audio streaming: **TIDAK BERLAKU: audio FPGA dibatalkan (keputusan pengguna 2026-11-14, "karena keterbatasan alat dan waktu, kami memutuskan untuk tidak jadi menggunakan speaker, jadi audio hanya dari laptop")**. Kode ekstensi audio di packet_parser.vhd dan stream_player berstatus di luar lingkup (pengembangan lanjut). | Port audio pada packet_parser.vhd dibiarkan tidak terhubung di top.vhd. | 2026-11-14 |
| D-15 | Arsitektur BRAM frame buffer untuk layar OLED: **Ditutup pada Opsi (b) (duplikasi PENYIMPANAN BRAM untuk OLED, kendali bank dan swap tunggal)** [DIVERIFIKASI: keputusan tim 2026-11-02 & 2026-11-14]. | Menginstansiasi blok duplikasi penyimpanan frame buffer BRAM kedua (mem2, +1 RAMB18E1) di dalam frame_buffer.vhd untuk pembacaan OLED oled_spi.vhd. Menghilangkan kebutuhan logika multiplexer/arbitrase Port B dan membiarkan jalur ascii_sink tetap utuh tanpa modifikasi. | 2026-11-14 |
| D-16 | Parameter komponen filter analog low-pass RC audio PMOD: **TIDAK BERLAKU: audio FPGA dibatalkan (keputusan pengguna 2026-11-14, "karena keterbatasan alat dan waktu, kami memutuskan untuk tidak jadi menggunakan speaker, jadi audio hanya dari laptop")**. | Komponen analog RC dan earphone ditiadakan dari target proyek. | 2026-11-14 |
| D-17 | Mekanisme kompensasi drift buffer audio FIFO: **TIDAK BERLAKU: audio FPGA dibatalkan (keputusan pengguna 2026-11-14, "karena keterbatasan alat dan waktu, kami memutuskan untuk tidak jadi menggunakan speaker, jadi audio hanya dari laptop")**. Modul audio_fifo.vhd berstatus di luar lingkup (pengembangan lanjut). | Modul audio_fifo tidak diintegrasikan ke top.vhd. | 2026-11-14 |
| D-18 | Resinkronisasi audio-video setelah buffer underflow pada streaming UART: **TIDAK BERLAKU: audio FPGA dibatalkan (keputusan pengguna 2026-11-14, "karena keterbatasan alat dan waktu, kami memutuskan untuk tidak jadi menggunakan speaker, jadi audio hanya dari laptop")**. | Masalah desinkronisasi AV pada buffer FPGA tidak lagi berlaku karena audio diputar eksklusif dari laptop pemegang waktu. | 2026-11-14 |

## Catatan Status Hardware
- **Board Basys 3:** Belum ada (pengujian hardware fisik ditunda sampai board tersedia; seluruh M0 dan M1 awal diverifikasi via simulasi xsim Vivado dan pengukuran bitstream offline).


