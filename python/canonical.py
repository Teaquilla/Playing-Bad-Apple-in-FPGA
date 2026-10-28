"""Format Frame Kanonik (SPEC Bagian 3).

Kontrak utama pertukaran frame antara modul:
- Ukuran: WIDTH=128, HEIGHT=64.
- Kedalaman: 1 bit per piksel. 1 = putih, 0 = hitam.
- Urutan piksel: row-major (y * WIDTH + x).
- Pengemasan byte: 8 piksel horizontal berurutan sepanjang x per byte.
  Bit 7 (MSB) = piksel paling kiri (x % 8 == 0).
  Bit 0 (LSB) = piksel paling kanan (x % 8 == 7).
- Ukuran frame: WIDTH * HEIGHT / 8 = 1024 byte.
"""

from typing import List
import numpy as np

FRAME_WIDTH: int = 128
FRAME_HEIGHT: int = 64
FRAME_BYTES: int = (FRAME_WIDTH * FRAME_HEIGHT) // 8  # 1024 bytes


def pack_frame(pixels_2d: np.ndarray, width: int = FRAME_WIDTH, height: int = FRAME_HEIGHT) -> bytes:
    """Mengemas array piksel 2D (height, width) bernilai 0/1 atau boolean menjadi bytes kanonik.
    
    Bit 7 adalah piksel paling kiri (x terkecil dalam blok 8 piksel).
    """
    if pixels_2d.shape != (height, width):
        raise ValueError(f"Ukuran frame {pixels_2d.shape} tidak sesuai dengan ({height}, {width})")
    
    # Binarize ke 0 atau 1 uint8
    bin_pixels = (pixels_2d > 0).astype(np.uint8)
    
    # Reshape ke (height, width // 8, 8)
    reshaped = bin_pixels.reshape((height, width // 8, 8))
    
    # Bobot bit: bit 7 di kiri (indeks 0), bit 0 di kanan (indeks 7)
    weights = np.array([128, 64, 32, 16, 8, 4, 2, 1], dtype=np.uint8)
    
    packed_bytes = np.sum(reshaped * weights, axis=2, dtype=np.uint8)
    out_bytes = packed_bytes.tobytes()
    
    expected_len = (width * height) // 8
    if len(out_bytes) != expected_len:
        raise ValueError(f"Panjang bytes kanonik {len(out_bytes)} != {expected_len}")
    
    return out_bytes


def unpack_frame(data: bytes, width: int = FRAME_WIDTH, height: int = FRAME_HEIGHT) -> np.ndarray:
    """Membongkar bytes kanonik menjadi array piksel 2D uint8 (height, width) bernilai 0 atau 1."""
    expected_len = (width * height) // 8
    if len(data) != expected_len:
        raise ValueError(f"Panjang data {len(data)} != {expected_len} byte untuk resolusi {width}x{height}")
    
    raw_bytes = np.frombuffer(data, dtype=np.uint8)
    
    # Unpack 8 bit per byte: bit 7 di posisi pertama
    unpacked_bits = np.unpackbits(raw_bytes)
    return unpacked_bits.reshape((height, width))


def pack_frames(frames: List[np.ndarray], width: int = FRAME_WIDTH, height: int = FRAME_HEIGHT) -> bytes:
    """Mengemas daftar frame menjadi satu aliran bytes."""
    return b"".join(pack_frame(f, width, height) for f in frames)


def unpack_frames(data: bytes, width: int = FRAME_WIDTH, height: int = FRAME_HEIGHT) -> List[np.ndarray]:
    """Membongkar aliran bytes menjadi daftar frame 2D."""
    frame_len = (width * height) // 8
    if len(data) % frame_len != 0:
        raise ValueError(f"Total panjang data {len(data)} bukan kelipatan {frame_len} byte")
    
    num_frames = len(data) // frame_len
    frames = []
    for i in range(num_frames):
        chunk = data[i * frame_len : (i + 1) * frame_len]
        frames.append(unpack_frame(chunk, width, height))
    return frames
