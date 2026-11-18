"""python/auto_player.py
Mode standby & remote control PC untuk memutar Bad Apple!! penuh secara otomatis
saat saklar SW0 pada Basys 3 digeser dari 0 ke 1, lengkap dengan kendali 5 tombol
Basys 3 (RsTx -> PC):
  - btnU (0x11): Play / Pause
  - btnR (0x12): Forward +5 detik (+150 frame @ 30 FPS)
  - btnL (0x13): Backward -5 detik (-150 frame @ 30 FPS)
  - btnC (0x14): Reset FPGA & Restart Video + Audio ke 00:00
  - btnD (0x15): Stop & kembali ke mode standby
"""

from __future__ import annotations

import argparse
from collections import deque
import os
import sys
import threading
import time
from pathlib import Path
from typing import Callable, Deque, Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from python.audio_player import AudioClock, AudioDevice, SoundDeviceAudio
from python.board_check import select_serial_port
from python.stream_player import (
    Clock,
    MonotonicClock,
    SerialTransport,
    StreamPlayer,
    Transport,
    split_stream_into_packets,
)

DEFAULT_STREAM_FILE = "data/stream_full.bin"
DEFAULT_AUDIO_FILE = "data/audio/bad_apple.wav"

CMD_PLAY_PAUSE = 0x11  # btnU
CMD_FWD_5S = 0x12      # btnR
CMD_BWD_5S = 0x13      # btnL
CMD_RESTART = 0x14     # btnC (saat SW0=1)
CMD_STOP = 0x15        # btnD
CONTROL_BYTES = frozenset({CMD_PLAY_PAUSE, CMD_FWD_5S, CMD_BWD_5S, CMD_RESTART, CMD_STOP})


def split_control_bytes(data: bytes) -> Tuple[bytes, List[int]]:
    """Memisahkan byte kontrol tombol (0x11..0x15) dari aliran karakter ASCII terminal."""
    if not data:
        return b"", []
    # Fast-path: sebagian besar chunk murni ASCII tanpa byte kontrol
    if not any(b in CONTROL_BYTES for b in data):
        return data, []

    ascii_buf = bytearray()
    cmds: List[int] = []
    for b in data:
        if b in CONTROL_BYTES:
            cmds.append(b)
        else:
            ascii_buf.append(b)
    return bytes(ascii_buf), cmds


def _format_mmss(frame_idx: int, fps: float) -> str:
    sec = max(0, int(round(frame_idx / max(1.0, fps))))
    return f"{sec // 60:02d}:{sec % 60:02d}"


def _enter_pressed() -> bool:
    """Memeriksa tombol Enter non-blocking di terminal Windows."""
    try:
        import msvcrt

        while msvcrt.kbhit():
            ch = msvcrt.getwch()
            if ch in ("\r", "\n"):
                return True
    except Exception:
        pass
    return False


def wait_for_sw0_trigger(
    transport: Transport,
    min_active_bytes: int = 64,
    silence_sec: float = 0.25,
    poll_interval_sec: float = 0.02,
    idle_hint_sec: float = 2.0,
    now_fn: Callable[[], float] = time.monotonic,
    sleep_fn: Callable[[float], None] = time.sleep,
    key_trigger_fn: Optional[Callable[[], bool]] = _enter_pressed,
    on_status: Optional[Callable[[str], None]] = print,
    show_standby_ascii: bool = False,
) -> str:
    """Menunggu transisi SW0: 0 -> 1 pada jalur RsTx FPGA (atau trigger tombol Enter)."""
    seen_bytes = 0
    active_announced = False
    hint_announced = False
    start_time = now_fn()
    last_rx_time: Optional[float] = None

    while True:
        chunk = transport.read(4096)
        ascii_chunk, _ = split_control_bytes(chunk)
        now = now_fn()

        if ascii_chunk:
            seen_bytes += len(ascii_chunk)
            last_rx_time = now
            if show_standby_ascii:
                sys.stdout.buffer.write(ascii_chunk)
                sys.stdout.buffer.flush()
            elif not active_announced and seen_bytes >= min_active_bytes:
                active_announced = True
                if on_status:
                    on_status(
                        "\n[STANDBY] Klip ROM (SW0=0) terdeteksi aktif di FPGA.\n"
                        "          Geser saklar SW0 ke ATAS (1) kapan saja untuk langsung memutar video penuh!"
                    )
        else:
            if (
                seen_bytes >= min_active_bytes
                and last_rx_time is not None
                and (now - last_rx_time) >= silence_sec
            ):
                if on_status:
                    on_status("\n[TRIGGER] SW0=1 terdeteksi! Memulai pemutaran penuh + audio...")
                return "sw0_switch"

            if (
                seen_bytes < min_active_bytes
                and not hint_announced
                and (now - start_time) >= idle_hint_sec
            ):
                hint_announced = True
                if on_status:
                    on_status(
                        "\n[MENUNGGU] Belum ada aliran klip dari FPGA (mungkin SW0 sudah di posisi 1).\n"
                        "           Geser SW0 ke BAWAH (0) sebentar lalu ke ATAS (1), "
                        "atau tekan ENTER untuk langsung mulai."
                    )

            if key_trigger_fn is not None and key_trigger_fn():
                if on_status:
                    on_status("\n[TRIGGER] Tombol ENTER ditekan! Memulai pemutaran penuh + audio...")
                return "manual_key"

            sleep_fn(poll_interval_sec)


def drain_transport(transport: Transport, max_rounds: int = 8) -> None:
    """Mengosongkan sisa byte lama di buffer RX serial sebelum sesi streaming dimulai."""
    for _ in range(max_rounds):
        if not transport.read(4096):
            break


def _default_audio_factory(
    wav_path: str,
    start_sec: float,
    hostapi: str,
    discipline: bool,
) -> Tuple[AudioDevice, Clock]:
    audio_dev = SoundDeviceAudio(wav_path, start_sec=start_sec, hostapi=hostapi)
    clock = AudioClock(audio_dev, stall_timeout_sec=0.1, discipline=discipline)
    return audio_dev, clock


def run_playback_with_controls(
    transport: Transport,
    packets: List[bytes],
    audio_path: Optional[str],
    audio_hostapi: str = "wasapi",
    audio_discipline: str = "on",
    fps: float = 30.0,
    av_offset_ms: float = 0.0,
    seek_seconds: float = 5.0,
    no_display: bool = False,
    audio_factory: Optional[Callable[[str, float, str, bool], Tuple[AudioDevice, Clock]]] = None,
    clock_factory: Optional[Callable[[], Clock]] = None,
    on_status: Optional[Callable[[str], None]] = print,
    on_ascii: Optional[Callable[[bytes], None]] = None,
    sleep_fn: Callable[[float], None] = time.sleep,
) -> Dict[str, object]:
    """Memutar video & audio dengan dukungan jeda, seek +/-5s, restart, dan stop dari tombol FPGA."""
    drain_transport(transport)
    if not packets:
        return {"outcome": "finished", "sent_frames": 0, "dropped_frames": 0, "received_bytes": 0}

    seek_step = max(1, int(round(seek_seconds * fps)))
    frame_idx = 0
    paused = False
    total_sent = 0
    total_dropped = 0
    total_rx = 0
    cmd_queue: Deque[int] = deque()
    cmd_lock = threading.Lock()

    make_audio = audio_factory or _default_audio_factory
    make_clock = clock_factory or MonotonicClock

    def emit_ascii(raw_ascii: bytes) -> None:
        if not raw_ascii or no_display:
            return
        if on_ascii is not None:
            on_ascii(raw_ascii)
        else:
            sys.stdout.buffer.write(raw_ascii)
            sys.stdout.buffer.flush()

    def pop_cmd() -> Optional[int]:
        with cmd_lock:
            return cmd_queue.popleft() if cmd_queue else None

    while frame_idx < len(packets):
        if paused:
            cmd = pop_cmd()
            if cmd is None:
                chunk = transport.read(4096)
                ascii_chunk, cmds = split_control_bytes(chunk)
                if ascii_chunk:
                    total_rx += len(ascii_chunk)
                    emit_ascii(ascii_chunk)
                if cmds:
                    with cmd_lock:
                        cmd_queue.extend(cmds)
                    cmd = pop_cmd()

            if cmd is None:
                sleep_fn(0.02)
                continue

            if cmd == CMD_PLAY_PAUSE:
                paused = False
                if on_status:
                    on_status(f"\n[RESUME @ {_format_mmss(frame_idx, fps)}]")
            elif cmd == CMD_FWD_5S:
                frame_idx = min(len(packets) - 1, frame_idx + seek_step)
                transport.write(packets[frame_idx])
                if on_status:
                    on_status(f"\n[FORWARD +5s -> {_format_mmss(frame_idx, fps)} (Paused)]")
            elif cmd == CMD_BWD_5S:
                frame_idx = max(0, frame_idx - seek_step)
                transport.write(packets[frame_idx])
                if on_status:
                    on_status(f"\n[BACKWARD -5s -> {_format_mmss(frame_idx, fps)} (Paused)]")
            elif cmd == CMD_RESTART:
                frame_idx = 0
                paused = False
                if on_status:
                    on_status("\n[RESTART -> 00:00]")
            elif cmd == CMD_STOP:
                if on_status:
                    on_status("\n[STOP] Pemutaran dihentikan.")
                return {
                    "outcome": "stopped",
                    "sent_frames": total_sent,
                    "dropped_frames": total_dropped,
                    "received_bytes": total_rx,
                    "final_frame": frame_idx,
                }
            continue

        # Mode Playing aktif: mulai segmen dari frame_idx saat ini
        audio_dev: Optional[AudioDevice] = None
        start_sec = frame_idx / max(1.0, fps)

        if audio_path and os.path.exists(audio_path):
            audio_dev, clock = make_audio(
                audio_path,
                start_sec,
                audio_hostapi,
                (audio_discipline == "on"),
            )
        else:
            if audio_path and frame_idx == 0 and on_status:
                on_status(f"[INFO] Berkas audio '{audio_path}' tidak ditemukan; memakai MonotonicClock.")
            clock = make_clock()

        def output_handler(data: bytes) -> None:
            ascii_part, cmds = split_control_bytes(data)
            if ascii_part:
                emit_ascii(ascii_part)
            if cmds:
                with cmd_lock:
                    cmd_queue.extend(cmds)

        def has_pending_cmd() -> bool:
            with cmd_lock:
                return len(cmd_queue) > 0

        player = StreamPlayer(
            transport=transport,
            clock=clock,
            fps=fps,
            av_offset_ms=av_offset_ms,
            on_terminal_output=output_handler,
            allow_large_negative_offset=True,
        )

        try:
            if audio_dev is not None:
                audio_dev.start()
            stats = player.play_packets(
                packets,
                start_frame=frame_idx,
                should_stop=has_pending_cmd,
            )
            sleep_fn(0.05)
            player.stop_reader()
        finally:
            player.stop_reader()
            if audio_dev is not None:
                audio_dev.stop()
                audio_dev.close()

        total_sent += int(stats["sent_frames"])
        total_dropped += int(stats["dropped_frames"])
        total_rx += int(stats["received_bytes"])
        frame_idx = int(player.next_frame_index)

        cmd = pop_cmd()

        if cmd is None:
            return {
                "outcome": "finished",
                "sent_frames": total_sent,
                "dropped_frames": total_dropped,
                "received_bytes": total_rx,
                "final_frame": frame_idx,
            }

        if cmd == CMD_PLAY_PAUSE:
            paused = True
            if on_status:
                on_status(f"\n[PAUSE @ {_format_mmss(frame_idx, fps)}] (Tekan btnU untuk lanjut)")
        elif cmd == CMD_FWD_5S:
            frame_idx = min(len(packets) - 1, frame_idx + seek_step)
            if on_status:
                on_status(f"\n[FORWARD +5s -> {_format_mmss(frame_idx, fps)}]")
        elif cmd == CMD_BWD_5S:
            frame_idx = max(0, frame_idx - seek_step)
            if on_status:
                on_status(f"\n[BACKWARD -5s -> {_format_mmss(frame_idx, fps)}]")
        elif cmd == CMD_RESTART:
            frame_idx = 0
            paused = False
            if on_status:
                on_status("\n[RESTART -> 00:00]")
        elif cmd == CMD_STOP:
            if on_status:
                on_status("\n[STOP] Pemutaran dihentikan.")
            return {
                "outcome": "stopped",
                "sent_frames": total_sent,
                "dropped_frames": total_dropped,
                "received_bytes": total_rx,
                "final_frame": frame_idx,
            }

    return {
        "outcome": "finished",
        "sent_frames": total_sent,
        "dropped_frames": total_dropped,
        "received_bytes": total_rx,
        "final_frame": frame_idx,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Standby Auto-Player Bad Apple!! dengan kendali tombol Basys 3"
    )
    parser.add_argument(
        "--port",
        type=str,
        default=None,
        help="Port serial UART (default: deteksi otomatis perangkat FTDI Basys 3).",
    )
    parser.add_argument("--baud", type=int, default=921600, help="Baud rate UART (default: 921600).")
    parser.add_argument(
        "--file",
        type=str,
        default=DEFAULT_STREAM_FILE,
        help="Berkas paket biner video penuh (default: data/stream_full.bin).",
    )
    parser.add_argument(
        "--audio",
        type=str,
        default=DEFAULT_AUDIO_FILE,
        help="Berkas WAV audio laptop (default: data/audio/bad_apple.wav).",
    )
    parser.add_argument("--no-audio", action="store_true", default=False, help="Putar tanpa audio PC.")
    parser.add_argument(
        "--audio-hostapi",
        type=str,
        choices=["default", "mme", "directsound", "wasapi"],
        default="wasapi",
        help="Host API audio PC (default: wasapi).",
    )
    parser.add_argument(
        "--audio-discipline",
        type=str,
        choices=["on", "off"],
        default="on",
        help="Disiplin jam audio (default: on).",
    )
    parser.add_argument("--fps", type=float, default=30.0, help="Laju frame video (default: 30.0).")
    parser.add_argument("--av-offset-ms", type=float, default=0.0, help="Offset A/V dalam ms (default: 0.0).")
    parser.add_argument(
        "--silence-ms",
        type=float,
        default=250.0,
        help="Durasi hening RsTx (ms) setelah SW0=0 untuk memicu start SW0=1 (default: 250 ms).",
    )
    parser.add_argument(
        "--show-standby-ascii",
        action="store_true",
        default=False,
        help="Tampilkan klip ROM SW0=0 di terminal selama mode standby.",
    )
    parser.add_argument(
        "--no-display",
        action="store_true",
        default=False,
        help="Matikan cetak ASCII ke terminal saat pemutaran berlangsung.",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        default=False,
        help="Keluar setelah pemutaran selesai (default: kembali ke mode standby).",
    )
    args = parser.parse_args()

    if not os.path.exists(args.file):
        print(
            f"Error: Berkas stream '{args.file}' belum ada.\n"
            f"Buat dulu dengan: .\\.venv\\Scripts\\python.exe python/make_full_stream.py --out {args.file}",
            file=sys.stderr,
        )
        return 1

    with open(args.file, "rb") as f:
        packets = split_stream_into_packets(f.read())
    if not packets:
        print(f"Error: Tidak ada paket valid di '{args.file}'.", file=sys.stderr)
        return 1

    try:
        port = select_serial_port(requested_port=args.port)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print("=" * 68)
    print("   BAD APPLE!! AUTO-PLAYER STANDBY + KENDALI TOMBOL BASYS 3")
    print("=" * 68)
    print(f"Port Serial : {port} @ {args.baud} baud")
    print(f"Berkas Video: {args.file} ({len(packets)} frame)")
    print(f"Audio PC    : {'Nonaktif' if args.no_audio else f'{args.audio} ({args.audio_hostapi}, discipline={args.audio_discipline})'}")
    print("Tombol SW0=1: btnU=Play/Pause | btnR=+5s | btnL=-5s | btnC=Restart | btnD=Stop")
    print("Tekan Ctrl+C kapan saja untuk keluar.")
    print("=" * 68)

    transport = SerialTransport(port=port, baudrate=args.baud, timeout=0.02)
    try:
        while True:
            wait_for_sw0_trigger(
                transport=transport,
                silence_sec=max(0.05, args.silence_ms / 1000.0),
                show_standby_ascii=args.show_standby_ascii,
            )
            stats = run_playback_with_controls(
                transport=transport,
                packets=packets,
                audio_path=None if args.no_audio else args.audio,
                audio_hostapi=args.audio_hostapi,
                audio_discipline=args.audio_discipline,
                fps=args.fps,
                av_offset_ms=args.av_offset_ms,
                no_display=args.no_display,
            )
            print(
                f"\n[{str(stats['outcome']).upper()}] Terkirim: {stats['sent_frames']} frame "
                f"(drop: {stats['dropped_frames']}, RX ASCII: {stats['received_bytes']} B)."
            )
            if args.once:
                break
            print("[STANDBY] Kembali siaga. Turunkan SW0 ke 0 lalu naikkan ke 1 untuk memutar ulang.")
    except KeyboardInterrupt:
        print("\n[KELUAR] Mode standby dihentikan oleh pengguna.")
    finally:
        transport.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
