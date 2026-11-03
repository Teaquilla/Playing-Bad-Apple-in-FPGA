#!/usr/bin/env python3
"""
python/analyze_bench_csv.py
Skrip mandiri untuk menganalisis penyimpangan selang kirim (inter-frame delivery interval deviation)
dari kolom mono_time pada berkas CSV hasil tolok ukur audio_clock.
Menggunakan pustaka standar Python dan NumPy murni.
"""

import csv
import sys
from pathlib import Path
import numpy as np

def analyze_csv(file_path: Path, fps: float = 30.0):
    with open(file_path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if "mono_time" not in reader.fieldnames:
            raise ValueError(f"Kolom 'mono_time' tidak ditemukan dalam {file_path}")
        mono_times = [float(row["mono_time"]) for row in reader]

    mono_arr = np.array(mono_times, dtype=np.float64)
    if len(mono_arr) < 2:
        return 0.0, 0.0, 0.0, 0

    # Hitung selang antar-sampel k dan k-1: delta_t = mono_arr[k] - mono_arr[k-1]
    # Kurangi dengan periode ideal 1/FPS, lalu ubah ke milidetik (ms)
    nominal_period_sec = 1.0 / fps
    diffs_ms = (np.diff(mono_arr) - nominal_period_sec) * 1000.0

    # Abaikan interval frame ke-0 (yaitu diffs_ms[0] = mono[1] - mono[0])
    # yang memuat latensi startup/pre-roll inisialisasi awal.
    # Evaluasi dilakukan untuk interval k >= 2.
    valid_diffs = diffs_ms[1:]
    if len(valid_diffs) == 0:
        return 0.0, 0.0, 0.0, 0

    abs_diffs = np.abs(valid_diffs)
    std_val = float(np.std(valid_diffs))
    p99_val = float(np.percentile(abs_diffs, 99))
    max_val = float(np.max(abs_diffs))

    return std_val, p99_val, max_val, len(valid_diffs)

def main():
    repo_root = Path(__file__).resolve().parent.parent
    bench_dir = repo_root / "data" / "benchmarks"

    if len(sys.argv) > 1:
        target_files = [Path(p) for p in sys.argv[1:]]
    else:
        target_files = sorted(bench_dir.glob("*.csv"))

    if not target_files:
        print("Tidak ada berkas CSV yang ditemukan untuk dianalisis.")
        sys.exit(1)

    print(f"{'Berkas':<28} | {'Std (ms)':<9} | {'P99 |dev| (ms)':<14} | {'Maks |dev| (ms)':<15} | {'N Interval'}")
    print("-" * 80)

    for csv_file in target_files:
        std_v, p99_v, max_v, count = analyze_csv(csv_file)
        name = csv_file.name
        print(f"{name:<28} | {std_v:<9.2f} | {p99_v:<14.2f} | {max_v:<15.2f} | {count}")

if __name__ == "__main__":
    main()
