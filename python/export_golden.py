"""Ekspor Vektor Golden untuk Simulasi dan Inisialisasi Hardware (TASKS T0.8).

Menghasilkan:
1. data/golden/frames.bin: Format kanonik 1024 byte/frame untuk N frame klip uji.
2. data/golden/ascii.bin: Format keluaran ASCII 1059 byte/frame untuk N frame klip uji.
3. data/golden/clip_bram.hex: File hex teks 1 byte per baris (2 karakter heksadesimal)
   untuk inisialisasi BRAM VHDL (memakai readmemh / Vivado init).
"""

from typing import List, Optional
import os
import numpy as np

from canonical import pack_frame, FRAME_BYTES
from ascii_renderer import render_ascii_frame
from extractor import extract_frames

GOLDEN_DIR: str = "data/golden"


def export_golden_vectors(
    frames: List[np.ndarray],
    output_dir: str = GOLDEN_DIR,
    clip_name: str = "clip_bram"
) -> dict:
    """Mengekspor daftar frame ke frames.bin, ascii.bin, dan clip_bram.hex."""
    os.makedirs(output_dir, exist_ok=True)
    num_frames = len(frames)

    # 1. frames.bin
    frames_bin_path = os.path.join(output_dir, "frames.bin")
    all_packed = b"".join(pack_frame(f) for f in frames)
    with open(frames_bin_path, "wb") as f:
        f.write(all_packed)

    # 2. ascii.bin
    ascii_bin_path = os.path.join(output_dir, "ascii.bin")
    all_ascii = b"".join(render_ascii_frame(f) for f in frames)
    with open(ascii_bin_path, "wb") as f:
        f.write(all_ascii)

    # 3. clip_bram.hex (1 byte per baris, format hex uppercase)
    hex_path = os.path.join(output_dir, f"{clip_name}.hex")
    with open(hex_path, "w", encoding="ascii") as f:
        for b in all_packed:
            f.write(f"{b:02X}\n")

    return {
        "num_frames": num_frames,
        "frames_bin": (frames_bin_path, len(all_packed)),
        "ascii_bin": (ascii_bin_path, len(all_ascii)),
        "hex_file": (hex_path, len(all_packed)),  # jumlah baris
    }


if __name__ == "__main__":
    video_path = "media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4"
    start_sec = 10.0
    duration_sec = 3.0
    print(f"Mengekstraksi klip uji 3 detik representatif (t={start_sec}s..{start_sec+duration_sec}s, 90 frame pada 30 fps)...")
    frames, meta = extract_frames(
        video_path,
        target_fps=30,
        start_sec=start_sec,
        duration_sec=duration_sec,
        aspect_mode="resize_area",
        threshold=128
    )
    res = export_golden_vectors(frames)
    print(f"Selesai! frames.bin: {res['frames_bin'][1]} byte, ascii.bin: {res['ascii_bin'][1]} byte, hex: {res['hex_file'][1]} baris.")

