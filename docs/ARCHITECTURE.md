# ARCHITECTURE: Bad Apple di Basys 3

**Status:** DRAF v0.1. Turunan dari `SPEC.md`; jika bertentangan, `SPEC.md` yang berlaku dan konflik harus dilaporkan.
**Bahasa HDL:** VHDL (D-1, diputuskan). Antarmuka modul tetap didefinisikan secara eksplisit sebagai tabel port.

Penanda yang dipakai: **[diverifikasi]** sudah dicek lewat simulasi/hardware, **[asumsi]** belum dicek. Semua angka di sini masih berstatus [asumsi] sampai milestone terkait selesai.

---

## 1. Gambaran umum (cakupan M0 sampai M2)

```
            frame_tick (swap buffer)
 [frame_timer] --------+-----------------------------+
       |               |                             |
       | sink_start    |                             |
       | (+1 siklus)   |                             |
       |               v                             v
 [frame_source] -> [decoder] -> [frame_buffer] -> [ascii_sink] -> [uart_tx] -> PC
   (M1: BRAM klip,  (M1: lurus,    ^ (double        | (blok 2x4,     (8N1)
    M2: UART RX)     M2: RLE)      |  buffer)       |  ramp ASCII)
                                   +--- read_busy --+

 Tahap lanjut: [audio_out] (PWM/sigma-delta ke PMOD), [oled_sink] (SSD1306)
```

Prinsip:
- Satu domain clock. Semua pengaturan waktu memakai clock-enable atau pulsa, bukan clock turunan.
- Jalur byte antar-modul memakai antarmuka aliran valid/ready (bagian 3).
- Sisi baca `frame_buffer` adalah port memori sinkron (alamat → data, latensi tetap) dan dikecualikan dari antarmuka stream valid/ready.
- Format frame kanonik (SPEC bagian 3) adalah satu-satunya format yang diketahui decoder, buffer, dan sink.
- Sumber data dan display bisa diganti tanpa mengubah modul lain.

---

## 2. Clock, reset, dan pin

- **Clock:** satu clock 100 MHz dari osilator Basys 3 [asumsi: verifikasi dengan XDC resmi Digilent].
- **Reset:** sinkron, aktif tinggi, dari tombol onboard yang di-debounce atau disinkronkan. Nama tombol ditetapkan di constraint.
- **UART ke PC:** lewat USB-UART onboard (FTDI). Nama dan pin port (RX dan TX dari sisi FPGA) harus disalin dari file XDC resmi Digilent untuk Basys 3, **jangan dari ingatan atau dari dokumen ini**.
- **Constraint:** satu file XDC, hanya pin yang dipakai yang diaktifkan.
- Sinyal asinkron dari luar (tombol, RX UART) wajib melewati sinkronisasi dua flip-flop.

---

## 3. Antarmuka aliran (stream)

Antarmuka valid/ready 8-bit berlaku untuk jalur transfer byte:
- **Aliran frame:** `frame_source` → `decoder` → sisi tulis `frame_buffer` (menyertakan sinyal `last`).
- **Aliran karakter:** `ascii_sink` → `uart_tx` (hanya `data`, `valid`, `ready`; tanpa sinyal `last`).
- *Pengecualian:* Sisi baca `frame_buffer` (`buf_addr` → `buf_data`) adalah antarmuka port memori sinkron (latensi tetap) dan tidak menggunakan antarmuka stream valid/ready.

| Sinyal | Arah (pengirim ke penerima) | Lebar | Arti |
|---|---|---|---|
| `data` | pengirim → penerima | 8 | byte data |
| `valid` | pengirim → penerima | 1 | `data` sah |
| `ready` | penerima → pengirim | 1 | penerima siap menerima |
| `last` | pengirim → penerima | 1 | byte terakhir dalam satu frame (byte ke-1024 pada format kanonik; **hanya dipakai pada aliran frame**, tidak ada pada `ascii_sink` → `uart_tx`) |

Aturan:
1. Transfer terjadi pada siklus saat `valid` dan `ready` keduanya 1.
2. Setelah `valid` naik, `data` (dan `last` jika ada) harus stabil sampai transfer terjadi.
3. Pengirim tidak boleh menunggu `ready` untuk menaikkan `valid`.
4. Tidak boleh ada loop kombinasional antara `valid` dan `ready` lintas modul.

---

## 4. Modul

### 4.1 `frame_timer`
Menghasilkan `frame_tick` (pulsa satu siklus) pada laju `FPS`. Karena 100 MHz / 30 tidak bulat, pakai akumulator fase: tiap siklus tambahkan `FPS` ke akumulator, dan jika akumulator mencapai `CLK_HZ`, kurangi `CLK_HZ` dan keluarkan pulsa. Dengan begitu rata-rata laju tepat (tanpa drift), hanya jitter paling banyak satu siklus.

**Urutan eksekusi per frame_tick:**
1. Pada siklus `T` saat `frame_tick = 1`: `frame_buffer` mengevaluasi swap bank (`swap_req`). Jika bank belakang sudah lengkap terisi (`w_last` sudah diterima), bank ditukar.
2. Pada siklus `T+1` (satu siklus setelah swap bank): pulsa `sink_start` dikirim ke `ascii_sink`. Sinyal bank aktif di `frame_buffer` sudah stabil, sehingga `ascii_sink` men-latch nomor bank depan yang baru dan mulai membaca.

| Port | Arah | Lebar | Keterangan |
|---|---|---|---|
| `clk`, `rst` | in | 1 | |
| `frame_tick` | out | 1 | pulsa satu siklus untuk swap buffer |
| `sink_start` | out | 1 | pulsa satu siklus (terlambat 1 siklus dari `frame_tick`) untuk memulai display sink |

Generic: `CLK_HZ` (100.000.000), `FPS` (30).

### 4.2 `uart_tx`
Pemancar UART 8N1. Pembagi baud memakai pembulatan bilangan bulat (galat sekitar ±0,5% pada 921600 baud, ini perlu dicek toleransinya) atau akumulator fraksional seperti di 4.1. Pilihan dicatat di `DECISIONS.md`.

| Port | Arah | Lebar | Keterangan |
|---|---|---|---|
| `clk`, `rst` | in | 1 | |
| `s_data`, `s_valid`, `s_ready` | in/in/out | 8/1/1 | aliran byte masuk (tanpa `last`) |
| `tx` | out | 1 | ke pin UART TX |

Generic: `CLK_HZ`, `BAUD`.

### 4.3 `frame_source`
M1: menghasilkan frame dari klip pendek yang disimpan di BRAM (diinisialisasi dari file hasil ekspor M0) atau dari pola uji. Tahap lanjut: dari flash atau UART RX. (Catatan: Total frame video 2:1 penuh adalah 6.532 frame pada 30 FPS, durasi 217,733 s).

**Pemicu kerja:** Modul ini berjalan bebas (*free-running*) mengalirkan byte frame dan diatur sepenuhnya oleh backpressure dari `w_ready` sisi tulis `frame_buffer`. Begitu keluar dari reset, `frame_source` menyajikan byte frame; jika `m_ready = 0` (buffer penuh atau sedang swap), source menunggu (*stall*). Setelah mencapai byte terakhir dari frame terakhir klip, pembacaan otomatis berputar kembali ke frame 0 (klip berulang). Port `start` dihapus untuk menyederhanakan kontrol.

| Port | Arah | Lebar | Keterangan |
|---|---|---|---|
| `clk`, `rst` | in | 1 | |
| `enable` | in | 1 | pengaktif modul (dihubungkan ke '1' saat pemutaran aktif) |
| `m_data`, `m_valid`, `m_ready`, `m_last` | out/out/in/out | 8/1/1/1 | aliran frame, 1024 byte per frame |

Generic: `WIDTH`, `HEIGHT`, `INIT_FILE`, `NUM_FRAMES` (klip berputar kembali ke awal).

### 4.4 `decoder`
M1: lurus (byte masuk = byte keluar), supaya jalur data dan antarmuka sudah teruji sebelum kodek ada. M2: dekode kodek terpilih (D-4: RLE per baris 8-bit) dengan antarmuka streaming UART RX sesuai referensi tunggal di `docs/PROTOCOL.md`. Antarmuka masuk-keluar berupa aliran (bagian 3); keluaran selalu format kanonik 1024 byte. Kompleksitas hardware decoder diestimasi sangat hemat: **~40–70 LUT `[DIASUMSIKAN]`**.

### 4.4.1 Modul Penerima Streaming & FIFO RX (M2)
Pada mode streaming (D-12 opsi b), modul `uart_rx` menerima paket data dari PC dan menyimpannya ke `rx_fifo`.
- **Ukuran FIFO RX:** Ditetapkan sebesar **2.048 Byte (2 KB)**.
  - Alasan: Paket maksimum adalah 1.033 Byte ($1024 + 9$). Mekanisme pointer baca spekulatif membutuhkan kapasitas buffer minimal menampung seluruh paket terpanjang ditambah sisa byte sebelumnya untuk memungkinkan operasi rollback saat terjadi galat/sinkron palsu. FIFO 2.048 Byte dipetakan tepat ke dalam **1 primitif Block RAM Artix-7 (1x RAMB18E1, mode 2048x8 atau 0,5 tile BRAM)** `[DIASUMSIKAN]`.
- **Mekanisme Pointer Komit & Spekulatif:**
  - `w_ptr`: ditulis oleh output byte serial `uart_rx`.
  - `r_ptr_spec`: membaca byte secara spekulatif untuk diproses oleh `packet_parser`.
  - `r_ptr_commit`: hanya dimajukan (`r_ptr_commit <= r_ptr_spec`) setelah paket terbukti valid (`packet_valid = '1'`).
  - Saat paket galat atau sinkron palsu (`packet_error = '1'`): `r_ptr_spec` dan `r_ptr_commit` dikembalikan ke posisi `r_ptr_sof + 1` (rollback).
- **Tanpa Flow Control (Hardware/Software):**
  - Jalur UART tidak memerlukan sinyal flow control RTS/CTS atau software XON/XOFF.
  - Alasan teknis: PC bertindak sebagai timekeeper utama (D-3) yang menyalurkan frame pada laju 30 FPS (interval 33,33 ms). Pada 921.600 baud, transmisi paket frame terpadat (716 B) hanya memakan waktu 7,77 ms (23,3% dari interval frame). Dekoder hardware di FPGA beroperasi pada 100 MHz dan mengosongkan FIFO RX ke dalam frame buffer dalam waktu kurang dari 0,015 ms (> 500x lebih cepat daripada laju baud UART). Dengan demikian, FIFO RX tidak akan pernah meluap dalam kondisi operasional normal.
- **Estimasi Sumber Daya Tambahan M2:** **~150–210 LUT dan 0,5 Tile BRAM (1x RAMB18E1) `[DIASUMSIKAN]`**.

### 4.5 `frame_buffer`
Double buffer: dua bank masing-masing 1024 byte.

| Port | Arah | Lebar | Keterangan |
|---|---|---|---|
| `clk`, `rst` | in | 1 | |
| `w_data`, `w_valid`, `w_ready`, `w_last` | in/in/out/in | 8/1/1/1 | sisi tulis (dari decoder) |
| `swap_req` | in | 1 | terapkan bank baru (dihubungkan ke `frame_tick`) |
| `read_busy` | in | 1 | sink sedang membaca bank depan (dihubungkan ke `ascii_sink.busy`) |
| `r_addr` | in | 10 | alamat byte baca (0 sampai 1023) |
| `r_data` | out | 8 | data baca dari bank depan, latensi tetap (1 siklus BRAM) |
| `frame_valid` | out | 1 | ada frame yang sudah lengkap |
| `underrun` | out | 1 | `frame_tick` datang saat bank belakang belum lengkap (`back_ready = 0`) |

Aturan:
- Penulis mengisi bank belakang; pada mode klip M1, saat byte dengan `w_last` diterima, bank ditandai lengkap (`back_ready = 1`). Pada mode streaming M2, penandaan `back_ready = 1` ditahan dalam status `PENDING_SWAP` sampai paket lengkap diverifikasi (footer `0xED` dan `checksum` cocok sesuai `docs/PROTOCOL.md`).
- Jika checksum atau footer salah pada mode streaming: frame yang rusak dibuang (`drop_req`), pointer tulis kembali ke 0, bank depan tetap menampilkan frame lama tanpa tearing/glitch visual, dan register kesalahan hardware `err_checksum_cnt` bertambah 1.
- Pada pulsa `swap_req`: swap bank hanya dilakukan jika **`back_ready = 1` DAN `read_busy = 0`**.
  - Jika syarat terpenuhi: bank belakang dan depan ditukar, dan `back_ready` kembali 0.
  - Jika `read_busy = 1` saat `swap_req` tiba: swap ditolak. Sink tetap menyelesaikan pembacaan frame lama di bank depan. Bank belakang tetap ditandai penuh (`back_ready = 1`), sehingga `w_ready = 0` dan `frame_source` tertahan (*stall*).
  - Jika `back_ready = 0` saat `swap_req` tiba: terjadi `underrun` (bank tidak ditukar, frame lama di bank depan ditampilkan ulang).
- **Definisi Status:**
  - **`overrun` (di `ascii_sink`):** terjadi saat `frame_tick` / `sink_start` datang ketika sink masih sibuk (`busy = 1` / `read_busy = 1`). Frame baru dilewati dan swap ditolak.
  - **`underrun` (di `frame_buffer`):** terjadi saat `frame_tick` / `swap_req` datang ketika bank belakang belum lengkap (`back_ready = 0`). Frame lama ditampilkan ulang.
- Sisi baca selalu membaca dari bank depan aktif melalui port memori sinkron sederhana (`r_addr` → `r_data`), sehingga sink tidak pernah membaca frame yang setengah tertimpa.

Ukuran: sekitar 16 Kbit untuk dua bank, jauh di bawah total BRAM xc7a35t [asumsi: verifikasi di laporan Vivado].

### 4.5.1 Pemetaan alamat
Alamat byte = `y * (WIDTH/8) + (x / 8)`. Untuk 128×64: 16 byte per baris, 64 baris.

### 4.6 `ascii_sink`
Membaca frame dari buffer dan mengirim aliran karakter sesuai SPEC bagian 5.1.

| Port | Arah | Lebar | Keterangan |
|---|---|---|---|
| `clk`, `rst` | in | 1 | |
| `start` | in | 1 | mulai satu frame (menerima `sink_start` dari `frame_timer`, 1 siklus setelah swap bank) |
| `busy` | out | 1 | sedang mengirim frame |
| `overrun` | out | 1 | `start` datang saat `busy = 1` (frame baru dilewati) |
| `buf_addr`, `buf_data` | out/in | 10/8 | port memori baca ke `frame_buffer` |
| `m_data`, `m_valid`, `m_ready` | out/out/in | 8/1/1 | aliran karakter ke `uart_tx` (tanpa `last`) |

Generic: `WIDTH`, `HEIGHT`, `INVERT`, dan isi ramp (9 karakter).

Urutan kerja untuk satu frame:
1. **Pemicu & Proteksi Overrun:** Saat pulsa `start` diterima: jika `busy = 0`, sink mengunci (*latch*) state bank aktif dan menyetel `busy <= '1'`. Jika `busy = 1`, aktifkan pulsa `overrun` 1 siklus dan abaikan frame baru.
2. **Kursor Terminal:** Kirim urutan ANSI escape `ESC [ H` (3 byte: `0x1B`, `0x5B`, `0x48`) ke `uart_tx` via valid/ready.
3. **Pengolahan & Pengiriman Karakter:**
   Untuk tiap baris teks `cy` (0 sampai 15):
   - Untuk tiap kolom byte `bc` (0 sampai 15): baca 4 byte pada baris piksel `4*cy + r` (r = 0..3) di alamat `(4*cy + r)*16 + bc`. Byte ini dipakai bersama untuk 4 sel berturut-turut `k = 0..3` (kolom teks `cx = 4*bc + k`).
   - Untuk tiap sel `k` (0..3): hitung jumlah bit putih pada posisi bit `7-2k` dan `6-2k` di keempat byte (hasil 0 sampai 8), lalu ambil karakter dari ramp pada indeks itu (atau `8 - indeks` jika `INVERT`). Kirim karakter ke `uart_tx`.
   - Di akhir baris (setelah 64 karakter): kirim `\r\n` (2 byte: `0x0D`, `0x0A`).
4. **Selesai Frame:** Setelah seluruh 16 baris selesai dikirim, turunkan `busy <= '0'`.

Urutan emisi (k = 0..3 dalam tiap `bc`, `bc` naik) memang sama dengan urutan kolom teks `cx`, jadi tidak perlu pengurutan ulang.

Waktu (perkiraan, 1059 byte per frame × 10 bit per byte pada UART 8N1):

| Baud | Waktu kirim per frame | FPS maksimum (secara teoretis) |
|---|---|---|
| 115200 | ±91,9 ms | ±10,9 |
| 460800 | ±23,0 ms | ±43,5 |
| 921600 | ±11,5 ms | ±87 |

Anggaran satu frame pada 30 fps adalah 33,3 ms. 115200 baud tidak cukup. 921600 memakai sekitar sepertiga anggaran. Pembacaan buffer (1024 byte per frame pada 100 MHz) jauh lebih cepat daripada UART, sehingga UART adalah bottleneck-nya.

### 4.7 `audio_out` (M3, kerangka)
Sesuai keputusan tim D-5 (2026-10-31), parameter audio hardware ditetapkan pada **PCM 8-bit 8 kHz mono unsigned** (titik tengah 128, ukuran total 217,84 s $\times$ 8.000 B = 1.742.720 Byte / 13,94 Mbit).
- **Konsekuensi Jalur Output A2 (Audio dari FPGA):** Masuk: aliran sampel PCM 8-bit 8 kHz pada laju `sample_tick`. Keluar: 1 pin PMOD (PWM atau sigma-delta) + filter rekonstruksi RC di luar FPGA + earphone [DIASUMSIKAN sampai ada rangkaian fisik dan batas arus pin diverifikasi dari datasheet]. Logika dekoder ADPCM di hardware dieliminasi penuh sehingga hemat logika.
- **Konsekuensi Jalur Output A1 (Audio dari PC Host):**
  - Status Jalur A1: **diuji di PC nyata (Realtek, MME, 20 s, tanpa board); sinkron audio-video: sinkron (penilaian pengguna)**.
  - Pemutaran audio di PC menggunakan berkas audio asli PCM 16-bit 44,1 kHz stereo (`data/audio/bad_apple.wav`) dan **TIDAK terpengaruh oleh D-5**. Jalur A1 tidak memerlukan modul hardware FPGA ini.
  - Implementasi host PC (`python/audio_player.py`): Menggunakan `sounddevice.RawOutputStream` dengan buffer callback Python (tanpa dependensi numpy pada callback) untuk latency rendah.
  - Sinkronisasi Jam (`AudioClock`): Waktu acuan streaming dihitung dari sampel fisik yang telah keluar dari DAC dengan interpolasi mikrodetik dan fallback anti-stall:
    $$\text{now}() = \text{start\_sec} + \frac{\text{frames\_played}}{\text{sample\_rate}} - \text{output\_latency} + \Delta t_{\text{interp}}$$
  - [DIASUMSIKAN]: celah 1.470 sampel ada di timeline kontainer dan tidak diisi ffmpeg (WAV = 9.380 x 1.024 sampel kontigu); sampel ke-k (k >= 1.024) berada di waktu kontainer k/44100 + 33,33 ms; frame n di 33,33 ms + n/30; maka frame n sejajar WAV pada n/30 [DIASUMSIKAN]; default --av-offset-ms = 0.
  - Video tampil di terminal sekitar [waktu kirim paket + waktu keluaran ASCII ~11,5 ms + latensi render terminal] setelah dikirim, sehingga offset kalibrasi di board kemungkinan negatif [DIASUMSIKAN sampai ada board].
  - Bila opsi `--audio` tidak disertakan pada `stream_player.py`, sistem beralih otomatis ke jam lokal `MonotonicClock` bawaan OS.

### 4.8 `oled_sink` (M4, kerangka)
Membaca `frame_buffer`, mengonversi ke page-addressing SSD1306, dan mengirim lewat master SPI atau I2C (D-7). Dikembangkan terlebih dulu di simulasi memakai model perilaku layar.

### 4.9 `top` (Integrasi Sistem)
Top-level entity (`hdl/top.vhd`) yang mengintegrasikan seluruh subsistem:
- **Jalur Data:** `frame_source` (atau `uart_rx` saat streaming) $\rightarrow$ `decoder` $\rightarrow$ `frame_buffer` $\rightarrow$ `ascii_sink` $\rightarrow$ `uart_tx`.
- **Pengendali Waktu & Mode:**
  - Generic `STREAMING_MODE : boolean := false`: Saat `false` (default M1), `swap_req` dipicu oleh `frame_timer.frame_tick` (30 FPS dari osilator onboard). Saat `true` (M2), `swap_req` dipicu oleh penanda selesai paket frame dari UART RX (PC Master sesuai D-3).
  - Generic `CLK_HZ : integer := 100_000_000`, `BAUD_RATE : integer := 921_600`, `TARGET_FPS : integer := 30`.
- **Clock & Reset:** 1 domain clock 100 MHz oscillator (`clk`), reset asinkron dari tombol `btnC` disinkronkan lewat 2-stage synchronizer (`sync_rst`).
- **Indikator LED Status:**
  - `led[0]`: Detak jantung (1 Hz blink dari bit ke-25 counter clock).
  - `led[1]`: Latched Underrun flag.
  - `led[2]`: Latched Overrun flag.
  - `led[3]`: Sink Busy flag.

#### Hasil Implementasi M1 (Vivado 2026.1, Part xc7a35tcpg236-1) `[DIVERIFIKASI]`
- **Timing:** WNS = **+1.485 ns**, TNS = **0.000 ns** (0 failing endpoints dari 970), WHS = **+0.080 ns**, THS = **0.000 ns** pada 100.000 MHz.
- **Utilisasi Sumber Daya:**
  - Slice LUTs: 2.750 / 20.800 (13,22%) — mencakup 2.606 LUT untuk ROM klip 90 frame (92 KB) yang disintesis dalam logika fabric, 62 LUT untuk timer, 46 LUT untuk sink.
  - Slice Registers (FF): 348 / 41.600 (0,84%).
  - Block RAM Tile: 0,5 Tile (1 $\times$ RAMB18E1) / 50 (1,00%) untuk frame buffer dual-bank.
  - Bonded IOB: 7 / 106 (6,60%) (`clk`, `btnC`, `RsRx`, `RsTx`, `led[0..3]`).
- **Ukuran Bitstream:**
  - Terkompresi: **549.964 byte** (4,40 Mbit / 549.756 byte file `.bin`), kompresi bitstream menghemat 13.138.016 bit (75,0%).
  - Tidak terkompresi: **2.192.221 byte** (17,54 Mbit / 2.192.012 byte file `.bin`).

#### Hasil Implementasi M2b Integrasi Streaming & Delayed Swap `[DIVERIFIKASI]`
- **Timing Pasca-Implementasi (Routed):** WNS = **+1,387 ns**, TNS = **0,000 ns**, WHS = **+0,071 ns**, THS = **0,000 ns** pada 100.000 MHz.
- **Utilisasi Sumber Daya (Total Routed):**
  - Slice LUTs: **3.128** / 20.800 (15,04%)
  - Slice Registers (FF): **618** / 41.600 (1,49%)
  - Block RAM Tile: **1,0 Tile** (2x RAMB18E1) / 50 (2,00%)
  - Bonded IOB: **12** / 106 (`clk`, `btnC`, `sw[0]`, `RsRx`, `RsTx`, `led[0..6]`)
- **Ukuran Bitstream:**
  - Terkompresi M2b: **618.468 byte** (4,95 Mbit), naik +4,77% dari 590.304 B sebelum perbaikan UART RX (variasi routing memengaruhi kompresibilitas [DIASUMSIKAN]).
  - Tidak terkompresi M2b: **2.192.221 byte** (17,54 Mbit / 2.192.012 byte file `.bin`).
- **Prosedur Mode Streaming & Pengaturan Board Fisik [DIASUMSIKAN]:**
  - **Saklar Pemilih Mode (SW0 Pin V17):** Geser saklar `sw[0]` (pin V17) ke '1' (posisi atas) untuk mengaktifkan mode streaming UART RX (M2). Bila `sw[0] = '0'`, sistem beroperasi pada mode pemutaran klip ROM on-chip (M1).
  - **Koneksi Port Serial & Pengaturan FTDI:** Port serial 921.600 baud, 8N1. Pengaturan Latency Timer driver FTDI pada Windows disetel ke 1 ms atau 2 ms untuk mencegah jitter transmisi USB [DIASUMSIKAN].
  - **Perintah Eksekusi Pemutar Host (`python/stream_player.py`):**
    ```powershell
    .\.venv\Scripts\python.exe python/stream_player.py --port COM3 --baud 921600 --clip data/golden/stream_clip.bin --fps 30 --av-offset-ms 0 --no-audio
    ```

---

## 5. Strategi verifikasi

1. **Golden vector dari Python (M0):** ekspor `frames.bin` (format kanonik) dan `ascii.bin` (hasil renderer referensi). File kecil ini boleh di-commit; video sumber dan keluaran besar tidak.
2. **Uji unit per modul:** tiap modul di bagian 4 punya testbench sendiri dengan kasus tepi (awal/akhir frame, `ready` yang naik-turun, reset di tengah transfer).
3. **Model UART di testbench:** sampel `tx` pada laju baud, susun kembali byte, lalu bandingkan dengan `ascii.bin`. Perbandingan harus byte-exact.
4. **Uji integrasi:** `frame_source → decoder → frame_buffer → ascii_sink → uart_tx` pada simulasi penuh dengan klip uji.
5. **Uji di hardware tanpa mengandalkan mata:** skrip Python (pyserial) menangkap N byte dari port serial dan membandingkannya dengan `ascii.bin`. Setelah itu baru dilihat di terminal.
6. **Laporan sumber daya dan timing** dari Vivado dilampirkan pada tiap milestone (tidak boleh ada pelanggaran timing).

---

## 6. Tata letak repo (usulan)

```
docs/        SPEC.md, ARCHITECTURE.md, TASKS.md, DECISIONS.md, RESEARCH.md
python/      ekstraksi, encoder, pemutar terminal, ekspor golden, tes
hdl/         satu folder per modul
sim/         testbench dan model (UART monitor, model SSD1306 nanti)
constraints/ XDC Basys 3
vivado/      skrip pembuat proyek
data/golden/ vektor uji kecil (frames.bin, ascii.bin)
```
Media sumber besar dimasukkan ke `.gitignore`.

---

## 7. Risiko dan mitigasi

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Ramp ASCII terlihat jelek di font tertentu | tampilan kurang enak | ramp dijadikan parameter dan disetel di M0 |
| Underrun UART pada baud rendah | frame terlewat | `overrun` dilaporkan; pakai baud ≥ 460800 |
| Terminal tidak mendukung ANSI | layar berantakan | uji terminal yang dipakai; siapkan mode tanpa ANSI sebagai cadangan |
| Data tidak muat di flash | tidak bisa standalone | keputusan D-9 setelah M0; mode streaming PC tetap ada |
| Akses flash QSPI rumit | M2 tertunda | riset dini; standalone tidak menghalangi MVP |
| Audio dan video drift | tidak sinkron | ukur di M3; opsi sinyal sinkronisasi periodik |
| Tersalah sambung ke earphone | merusak pin atau earphone | rangkaian direview manusia sebelum dihubungkan |
