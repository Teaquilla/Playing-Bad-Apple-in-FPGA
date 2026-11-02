# Panduan Bringup Perangkat Keras: Basys 3 (BRINGUP.md)

Dokumen ini menyediakan panduan langkah demi langkah saat board Digilent Basys 3 tiba untuk pengujian bitstream M1.

> [!NOTE]
> Seluruh langkah yang melibatkan interaksi fisik dengan board, deteksi driver USB hardware, dan transmisi kabel fisik ditandai sebagai **[DIASUMSIKAN]** karena pengujian fisik masih tertunda ketersediaan hardware.

---

## 1. Persiapan Perangkat Keras

1. **Board Basys 3:** Pastikan board Digilent Basys 3 (Xilinx Artix-7 `xc7a35tcpg236-1`) dalam kondisi baik.
2. **Koneksi Kabel:** Hubungkan kabel micro-USB dari port USB PC ke port micro-USB **J4** (berlabel `PROG / UART`) pada Basys 3 [DIASUMSIKAN].
3. **Pengaturan Jumper Power & Konfigurasi:**
   - Jumper **JP1** (JTAG / SPI Flash): Setel ke posisi **JTAG** untuk pemrograman RAM sementara, atau **QSPI** jika memprogram flash memori non-volatile [DIASUMSIKAN].
   - Jumper **JP2** (Power Source): Setel ke **USB** (menghubungkan pin 1-2) [DIASUMSIKAN].
4. **Sakelar Daya (Power Switch):** Geser sakelar daya **SW16** (sudut kiri atas) ke posisi **ON**. Pastikan LED merah penanda daya (`POWER` LD17) menyala terang [DIASUMSIKAN].

---

## 2. Identifikasi Port Serial (COM) di Windows

Board Basys 3 menggunakan jembatan USB-JTAG/UART terintegrasi FTDI FT2232HQ.

Jalankan perintah PowerShell berikut untuk mendeteksi nomor port COM yang dialokasikan:
```powershell
Get-CimInstance Win32_SerialPort | Select-Object DeviceID, Description
```
*(Contoh keluaran yang diharapkan: `COM3` atau `COM4` dengan deskripsi `USB Serial Port` atau `Digilent USB Device`)* [DIASUMSIKAN].

### Pengaturan Latency Timer Driver FTDI di Windows [DIASUMSIKAN]
Secara default, driver Virtual COM Port (VCP) FTDI pada Windows menggunakan **Latency Timer = 16 ms**.
- **Konfigurasi yang Diperlukan:** Ubah Latency Timer ke **1 ms** atau **2 ms** [DIASUMSIKAN, belum diuji di hardware].
- **Langkah Pengaturan:**
  1. Buka **Device Manager** (`devmgmt.msc`).
  2. Buka kategori **Ports (COM & LPT)** $\rightarrow$ klik kanan pada perangkat **USB Serial Port (COMx)** $\rightarrow$ pilih **Properties**.
  3. Buka tab **Port Settings** $\rightarrow$ klik tombol **Advanced...**.
  4. Pada kelompok *BM Options*, ubah nilai **Latency Timer (msec)** dari nilai default `16` menjadi **`1`** (atau `2`).
  5. Klik **OK** dan restart koneksi terminal/skrip Python.
- **Alasan Teknis Singkat:**
  Chip FTDI FT2232HQ menahan paket data USB masuk sebelum diserahkan ke sistem operasi sampai buffer penuh (62 byte paket USB) atau batas waktu timer kedaluwarsa. Pada laju 30 FPS (interval frame 33,33 ms), latensi 16 ms menyebabkan penundaan separuh periode frame, memicu *jitter* penyerahan paket dan transmisi berfluktuasi (*bursting*) pada komunikasi serial full-duplex dua arah (streaming RLE ke FPGA dan output ASCII ke terminal PC) [DIASUMSIKAN].

---

## 3. Pemrograman Bitstream FPGA

### Opsi A: Menggunakan GUI Vivado Hardware Manager
1. Buka Vivado 2026.1 Hardware Manager:
   ```powershell
   powershell -ExecutionPolicy Bypass -File vivado/env.ps1 cmd /c "vivado -mode gui"
   ```
2. Klik **Open Target** $\rightarrow$ **Auto Connect** [DIASUMSIKAN].
3. Klik kanan pada part `xc7a35t_0` $\rightarrow$ **Program Device...** [DIASUMSIKAN].
4. Pilih berkas bitstream terkompresi (M1 Klip atau M2b Streaming):
   - Bitstream File M1 (Klip ROM): `vivado/build_m1/top_compressed.bit`
   - Bitstream File M2b (Streaming PC): `vivado/build_m2b/top_compressed.bit`
5. Klik **Program**. LED hijau penanda selesai konfigurasi (`DONE` LD18) pada board Basys 3 harus menyala [DIASUMSIKAN].

### Opsi B: Menggunakan Skrip Tcl Batch (Tanpa GUI)
Jalankan pemrograman langsung dari terminal:
```powershell
powershell -ExecutionPolicy Bypass -File vivado/env.ps1 cmd /c "vivado -mode batch -source vivado/program_basys3.tcl"
```
*(Skrip Tcl mengeksekusi `open_hw_manager`, `connect_hw_server`, `open_hw_target`, dan `program_hw_devices` secara otomatis)* [DIASUMSIKAN].

---

## 4. Pengaturan Terminal VT100 untuk Demonstrasi Visual

Untuk melihat pemutaran ASCII secara langsung di layar:
1. Buka aplikasi terminal emulator (misalnya **PuTTY**, **Tera Term**, atau **Windows Terminal**).
2. Pengaturan Port Serial:
   - **Baud Rate:** `921600`
   - **Data Bits:** `8`
   - **Parity:** `None`
   - **Stop Bits:** `1`
   - **Flow Control:** `None`
3. Pengaturan Layar / Jendela:
   - Ukuran jendela minimal: **128 kolom × 66 baris** (direkomendasikan layar penuh / maximized) [DIASUMSIKAN].
   - Font: Gunakan font monospaced rapat seperti `Consolas`, `Cascadia Code`, atau `Courier New` ukuran kecil (8-10 pt) [DIASUMSIKAN].
4. Hasil yang Diharapkan:
   - Terminal menampilkan animasi siluet Bad Apple 128×64 berputar secara terus menerus (looping 90 frame) pada laju ~30 FPS dengan visual halus tanpa tearing [DIASUMSIKAN].

---

## 5. Pengujian Byte-Exact Menggunakan `uart_capture.py`

Untuk memvalidasi integritas data serial bit-for-bit di lingkungan `.venv`:
```powershell
.\.venv\Scripts\python.exe python/uart_capture.py --port COMx --baud 921600 --frames 90 --compare data/golden/ascii.bin
```
*(Ganti `COMx` dengan port serial terdeteksi, misalnya `COM3`)*.

### Hasil yang Diharapkan:
- Skrip menangkap tepat 95.310 byte (90 frame × 1.059 byte per frame).
- Skrip mencetak konfirmasi:
  `[SUCCESS] 95310 byte tertangkap dan identik 100% byte-exact dengan data/golden/ascii.bin!` [DIASUMSIKAN].

---

## 6. Pengujian Mode Streaming M2b Menggunakan `stream_player.py` [DIASUMSIKAN]

Untuk memvalidasi pemutaran video streaming dari PC ke FPGA Basys 3:
1. **Pemilihan Mode pada Board:**
   - Geser saklar **SW0** (pin `V17`, saklar paling kanan pada barisan 16 switch Basys 3) ke posisi **`UP` / `1`** [DIASUMSIKAN].
   - Jika saklar SW0 berada pada posisi `0`, sistem akan memainkan klip ROM internal BRAM (Mode M1).
2. **Pengaturan Port Serial & Driver FTDI:**
   - **Baud Rate:** `921600`
   - **Data Bits:** `8`
   - **Parity:** `None`
   - **Stop Bits:** `1`
   - **Flow Control:** `None`
   - Pastikan **Latency Timer** driver FTDI pada Windows sudah diubah dari default 16 ms menjadi **`1 ms`** (atau `2 ms`) di Device Manager [DIASUMSIKAN].
   - *Catatan Port Tunggal:* Board Basys 3 hanya memiliki satu port serial FTDI terintegrasi. Terminal eksternal tidak dapat membuka port COM secara bersamaan dengan `stream_player.py` karena batas eksklusif handle serial OS Windows [DIASUMSIKAN]. Oleh karena itu, pembacaan byte ASCII dari pin RsTx (~31,8 KB/s) ditangani langsung oleh background thread `stream_player.py`. Operasi baca dan tulis simultan pada `SerialTransport` berstatus **[DIASUMSIKAN]** sampai diverifikasi pada board fisik atau loopback adapter.
3. **Eksekusi Host Streamer:**
   Jalankan pemutar streaming dari lingkungan `.venv`:
   ```powershell
   .\.venv\Scripts\python.exe python/stream_player.py --port COM3 --baud 921600 --clip data/golden/stream_clip.bin --fps 30 --av-offset-ms 0
   ```
   *(Ganti `COM3` dengan nomor port COM fisik yang terdeteksi)*.

   - **Parameter Jam & Audio (`--audio`):**
     - Tanpa `--audio`: Streamer menggunakan jam monotonik sistem (`MonotonicClock`).
     - Dengan `--audio PATH`: Memutar audio WAV PC (A1) menggunakan backend `sounddevice.RawOutputStream` dan menyinkronkan video terhadap `AudioClock`.
       Contoh: `--audio data/audio/bad_apple.wav`.
   - **Parameter `--av-offset-ms`:** Nilai offset audio/video dalam milidetik. Nilai positif berarti video dikirim lebih lambat dari jam acuan (default: `0` ms `[DIASUMSIKAN]`).
     > [!WARNING]
     > Nilai `--av-offset-ms` tidak boleh lebih negatif dari $-(2/\text{FPS}) \times 1000\text{ ms}$ (pada 30 FPS batasnya adalah $-66,67\text{ ms}$). Jika lebih negatif, konstruktor `StreamPlayer` menolak dengan `ValueError` karena frame awal akan langsung dibuang sebagai frame terlambat.
   - **Opsi Rentang Frame:**
     - `--start-frame N`: Indeks frame awal (default: 0).
     - `--max-frames M`: Batas jumlah frame yang diputar (default: semua frame).
   - **Opsi Penyimpanan & Tampilan:**
     - Simpan rekaman mentah ASCII ke file: tambahkan `--ascii-out stream_run.bin`.
     - Matikan tampilan animasi di terminal: tambahkan `--no-display`.

4. **Mode Simulasi Boardless Mandiri (`--fake-fpga`):**
   Untuk menguji seluruh pipeline perangkat lunak host (video RLE + audio PC + render ASCII) secara mandiri di PC tanpa perangkat keras FPGA:

   - **Kasus A: Memutar Klip Golden 90 Frame (`data/golden/stream_clip.bin`):**
     Berkas `stream_clip.bin` memuat frame 300..389 dari MP4 asli (detik 10,0 hingga 13,0). Agar audio berbunyi selaras dengan visual klip, gunakan `--audio-start-sec 10.0`:
     ```powershell
     .\.venv\Scripts\python.exe python/stream_player.py --fake-fpga --clip data/golden/stream_clip.bin --audio data/audio/bad_apple.wav --audio-start-sec 10.0
     ```

   - **Kasus B: Memutar Aliran Video Penuh (`data/stream_full.bin`):**
     Pembuatan berkas aliran biner video lengkap dilakukan dengan skrip tracked `python/make_full_stream.py`:
     ```powershell
     .\.venv\Scripts\python.exe python/make_full_stream.py --frames 1000 --out data/stream_full.bin
     ```
     Jika berkas aliran video lengkap digunakan, opsi `--start-frame 300` secara otomatis menyelaraskan audio ke sampel awal $300 / 30 \times 44.100 = 441.000$ (detik 10,0):
     ```powershell
     .\.venv\Scripts\python.exe python/stream_player.py --fake-fpga --file data/stream_full.bin --audio data/audio/bad_apple.wav --start-frame 300 --max-frames 90
     ```

   *Catatan Evaluasi Waktu & Sinkronisasi [DIASUMSIKAN]:*
   - Celah 1.470 sampel ada di timeline kontainer dan tidak diisi ffmpeg (WAV = 9.380 x 1.024 sampel kontigu); sampel ke-k ($k \ge 1.024$) berada di waktu kontainer $k/44100 + 33,33\text{ ms}$; frame $n$ di $33,33\text{ ms} + n/30$; maka frame $n$ sejajar WAV pada $n/30$ [DIASUMSIKAN]; default `--av-offset-ms = 0` [DIASUMSIKAN].
   - Video tampil di terminal sekitar [waktu kirim paket + waktu keluaran ASCII ~11,5 ms + latensi render terminal] setelah dikirim, sehingga offset kalibrasi di board kemungkinan bernilai negatif [DIASUMSIKAN sampai ada board fisik].
   - Penilaian akhir keselarasan sinkronisasi audio-video dilakukan secara subjektif oleh pengguna (mata dan telinga), bukan oleh skrip atau asisten.

### Hasil yang Diharapkan [DIASUMSIKAN]:
- Skrip mengirimkan seluruh frame paket RLE pada laju 30 FPS.
- Thread pembaca simultan menangkap aliran byte ASCII dari pin RsTx (~31,8 KB/s) tanpa lagging atau deadlock.
- Terminal menampilkan animasi ASCII 128×64 tanpa tearing (buffer swap tertunda hanya terjadi saat frame baru valid).
  > [!NOTE]
  > - Dukungan dan kelancaran rendering escape sequence ANSI (`\x1b[H` / `ESC [ H`) di Windows Terminal atau terminal emulator lainnya berstatus **`[DIASUMSIKAN]`** sampai diverifikasi langsung pada hardware dan terminal riil.
  > - Karakteristik jitter penjadwalan frame (< 2 ms) hanya diukur pada mesin pengujian spesifik ini tanpa perangkat serial fisik riil, dan tidak menjamin angka yang sama pada sistem lain atau dengan beban I/O serial riil.
- Pada ringkasan akhir: `Total Frame: 90`, `Frame Terkirim: 90`, `Frame Dibuang: 0`, `Byte Diterima: 95310`.

---

## 7. Prosedur Diagnostik & Pencatatan Bila Terjadi Kegagalan

| Gejala Masalah | Kemungkinan Penyebab | Tindakan Pemeriksaan & Solusi |
|---|---|---|
| **Hardware Manager gagal koneksi ("No hardware target detected")** | Driver USB Digilent belum terpasang atau kabel micro-USB hanya mendukung pengisian daya (power-only). | 1. Pasang/instal ulang Digilent Cable Drivers via Vivado. <br>2. Ganti kabel micro-USB dengan kabel data terverifikasi. <br>3. Periksa apakah perangkat muncul di Device Manager pada kelompok "Universal Serial Bus controllers" [DIASUMSIKAN]. |
| **Port COM tidak muncul di Device Manager** | Driver FTDI VCP (Virtual COM Port) tidak aktif secara default di Windows. | Buka Device Manager $\rightarrow$ klik kanan properti port FTDI $\rightarrow$ Advanced $\rightarrow$ centang "Load VCP" [DIASUMSIKAN]. |
| **Karakter rusak / simbol acak di terminal** | Ketidakcocokan baud rate atau distorsi sinyal UART pada kabel USB panjang. | 1. Pastikan baud rate terminal disetel tepat pada `921600`. <br>2. Simpan dump raw hex menggunakan `uart_capture.py --raw-dump debug.bin` untuk menganalisis apakah kesalahan terjadi pada bit rate atau framing [DIASUMSIKAN]. |
| **Gambar terpotong atau baris berantakan (tearing)** | Terminal tidak mendukung escape sequence ANSI `\x1b[H` (cursor home) atau buffer terminal terlalu kecil. | 1. Gunakan terminal modern seperti Windows Terminal atau PuTTY. <br>2. Pastikan lebar terminal minimal 128 karakter. |
| **Animasi berhenti / macet (freeze)** | Tombol `btnC` aktif atau terjadi kondisi stall pada pipeline sinkronisasi. | Tekan tombol tengah `btnC` pada Basys 3 untuk mereset seluruh sistem kembali ke frame 0 [DIASUMSIKAN]. |

---

## 8. Tolok Ukur Jam Audio Menggunakan `bench_audio_clock.py`

Untuk menguji performa jam audio (`AudioClock`), stabilitas penjadwalan frame video terhadap callback audio PC, dan akurasi model disiplin jam tanpa/dengan regresi linear jendela geser:

```powershell
.\.venv\Scripts\python.exe python/bench_audio_clock.py --seconds 20 --hostapi wasapi --discipline on --csv data/benchmarks/wasapi_20s_on.csv
```

### Parameter:
- `--wav PATH`: Path ke berkas WAV acuan (default: `data/audio/bad_apple.wav`).
- `--seconds N`: Durasi pengujian dalam detik (default: `20.0`).
- `--hostapi API`: Nama Host API PortAudio/Windows (`mme`, `directsound`, `wasapi`, atau `default`).
- `--device ID`: Nomor indeks perangkat output suara `sounddevice` (opsional).
- `--discipline {off,on}`: Mengaktifkan atau menonaktifkan disiplin jam regresi linear jendela geser (default: `off`).
- `--fps FPS`: Laju frame video simulasi acuan (default: `30.0`).
- `--csv PATH`: Path penyimpanan berkas rekaman per-frame CSV (opsional).

### Metrik yang Dilaporkan:
- **Reported Latency (ms):** Estimasi latensi perangkat keras output audio yang dilaporkan oleh driver audio/DAC.
- **Initial Offset (ms):** Waktu tunggu dari pemanggilan `start()` hingga tibanya callback audio pertama.
- **Audio Clock Step (min/med/max ms):** Interval waktu antar pembaruan callback audio fisik.
- **Overshoot Jam Audio (mean/p99/max ms):** Kelebihan waktu (*overshoot*) pada domain jam audio itu sendiri (`clock.now() - target_time`) setelah fungsi `sleep_until` selesai menunggu target waktu frame ($k/\text{FPS}$).
- **Penyimpangan Selang Kirim Monotonik (std/p99/max ms):** Variasi interval waktu kirim nyata antar frame pada jam monotonik sistem (`mono_time[k] - mono_time[k-1] - 1/FPS`) untuk $k \ge 3$.
- **Residual Garis Lurus Monotonik (std/max ms):** Deviasi waktu kirim monotonik terhadap garis lurus regresi terbaik `mono_time[k] ~ a + k/FPS` untuk $k \ge 3$.
- **Drift Slope ($\text{ppm} \pm \sigma_{\text{ppm}}$):** Estimasi penyimpangan frekuensi clock audio fisik terhadap jam monotonik sistem dalam satuan ppm (*parts-per-million*) beserta nilai ketidakpastian standar error ($\pm \sigma_{\text{ppm}}$).
- **Callback Flags:** Indikator *underflow* atau *overflow* buffer audio dari driver.

