"""Codec Mentah (Raw Canonical) - 1024 byte per frame tanpa kompresi."""

from typing import List
import numpy as np
from canonical import pack_frame, unpack_frame, FRAME_WIDTH, FRAME_HEIGHT, FRAME_BYTES


class RawCodec:
    name: str = "raw"

    @staticmethod
    def encode_frame(frame: np.ndarray) -> bytes:
        return pack_frame(frame)

    @staticmethod
    def decode_frame(data: bytes) -> np.ndarray:
        return unpack_frame(data)

    @staticmethod
    def encode(frames: List[np.ndarray]) -> bytes:
        return b"".join(RawCodec.encode_frame(f) for f in frames)

    @staticmethod
    def decode(data: bytes, num_frames: int) -> List[np.ndarray]:
        frames = []
        for i in range(num_frames):
            chunk = data[i * FRAME_BYTES : (i + 1) * FRAME_BYTES]
            frames.append(RawCodec.decode_frame(chunk))
        return frames
