"""Skrip Penyetelan Ramp ASCII Interaktif (TASKS T0.9).

Menampilkan frame sampel Bad Apple dengan beberapa kandidat ramp ASCII 9-karakter
secara berdampingan di terminal agar tim proyek dapat mengevaluasi dan memilih.
"""

import sys
import os
import cv2
import numpy as np

from extractor import extract_frames, FRAME_WIDTH, FRAME_HEIGHT
from ascii_renderer import render_ascii_frame

# Kandidat ramp 9 karakter (indeks 0=kosong s.d. 8=paling padat)
RAMP_CANDIDATES = {
    "Ramp A (Default SPEC 5.1)": " .:-=+*#@",
    "Ramp B (Kontras Cepat)   ": " .·:+=*#@",
    "Ramp C (Gradasi Halus)   ": " .',:;*#@",
    "Ramp D (Tebal Siluet)    ": "  ..::*@@",
}


def display_side_by_side(frame_pixels: np.ndarray, frame_name: str = ""):
    """Merender 1 frame dengan 4 ramp berbeda dalam tata letak 2x2 atau baris per baris."""
    print("=" * 80)
    print(f"EVALUASI RAMP ASCII UNTUK FRAME: {frame_name}")
    print("=" * 80)

    for label, ramp in RAMP_CANDIDATES.items():
        print(f"\n--- {label} (Ramp: '{ramp}') ---")
        ascii_bytes = render_ascii_frame(frame_pixels, ramp=ramp)
        # Hapus ANSI header \x1b[H untuk pencetakan statis bertahap
        text = ascii_bytes[3:].decode("ascii")
        # Cetak baris dengan indent
        for line in text.splitlines():
            print("  " + line)


def tune_ramps(video_path: str = "media/【東方】Bad Apple!! ＰＶ【影絵】.mp4"):
    sample_indices = [300, 1200, 2500]
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Gagal membuka {video_path}")

    from extractor import transform_aspect_ratio
    from binarizer import threshold_binarize

    for idx in sample_indices:
        cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
        ret, frame = cap.read()
        if not ret:
            continue
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        fitted = transform_aspect_ratio(gray, FRAME_WIDTH, FRAME_HEIGHT, mode="crop")
        bin_frame = threshold_binarize(fitted, threshold=128)

        display_side_by_side(bin_frame, frame_name=f"Frame #{idx}")

    cap.release()
    print("\n" + "=" * 80)
    print("Silakan tinjau tampilan karakter di terminal untuk menentukan pilihan ramp pada T0.10.")
    print("=" * 80)


if __name__ == "__main__":
    tune_ramps()
