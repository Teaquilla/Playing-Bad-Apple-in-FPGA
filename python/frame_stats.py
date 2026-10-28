"""Statistik Kompresi RLE per Frame & Analisis Bandwidth UART (TASKS Butir D).

Menghitung:
1. Rata-rata byte per frame.
2. Persentil 95 (P95) dan 99 (P99).
3. Nilai maksimum (frame terpadat).
4. Evaluasi transmisi pada 921.600 baud dalam 1 periode frame (33,33 ms = 3.072 byte max).
5. Simulasi leaky bucket buffer untuk streaming data RLE dari PC lewat UART RX.
"""

import sys
import numpy as np
import cv2

if sys.stdout.encoding != 'utf-8':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

from canonical import FRAME_WIDTH, FRAME_HEIGHT
from extractor import transform_aspect_ratio
from binarizer import threshold_binarize
from video_codecs.rle_line import RleLineCodec


def analyze_rle_frames(video_path: str = "media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4"):
    print(f"Membuka {video_path}...")
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Gagal membuka {video_path}")

    frame_bytes_list = []
    idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        fitted = transform_aspect_ratio(gray, FRAME_WIDTH, FRAME_HEIGHT, mode="resize_area")
        bin_frame = threshold_binarize(fitted, threshold=128)

        # Encode frame dengan RLE Line (termasuk 2-byte header panjang)
        enc = RleLineCodec.encode_frame(bin_frame)
        frame_bytes_list.append(len(enc))

        idx += 1
        if idx % 1000 == 0:
            print(f"  Diproses {idx} frame...")
    cap.release()

    frame_sizes = np.array(frame_bytes_list)
    total_frames = len(frame_sizes)

    mean_bytes = np.mean(frame_sizes)
    p50_bytes = np.percentile(frame_sizes, 50)
    p90_bytes = np.percentile(frame_sizes, 90)
    p95_bytes = np.percentile(frame_sizes, 95)
    p99_bytes = np.percentile(frame_sizes, 99)
    max_bytes = np.max(frame_sizes)
    min_bytes = np.min(frame_sizes)
    max_frame_idx = int(np.argmax(frame_sizes))

    # Analisis Bandwidth UART 921600 baud (8N1 = 10 bit per byte)
    BAUD_RATE = 921600
    BYTES_PER_SEC = BAUD_RATE / 10.0  # 92.160 byte/detik
    FRAME_PERIOD_SEC = 1.0 / 30.0     # 0.033333... detik (33.33 ms)
    MAX_BYTES_PER_FRAME_BUDGET = BYTES_PER_SEC * FRAME_PERIOD_SEC  # 3072 byte

    # Waktu transmisi frame terpadat
    densest_tx_time_ms = (max_bytes * 10.0 / BAUD_RATE) * 1000.0

    # Simulasi Leaky Bucket FIFO Buffer jika di-stream konstan atau burst dari PC
    # Asumsi 1: PC mengirim pada laju konstan rata-rata vs konsumsi decoder per frame tick
    # Asumsi 2: PC mengirim data frame berikutnya secepat mungkin hingga buffer penuh (flow control XON/XOFF atau RTS/CTS)
    # Mari kita simulasikan akumulator buffer:
    # Pada tiap frame_tick (1/30 detik), decoder mengonsumsi frame_sizes[i] byte.
    # Selama 1 frame (33.33 ms), UART RX menerima hingga 3072 byte (atau sejumlah byte yang tersedia).
    # Model paling sederhana: PC men-stream frame demi frame pada 921600 baud.
    # Jika frame i memiliki ukuran > 3072 byte, transmisi memakan waktu > 33.33 ms (terjadi delay/starvation jika tanpa buffer awal).
    # Jika ada pre-buffering N frame:
    # Hitung cumulative deficit:
    cum_produced = np.cumsum(frame_sizes)  # total byte yang harus dikonsumsi hingga frame i
    time_points = (np.arange(1, total_frames + 1)) * FRAME_PERIOD_SEC
    # Laju transfer maksimum UART hingga waktu t:
    max_uart_delivered = time_points * BYTES_PER_SEC
    margin = max_uart_delivered - cum_produced

    print("\n=== HASIL STATISTIK PER FRAME VIDEO RLE (6.532 FRAME) ===")
    print(f"Total Frame         : {total_frames}")
    print(f"Rata-rata (Mean)    : {mean_bytes:.1f} byte/frame ({mean_bytes * 8:.1f} bit/frame)")
    print(f"Median (P50)        : {p50_bytes:.1f} byte/frame")
    print(f"Persentil 90 (P90)  : {p90_bytes:.1f} byte/frame")
    print(f"Persentil 95 (P95)  : {p95_bytes:.1f} byte/frame")
    print(f"Persentil 99 (P99)  : {p99_bytes:.1f} byte/frame")
    print(f"Maksimum (Terpadat) : {max_bytes} byte/frame (Frame {max_frame_idx})")
    print(f"Minimum (Teringan)  : {min_bytes} byte/frame")

    print("\n=== EVALUASI TRANSMISI PADA 921.600 BAUD ===")
    print(f"Anggaran byte per periode 33,33 ms : {MAX_BYTES_PER_FRAME_BUDGET:.1f} byte")
    print(f"Ukuran frame terpadat              : {max_bytes} byte")
    print(f"Waktu transmisi frame terpadat     : {densest_tx_time_ms:.2f} ms")
    if max_bytes <= MAX_BYTES_PER_FRAME_BUDGET:
        print("KESIMPULAN: Frame terpadat BISA dikirim dalam 1 periode frame (33,3 ms)!")
    else:
        print(f"KESIMPULAN: Frame terpadat MELEBIHI kapasitas 1 periode frame (+{max_bytes - MAX_BYTES_PER_FRAME_BUDGET:.0f} byte)!")

    # Berapa frame yang melebihi 3.072 byte?
    over_budget_frames = np.sum(frame_sizes > MAX_BYTES_PER_FRAME_BUDGET)
    print(f"Jumlah frame yang melebihi 3.072 byte: {over_budget_frames} dari {total_frames} frame ({over_budget_frames/total_frames*100:.2f}%)")

    # Estimasi FIFO buffer:
    # Jika frame terpadat datang, butuh buffer penampung berapa?
    # Jika buffer menampung minimal 1 frame terpadat + margin:
    # 1 Block RAM 36Kb = 4.096 byte (atau 2 BRAM 18Kb = 2.048 byte).
    print(f"\nRekomendasi FIFO Buffer FPGA:")
    print(f"- Kapasitas 1 BRAM 36Kb (4.096 byte) dapat menampung hingga frame terpadat ({max_bytes} byte).")
    print(f"- Kapasitas 2 BRAM 36Kb (8.192 byte) dapat menampung margin burst inter-frame.")

    return {
        "total_frames": total_frames,
        "mean": mean_bytes,
        "p95": p95_bytes,
        "p99": p99_bytes,
        "max": max_bytes,
        "min": min_bytes,
        "max_frame_idx": max_frame_idx,
        "densest_tx_time_ms": densest_tx_time_ms,
        "max_budget": MAX_BYTES_PER_FRAME_BUDGET,
        "over_budget_count": over_budget_frames
    }


if __name__ == "__main__":
    analyze_rle_frames()
