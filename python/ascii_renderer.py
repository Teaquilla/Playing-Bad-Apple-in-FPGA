"""Renderer ASCII Referensi (SPEC Bagian 5.1 & TASKS T0.4).

Mengubah frame kanonik 128x64 menjadi aliran karakter ASCII untuk display terminal via UART:
- Blok karakter: 2 piksel lebar x 4 piksel tinggi per karakter.
- Resolusi teks: 64 kolom x 16 baris.
- Level intensitas: jumlah piksel putih dalam blok 2x4 (0 sampai 8) menjadi indeks ke ramp.
- Ramp default: " .:-=+*#@" (9 karakter, indeks 0 sampai 8).
- Header frame: ESC [ H (3 byte, \x1b[H).
- Tiap baris teks: 64 karakter + \r\n (66 byte).
- Panjang total per frame: 3 + 16 * 66 = 1059 byte.
"""

from typing import Union
import numpy as np
from canonical import unpack_frame, FRAME_WIDTH, FRAME_HEIGHT

DEFAULT_RAMP: str = " .:-=+*#@"
ASCII_COLS: int = FRAME_WIDTH // 2   # 64 kolom
ASCII_ROWS: int = FRAME_HEIGHT // 4  # 16 baris
ASCII_FRAME_LEN: int = 3 + ASCII_ROWS * (ASCII_COLS + 2)  # 1059 byte


def render_ascii_frame(
    frame: Union[np.ndarray, bytes],
    ramp: str = DEFAULT_RAMP,
    invert: bool = False
) -> bytes:
    """Mengonversi 1 frame kanonik (array 2D (64, 128) atau 1024 bytes) ke ASCII bytes (1059 bytes)."""
    if isinstance(frame, (bytes, bytearray)):
        pixels = unpack_frame(frame)
    else:
        pixels = (frame > 0).astype(np.uint8)

    if pixels.shape != (FRAME_HEIGHT, FRAME_WIDTH):
        raise ValueError(f"Ukuran frame {pixels.shape} tidak sesuai dengan ({FRAME_HEIGHT}, {FRAME_WIDTH})")

    if len(ramp) != 9:
        raise ValueError(f"Panjang ramp harus 9 karakter (tingkat 0 sampai 8), diterima: {len(ramp)}")

    # Header ANSI kursor pojok atas kiri (ESC [ H)
    out_chunks = [b"\x1b[H"]

    # Proses per baris teks (cy = 0 .. 15)
    for cy in range(ASCII_ROWS):
        row_chars = []
        y_start = cy * 4
        # Ekstrak 4 baris piksel untuk baris teks ini
        block_4rows = pixels[y_start : y_start + 4, :]  # shape: (4, 128)

        # Proses per kolom teks (cx = 0 .. 63)
        for cx in range(ASCII_COLS):
            x_start = cx * 2
            # Blok 2x4 piksel
            sub_block = block_4rows[:, x_start : x_start + 2]
            white_count = int(np.sum(sub_block))  # 0 sampai 8

            idx = (8 - white_count) if invert else white_count
            row_chars.append(ramp[idx])

        row_str = "".join(row_chars) + "\r\n"
        out_chunks.append(row_str.encode("ascii"))

    result = b"".join(out_chunks)
    if len(result) != ASCII_FRAME_LEN:
        raise RuntimeError(f"Panjang keluaran ASCII {len(result)} != {ASCII_FRAME_LEN} byte")
    return result


def render_ascii_frames(
    frames: list[Union[np.ndarray, bytes]],
    ramp: str = DEFAULT_RAMP,
    invert: bool = False
) -> bytes:
    """Mengonversi daftar frame kanonik menjadi aliran keluaran ASCII biner."""
    return b"".join(render_ascii_frame(f, ramp=ramp, invert=invert) for f in frames)
