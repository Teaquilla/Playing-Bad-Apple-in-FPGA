"""Modul Ekstraksi Frame Video ke Format Kanonik 128x64 1-bit (T0.3)."""

from typing import List, Tuple, Dict, Any, Optional
import os
import cv2
import numpy as np

from canonical import pack_frame, FRAME_WIDTH, FRAME_HEIGHT
from binarizer import threshold_binarize, otsu_binarize, floyd_steinberg_dither


def transform_aspect_ratio(
    gray_frame: np.ndarray,
    target_width: int = FRAME_WIDTH,
    target_height: int = FRAME_HEIGHT,
    mode: str = "resize_area"
) -> np.ndarray:
    """Mengubah ukuran dan rasio aspek frame grayscale (H, W) ke kanvas (target_height, target_width).
    
    Mode:
    - 'resize_area' / 'direct': Area resize langsung (ideal untuk sumber 2:1 seperti 1280x640 -> 128x64).
    - 'stretch': Non-linear stretch langsung ke (target_width, target_height).
    - 'letterbox': Menjaga rasio aspek dengan bar hitam di samping (pillarbox).
    - 'crop': Menjaga rasio aspek dengan center crop vertikal tanpa bar hitam.
    """
    src_h, src_w = gray_frame.shape

    if mode in ("resize_area", "direct"):
        return cv2.resize(gray_frame, (target_width, target_height), interpolation=cv2.INTER_AREA)

    elif mode == "stretch":
        return cv2.resize(gray_frame, (target_width, target_height), interpolation=cv2.INTER_AREA)

    elif mode == "letterbox":
        # Fit to height
        scale = target_height / src_h
        scaled_w = int(round(src_w * scale))
        resized = cv2.resize(gray_frame, (scaled_w, target_height), interpolation=cv2.INTER_AREA)

        canvas = np.zeros((target_height, target_width), dtype=np.uint8)
        # Tempatkan di tengah
        start_x = (target_width - scaled_w) // 2
        canvas[:, start_x : start_x + scaled_w] = resized[:, : min(scaled_w, target_width - start_x)]
        return canvas

    elif mode == "crop":
        # Fit to width
        scale = target_width / src_w
        scaled_h = int(round(src_h * scale))
        resized = cv2.resize(gray_frame, (target_width, scaled_h), interpolation=cv2.INTER_AREA)

        # Center crop vertikal
        start_y = max(0, (scaled_h - target_height) // 2)
        return resized[start_y : start_y + target_height, :]

    else:
        raise ValueError(f"Mode rasio aspek tidak dikenal: {mode}. Pilihan: 'resize_area', 'direct', 'stretch', 'letterbox', 'crop'")


def extract_frames(
    video_path: str = "media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4",
    target_fps: int = 30,
    aspect_mode: str = "resize_area",
    threshold: int = 128,
    method: str = "threshold",
    start_sec: float = 0.0,
    duration_sec: Optional[float] = None,
    max_frames: Optional[int] = None,
) -> Tuple[List[np.ndarray], Dict[str, Any]]:
    """Mengekstraksi frame video dari video_path menjadi daftar array 2D 1-bit (64, 128).
    
    Returns:
        (frames_list, metadata_dict)
    """
    if not os.path.exists(video_path):
        raise FileNotFoundError(f"File video tidak ditemukan: {video_path}")

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Gagal membuka video: {video_path}")

    src_fps = cap.get(cv2.CAP_PROP_FPS)
    total_src_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    src_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    src_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    duration_total = total_src_frames / src_fps if src_fps > 0 else 0.0

    # Navigasi ke start_sec
    start_frame_idx = int(round(start_sec * src_fps))
    if start_frame_idx > 0:
        cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame_idx)

    frames = []
    current_src_frame = start_frame_idx
    step = src_fps / target_fps if target_fps > 0 else 1.0

    target_frame_count = None
    if duration_sec is not None:
        target_frame_count = int(round(duration_sec * target_fps))
    if max_frames is not None:
        if target_frame_count is None or max_frames < target_frame_count:
            target_frame_count = max_frames

    accum_frame_float = float(start_frame_idx)

    while True:
        if target_frame_count is not None and len(frames) >= target_frame_count:
            break

        ret, frame = cap.read()
        if not ret:
            break

        # Cek apakah frame saat ini cocok dengan sampling target_fps
        # Jika step ~= 1.0 (karena 30 fps -> 30 fps), setiap frame diproses
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        fitted = transform_aspect_ratio(gray, FRAME_WIDTH, FRAME_HEIGHT, mode=aspect_mode)

        if method == "threshold":
            bin_frame = threshold_binarize(fitted, threshold=threshold)
        elif method == "otsu":
            bin_frame = otsu_binarize(fitted)
        elif method == "dither":
            bin_frame = floyd_steinberg_dither(fitted)
        else:
            raise ValueError(f"Metode binerisasi tidak dikenal: {method}")

        frames.append(bin_frame)
        current_src_frame += 1

    cap.release()

    meta = {
        "video_path": video_path,
        "src_fps": src_fps,
        "target_fps": target_fps,
        "src_width": src_width,
        "src_height": src_height,
        "total_src_frames": total_src_frames,
        "duration_total_sec": duration_total,
        "extracted_frames": len(frames),
        "aspect_mode": aspect_mode,
        "method": method,
        "threshold": threshold,
    }
    return frames, meta


def export_frames_to_bin(frames: List[np.ndarray], output_bin_path: str) -> int:
    """Mengemas daftar frame dan menulisnya ke file binary frames.bin."""
    os.makedirs(os.path.dirname(os.path.abspath(output_bin_path)), exist_ok=True)
    with open(output_bin_path, "wb") as f:
        for frame in frames:
            f.write(pack_frame(frame))
    return len(frames) * 1024
