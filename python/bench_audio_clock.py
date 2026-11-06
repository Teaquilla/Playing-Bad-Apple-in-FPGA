"""python/bench_audio_clock.py
Skrip tolok ukur (benchmarking) jam audio PC (AudioClock) terhadap berbagai Host API PortAudio/Windows.

Mengukur:
- Latensi yang dilaporkan driver/hardware
- Audio clock step (min, median, max ms)
- Overshoot jam audio (diff actual vs target: mean, p99, max ms)
- Initial offset (ms)
- Penyimpangan selang kirim monotonik (k>=2 vs 1/FPS: std, p99|dev|, maks|dev|, mean)
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
from typing import Dict, Any, List, Tuple
import numpy as np

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from python.audio_player import SoundDeviceAudio, AudioClock


def compute_delivery_metrics(mono_times: List[float] | np.ndarray, fps: float = 30.0) -> Dict[str, Any]:
    """Menghitung metrik penyimpangan selang kirim identik dengan python/analyze_bench_csv.py."""
    mono_arr = np.array(mono_times, dtype=np.float64)
    if len(mono_arr) < 2:
        return {
            "std": 0.0,
            "p99_abs": 0.0,
            "max_abs": 0.0,
            "mean_signed": 0.0,
            "count": 0,
            "n_gt_16_7": 0,
        }

    nominal_period_sec = 1.0 / fps
    diffs_ms = (np.diff(mono_arr) - nominal_period_sec) * 1000.0

    # Interval frame ke-0 (diffs_ms[0] = mono[1] - mono[0]) diabaikan karena memuat latensi startup
    valid_diffs = diffs_ms[1:]
    if len(valid_diffs) == 0:
        return {
            "std": 0.0,
            "p99_abs": 0.0,
            "max_abs": 0.0,
            "mean_signed": 0.0,
            "count": 0,
            "n_gt_16_7": 0,
        }

    abs_diffs = np.abs(valid_diffs)
    std_val = float(np.std(valid_diffs))
    p99_val = float(np.percentile(abs_diffs, 99))
    max_val = float(np.max(abs_diffs))
    mean_signed = float(np.mean(valid_diffs))
    n_gt_16_7 = int(np.sum(abs_diffs > 16.7))

    return {
        "std": std_val,
        "p99_abs": p99_val,
        "max_abs": max_val,
        "mean_signed": mean_signed,
        "count": len(valid_diffs),
        "n_gt_16_7": n_gt_16_7,
    }


def generate_csv_path(hostapi_name: str, seconds: float, discipline: str, base_path: str | None = None) -> str:
    """Menghasilkan path CSV unik dengan format: {hostapi}_{duration}s_{discipline}_{timestamp}.csv."""
    clean_api = hostapi_name.lower().replace("windows ", "").replace(" ", "_")
    dur_str = f"{int(seconds)}s" if float(seconds).is_integer() else f"{seconds}s"
    ts = time.strftime("%Y%m%d-%H%M%S")
    default_name = f"{clean_api}_{dur_str}_{discipline}_{ts}.csv"

    if base_path is None:
        target_dir = _REPO_ROOT / "data" / "benchmarks"
        target_dir.mkdir(parents=True, exist_ok=True)
        return str(target_dir / default_name)

    p = Path(base_path)
    if p.is_dir() or str(base_path).endswith("/") or str(base_path).endswith("\\"):
        p.mkdir(parents=True, exist_ok=True)
        return str(p / default_name)

    # Jika nama berkas spesifik diberikan, sisipkan cap waktu agar tidak menimpa berkas lama
    if ts not in p.stem:
        target_file = p.parent / f"{p.stem}_{ts}{p.suffix}"
    else:
        target_file = p
    target_file.parent.mkdir(parents=True, exist_ok=True)
    return str(target_file)


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

    # Hitung metrik statistik overshoot jam audio (internal domain audio)
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

    # Hitung metrik penyimpangan selang kirim monotonik yang selaras dengan analyzer (k >= 2)
    mono_times = [r["mono_time"] for r in records]
    n_frames = len(mono_times)

    delivery_metrics = compute_delivery_metrics(mono_times, fps=fps)

    # Hitung residual terhadap garis lurus terbaik untuk k >= 2
    mono_line_residuals: List[float] = []
    std_res = 0.0
    max_res = 0.0

    if n_frames > 2:
        y_vals = [mono_times[k] - (k * frame_interval) for k in range(2, n_frames)]
        a_opt = sum(y_vals) / len(y_vals)

        for k in range(2, n_frames):
            pred_time = a_opt + (k * frame_interval)
            res_ms = (mono_times[k] - pred_time) * 1000.0
            mono_line_residuals.append(res_ms)

        r_count = len(mono_line_residuals)
        if r_count >= 2:
            var_res = sum(r ** 2 for r in mono_line_residuals) / (r_count - 1)
            std_res = math.sqrt(var_res)
            max_res = max(abs(r) for r in mono_line_residuals)

    # Lengkapi catatan per-frame untuk CSV
    for k in range(n_frames):
        if k >= 2:
            dt_mono = (mono_times[k] - mono_times[k - 1] - frame_interval) * 1000.0
            records[k]["mono_interval_dev_ms"] = dt_mono
            records[k]["mono_line_residual_ms"] = mono_line_residuals[k - 2]
        else:
            records[k]["mono_interval_dev_ms"] = 0.0
            records[k]["mono_line_residual_ms"] = 0.0

    # Tentukan nama berkas CSV unik (tidak menimpa berkas)
    actual_csv_path = generate_csv_path(
        hostapi_name=hostapi_name,
        seconds=seconds,
        discipline=discipline,
        base_path=csv_path,
    )

    with open(actual_csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "frame", "target_time", "actual_time", "diff_ms",
                "mono_time", "frames_played", "drift_ppm", "slope_std_err_ppm",
                "mono_interval_dev_ms", "mono_line_residual_ms"
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
        "overshoot_audio_ms": {"mean": mean_diff, "p99": p99_diff, "max": max_diff},
        "delivery_interval_dev_ms": delivery_metrics,
        "mono_line_residual_ms": {"std": std_res, "max": max_res},
        "initial_offset_ms": initial_offset_ms,
        "drift_ppm": drift_ppm,
        "slope_std_err_ppm": se_ppm,
        "callback_flags": flags,
        "csv_path": actual_csv_path,
    }
    return result


def print_single_result(res: Dict[str, Any], run_idx: int = 1, total_runs: int = 1) -> None:
    cb = res["cb_steps_ms"]
    diff = res["overshoot_audio_ms"]
    m_int = res["delivery_interval_dev_ms"]
    m_res = res["mono_line_residual_ms"]
    flags = res["callback_flags"]
    header = f"HASIL TOLOK UKUR JAM AUDIO (Run #{run_idx}/{total_runs})" if total_runs > 1 else "HASIL TOLOK UKUR JAM AUDIO (AudioClock)"
    print("=" * 72)
    print(header)
    print("=" * 72)
    print(f"Host API              : {res['hostapi']} (Device #{res['device_index']}: {res['device_name']})")
    print(f"Durasi Uji            : {res['duration_sec']:.1f} s (Aktual: {res['elapsed_sec']:.2f} s)")
    print(f"Disiplin Jam          : {res['discipline']}")
    print(f"Reported Latency      : {res['reported_latency_ms']:.2f} ms")
    print(f"Initial Offset        : {res['initial_offset_ms']:.2f} ms")
    print(f"Audio Clock Step      : min={cb['min']:.2f} ms, med={cb['med']:.2f} ms, max={cb['max']:.2f} ms")
    print(f"Overshoot Jam Audio   : mean={diff['mean']:+.2f} ms, p99={diff['p99']:+.2f} ms, max={diff['max']:+.2f} ms")
    print(f"Penyimpangan Selang   : std={m_int['std']:.2f} ms, p99|dev|={m_int['p99_abs']:.2f} ms, maks|dev|={m_int['max_abs']:.2f} ms (k>=2)")
    print(f"Rata-rata Selang      : {m_int['mean_signed']:+.2f} ms, Jumlah |dev| > 16.7ms: {m_int['n_gt_16_7']} frame")
    print(f"Residual Garis Mono   : std={m_res['std']:.2f} ms, max={m_res['max']:.2f} ms (k>=2)")
    print(f"Drift Slope           : {res['drift_ppm']:+.1f} ppm +/- {res['slope_std_err_ppm']:.1f} ppm")
    print(f"Callback Flags        : underflow={flags.get('output_underflow', 0)}, overflow={flags.get('output_overflow', 0)}, other={flags.get('other', 0)}")
    print(f"CSV Tersimpan         : {res['csv_path']}")
    print("=" * 72)


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmarking jam audio (AudioClock) Bad Apple!!")
    parser.add_argument("--wav", type=str, default="data/audio/bad_apple.wav", help="Path ke berkas audio WAV")
    parser.add_argument("--seconds", type=float, default=20.0, help="Durasi pengujian dalam detik (default: 20)")
    parser.add_argument("--hostapi", type=str, default="default", help="Nama Host API (mme, directsound, wasapi, default)")
    parser.add_argument("--device", type=int, default=None, help="Device ID sounddevice")
    parser.add_argument("--discipline", choices=["off", "on"], default="off", help="Aktifkan disiplin jam (default: off)")
    parser.add_argument("--fps", type=float, default=30.0, help="Frame rate acuan video (default: 30)")
    parser.add_argument("--csv", type=str, default=None, help="Path berkas CSV keluaran atau direktori target")
    parser.add_argument("--repeat", type=int, default=1, help="Jumlah perulangan pengujian (default: 1)")

    args = parser.parse_args()

    results: List[Dict[str, Any]] = []

    for rep in range(args.repeat):
        if rep > 0:
            print(f"\n[Jeda Antar-Run] Menunggu 3.0 detik sebelum run #{rep + 1}...\n")
            time.sleep(3.0)

        res = run_benchmark(
            wav_path=args.wav,
            seconds=args.seconds,
            hostapi=args.hostapi,
            device=args.device,
            discipline=args.discipline,
            fps=args.fps,
            csv_path=args.csv,
        )
        results.append(res)
        print_single_result(res, run_idx=rep + 1, total_runs=args.repeat)


if __name__ == "__main__":
    main()
