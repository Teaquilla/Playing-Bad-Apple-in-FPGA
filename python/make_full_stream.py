"""python/make_full_stream.py
Skrip pembuat aliran paket biner Bad Apple!! lengkap (stream_full.bin).
Memakai ulang pustaka modul M0 (python.extractor, python.canonical, python.stream_encoder).

Penggunaan:
  python python/make_full_stream.py [--frames N] [--out PATH] [--media PATH]
"""

from __future__ import annotations
import argparse
import os
import sys
import time
from pathlib import Path

# Pastikan direktori akar repositori ada di sys.path
_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from python.canonical import pack_frame
from python.extractor import extract_frames
from python.stream_encoder import encode_canonical_frame


def make_full_stream(
    media_path: str = "media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4",
    out_path: str = "data/stream_full.bin",
    max_frames: int | None = None,
) -> int:
    """Mengekstraksi frame video dari media_path dan mengodekannya ke aliran paket biner streaming."""
    if not os.path.exists(media_path):
        raise FileNotFoundError(f"Berkas media tidak ditemukan: {media_path}")

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)

    print(f"Mengekstraksi frame dari: {media_path}")
    print(f"Target frame: {'Semua frame' if max_frames is None else max_frames}")
    t0 = time.time()
    frames, meta = extract_frames(
        video_path=media_path,
        target_fps=30,
        start_sec=0.0,
        max_frames=max_frames,
        aspect_mode="resize_area",
        threshold=128,
    )
    t_extract = time.time() - t0
    num_frames = len(frames)
    print(f"Ekstraksi selesai: {num_frames} frame dalam {t_extract:.2f} detik ({num_frames / max(1e-6, t_extract):.1f} FPS)")

    print("Mengodekan frame ke paket streaming RLE...")
    t1 = time.time()
    packets = [encode_canonical_frame(i, pack_frame(f)) for i, f in enumerate(frames)]
    stream_bytes = b"".join(packets)
    t_encode = time.time() - t1
    print(f"Pengodean selesai: {len(stream_bytes):,} byte dalam {t_encode:.2f} detik")

    with open(out_path, "wb") as f:
        f.write(stream_bytes)

    print(f"Berkas stream berhasil disimpan ke: {out_path} ({len(stream_bytes):,} byte, {num_frames} frame)")
    return num_frames


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Buat berkas aliran paket streaming biner Bad Apple!! dari berkas MP4."
    )
    parser.add_argument(
        "--frames",
        type=int,
        default=None,
        help="Jumlah maksimum frame yang diekstraksi dan dikodekan (default: semua frame).",
    )
    parser.add_argument(
        "--out",
        type=str,
        default="data/stream_full.bin",
        help="Jalur berkas biner keluaran stream (default: data/stream_full.bin).",
    )
    parser.add_argument(
        "--media",
        type=str,
        default="media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4",
        help="Jalur berkas video masukan MP4 (default: media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4).",
    )

    args = parser.parse_args()
    make_full_stream(
        media_path=args.media,
        out_path=args.out,
        max_frames=args.frames,
    )


if __name__ == "__main__":
    main()
