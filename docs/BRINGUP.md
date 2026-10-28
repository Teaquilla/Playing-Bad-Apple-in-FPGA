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

---

## 3. Pemrograman Bitstream FPGA

### Opsi A: Menggunakan GUI Vivado Hardware Manager
1. Buka Vivado 2026.1 Hardware Manager:
   ```powershell
   powershell -ExecutionPolicy Bypass -File vivado/env.ps1 cmd /c "vivado -mode gui"
   ```
2. Klik **Open Target** $\rightarrow$ **Auto Connect** [DIASUMSIKAN].
3. Klik kanan pada part `xc7a35t_0` $\rightarrow$ **Program Device...** [DIASUMSIKAN].
4. Pilih berkas bitstream terkompresi M1:
   - Bitstream File: `vivado/build_m1/top_compressed.bit`
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

## 6. Prosedur Diagnostik & Pencatatan Bila Terjadi Kegagalan

| Gejala Masalah | Kemungkinan Penyebab | Tindakan Pemeriksaan & Solusi |
|---|---|---|
| **Hardware Manager gagal koneksi ("No hardware target detected")** | Driver USB Digilent belum terpasang atau kabel micro-USB hanya mendukung pengisian daya (power-only). | 1. Pasang/instal ulang Digilent Cable Drivers via Vivado. <br>2. Ganti kabel micro-USB dengan kabel data terverifikasi. <br>3. Periksa apakah perangkat muncul di Device Manager pada kelompok "Universal Serial Bus controllers" [DIASUMSIKAN]. |
| **Port COM tidak muncul di Device Manager** | Driver FTDI VCP (Virtual COM Port) tidak aktif secara default di Windows. | Buka Device Manager $\rightarrow$ klik kanan properti port FTDI $\rightarrow$ Advanced $\rightarrow$ centang "Load VCP" [DIASUMSIKAN]. |
| **Karakter rusak / simbol acak di terminal** | Ketidakcocokan baud rate atau distorsi sinyal UART pada kabel USB panjang. | 1. Pastikan baud rate terminal disetel tepat pada `921600`. <br>2. Simpan dump raw hex menggunakan `uart_capture.py --raw-dump debug.bin` untuk menganalisis apakah kesalahan terjadi pada bit rate atau framing [DIASUMSIKAN]. |
| **Gambar terpotong atau baris berantakan (tearing)** | Terminal tidak mendukung escape sequence ANSI `\x1b[H` (cursor home) atau buffer terminal terlalu kecil. | 1. Gunakan terminal modern seperti Windows Terminal atau PuTTY. <br>2. Pastikan lebar terminal minimal 128 karakter. |
| **Animasi berhenti / macet (freeze)** | Tombol `btnC` aktif atau terjadi kondisi stall pada pipeline sinkronisasi. | Tekan tombol tengah `btnC` pada Basys 3 untuk mereset seluruh sistem kembali ke frame 0 [DIASUMSIKAN]. |
