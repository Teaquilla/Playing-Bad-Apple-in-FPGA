# Protokol Paket Streaming UART (docs/PROTOCOL.md)

Dokumen ini merupakan satu-satunya acuan resmi format transmisi streaming frame video dari PC (Host) ke FPGA Basys 3 melalui UART RX (Milestone M2).

---

## 1. Format Paket Data

Setiap frame video dikemas ke dalam satu paket mandiri dengan struktur berurutan sebagai berikut:

| No | Nama Field | Ukuran | Tipe Data | Nilai / Aturan Validasi |
|:---:|:---|:---:|:---:|:---|
| 1 | **SOF** *(Start of Frame)* | 3 Byte | Konstanta | `0x55`, `0xAA`, `0x5A` (penanda awal paket) |
| 2 | **FRAME_ID** | 2 Byte | uint16 (Big-Endian) | `0x0000` s.d. `0x1983` (indeks frame 0 .. 6531) |
| 3 | **PAYLOAD_LEN** | 2 Byte | uint16 (Big-Endian) | $N$, panjang payload RLE dalam bytes ($64 \le N \le 1024$) |
| 4 | **PAYLOAD** | $N$ Byte | Aliran Byte | Data kompresi RLE per baris 8-bit (Fixed 8-bit) |
| 5 | **EOF** *(End of Frame)* | 1 Byte | Konstanta | `0xED` (penanda akhir payload) |
| 6 | **CHECKSUM** | 1 Byte | uint8 | XOR akumulatif 8-bit dari seluruh byte paket antara SOF dan EOF |

**Panjang Total Paket:**
$$\text{Total Bytes} = 3 + 2 + 2 + N + 1 + 1 = N + 9\text{ Byte}$$

---

## 2. Definisi dan Perhitungan Checksum

Checksum dihitung menggunakan operasi Bitwise XOR ($\oplus$) pada seluruh byte yang berada di antara `SOF` dan `CHECKSUM` (yaitu mencakup `FRAME_ID`, `PAYLOAD_LEN`, seluruh $N$ byte `PAYLOAD`, dan penanda `EOF`):

$$\text{CHECKSUM} = \text{FRAME\_ID}[15..8] \oplus \text{FRAME\_ID}[7..0] \oplus \text{LEN}[15..8] \oplus \text{LEN}[7..0] \oplus \left( \bigoplus_{i=0}^{N-1} \text{PAYLOAD}[i] \right) \oplus \text{0xED}$$

### Sifat Verifikasi di Sisi Penerima (FPGA):
Jika penerima (FPGA) menghitung XOR akumulatif terhadap seluruh byte mulai dari `FRAME_ID` hingga `CHECKSUM`, nilai akhir akumulator harus tepat sama dengan `0x00`:
$$\text{Akumulator}_{\text{valid}} = \left( \bigoplus \text{Header} \right) \oplus \left( \bigoplus \text{Payload} \right) \oplus \text{0xED} \oplus \text{CHECKSUM} == \text{0x00}$$

---

## 3. Batas Atas `PAYLOAD_LEN` dan Analisis Ukuran

1. **Batas Teoretis RLE per Baris:**
   - Resolusi kanvas adalah $128 \times 64$ piksel.
   - Pada skema RLE per baris, setiap baris diawali dari warna hitam (0).
   - Kasus terburuk teoretis (pola bolak-balik catur 1-piksel: $0, 1, 0, 1, \dots$): membutuhkan 128 run bernilai 1. Jika baris diawali warna putih, dibutuhkan run awal 0, sehingga maksimal 129 run per baris.
   - Batas maksimum teoretis mutlak: $64 \times 129 = 8.256\text{ Byte}$.
2. **Karakteristik Kompresi & Batas Ukuran Kanonik:**
   - Format frame kanonik tanpa kompresi adalah $128 \times 64 / 8 = 1.024\text{ Byte}$.
   - Algoritma kompresi RLE pada video siluet Bad Apple dirancang untuk mereduksi ukuran di bawah format kanonik ($1.024\text{ Byte}$).
3. **Statistik Data Nyata Bad Apple (6.532 Frame dari `python/frame_stats.py`):**
   - **Frame teringan nyata (Minimum):** **66 Byte** (layar dominan hitam dengan sedikit elemen putih di awal baris).
   - Frame median (P50): **258,0 Byte**.
   - Frame rata-rata: **269,6 Byte**.
   - Persentil 99 (P99): **653,1 Byte**.
   - **Frame terpadat nyata (Maksimum):** **707 Byte** (Frame 1853).
4. **Penetapan Batas Atas Validasi (`PAYLOAD_LEN_MAX`):**
   - Ditetapkan batas atas validasi: **$\text{PAYLOAD\_LEN} \le 1.024\text{ Byte}$** (`PAYLOAD_LEN_MAX = 1024`).
   - Batas ini merupakan **batasan format resmi**. `stream_encoder` wajib melempar galat bila encoding menghasilkan frame $> 1024$ byte. Batas ini 100% aman untuk Bad Apple karena frame terpadat nyata hanya 707 Byte.
   - Batas bawah validasi: **$\text{PAYLOAD\_LEN} \ge 64\text{ Byte}$** (karena 64 baris minimal membutuhkan 1 byte run per baris; frame teringan nyata adalah 66 Byte).

---

## 4. Analisis Waktu Transmisi dan Parameter Timeout Paket

- **Laju UART:** 921.600 baud, 8N1 (1 start bit, 8 data bit, 1 stop bit = 10 bit per byte).
- **Laju Transfer Efektif:** $92.160\text{ Byte/detik} = 92,16\text{ Byte/ms}$.
- **Waktu Transmisi per Paket:**
  - Paket Teringan ($N = 66\text{ B}$, total $75\text{ B}$): $75 / 92,16 \approx \mathbf{0,81\text{ ms}}$.
  - Paket Rata-rata ($N \approx 270\text{ B}$, total $279\text{ B}$): $279 / 92,16 \approx \mathbf{3,03\text{ ms}}$.
  - Paket Terpadat Nyata ($N = 707\text{ B}$, total $716\text{ B}$): $716 / 92,16 \approx \mathbf{7,77\text{ ms}}$.
  - Paket Maksimum Batas ($N = 1024\text{ B}$, total $1033\text{ B}$): $1033 / 92,16 \approx \mathbf{11,21\text{ ms}}$.
- **Anggaran Frame 30 FPS:** $1 / 30\text{ s} = \mathbf{33,33\text{ ms}}$.
  - Frame terpadat hanya mengonsumsi $\mathbf{23,3\%}$ dari anggaran interval 30 FPS.
- **Batas Waktu per Paket (*Packet Timeout*):**
  - Parameter timeout diimplementasikan sebagai parameter generic HDL (`TIMEOUT_CYCLES : integer := 5_000_000`, setara 50 ms pada clock 100 MHz) `[DIASUMSIKAN sampai diukur di board]`.
  - Nilai awal generic diperbesar (50 ms) untuk mengakomodasi jitter penjadwal OS Windows dan latency timer driver FTDI sebelum diukur secara presisi pada perangkat keras fisik.

---

## 5. Arsitektur Buffer RX: FIFO 2 KB dengan Pointer Spekulatif

- **Kebutuhan Ukuran FIFO:**
  Paket terpanjang yang diizinkan memiliki ukuran $1.024 + 9 = 1.033\text{ Byte}$. Untuk mendukung mekanisme pembatalan paket (*rollback*), buffer harus mampu menampung minimal satu paket maksimum penuh ditambah sisa byte sebelumnya.
  Oleh karena itu, ditetapkan **FIFO RX sebesar 2.048 Byte (2 KB)**, yang dipetakan secara optimal ke dalam **1 primitif Block RAM Artix-7 (1x RAMB18E1, konfigurasi 2048 x 8)**.
- **Mekanisme Pointer Terkomit vs Pointer Spekulatif:**
  1. `w_ptr` (Pointer Tulis): Bertambah setiap kali byte serial valid diterima dari `uart_rx`.
  2. `r_ptr_commit` (Pointer Baca Terkomit): Menunjuk ke byte awal paket yang sedang diproses. Byte sebelum `r_ptr_commit` dianggap telah dikeluarkan dari FIFO.
  3. `r_ptr_spec` (Pointer Baca Spekulatif): Bergerak maju membaca byte demi byte (SOF, header, payload, EOF, checksum) untuk disalurkan ke parser dan dekoder.
  4. **Jika Paket Terbukti Valid (`packet_valid = '1'`):**
     - Transaksi dikomit: `r_ptr_commit <= r_ptr_spec`. Seluruh byte paket secara resmi di-pop dari FIFO.
  5. **Jika Terjadi Galat / Sinkron Palsu (`packet_error = '1'`):**
     - Transaksi dibatalkan (*rollback*): `r_ptr_spec <= r_ptr_sof + 1` dan `r_ptr_commit <= r_ptr_sof + 1` (di mana `r_ptr_sof` adalah alamat byte `0x55` pertama).
     - Parser langsung melanjutkan pencarian pola SOF berikutnya mulai dari byte tepat setelah SOF palsu tersebut tanpa kehilangan byte valid yang mungkin beririsan.

---

## 5. Analisis Keunikan Penanda & Penanganan Sinkron Palsu (*False Sync*)

### Koreksi Analisis Keunikan Penanda:
- **Di dalam Payload RLE:**
  - Panjang run per baris bernilai $0 \le L \le 128$.
  - Nilai $0$ s.d. $127$ dikodekan sebagai `0x00` s.d. `0x7F` (bit-7 bernilai `0`).
  - Nilai $128$ dikodekan sebagai `0x80`.
  - Oleh karena itu, nilai `0xAA` (`10101010_2` = 170) dan `0xED` (`11101101_2` = 237) **TIDAK AKAN PERNAH MUNCUL** di dalam byte panjang run RLE.
- **Namun pada Field Header dan Checksum:**
  - Field `FRAME_ID` (2 byte: 0 .. 6531) dan `PAYLOAD_LEN` (2 byte) dapat bernilai apa saja. Sebagai contoh, frame nomor `0x55AA` atau panjang payload `0x00ED` mengandung byte-byte penanda tersebut.
  - Byte `CHECKSUM` adalah hasil XOR yang bernilai acak antara `0x00` dan `0xFF`.
  - Gangguan derau pada kabel serial (noise) atau byte sampah saat kabel dicabut/pasang juga dapat menghasilkan deretan acak yang menyerupai pola `0x55 0xAA 0x5A`.

### Prosedur Deteksi dan Resinkronisasi Sinkron Palsu:
Untuk mencegah FPGA terkunci pada sinkronisasi palsu, FPGA melakukan **validasi bertingkat**:
1. **Validasi Panjang:** Memastikan $64 \le \text{PAYLOAD\_LEN} \le 1.024$.
2. **Validasi EOF:** Memeriksa apakah byte pada offset $(\text{SOF} + 4 + \text{PAYLOAD\_LEN})$ bernilai tepat `0xED`.
3. **Validasi Checksum:** Memverifikasi bahwa hasil XOR akumulatif bernilai `0x00`.

**Aturan Resinkronisasi Kritis:**
> [!IMPORTANT]
> Jika salah satu dari ketiga validasi di atas gagal:
> - Paket dinyatakan **BATAL (Sinkron Palsu)**.
> - FPGA **TIDAK BOLEH** melompati seluruh panjang paket yang salah!
> - Pencarian pola SOF baru **HARUS DILANJUTKAN DARI SATU BYTE SETELAH AWAL SOF PALSU TERSEBUT** (yaitu byte tepat setelah `0x55` pertama yang keliru).
> - Hal ini menjamin bahwa paket valid sejati yang kebetulan beririsan atau diawali pola mirip tidak akan terlewat (*no missed packets*).

---

## 6. Integrasi dengan Double Buffer (Frame Buffer)

1. Dekoder merekonstruksi data kanonik (1.024 byte) ke bank belakang `frame_buffer`.
2. Saat byte ke-1.023 selesai didekode, `frame_buffer` masuk ke status **`PENDING_SWAP`**.
3. Swap buffer **HANYA** dieksekusi saat pulsa `packet_valid` aktif setelah `0xED` dan `CHECKSUM` valid terkonfirmasi.
4. Jika paket korup atau checksum salah:
   - Pulsa `packet_error` aktif.
   - Sinyal `drop_req` mengembalikan pointer tulis bank belakang ke 0.
   - Bank depan **TETAP MENAMPILKAN FRAME LAMA** (mencegah glitch visual atau tearing pada layar terminal).
   - Register kesalahan hardware `err_checksum_cnt` bertambah 1.

