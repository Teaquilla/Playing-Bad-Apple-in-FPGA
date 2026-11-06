"""tests/test_bench_audio_clock.py
Pengujian unit untuk menyelaraskan metrik penyimpangan selang kirim antara
python/bench_audio_clock.py dan python/analyze_bench_csv.py menggunakan data sintetis.
"""

import csv
import math
import tempfile
from pathlib import Path
import numpy as np
import pytest

from python.bench_audio_clock import compute_delivery_metrics
from python.analyze_bench_csv import analyze_csv


def test_metrics_alignment_synthetic_data():
    """Memastikan perhitungan std, p99|dev|, maks|dev|, dan jumlah interval cocok bit-exact."""
    np.random.seed(42)
    fps = 30.0
    frame_interval = 1.0 / fps
    n_frames = 600

    # Buat data waktu monotonik sintetis dengan jitter acak dan beberapa spike
    mono_times = [0.0]
    for k in range(1, n_frames):
        jitter = np.random.normal(0.0, 0.003)  # jitter ~3ms
        if k in (50, 150, 300):
            jitter += 0.025  # spike ~25ms
        dt = frame_interval + jitter
        mono_times.append(mono_times[-1] + max(0.001, dt))

    # 1. Hitung langsung via bench_audio_clock
    bench_res = compute_delivery_metrics(mono_times, fps=fps)

    # 2. Tulis ke berkas CSV sementara dan hitung via analyze_bench_csv
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, newline="") as tf:
        temp_csv_path = Path(tf.name)
        writer = csv.DictWriter(tf, fieldnames=["frame", "mono_time"])
        writer.writeheader()
        for i, t in enumerate(mono_times):
            writer.writerow({"frame": i, "mono_time": t})

    try:
        ana_std, ana_p99, ana_max, ana_count = analyze_csv(temp_csv_path, fps=fps)

        # Verifikasi keselarasan matematis identik
        assert bench_res["count"] == ana_count
        assert math.isclose(bench_res["std"], ana_std, abs_tol=1e-9)
        assert math.isclose(bench_res["p99_abs"], ana_p99, abs_tol=1e-9)
        assert math.isclose(bench_res["max_abs"], ana_max, abs_tol=1e-9)
        assert bench_res["count"] == n_frames - 2
    finally:
        if temp_csv_path.exists():
            temp_csv_path.unlink()

