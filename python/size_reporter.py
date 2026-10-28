"""Pembangkit Laporan Ukuran & Komparasi Codec Kompresi 1-Bit (TASKS T0.7).

Menghasilkan tabel metrik total bit, bit per frame, dan rasio kompresi
untuk ketiga kandidat codec (Raw, RleLine, XorRle):
1. Klip Uji 90 frame (3 detik pada 30 fps).
2. Video Lengkap 6.572 frame (219 detik).

Serta analisis kecukupan memori terhadap:
- Sisa Flash Onboard Basys 3: 16.018.336 bit (~1.909 KB / 1,91 MB).
- Total BRAM Artix-7 xc7a35t: 1.800 Kbit (50 x 36Kb = 225 KB).
"""

from typing import List, Dict, Any
import os
import sys
import csv
import cv2
import numpy as np

# Reconfigure stdout for UTF-8 on Windows
if sys.stdout.encoding != 'utf-8':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

from canonical import FRAME_WIDTH, FRAME_HEIGHT, FRAME_BYTES
from extractor import transform_aspect_ratio
from binarizer import threshold_binarize
from video_codecs import RawCodec, RleLineCodec, XorRleCodec
from video_codecs.rle_variable import evaluate_variable_rle

FLASH_REMAINING_BITS: int = 16_018_336  # ~1.9 MB (SPEC Bagian 6)
FLASH_REMAINING_BYTES: int = FLASH_REMAINING_BITS // 8  # 2.002.292 bytes
TOTAL_BRAM_BYTES: int = 225 * 1024  # 230.400 bytes (50 Block RAM 36Kb Artix-7 xc7a35t)


def evaluate_frames(frames: List[np.ndarray], label: str) -> Dict[str, Any]:
    """Mengevaluasi ukuran dan metrik kompresi ketiga codec pada sekumpulan frame."""
    num_frames = len(frames)
    duration_sec = num_frames / 30.0

    # 1. Raw
    raw_bytes = RawCodec.encode(frames)
    raw_size = len(raw_bytes)
    raw_bits = raw_size * 8

    # 2. RLE Line
    rle_bytes = RleLineCodec.encode(frames)
    rle_size = len(rle_bytes)
    rle_bits = rle_size * 8

    # 3. XOR-RLE (keyframe interval 150 = 5 detik)
    xor_bytes = XorRleCodec.encode(frames, keyframe_interval=150)
    xor_size = len(xor_bytes)
    xor_bits = xor_size * 8

    return {
        "label": label,
        "num_frames": num_frames,
        "duration_sec": duration_sec,
        "codecs": {
            "Raw": {
                "bytes": raw_size,
                "bits": raw_bits,
                "bits_per_frame": raw_bits / num_frames,
                "bytes_per_sec": raw_size / duration_sec,
                "ratio": 1.0,
                "fits_flash": raw_size <= FLASH_REMAINING_BYTES,
                "fits_bram": raw_size <= TOTAL_BRAM_BYTES,
            },
            "RLE Line": {
                "bytes": rle_size,
                "bits": rle_bits,
                "bits_per_frame": rle_bits / num_frames,
                "bytes_per_sec": rle_size / duration_sec,
                "ratio": raw_size / rle_size if rle_size > 0 else 0,
                "fits_flash": rle_size <= FLASH_REMAINING_BYTES,
                "fits_bram": rle_size <= TOTAL_BRAM_BYTES,
            },
            "XOR-RLE": {
                "bytes": xor_size,
                "bits": xor_bits,
                "bits_per_frame": xor_bits / num_frames,
                "bytes_per_sec": xor_size / duration_sec,
                "ratio": raw_size / xor_size if xor_size > 0 else 0,
                "fits_flash": xor_size <= FLASH_REMAINING_BYTES,
                "fits_bram": xor_size <= TOTAL_BRAM_BYTES,
            },
        }
    }


def generate_full_report(video_path: str = "media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4"):
    print(f"Membuka {video_path}...")
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Gagal membuka {video_path}")

    total_frames_src = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    print(f"Total frame sumber: {total_frames_src}")

    all_frames = []
    clip_frames = []

    # Klip uji: 3 detik gerak representatif (frame 300 s.d. 389, t=10.0s..13.0s)
    CLIP_START_FRAME = 300
    CLIP_LEN = 90

    print("Mengekstraksi seluruh frame video (mode: resize_area, threshold: 128)...")
    idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        fitted = transform_aspect_ratio(gray, FRAME_WIDTH, FRAME_HEIGHT, mode="resize_area")
        bin_frame = threshold_binarize(fitted, threshold=128)
        all_frames.append(bin_frame)
        if CLIP_START_FRAME <= idx < CLIP_START_FRAME + CLIP_LEN:
            clip_frames.append(bin_frame)
        idx += 1
        if idx % 1000 == 0:
            print(f"  Sudah diekstraksi {idx}/{total_frames_src} frame...")
    cap.release()

    print(f"Selesai ekstraksi: {len(all_frames)} frame.")

    print(f"\nMengevaluasi Klip Uji ({len(clip_frames)} frame / 3 detik, frame {CLIP_START_FRAME}..{CLIP_START_FRAME+CLIP_LEN-1})...")
    clip_eval = evaluate_frames(clip_frames, "Klip Uji (3 Detik, t=10s)")

    print(f"Mengevaluasi Video Penuh ({len(all_frames)} frame / {len(all_frames)/30:.1f} detik)...")
    full_eval = evaluate_frames(all_frames, f"Video Penuh ({len(all_frames)} frame)")

    # Evaluasi sandi panjang variabel
    print("\nMengevaluasi Sandi Panjang Variabel (Elias-Gamma & Nibble-Prefix)...")
    clip_var_rle = evaluate_variable_rle(clip_frames)
    full_var_rle = evaluate_variable_rle(all_frames)

    print(f"\n--- HASIL VARIABLE-LENGTH RLE (FULL VIDEO {len(all_frames)} FRAME) ---")
    print(f"Total runs: {full_var_rle['total_runs']} ({full_var_rle['runs_per_frame']:.1f} run/frame)")
    print(f"Fixed 8-bit RLE : {full_var_rle['fixed_8bit']['bytes']:,} bytes ({full_var_rle['fixed_8bit']['bits']:,} bits)")
    print(f"Elias-Gamma     : {full_var_rle['elias_gamma']['bytes']:,} bytes ({full_var_rle['elias_gamma']['bits']:,} bits), hemat {full_var_rle['elias_gamma']['savings_percent']:.2f}%")
    print(f"Nibble-Prefix   : {full_var_rle['prefix_code']['bytes']:,} bytes ({full_var_rle['prefix_code']['bits']:,} bits), hemat {full_var_rle['prefix_code']['savings_percent']:.2f}%")

    # Simpan ke CSV
    os.makedirs("data", exist_ok=True)
    csv_path = "data/compression_report.csv"
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["Dataset", "Codec", "Frames", "Total Bytes", "Total Bits", "Bits/Frame", "KB/s", "Rasio", "Muat Flash 1.9MB", "Muat BRAM 225KB"])
        for ev in [clip_eval, full_eval]:
            lbl = ev["label"]
            nf = ev["num_frames"]
            for c_name, c_data in ev["codecs"].items():
                writer.writerow([
                    lbl,
                    c_name,
                    nf,
                    c_data["bytes"],
                    c_data["bits"],
                    f"{c_data['bits_per_frame']:.1f}",
                    f"{c_data['bytes_per_sec']/1024:.2f}",
                    f"{c_data['ratio']:.2f}x",
                    "Ya" if c_data["fits_flash"] else "Tidak",
                    "Ya" if c_data["fits_bram"] else "Tidak"
                ])
        # Tambahkan baris untuk varian variable-length RLE
        writer.writerow([
            f"Video Penuh ({len(all_frames)} frame)",
            "RLE Elias-Gamma",
            len(all_frames),
            full_var_rle["elias_gamma"]["bytes"],
            full_var_rle["elias_gamma"]["bits"],
            f"{full_var_rle['elias_gamma']['bits']/len(all_frames):.1f}",
            f"{(full_var_rle['elias_gamma']['bytes']/(len(all_frames)/30))/1024:.2f}",
            f"{full_eval['codecs']['Raw']['bytes']/full_var_rle['elias_gamma']['bytes']:.2f}x",
            "Ya" if full_var_rle["elias_gamma"]["bytes"] <= FLASH_REMAINING_BYTES else "Tidak",
            "Tidak"
        ])
        writer.writerow([
            f"Video Penuh ({len(all_frames)} frame)",
            "RLE Nibble-Prefix (4/8 bit)",
            len(all_frames),
            full_var_rle["prefix_code"]["bytes"],
            full_var_rle["prefix_code"]["bits"],
            f"{full_var_rle['prefix_code']['bits']/len(all_frames):.1f}",
            f"{(full_var_rle['prefix_code']['bytes']/(len(all_frames)/30))/1024:.2f}",
            f"{full_eval['codecs']['Raw']['bytes']/full_var_rle['prefix_code']['bytes']:.2f}x",
            "Ya" if full_var_rle["prefix_code"]["bytes"] <= FLASH_REMAINING_BYTES else "Tidak",
            "Tidak"
        ])

    print(f"\nLaporan CSV disimpan di {csv_path}")
    return clip_eval, full_eval, full_var_rle


if __name__ == "__main__":
    generate_full_report()

