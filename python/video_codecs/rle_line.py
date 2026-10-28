"""Codec RLE per Baris (Line-based Run-Length Encoding).

Karakteristik Hardware FPGA:
- Sangat murah: hanya butuh counter kolom 7-bit (0..128) dan 1 flip-flop warna (0/1).
- Error confinement: error tidak merembet antar baris.
- Format per baris:
  Run bergiliran dimulai dari HITAM (0). Jika piksel pertama PUTIH (1), run pertama = 0.
  Tiap panjang run berupa 1 byte uint8 (0..128).
  Saat akumulator panjang run mencapai 128, baris otomatis selesai, warna di-reset ke 0 untuk baris berikutnya.
- Header per frame: 2 byte uint16 (big-endian) panjang payload frame RLE dalam bytes.
"""

from typing import List, Tuple
import struct
import numpy as np
from canonical import FRAME_WIDTH, FRAME_HEIGHT


class RleLineCodec:
    name: str = "rle_line"

    @staticmethod
    def encode_row(row_pixels: np.ndarray) -> bytes:
        """Mengodekan 1 baris (128 piksel) menjadi run lengths uint8 bergiliran dimulai dari 0."""
        runs = []
        expected_color = 0
        current_len = 0

        for pixel in row_pixels:
            val = 1 if pixel > 0 else 0
            if val == expected_color:
                current_len += 1
            else:
                runs.append(current_len)
                expected_color = 1 - expected_color
                current_len = 1
        runs.append(current_len)

        return bytes(runs)

    @staticmethod
    def decode_row(data: bytes, offset: int = 0) -> Tuple[np.ndarray, int]:
        """Mendekode 1 baris piksel (128 piksel) dari data stream byte RLE."""
        row = np.zeros(FRAME_WIDTH, dtype=np.uint8)
        pos = 0
        current_color = 0
        idx = offset

        while pos < FRAME_WIDTH:
            if idx >= len(data):
                raise ValueError("Data RLE terpotong sebelum baris selesai")
            run_len = data[idx]
            idx += 1

            if pos + run_len > FRAME_WIDTH:
                raise ValueError(f"Run length melebihi batas baris 128: pos={pos}, run_len={run_len}")

            if current_color == 1:
                row[pos : pos + run_len] = 1

            pos += run_len
            current_color = 1 - current_color

        return row, (idx - offset)

    @classmethod
    def encode_frame(cls, frame: np.ndarray) -> bytes:
        """Mengodekan 1 frame 128x64. Mengembalikan: 2-byte length + payload RLE."""
        payload_chunks = []
        for y in range(FRAME_HEIGHT):
            payload_chunks.append(cls.encode_row(frame[y, :]))
        payload = b"".join(payload_chunks)
        header = struct.pack(">H", len(payload))
        return header + payload

    @classmethod
    def decode_frame(cls, data: bytes, offset: int = 0) -> Tuple[np.ndarray, int]:
        """Mendekode 1 frame 128x64 dari data stream."""
        if offset + 2 > len(data):
            raise ValueError("Header frame RLE terpotong")
        payload_len = struct.unpack(">H", data[offset : offset + 2])[0]
        cur = offset + 2

        frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
        for y in range(FRAME_HEIGHT):
            row, consumed = cls.decode_row(data, cur)
            frame[y, :] = row
            cur += consumed

        total_consumed = 2 + payload_len
        if cur != offset + total_consumed:
            raise ValueError(f"Payload terbaca ({cur - offset - 2}) != panjang header ({payload_len})")

        return frame, total_consumed

    @classmethod
    def encode(cls, frames: List[np.ndarray]) -> bytes:
        return b"".join(cls.encode_frame(f) for f in frames)

    @classmethod
    def decode(cls, data: bytes, num_frames: int) -> List[np.ndarray]:
        frames = []
        offset = 0
        for _ in range(num_frames):
            frame, consumed = cls.decode_frame(data, offset)
            frames.append(frame)
            offset += consumed
        return frames
