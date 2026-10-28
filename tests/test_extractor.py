import os
import numpy as np
import pytest
from binarizer import threshold_binarize, otsu_binarize, floyd_steinberg_dither
from extractor import transform_aspect_ratio, extract_frames, export_frames_to_bin, FRAME_WIDTH, FRAME_HEIGHT


def test_binarizers():
    gray = np.array([
        [0, 50, 100, 150, 200, 255],
        [30, 80, 130, 180, 220, 250],
    ], dtype=np.uint8)

    th = threshold_binarize(gray, threshold=128)
    assert th.shape == gray.shape
    assert th[0, 2] == 0  # 100 <= 128
    assert th[0, 3] == 1  # 150 > 128

    otsu = otsu_binarize(gray)
    assert otsu.shape == gray.shape
    assert set(np.unique(otsu)).issubset({0, 1})

    fs = floyd_steinberg_dither(gray)
    assert fs.shape == gray.shape
    assert set(np.unique(fs)).issubset({0, 1})


def test_aspect_ratio_transform():
    # Buat dummy frame 480x360 (4:3)
    dummy = np.zeros((360, 480), dtype=np.uint8)

    # Stretch
    st = transform_aspect_ratio(dummy, FRAME_WIDTH, FRAME_HEIGHT, mode="stretch")
    assert st.shape == (FRAME_HEIGHT, FRAME_WIDTH)

    # Letterbox (harus tepat 64x128)
    lb = transform_aspect_ratio(dummy, FRAME_WIDTH, FRAME_HEIGHT, mode="letterbox")
    assert lb.shape == (FRAME_HEIGHT, FRAME_WIDTH)

    # Crop (harus tepat 64x128)
    cr = transform_aspect_ratio(dummy, FRAME_WIDTH, FRAME_HEIGHT, mode="crop")
    assert cr.shape == (FRAME_HEIGHT, FRAME_WIDTH)

    # Resize area / Direct (harus tepat 64x128)
    ra = transform_aspect_ratio(dummy, FRAME_WIDTH, FRAME_HEIGHT, mode="resize_area")
    assert ra.shape == (FRAME_HEIGHT, FRAME_WIDTH)

    di = transform_aspect_ratio(dummy, FRAME_WIDTH, FRAME_HEIGHT, mode="direct")
    assert di.shape == (FRAME_HEIGHT, FRAME_WIDTH)


def test_extract_sample_frames(tmp_path):
    video_path = "media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4"
    if not os.path.exists(video_path):
        pytest.skip(f"Berkas video '{video_path}' tidak ditemukan di direktori media/. Uji ekstraksi dilewati.")
    frames, meta = extract_frames(video_path, max_frames=5, aspect_mode="resize_area", threshold=128)
    assert len(frames) == 5
    assert meta["src_fps"] == 30.0
    assert meta["target_fps"] == 30
    assert frames[0].shape == (FRAME_HEIGHT, FRAME_WIDTH)

    bin_path = str(tmp_path / "test_frames.bin")
    total_bytes = export_frames_to_bin(frames, bin_path)
    assert total_bytes == 5 * 1024
    with open(bin_path, "rb") as f:
        data = f.read()
    assert len(data) == 5 * 1024

