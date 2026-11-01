"""python/extract_audio.py
Mengekstrak trek audio asli dari berkas video MP4 ke PCM16 WAV menggunakan ffmpeg.
Memeriksa metrik audio: jumlah sampel, laju, kanal, durasi, dan posisi sampel non-hening pertama.
"""

from __future__ import annotations
import os
import subprocess
import sys
import wave
import numpy as np
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))


def extract_audio(
    input_video: str,
    output_wav: str
) -> dict:
    if not os.path.exists(input_video):
        raise FileNotFoundError(f"Berkas video input tidak ditemukan: {input_video}")

    os.makedirs(os.path.dirname(os.path.abspath(output_wav)), exist_ok=True)

    # Jalankan ffmpeg untuk ekstraksi audio PCM 16-bit dengan laju dan kanal asli
    cmd = [
        "ffmpeg",
        "-y",
        "-i", input_video,
        "-vn",
        "-acodec", "pcm_s16le",
        output_wav,
    ]

    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"Gagal menjalankan ffmpeg:\n{res.stderr}")

    # Analisis berkas WAV
    with wave.open(output_wav, "rb") as wf:
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()
        raw_frames = wf.readframes(n_frames)

    duration_sec = n_frames / float(framerate)

    # Buka data sebagai array numpy int16
    audio_data = np.frombuffer(raw_frames, dtype=np.int16)
    if n_channels > 1:
        audio_data = audio_data.reshape(-1, n_channels)
        # Cari amplitudo maksimum lintas kanal
        max_amplitude = np.max(np.abs(audio_data), axis=1)
    else:
        max_amplitude = np.abs(audio_data)

    # Ambang batas 0,5% dari skala penuh 16-bit (32768 * 0.005 = 163.84 -> 164)
    threshold = 32768.0 * 0.005
    non_silent_indices = np.where(max_amplitude >= threshold)[0]

    if len(non_silent_indices) > 0:
        first_non_silent_idx = int(non_silent_indices[0])
        first_non_silent_ms = (first_non_silent_idx / float(framerate)) * 1000.0
    else:
        first_non_silent_idx = -1
        first_non_silent_ms = -1.0

    return {
        "channels": n_channels,
        "sample_width_bytes": sampwidth,
        "sample_rate_hz": framerate,
        "total_samples": n_frames,
        "duration_sec": duration_sec,
        "threshold_amplitude": threshold,
        "first_non_silent_sample": first_non_silent_idx,
        "first_non_silent_ms": first_non_silent_ms,
    }


def main():
    root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    video_path = os.path.join(root_dir, "media", "Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4")
    out_wav = os.path.join(root_dir, "data", "audio", "bad_apple.wav")

    print(f"Mengekstrak audio dari: {video_path}")
    metrics = extract_audio(video_path, out_wav)

    print("=" * 60)
    print("METRIK AUDIO TEREKSTRAK (PCM16 WAV):")
    print(f"Berkas Keluaran : {out_wav}")
    print(f"Kanal           : {metrics['channels']} (Stereo)" if metrics['channels'] == 2 else f"Kanal           : {metrics['channels']}")
    print(f"Lebar Sampel    : {metrics['sample_width_bytes'] * 8}-bit")
    print(f"Laju Sampel     : {metrics['sample_rate_hz']} Hz")
    print(f"Total Sampel    : {metrics['total_samples']:,} sampel")
    print(f"Durasi          : {metrics['duration_sec']:.4f} detik")
    print(f"Ambang Deteksi  : 0,5% skala penuh ({metrics['threshold_amplitude']:.2f})")
    print(f"Sampel Aktif 1  : Sampel ke-{metrics['first_non_silent_sample']:,} ({metrics['first_non_silent_ms']:.3f} ms)")
    print("=" * 60)


if __name__ == "__main__":
    main()
