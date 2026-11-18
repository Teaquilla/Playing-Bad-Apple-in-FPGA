"""tests/test_auto_player.py
Unit test untuk logika deteksi transisi SW0 (0 -> 1), ekstraksi byte perintah tombol,
dan kendali Play/Pause, Forward +5s, Backward -5s, Restart, serta Stop di python/auto_player.py.
"""

from __future__ import annotations

import sys
import threading
from pathlib import Path
from typing import List

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from python.auto_player import (
    CMD_BWD_5S,
    CMD_FWD_5S,
    CMD_PLAY_PAUSE,
    CMD_RESTART,
    CMD_STOP,
    run_playback_with_controls,
    split_control_bytes,
    wait_for_sw0_trigger,
)
from python.stream_player import FakeClock, Transport


class ScriptedRxTransport(Transport):
    """Transport simulasi untuk menguji trigger SW0 secara deterministik."""

    def __init__(self, schedule: List[bytes]):
        self._schedule = list(schedule)
        self._idx = 0

    def write(self, data: bytes) -> None:
        pass

    def read(self, max_bytes: int = 4096) -> bytes:
        if self._idx < len(self._schedule):
            chunk = self._schedule[self._idx]
            self._idx += 1
            return chunk[:max_bytes]
        return b""

    def close(self) -> None:
        pass


class StepClock:
    """Jam virtual deterministik untuk menguji timeout tanpa delay nyata."""

    def __init__(self, start: float = 0.0):
        self.t = start

    def now(self) -> float:
        return self.t

    def sleep(self, dt: float) -> None:
        self.t += dt


class ControlMockTransport(Transport):
    """Transport simulasi yang mencatat indeks paket dikirim dan menyuntikkan byte tombol."""

    def __init__(self, on_write_packet=None):
        self._rx = bytearray()
        self._lock = threading.Lock()
        self.sent_indices: List[int] = []
        self._on_write_packet = on_write_packet

    def write(self, data: bytes) -> None:
        # Setiap paket dummy berformat b"PKT:" + 4-byte index
        if data.startswith(b"PKT:") and len(data) >= 8:
            idx = int.from_bytes(data[4:8], "big")
            self.sent_indices.append(idx)
            if self._on_write_packet is not None:
                self._on_write_packet(idx, len(self.sent_indices), self)

    def inject_rx(self, data: bytes) -> None:
        with self._lock:
            self._rx.extend(data)

    def read(self, max_bytes: int = 4096) -> bytes:
        with self._lock:
            chunk = bytes(self._rx[:max_bytes])
            del self._rx[:max_bytes]
            return chunk

    def close(self) -> None:
        pass


def _make_dummy_packets(count: int) -> List[bytes]:
    return [b"PKT:" + i.to_bytes(4, "big") for i in range(count)]


def test_ignores_normal_interframe_gap_and_triggers_on_sw0_silence():
    clock = StepClock()
    chunks = [
        b"X" * 100,
        b"",
        b"",
        b"Y" * 100,
    ] + [b""] * 30
    transport = ScriptedRxTransport(chunks)
    messages: List[str] = []

    reason = wait_for_sw0_trigger(
        transport=transport,
        min_active_bytes=64,
        silence_sec=0.25,
        poll_interval_sec=0.02,
        now_fn=clock.now,
        sleep_fn=clock.sleep,
        key_trigger_fn=lambda: False,
        on_status=messages.append,
    )

    assert reason == "sw0_switch"
    assert clock.t >= 0.30
    assert any("[STANDBY]" in m for m in messages)
    assert any("[TRIGGER]" in m for m in messages)


def test_manual_enter_fallback_when_sw0_already_high():
    clock = StepClock()
    transport = ScriptedRxTransport([])
    polls = {"count": 0}
    messages: List[str] = []

    def fake_key() -> bool:
        polls["count"] += 1
        return polls["count"] >= 5

    reason = wait_for_sw0_trigger(
        transport=transport,
        min_active_bytes=64,
        silence_sec=0.25,
        poll_interval_sec=0.5,
        idle_hint_sec=1.0,
        now_fn=clock.now,
        sleep_fn=clock.sleep,
        key_trigger_fn=fake_key,
        on_status=messages.append,
    )

    assert reason == "manual_key"
    assert any("[MENUNGGU]" in m for m in messages)


def test_split_control_bytes_strips_commands_without_corrupting_ascii():
    raw = b"\x1b[H .:-=+*" + bytes([CMD_PLAY_PAUSE, CMD_FWD_5S]) + b"#@\r\n" + bytes([CMD_RESTART])
    ascii_part, cmds = split_control_bytes(raw)
    assert ascii_part == b"\x1b[H .:-=+*#@\r\n"
    assert cmds == [CMD_PLAY_PAUSE, CMD_FWD_5S, CMD_RESTART]


def test_playback_forward_backward_pause_resume_restart_and_stop():
    packets = _make_dummy_packets(400)
    statuses: List[str] = []
    ascii_out = bytearray()

    class FastFakeClock(FakeClock):
        def sleep_until(self, target_time: float) -> None:
            self.sleep_calls.append(target_time)
            if target_time > self._current_time:
                self._current_time = target_time

    # Skenario berurutan via write callback:
    # 1. Kirim frame 0..4 -> kirim CMD_FWD_5S (+150 frame -> loncat ke 155)
    # 2. Di sekitar 156 -> kirim CMD_BWD_5S (-150 frame -> mundur ke 7)
    # 3. Setelah dikirim 10 paket -> kirim CMD_PLAY_PAUSE -> lalu saat paused kirim CMD_PLAY_PAUSE untuk resume
    # 4. Setelah resume -> kirim CMD_RESTART (kembali ke 0)
    # 5. Setelah restart kirim frame 0..2 -> kirim CMD_STOP
    stage = {"step": 0}

    def on_pkt(idx: int, total_writes: int, tr: ControlMockTransport) -> None:
        tr.inject_rx(b"A")
        if stage["step"] == 0 and idx == 4:
            stage["step"] = 1
            tr.inject_rx(bytes([CMD_FWD_5S]))
        elif stage["step"] == 1 and idx >= 156:
            stage["step"] = 2
            tr.inject_rx(bytes([CMD_BWD_5S]))
        elif stage["step"] == 2 and total_writes >= 12:
            stage["step"] = 3
            # Pause lalu segera resume di poll berikutnya
            tr.inject_rx(bytes([CMD_PLAY_PAUSE]))
            tr.inject_rx(bytes([CMD_PLAY_PAUSE]))
        elif stage["step"] == 3 and total_writes >= 15:
            stage["step"] = 4
            tr.inject_rx(bytes([CMD_RESTART]))
        elif stage["step"] == 4 and idx == 2:
            stage["step"] = 5
            tr.inject_rx(bytes([CMD_STOP]))

    transport = ControlMockTransport(on_write_packet=on_pkt)
    res = run_playback_with_controls(
        transport=transport,
        packets=packets,
        audio_path=None,
        fps=30.0,
        seek_seconds=5.0,
        clock_factory=FastFakeClock,
        on_status=statuses.append,
        on_ascii=ascii_out.extend,
        sleep_fn=lambda _dt: None,
    )

    assert res["outcome"] == "stopped"
    # Terbukti melompat >= 155 saat Forward, kembali rendah saat Backward & Restart ke 0
    assert any(i >= 155 for i in transport.sent_indices)
    assert transport.sent_indices[-1] >= 2
    assert any("[FORWARD +5s" in s for s in statuses)
    assert any("[BACKWARD -5s" in s for s in statuses)
    assert any("[PAUSE" in s for s in statuses)
    assert any("[RESTART" in s for s in statuses)
    assert any("[STOP]" in s for s in statuses)
    # Byte kontrol tidak boleh bocor ke output ASCII terminal
    assert all(b == ord("A") for b in ascii_out)
