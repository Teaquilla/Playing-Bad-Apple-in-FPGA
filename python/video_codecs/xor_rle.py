"""Codec Inter-frame XOR + RLE per Baris (Temporal Differencing + RLE).

Memanfaatkan redundansi temporal antar-frame video:
- Frame 0 (Keyframe / I-frame): Dikodekan utuh dengan RLE per baris.
- Frame N (Delta frame / P-frame): Menghitung diff = frame[N] ^ frame[N-1].
  Diff tersebut dikodekan dengan RLE per baris. Sebagian besar baris tanpa perubahan
  akan memiliki run tunggal bernilai 128 bit hitam (1 byte per baris).
- Header per frame:
  [frame_type: uint8 (1=Keyframe, 0=Delta)] + [payload_len: uint16 (big-endian)] + [payload: RLE bytes].
"""

from typing import List, Tuple
import struct
import numpy as np
from canonical import FRAME_WIDTH, FRAME_HEIGHT
from .rle_line import RleLineCodec


class XorRleCodec:
    name: str = "xor_rle"

    @classmethod
    def encode(cls, frames: List[np.ndarray], keyframe_interval: int = 150) -> bytes:
        """Mengodekan daftar frame dengan temporal XOR + RLE.
        
        keyframe_interval: Interval penyisipan keyframe untuk mencegah akumulasi error
        (default 150 frame = setiap 5 detik pada 30 fps).
        """
        if not frames:
            return b""

        encoded_chunks = []
        prev_frame = None

        for idx, frame in enumerate(frames):
            is_keyframe = (idx % keyframe_interval == 0) or (prev_frame is None)

            if is_keyframe:
                frame_to_encode = frame
                frame_type = 1
            else:
                frame_to_encode = np.bitwise_xor(frame, prev_frame)
                frame_type = 0

            # Encode frame_to_encode dengan RLE per baris
            payload_chunks = [RleLineCodec.encode_row(frame_to_encode[y, :]) for y in range(FRAME_HEIGHT)]
            payload = b"".join(payload_chunks)

            # Header: 1 byte type + 2 byte length
            header = struct.pack(">BH", frame_type, len(payload))
            encoded_chunks.append(header + payload)

            prev_frame = frame

        return b"".join(encoded_chunks)

    @classmethod
    def decode(cls, data: bytes, num_frames: int) -> List[np.ndarray]:
        """Mendekode aliran bytes menjadi daftar frame kanonik 2D."""
        frames = []
        prev_frame = None
        offset = 0

        for _ in range(num_frames):
            if offset + 3 > len(data):
                raise ValueError("Header XOR-RLE frame terpotong")

            frame_type, payload_len = struct.unpack(">BH", data[offset : offset + 3])
            cur = offset + 3

            # Decode RLE
            decoded_diff = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
            for y in range(FRAME_HEIGHT):
                row, consumed = RleLineCodec.decode_row(data, cur)
                decoded_diff[y, :] = row
                cur += consumed

            if frame_type == 1 or prev_frame is None:
                # Keyframe
                reconstructed = decoded_diff
            else:
                # Delta frame
                reconstructed = np.bitwise_xor(decoded_diff, prev_frame)

            frames.append(reconstructed)
            prev_frame = reconstructed
            offset += (3 + payload_len)

        return frames
