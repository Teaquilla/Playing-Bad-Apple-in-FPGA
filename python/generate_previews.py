"""Skrip Generator Gambar Pratinjau Komparasi Binerisasi pada Video 2:1 (T0.3)."""

import os
import cv2
import numpy as np

from binarizer import threshold_binarize, floyd_steinberg_dither
from extractor import transform_aspect_ratio, FRAME_WIDTH, FRAME_HEIGHT

PREVIEW_DIR = "data/preview"
SAMPLE_FRAME_INDICES = [300, 1200, 2500, 4200]
DEFAULT_VIDEO = "media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4"


def generate_comparisons(video_path: str = DEFAULT_VIDEO):
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Gagal membuka {video_path}")

    report_lines = []
    report_lines.append(f"# Komparasi Binerisasi Bad Apple (Video 2:1: {os.path.basename(video_path)})\n")

    for idx in SAMPLE_FRAME_INDICES:
        cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
        ret, frame = cap.read()
        if not ret:
            continue

        # Simpan satu frame representatif asli untuk membuktikan ketiadaan bilah hitam
        if idx == 300:
            sample_orig_path = f"{PREVIEW_DIR}/sample_2_1_frame.png"
            cv2.imwrite(sample_orig_path, frame)

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

        # Direct resize area 1280x640 -> 128x64 (native 2:1)
        area_gray = transform_aspect_ratio(gray, FRAME_WIDTH, FRAME_HEIGHT, mode="resize_area")
        bin_thresh = threshold_binarize(area_gray, threshold=128) * 255
        bin_dither = floyd_steinberg_dither(area_gray) * 255

        # Gabungkan berdampingan: Grayscale Resized | Ambang Tetap 128 | Floyd-Steinberg
        comp_bin = np.hstack([area_gray, bin_thresh, bin_dither])
        comp_bin_large = cv2.resize(comp_bin, (comp_bin.shape[1] * 3, comp_bin.shape[0] * 3), interpolation=cv2.INTER_NEAREST)
        bin_filename = f"{PREVIEW_DIR}/compare_binarize_2_1_frame_{idx}.png"
        cv2.imwrite(bin_filename, comp_bin_large)

        # Hitung statistik
        density_thresh = np.mean(bin_thresh > 0)
        density_dither = np.mean(bin_dither > 0)
        transitions_thresh = int(np.sum(np.diff(bin_thresh > 0, axis=1) != 0))
        transitions_dither = int(np.sum(np.diff(bin_dither > 0, axis=1) != 0))

        report_lines.append(f"### Frame {idx}:")
        report_lines.append(f"- Ambang Tetap 128: transisi horizontal = {transitions_thresh}, piksel putih = {density_thresh*100:.1f}%")
        report_lines.append(f"- Dithering FS    : transisi horizontal = {transitions_dither}, piksel putih = {density_dither*100:.1f}%")
        ratio_trans = transitions_dither / max(1, transitions_thresh)
        report_lines.append(f"- Rasio transisi Dither / Ambang: {ratio_trans:.2f}x lebih sering berganti bit\n")

    cap.release()

    report_path = f"{PREVIEW_DIR}/comparison_report_2_1.txt"
    with open(report_path, "w", encoding="utf-8") as f:
        f.write("\n".join(report_lines))

    print(f"Pratinjau binerisasi 2:1 berhasil disimpan di {PREVIEW_DIR}/")
    return report_lines


if __name__ == "__main__":
    generate_comparisons()
