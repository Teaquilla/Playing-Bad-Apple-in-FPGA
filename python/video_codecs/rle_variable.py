"""Evaluasi Sandi Run-Length Berpanjang Variabel (TASKS Butir 4).

Membandingkan skema pengodean panjang run:
1. RLE Fixed 8-bit (uint8): Tiap run length dikodekan dalam tepat 8 bit (1 byte).
2. Elias-Gamma Coding: Kode universal untuk bilangan bulat k >= 1.
   Panjang k dikodekan dengan floor(log2(k)) bit nol + representasi biner k (total 2*floor(log2(k)) + 1 bit).
   Untuk mengakomodasi run_length = 0 (jika baris mulai dengan putih), dikodekan (k + 1).
3. Exp-Golomb Coding (Order-0 / k=0): Ekivalen dengan Elias-gamma yang digeser.
"""

from typing import List, Tuple
import numpy as np
from canonical import FRAME_WIDTH, FRAME_HEIGHT
from .rle_line import RleLineCodec


def elias_gamma_bit_len(val: int) -> int:
    """Menghitung panjang bit dari nilai integer val >= 0 menggunakan Elias-Gamma (val + 1)."""
    k = val + 1  # k >= 1
    n = k.bit_length() - 1  # floor(log2(k))
    return 2 * n + 1


def prefix_code_bit_len(val: int) -> int:
    """Tabel kode tetap kecil / Nibble prefix:
    Jika val <= 7: prefix '0' (1 bit) + 3 bit nilai = 4 bit (setengah byte).
    Jika val > 7:  prefix '1' (1 bit) + 7 bit nilai (val - 8) = 8 bit (1 byte).
    Dekoder hardware: hanya cek 1 bit! Sangat sederhana.
    """
    if val <= 7:
        return 4
    else:
        return 8


def evaluate_variable_rle(frames: List[np.ndarray]) -> dict:
    """Mengevaluasi total bit untuk RLE Fixed 8-bit, Elias-Gamma, dan Nibble Prefix."""
    total_runs = 0
    total_bits_fixed_8bit = 0
    total_bits_elias_gamma = 0
    total_bits_prefix_code = 0

    run_length_histogram = {}

    for frame in frames:
        for y in range(FRAME_HEIGHT):
            row = frame[y, :]
            runs = []
            expected_color = 0
            current_len = 0
            for pixel in row:
                val = 1 if pixel > 0 else 0
                if val == expected_color:
                    current_len += 1
                else:
                    runs.append(current_len)
                    expected_color = 1 - expected_color
                    current_len = 1
            runs.append(current_len)

            total_runs += len(runs)
            for r in runs:
                run_length_histogram[r] = run_length_histogram.get(r, 0) + 1
                total_bits_fixed_8bit += 8
                total_bits_elias_gamma += elias_gamma_bit_len(r)
                total_bits_prefix_code += prefix_code_bit_len(r)

    # Ditambah framing per frame (2 byte header per frame):
    fixed_total_bits = total_bits_fixed_8bit + len(frames) * 16
    elias_total_bits = total_bits_elias_gamma + len(frames) * 16
    prefix_total_bits = total_bits_prefix_code + len(frames) * 16

    return {
        "num_frames": len(frames),
        "total_runs": total_runs,
        "runs_per_frame": total_runs / max(1, len(frames)),
        "fixed_8bit": {
            "bits": fixed_total_bits,
            "bytes": (fixed_total_bits + 7) // 8,
        },
        "elias_gamma": {
            "bits": elias_total_bits,
            "bytes": (elias_total_bits + 7) // 8,
            "diff_bytes": ((fixed_total_bits + 7) // 8) - ((elias_total_bits + 7) // 8),
            "savings_percent": (1.0 - (elias_total_bits / fixed_total_bits)) * 100.0,
        },
        "prefix_code": {
            "bits": prefix_total_bits,
            "bytes": (prefix_total_bits + 7) // 8,
            "diff_bytes": ((fixed_total_bits + 7) // 8) - ((prefix_total_bits + 7) // 8),
            "savings_percent": (1.0 - (prefix_total_bits / fixed_total_bits)) * 100.0,
        },
        "histogram": run_length_histogram
    }

