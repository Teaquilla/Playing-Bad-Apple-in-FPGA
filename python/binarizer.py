"""Modul Binerisasi Citra (Ambang Tetap, Otsu, dan Floyd-Steinberg Dithering)."""

import numpy as np
import cv2


def threshold_binarize(gray_image: np.ndarray, threshold: int = 128) -> np.ndarray:
    """Binerisasi ambang tetap: nilai > threshold menjadi 1, selainnya 0."""
    return (gray_image > threshold).astype(np.uint8)


def otsu_binarize(gray_image: np.ndarray) -> np.ndarray:
    """Binerisasi otomatis dengan metode Otsu."""
    _, bin_img = cv2.threshold(gray_image, 0, 1, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    return bin_img.astype(np.uint8)


def floyd_steinberg_dither(gray_image: np.ndarray) -> np.ndarray:
    """Binerisasi dengan algoritma Floyd-Steinberg Error Diffusion Dithering.
    
    Menghasilkan citra 1-bit (0 atau 1) dengan mendistribusikan galat kuantisasi
    ke tetangga terdekat:
      *       7/16
    3/16 5/16 1/16
    """
    img = gray_image.astype(np.float32).copy()
    h, w = img.shape
    out = np.zeros((h, w), dtype=np.uint8)

    for y in range(h):
        for x in range(w):
            old_val = img[y, x]
            new_val = 255.0 if old_val > 127.5 else 0.0
            out[y, x] = 1 if new_val > 0 else 0
            err = old_val - new_val

            if x + 1 < w:
                img[y, x + 1] += err * (7.0 / 16.0)
            if y + 1 < h:
                if x > 0:
                    img[y + 1, x - 1] += err * (3.0 / 16.0)
                img[y + 1, x] += err * (5.0 / 16.0)
                if x + 1 < w:
                    img[y + 1, x + 1] += err * (1.0 / 16.0)

    return out
