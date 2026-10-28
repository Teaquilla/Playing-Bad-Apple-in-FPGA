import numpy as np
import pytest
from canonical import FRAME_WIDTH, FRAME_HEIGHT
from video_codecs import RawCodec, RleLineCodec, XorRleCodec



@pytest.fixture
def sample_frames():
    np.random.seed(42)
    frames = []
    # Frame 0: Pola garis
    f0 = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    f0[::2, :] = 1
    frames.append(f0)

    # Frame 1: Perubahan kecil dari frame 0
    f1 = f0.copy()
    f1[10:20, 30:50] = 1
    frames.append(f1)

    # Frame 2: Perubahan kecil lainnya
    f2 = f1.copy()
    f2[15:25, 40:60] = 0
    frames.append(f2)

    # Frame 3: Seluruh hitam
    frames.append(np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8))

    # Frame 4: Seluruh putih
    frames.append(np.ones((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8))

    # Frame 5: Acak
    frames.append(np.random.randint(0, 2, size=(FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8))

    return frames


def test_raw_codec_roundtrip(sample_frames):
    encoded = RawCodec.encode(sample_frames)
    assert len(encoded) == len(sample_frames) * 1024
    decoded = RawCodec.decode(encoded, len(sample_frames))
    assert len(decoded) == len(sample_frames)
    for orig, dec in zip(sample_frames, decoded):
        assert np.array_equal(orig, dec)


def test_rle_line_codec_roundtrip(sample_frames):
    encoded = RleLineCodec.encode(sample_frames)
    decoded = RleLineCodec.decode(encoded, len(sample_frames))
    assert len(decoded) == len(sample_frames)
    for orig, dec in zip(sample_frames, decoded):
        assert np.array_equal(orig, dec)


def test_xor_rle_codec_roundtrip(sample_frames):
    encoded = XorRleCodec.encode(sample_frames, keyframe_interval=3)
    decoded = XorRleCodec.decode(encoded, len(sample_frames))
    assert len(decoded) == len(sample_frames)
    for orig, dec in zip(sample_frames, decoded):
        assert np.array_equal(orig, dec)


def test_variable_rle_evaluator(sample_frames):
    from video_codecs.rle_variable import evaluate_variable_rle, elias_gamma_bit_len, prefix_code_bit_len
    res = evaluate_variable_rle(sample_frames)
    assert res["num_frames"] == len(sample_frames)
    assert res["total_runs"] > 0
    assert res["fixed_8bit"]["bytes"] > 0
    assert res["elias_gamma"]["bytes"] > 0
    assert res["prefix_code"]["bytes"] > 0
    # Cek fungsi individual
    assert elias_gamma_bit_len(0) == 1
    assert elias_gamma_bit_len(1) == 3
    assert elias_gamma_bit_len(128) == 15
    assert prefix_code_bit_len(0) == 4
    assert prefix_code_bit_len(7) == 4
    assert prefix_code_bit_len(8) == 8
    assert prefix_code_bit_len(128) == 8

