"""python/calibrate_av.py
Pembantu kalibrasi interaktif nilai --av-offset-ms pada python/stream_player.py.

Fitur:
1. Menjalankan stream_player.py berurutan untuk daftar --av-offset-ms
   (default: -80,-40,0,40,80), dengan --audio-hostapi wasapi --audio-discipline on
   serta --max-frames 600 per langkah.
2. Menanyakan pengguna 'sinkron? (y/n)' setelah tiap langkah.
3. Mencetak rentang offset yang dinilai sinkron dan menyarankan nilai tengahnya.
4. Mode --dry-run mencetak perintah tanpa menjalankan audio atau subprocess.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))


def parse_offsets(offsets_str: str) -> List[float]:
    """Menguraikan daftar nilai --av-offset-ms dipisahkan koma."""
    tokens = [tok.strip() for tok in offsets_str.split(",") if tok.strip() != ""]
    if not tokens:
        raise ValueError("Daftar --offsets tidak boleh kosong.")
    return [float(tok) for tok in tokens]


def parse_yes_no(raw: str) -> bool:
    """Menguraikan jawaban y/n ('sinkron? (y/n)') menjadi boolean."""
    norm = raw.strip().lower()
    if norm in {"y", "yes", "ya"}:
        return True
    if norm in {"n", "no", "tidak"}:
        return False
    raise ValueError(f"Jawaban harus 'y' atau 'n', didapat: {raw!r}")


def format_offset_arg(offset_ms: float) -> str:
    """Memformat offset integer secara ringkas bila bernilai bulat."""
    return str(int(offset_ms)) if float(offset_ms).is_integer() else str(offset_ms)


def build_stream_player_cmd(
    offset_ms: float,
    port: str = "COM3",
    baud: int = 921600,
    frames: int = 600,
    start_frame: int = 0,
    fps: float = 30.0,
    clip: str = "data/golden/stream_clip.bin",
    audio: str = "data/audio/bad_apple.wav",
    audio_start_sec: float = 10.0,
    fake_fpga: bool = False,
    no_display: bool = False,
    python_exe: str = sys.executable,
) -> List[str]:
    """Menyusun daftar argumen CLI untuk memanggil python/stream_player.py."""
    cmd = [
        python_exe,
        "python/stream_player.py",
        "--port",
        port,
        "--baud",
        str(baud),
        "--clip",
        clip,
        "--audio",
        audio,
        "--audio-start-sec",
        str(audio_start_sec),
        "--audio-hostapi",
        "wasapi",
        "--audio-discipline",
        "on",
        "--fps",
        str(fps),
        "--av-offset-ms",
        format_offset_arg(offset_ms),
        "--start-frame",
        str(start_frame),
        "--max-frames",
        str(frames),
    ]
    if fake_fpga:
        cmd.append("--fake-fpga")
    if no_display:
        cmd.append("--no-display")
    return cmd


def summarize_calibration(sync_offsets: Sequence[float]) -> Dict[str, Any]:
    """Menghitung rentang offset sinkron [min, max] dan nilai tengah yang disarankan."""
    offsets = list(sync_offsets)
    if not offsets:
        return {
            "sync_offsets": [],
            "min_offset": None,
            "max_offset": None,
            "midpoint_offset": None,
        }
    min_off = min(offsets)
    max_off = max(offsets)
    mid_off = (min_off + max_off) / 2.0
    return {
        "sync_offsets": offsets,
        "min_offset": min_off,
        "max_offset": max_off,
        "midpoint_offset": mid_off,
    }


def _prompt_yes_no(prompt: str, input_fn: Callable[[str], str]) -> bool:
    while True:
        raw = input_fn(prompt)
        try:
            return parse_yes_no(raw)
        except ValueError:
            print("Masukan tidak dikenal; ketik 'y' atau 'n'.")


def run_calibration(
    offsets: Sequence[float],
    port: str = "COM3",
    baud: int = 921600,
    frames: int = 600,
    start_frame: int = 0,
    fps: float = 30.0,
    clip: str = "data/golden/stream_clip.bin",
    audio: str = "data/audio/bad_apple.wav",
    audio_start_sec: float = 10.0,
    fake_fpga: bool = False,
    no_display: bool = False,
    dry_run: bool = False,
    answers: Optional[Sequence[str]] = None,
    input_fn: Optional[Callable[[str], str]] = None,
    runner: Callable[..., Any] = subprocess.run,
    python_exe: str = sys.executable,
) -> Dict[str, Any]:
    """Menjalankan sapuan kalibrasi --av-offset-ms dan mengumpulkan penilaian pengguna."""
    commands: List[List[str]] = []
    sync_offsets: List[float] = []
    answer_iter = iter(answers) if answers is not None else None

    for idx, off in enumerate(offsets, start=1):
        cmd = build_stream_player_cmd(
            offset_ms=off,
            port=port,
            baud=baud,
            frames=frames,
            start_frame=start_frame,
            fps=fps,
            clip=clip,
            audio=audio,
            audio_start_sec=audio_start_sec,
            fake_fpga=fake_fpga,
            no_display=no_display,
            python_exe=python_exe,
        )
        commands.append(cmd)
        cmd_str = subprocess.list2cmdline(cmd)

        if dry_run:
            print(f"[DRY-RUN {idx}/{len(offsets)}] offset={format_offset_arg(off)} ms -> {cmd_str}")
        else:
            print(f"[LANGKAH {idx}/{len(offsets)}] Menjalankan offset={format_offset_arg(off)} ms...")
            print(f"  Perintah: {cmd_str}")
            res = runner(cmd, cwd=str(_REPO_ROOT), check=False)
            if getattr(res, "returncode", 0) != 0:
                print(f"  [PERINGATAN] stream_player keluar dengan kode {res.returncode}")

        if answer_iter is not None:
            raw_ans = next(answer_iter)
            is_sync = parse_yes_no(raw_ans)
            print(f"sinkron? (y/n): {raw_ans}")
        elif input_fn is not None:
            is_sync = _prompt_yes_no("sinkron? (y/n): ", input_fn)
        elif dry_run and not sys.stdin.isatty():
            continue
        else:
            is_sync = _prompt_yes_no("sinkron? (y/n): ", input)

        if is_sync:
            sync_offsets.append(off)

    summary = summarize_calibration(sync_offsets)
    summary["commands"] = commands
    summary["dry_run"] = dry_run
    return summary


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Kalibrasi bertahap --av-offset-ms untuk audio laptop WASAPI (--audio-discipline on)."
    )
    parser.add_argument("--port", type=str, default="COM3", help="Port serial UART (default: COM3).")
    parser.add_argument("--baud", type=int, default=921600, help="Laju baud UART (default: 921600).")
    parser.add_argument(
        "--offsets",
        type=str,
        default="-80,-40,0,40,80",
        help="Daftar offset ms dipisahkan koma (default: -80,-40,0,40,80).",
    )
    parser.add_argument("--frames", type=int, default=600, help="Jumlah frame per langkah (default: 600).")
    parser.add_argument("--start-frame", type=int, default=0, help="Indeks frame awal klip (default: 0).")
    parser.add_argument("--fps", type=float, default=30.0, help="Laju frame per detik (default: 30.0).")
    parser.add_argument(
        "--clip",
        type=str,
        default="data/golden/stream_clip.bin",
        help="Berkas aliran paket video biner (default: data/golden/stream_clip.bin; pakai data/stream_full.bin untuk >= 600 frame penuh).",
    )
    parser.add_argument(
        "--audio",
        type=str,
        default="data/audio/bad_apple.wav",
        help="Berkas WAV audio laptop (default: data/audio/bad_apple.wav).",
    )
    parser.add_argument(
        "--audio-start-sec",
        type=float,
        default=10.0,
        help="Posisi awal audio dalam detik (default: 10.0).",
    )
    parser.add_argument(
        "--fake-fpga",
        action="store_true",
        default=False,
        help="Teruskan --fake-fpga ke stream_player.py.",
    )
    parser.add_argument(
        "--no-display",
        action="store_true",
        default=False,
        help="Teruskan --no-display ke stream_player.py.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Cetak daftar perintah stream_player.py tanpa menjalankan audio atau pemutaran.",
    )
    parser.add_argument(
        "--answers",
        type=str,
        default=None,
        help="Daftar jawaban y/n dipisahkan koma (mis. n,y,y,n,n) untuk mode non-interaktif/tes.",
    )
    args = parser.parse_args(argv)

    offsets = parse_offsets(args.offsets)
    parsed_answers: Optional[List[str]] = None
    if args.answers is not None:
        parsed_answers = [a.strip() for a in args.answers.split(",") if a.strip() != ""]
        if len(parsed_answers) != len(offsets):
            raise ValueError(
                f"Jumlah --answers ({len(parsed_answers)}) harus sama dengan jumlah --offsets ({len(offsets)})."
            )

    summary = run_calibration(
        offsets=offsets,
        port=args.port,
        baud=args.baud,
        frames=args.frames,
        start_frame=args.start_frame,
        fps=args.fps,
        clip=args.clip,
        audio=args.audio,
        audio_start_sec=args.audio_start_sec,
        fake_fpga=args.fake_fpga,
        no_display=args.no_display,
        dry_run=args.dry_run,
        answers=parsed_answers,
    )

    print("\n" + "=" * 60)
    print("RINGKASAN KALIBRASI --av-offset-ms [DIASUMSIKAN]:")
    if summary["sync_offsets"]:
        formatted = ", ".join(f"{format_offset_arg(x)} ms" for x in summary["sync_offsets"])
        print(f"Offset sinkron         : {formatted}")
        print(
            f"Rentang sinkron        : {format_offset_arg(summary['min_offset'])} ms s.d. "
            f"{format_offset_arg(summary['max_offset'])} ms"
        )
        print(f"Saran nilai tengah     : {format_offset_arg(summary['midpoint_offset'])} ms")
    else:
        print("Offset sinkron         : (tidak ada yang ditandai sinkron)")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
