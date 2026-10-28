import numpy as np
import pytest
from canonical import pack_frame, unpack_frame, pack_frames, unpack_frames, FRAME_WIDTH, FRAME_HEIGHT, FRAME_BYTES


def test_frame_size_and_type():
    assert FRAME_WIDTH == 128
    assert FRAME_HEIGHT == 64
    assert FRAME_BYTES == 1024


def test_pack_all_black():
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    packed = pack_frame(frame)
    assert len(packed) == 1024
    assert packed == b"\x00" * 1024


def test_pack_all_white():
    frame = np.ones((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    packed = pack_frame(frame)
    assert len(packed) == 1024
    assert packed == b"\xFF" * 1024


def test_bit_mapping_leftmost_and_rightmost():
    # Bit 7 (MSB) adalah piksel paling kiri (x=0)
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    frame[0, 0] = 1  # Baris 0, kolom 0 (paling kiri)
    packed = pack_frame(frame)
    assert packed[0] == 0b10000000
    assert packed[1:] == b"\x00" * 1023

    # Bit 0 (LSB) adalah piksel ke-7 (x=7, paling kanan dalam byte pertama)
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    frame[0, 7] = 1  # Baris 0, kolom 7
    packed = pack_frame(frame)
    assert packed[0] == 0b00000001
    assert packed[1:] == b"\x00" * 1023

    # Tes kolom berikutnya: x=8 (byte ke-1, bit 7)
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    frame[0, 8] = 1
    packed = pack_frame(frame)
    assert packed[0] == 0x00
    assert packed[1] == 0b10000000

    # Baris kedua: y=1, x=0 (byte ke-16, bit 7)
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    frame[1, 0] = 1
    packed = pack_frame(frame)
    assert packed[16] == 0b10000000


def test_round_trip_random():
    np.random.seed(42)
    random_frame = np.random.randint(0, 2, size=(FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    packed = pack_frame(random_frame)
    assert len(packed) == 1024
    unpacked = unpack_frame(packed)
    assert np.array_equal(random_frame, unpacked)


def test_pack_unpack_frames():
    np.random.seed(123)
    frames = [
        np.random.randint(0, 2, size=(FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
        for _ in range(5)
    ]
    packed = pack_frames(frames)
    assert len(packed) == 5 * 1024
    unpacked = unpack_frames(packed)
    assert len(unpacked) == 5
    for orig, unp in zip(frames, unpacked):
        assert np.array_equal(orig, unp)


def test_invalid_shape():
    with pytest.raises(ValueError):
        pack_frame(np.zeros((64, 64), dtype=np.uint8))
    
    with pytest.raises(ValueError):
        unpack_frame(b"\x00" * 512)
