"""Modul Persiapan dan Kuantisasi Audio untuk Basys 3 (TASKS Butir 3).

Mengekstrak audio dari media/, melakukan resampling ke 8.000 Hz mono,
dan melakukan kuantisasi:
1. PCM 8-bit (unsigned 8-bit, 8.000 B/s = 64 kbps).
2. PCM 4-bit (16 tingkat kuantisasi, 4.000 B/s = 32 kbps).

Menyimpan file WAV uji pendengaran di data/preview/:
- audio_8kHz_8bit.wav
- audio_8kHz_4bit.wav (kuantisasi 4-bit dirender ke WAV 8-bit agar dapat diputar player OS)
"""

from typing import Tuple, Dict, Any
import os
import sys
import subprocess
import wave
import numpy as np

# Reconfigure stdout for UTF-8 on Windows
if sys.stdout.encoding != 'utf-8':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

PREVIEW_DIR = "data/preview"
TARGET_SAMPLE_RATE = 8000


def extract_and_convert_audio(
    input_media_path: str = "media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4",
    output_dir: str = PREVIEW_DIR,
    sample_rate: int = TARGET_SAMPLE_RATE
) -> Dict[str, Any]:
    """Mengekstrak audio dari file media ke mono 8 kHz dan menghasilkan WAV 8-bit dan 4-bit."""
    os.makedirs(output_dir, exist_ok=True)

    # Ekstrak audio mentah PCM s16le 8 kHz mono via ffmpeg CLI
    raw_s16_path = os.path.join(output_dir, "temp_audio_8k_s16.raw")
    cmd = [
        "ffmpeg", "-y", "-i", input_media_path,
        "-vn",                      # No video
        "-ac", "1",                 # Mono
        "-ar", str(sample_rate),    # 8000 Hz
        "-f", "s16le",              # Signed 16-bit little-endian
        raw_s16_path
    ]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if res.returncode != 0:
        raise RuntimeError(f"FFmpeg gagal mengekstrak audio: {res.stderr.decode('utf-8', errors='replace')}")

    # Baca sampel PCM 16-bit
    with open(raw_s16_path, "rb") as f:
        raw_bytes = f.read()

    # Hapus file raw sementara
    try:
        os.remove(raw_s16_path)
    except OSError:
        pass

    samples_i16 = np.frombuffer(raw_bytes, dtype=np.int16)
    total_samples = len(samples_i16)
    duration_sec = total_samples / sample_rate

    # Normalisasi ke float [-1.0, 1.0]
    samples_float = samples_i16.astype(np.float32) / 32768.0

    # 1. Kuantisasi PCM 8-bit Unsigned (0..255, titik tengah 128)
    # Range: 0 sampai 255
    samples_u8 = np.clip(np.round((samples_float + 1.0) * 127.5), 0, 255).astype(np.uint8)

    wav_8bit_path = os.path.join(output_dir, "audio_8kHz_8bit.wav")
    with wave.open(wav_8bit_path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(1)  # 1 byte = 8 bit
        w.setframerate(sample_rate)
        w.writeframes(samples_u8.tobytes())

    # 2. Kuantisasi PCM 4-bit (16 tingkat nilai: 0..15)
    # Kuantisasi 4-bit linear
    samples_4bit_levels = np.clip(np.round((samples_float + 1.0) * 7.5), 0, 15).astype(np.uint8)
    # Kemas 2 sampel per byte untuk hardware flash storage
    packed_4bit_bytes = bytearray(total_samples // 2)
    for i in range(total_samples // 2):
        s0 = samples_4bit_levels[2 * i] & 0x0F
        s1 = samples_4bit_levels[2 * i + 1] & 0x0F
        packed_4bit_bytes[i] = (s0 << 4) | s1

    # Untuk evaluasi telinga tim, de-kuantisasi kembali ke 8-bit WAV (tingkat 0..15 dipetakan ke 0..255)
    samples_4bit_reconstructed_u8 = (samples_4bit_levels * 17).astype(np.uint8)
    wav_4bit_path = os.path.join(output_dir, "audio_8kHz_4bit.wav")
    with wave.open(wav_4bit_path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(1)  # Simpan sebagai 8-bit WAV agar kompatibel dengan pemutar OS
        w.setframerate(sample_rate)
        w.writeframes(samples_4bit_reconstructed_u8.tobytes())

    raw_4bit_bin_path = os.path.join(output_dir, "audio_8kHz_4bit_packed.bin")
    with open(raw_4bit_bin_path, "wb") as f:
        f.write(packed_4bit_bytes)

    stats = {
        "sample_rate": sample_rate,
        "total_samples": total_samples,
        "duration_sec": duration_sec,
        "size_8bit_bytes": len(samples_u8),
        "size_8bit_bits": len(samples_u8) * 8,
        "size_4bit_packed_bytes": len(packed_4bit_bytes),
        "size_4bit_packed_bits": len(packed_4bit_bytes) * 8,
        "wav_8bit_path": wav_8bit_path,
        "wav_4bit_path": wav_4bit_path,
    }
    return stats


if __name__ == "__main__":
    st = extract_and_convert_audio()
    print(f"Audio 8 kHz berhasil disiapkan!")
    print(f"Durasi: {st['duration_sec']:.2f} s ({st['total_samples']} sampel)")
    print(f"PCM 8-bit: {st['size_8bit_bytes']} byte ({st['size_8bit_bits']} bit) -> {st['wav_8bit_path']}")
    print(f"PCM 4-bit: {st['size_4bit_packed_bytes']} byte ({st['size_4bit_packed_bits']} bit) -> {st['wav_4bit_path']}")
