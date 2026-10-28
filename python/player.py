"""Pemutar Terminal Bad Apple (ASCII, Braille, Half-Block) - TASKS T0.5.

Mendukung 3 mode rendering:
1. 'ascii': 64x16 karakter (blok 2x4 piksel per sel, kontrak SPEC 5.1).
2. 'braille': 64x16 sel Unicode Braille (U+2800..U+28FF, 2x4 piksel per sel resolusi penuh 128x64).
3. 'half-block': 128x32 sel Unicode Half-block (1x2 piksel per sel).

Fitur:
- Rendering bebas flicker menggunakan ANSI cursor home (\x1b[H) dan single buffer flush.
- Timing presisi berbasis time.perf_counter() dengan kompensasi drift.
"""

from typing import List, Union
import sys
import time
import argparse
import numpy as np

from canonical import unpack_frame, FRAME_WIDTH, FRAME_HEIGHT
from ascii_renderer import render_ascii_frame, DEFAULT_RAMP
from extractor import extract_frames


def frame_to_braille(frame: np.ndarray) -> str:
    """Mengonversi frame 128x64 ke teks Unicode Braille 64 kolom x 16 baris.
    
    Pemetaan bit Braille (2x4 piksel per sel):
    dot 1: (x=0, y=0) -> bit 0 (0x01)
    dot 2: (x=0, y=1) -> bit 1 (0x02)
    dot 3: (x=0, y=2) -> bit 2 (0x04)
    dot 4: (x=1, y=0) -> bit 3 (0x08)
    dot 5: (x=1, y=1) -> bit 4 (0x10)
    dot 6: (x=1, y=2) -> bit 5 (0x20)
    dot 7: (x=0, y=3) -> bit 6 (0x40)
    dot 8: (x=1, y=3) -> bit 7 (0x80)
    """
    rows = []
    for cy in range(FRAME_HEIGHT // 4):
        chars = []
        y0 = cy * 4
        for cx in range(FRAME_WIDTH // 2):
            x0 = cx * 2
            b = 0
            if frame[y0 + 0, x0 + 0]: b |= 0x01
            if frame[y0 + 1, x0 + 0]: b |= 0x02
            if frame[y0 + 2, x0 + 0]: b |= 0x04
            if frame[y0 + 0, x0 + 1]: b |= 0x08
            if frame[y0 + 1, x0 + 1]: b |= 0x10
            if frame[y0 + 2, x0 + 1]: b |= 0x20
            if frame[y0 + 3, x0 + 0]: b |= 0x40
            if frame[y0 + 3, x0 + 1]: b |= 0x80
            chars.append(chr(0x2800 + b))
        rows.append("".join(chars))
    return "\x1b[H" + "\n".join(rows) + "\n"


def frame_to_halfblock(frame: np.ndarray) -> str:
    """Mengonversi frame 128x64 ke teks Unicode Half-block 128 kolom x 32 baris.
    
    1x2 piksel per sel teks:
    - 0, 0: ' '
    - 1, 0: '▀' (atas)
    - 0, 1: '▄' (bawah)
    - 1, 1: '█' (penuh)
    """
    rows = []
    for cy in range(FRAME_HEIGHT // 2):
        y0 = cy * 2
        top_row = frame[y0, :]
        bottom_row = frame[y0 + 1, :]
        chars = []
        for x in range(FRAME_WIDTH):
            t = top_row[x]
            b = bottom_row[x]
            if t and b:
                chars.append("█")
            elif t:
                chars.append("▀")
            elif b:
                chars.append("▄")
            else:
                chars.append(" ")
        rows.append("".join(chars))
    return "\x1b[H" + "\n".join(rows) + "\n"


def play_frames(
    frames: List[Union[np.ndarray, bytes]],
    mode: str = "ascii",
    fps: float = 30.0,
    ramp: str = DEFAULT_RAMP,
    loop: bool = False
):
    """Memutar daftar frame kanonik di terminal secara kontinu tanpa flicker."""
    period = 1.0 / fps if fps > 0 else 1.0 / 30.0

    # Pastikan format berupa 2D numpy array
    prepared_frames = []
    for f in frames:
        if isinstance(f, (bytes, bytearray)):
            prepared_frames.append(unpack_frame(f))
        else:
            prepared_frames.append((f > 0).astype(np.uint8))

    # Bersihkan layar sekali di awal dan sembunyikan kursor
    sys.stdout.write("\x1b[2J\x1b[?25l")
    sys.stdout.flush()

    try:
        while True:
            t_start = time.perf_counter()
            for idx, frame in enumerate(prepared_frames):
                t_frame_start = time.perf_counter()

                if mode == "ascii":
                    rendered = render_ascii_frame(frame, ramp=ramp).decode("ascii")
                elif mode == "braille":
                    rendered = frame_to_braille(frame)
                elif mode == "half-block":
                    rendered = frame_to_halfblock(frame)
                else:
                    raise ValueError(f"Mode tidak dikenal: {mode}")

                sys.stdout.write(rendered)
                sys.stdout.flush()

                # Sleep presisi
                elapsed = time.perf_counter() - t_frame_start
                remaining = period - elapsed
                if remaining > 0.001:
                    time.sleep(remaining)

            if not loop:
                break
    finally:
        # Kembalikan kursor
        sys.stdout.write("\x1b[?25h\n")
        sys.stdout.flush()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Bad Apple Terminal Player")
    parser.add_argument("--video", default="media/【東方】Bad Apple!! ＰＶ【影絵】.mp4", help="Path video sumber")
    parser.add_argument("--mode", choices=["ascii", "braille", "half-block"], default="ascii", help="Mode display")
    parser.add_argument("--fps", type=float, default=30.0, help="Target FPS")
    parser.add_argument("--duration", type=float, default=10.0, help="Durasi pemutaran (detik)")
    parser.add_argument("--loop", action="store_true", help="Putar berulang")
    args = parser.parse_args()

    print(f"Mengekstraksi {args.duration} detik dari {args.video}...")
    frames, meta = extract_frames(args.video, target_fps=int(args.fps), duration_sec=args.duration)
    print(f"Memutar {len(frames)} frame dalam mode {args.mode} pada {args.fps} FPS...")
    time.sleep(1)
    play_frames(frames, mode=args.mode, fps=args.fps, loop=args.loop)
