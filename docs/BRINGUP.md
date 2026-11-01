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
   ```powershell
   .\.venv\Scripts\python.exe python/stream_player.py --fake-fpga --clip data/golden/stream_clip.bin --audio data/audio/bad_apple.wav --start-frame 0 --max-frames 90
   ```
   *Catatan:* Evaluasi keselarasan sinkronisasi audio-video merupakan evaluasi subjektif pengguna.

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
