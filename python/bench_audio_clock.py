"""python/bench_audio_clock.py
Skrip tolok ukur (benchmarking) jam audio PC (AudioClock) terhadap berbagai Host API PortAudio/Windows.

Mengukur:
- Latensi yang dilaporkan driver/hardware
- Audio clock step (min, median, max ms)
- Selisih jadwal vs kirim (send vs sched diff: mean, p99, max ms)
- Initial offset (ms)
- Kemiringan drift jam (drift slope ppm ± ketidakpastian std err sigma_ppm)
- Callback flags (output underflow, overflow, dll)
"""

from __future__ import annotations
import argparse
import csv
import math
import os
import sys
import time
from pathlib import Path
from typing import Dict, Any, List

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from python.audio_player import SoundDeviceAudio, AudioClock


def run_benchmark(
    wav_path: str,
    seconds: float = 20.0,
    hostapi: str = "default",
    device: int | None = None,
    discipline: str = "off",
    fps: float = 30.0,
    csv_path: str | None = None,
) -> Dict[str, Any]:
    """Menjalankan tolok ukur AudioClock selama `seconds` detik."""
    import sounddevice as sd

    use_discipline = (discipline.lower() == "on")
    audio_dev = SoundDeviceAudio(
        wav_path=wav_path,
        start_sec=0.0,
        hostapi=hostapi if hostapi != "default" else None,
        device=device,
    )

    dev_index = audio_dev._stream.device
    dev_info = sd.query_devices(dev_index)
    api_info = sd.query_hostapis(dev_info["hostapi"])
    device_name = dev_info["name"]
    hostapi_name = api_info["name"]

    clock = AudioClock(
        device=audio_dev,
        discipline=use_discipline,
        discipline_window_sec=2.0,
    )

    total_frames = int(math.ceil(seconds * fps))
    frame_interval = 1.0 / fps

    clock_diffs: List[float] = []
    cb_steps: List[float] = []
    records: List[Dict[str, Any]] = []

    audio_dev.start()
    t0_mono = time.monotonic()

    # Tunggu callback audio pertama tiba
    while time.monotonic() - t0_mono < 2.0:
        if audio_dev.frames_played() > 0:
            break
        time.sleep(0.001)

    initial_offset_ms = (time.monotonic() - t0_mono) * 1000.0
    last_cb_mono = audio_dev.last_callback_mono()

    start_bench_mono = time.monotonic()

    for k in range(total_frames):
        target_time = k * frame_interval
        clock.sleep_until(target_time)
        t_actual = clock.now()
        cur_mono = time.monotonic()

        diff_ms = (t_actual - target_time) * 1000.0
        clock_diffs.append(diff_ms)

        cb_mono = audio_dev.last_callback_mono()
        if cb_mono != last_cb_mono:
            dt_cb = (cb_mono - last_cb_mono) * 1000.0
            cb_steps.append(dt_cb)
            last_cb_mono = cb_mono

        disc_stats = clock.get_discipline_stats()

        records.append({
            "frame": k,
            "target_time": target_time,
            "actual_time": t_actual,
            "diff_ms": diff_ms,
            "mono_time": cur_mono - start_bench_mono,
            "frames_played": audio_dev.frames_played(),
            "drift_ppm": disc_stats.get("drift_ppm", 0.0),
            "slope_std_err_ppm": disc_stats.get("slope_std_err_ppm", 0.0),
        })

    elapsed_actual = time.monotonic() - start_bench_mono
    reported_latency_ms = audio_dev.output_latency() * 1000.0
    flags = audio_dev.callback_flags()
    disc_final = clock.get_discipline_stats()

    audio_dev.stop()
    audio_dev.close()

    # Hitung metrik statistik
    sorted_diffs = sorted(clock_diffs)
    mean_diff = sum(clock_diffs) / len(clock_diffs) if clock_diffs else 0.0
    p99_idx = int(0.99 * (len(sorted_diffs) - 1)) if sorted_diffs else 0
    p99_diff = sorted_diffs[p99_idx] if sorted_diffs else 0.0
    max_diff = sorted_diffs[-1] if sorted_diffs else 0.0

    cb_min = min(cb_steps) if cb_steps else 0.0
    cb_max = max(cb_steps) if cb_steps else 0.0
    if cb_steps:
        sorted_cb = sorted(cb_steps)
        cb_med = sorted_cb[len(sorted_cb) // 2]
    else:
        cb_med = 0.0

    drift_ppm = disc_final.get("drift_ppm", 0.0)
    se_ppm = disc_final.get("slope_std_err_ppm", 0.0)

    # Simpan CSV jika diminta
    if csv_path:
        csv_file = Path(csv_path)
        csv_file.parent.mkdir(parents=True, exist_ok=True)
        with open(csv_file, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(
                f,
                fieldnames=[
                    "frame", "target_time", "actual_time", "diff_ms",
                    "mono_time", "frames_played", "drift_ppm", "slope_std_err_ppm"
                ],
            )
            writer.writeheader()
            writer.writerows(records)

    result = {
        "hostapi": hostapi_name,
        "device_index": dev_index,
        "device_name": device_name,
        "duration_sec": seconds,
        "elapsed_sec": elapsed_actual,
        "discipline": "on" if use_discipline else "off",
        "reported_latency_ms": reported_latency_ms,
        "cb_steps_ms": {"min": cb_min, "med": cb_med, "max": cb_max},
        "diff_ms": {"mean": mean_diff, "p99": p99_diff, "max": max_diff},
        "initial_offset_ms": initial_offset_ms,
        "drift_ppm": drift_ppm,
        "slope_std_err_ppm": se_ppm,
        "callback_flags": flags,
        "csv_path": csv_path,
    }
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmarking jam audio (AudioClock) Bad Apple!!")
    parser.add_argument("--wav", type=str, default="data/audio/bad_apple.wav", help="Path ke berkas audio WAV")
    parser.add_argument("--seconds", type=float, default=20.0, help="Durasi pengujian dalam detik (default: 20)")
    parser.add_argument("--hostapi", type=str, default="default", help="Nama Host API (mme, directsound, wasapi, default)")
    parser.add_argument("--device", type=int, default=None, help="Device ID sounddevice")
    parser.add_argument("--discipline", choices=["off", "on"], default="off", help="Aktifkan disiplin jam (default: off)")
    parser.add_argument("--fps", type=float, default=30.0, help="Frame rate acuan video (default: 30)")
    parser.add_argument("--csv", type=str, default=None, help="Path berkas CSV keluaran")

    args = parser.parse_args()

    res = run_benchmark(
        wav_path=args.wav,
        seconds=args.seconds,
        hostapi=args.hostapi,
        device=args.device,
        discipline=args.discipline,
        fps=args.fps,
        csv_path=args.csv,
    )

    cb = res["cb_steps_ms"]
    diff = res["diff_ms"]
    flags = res["callback_flags"]
    print("=" * 72)
    print("HASIL TOLOK UKUR JAM AUDIO (AudioClock)")
    print("=" * 72)
    print(f"Host API         : {res['hostapi']} (Device #{res['device_index']}: {res['device_name']})")
    print(f"Durasi Uji       : {res['duration_sec']:.1f} s (Aktual: {res['elapsed_sec']:.2f} s)")
    print(f"Disiplin Jam     : {res['discipline']}")
    print(f"Reported Latency : {res['reported_latency_ms']:.2f} ms")
    print(f"Initial Offset   : {res['initial_offset_ms']:.2f} ms")
    print(f"Audio Clock Step : min={cb['min']:.2f} ms, med={cb['med']:.2f} ms, max={cb['max']:.2f} ms")
    print(f"Send vs Sched    : mean={diff['mean']:+.2f} ms, p99={diff['p99']:+.2f} ms, max={diff['max']:+.2f} ms")
    print(f"Drift Slope      : {res['drift_ppm']:+.1f} ppm +/- {res['slope_std_err_ppm']:.1f} ppm")
    print(f"Callback Flags   : underflow={flags.get('output_underflow', 0)}, overflow={flags.get('output_overflow', 0)}, other={flags.get('other', 0)}")
    if res['csv_path']:
        print(f"CSV Tersimpan    : {res['csv_path']}")
    print("=" * 72)


if __name__ == "__main__":
    main()
