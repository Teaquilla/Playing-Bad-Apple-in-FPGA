"""tests/test_board_check.py
Pengujian unit deterministik untuk python/board_check.py dan python/calibrate_av.py
tanpa perangkat keras fisik maupun audio hardware.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import List

import pytest

from python.ascii_renderer import ASCII_FRAME_LEN
from python.board_check import (
    discover_serial_ports,
    load_golden_ascii_hex,
    load_golden_packets,
    run_board_check,
    select_serial_port,
)
from python.calibrate_av import (
    main as calibrate_main,
    parse_offsets,
    parse_yes_no,
    run_calibration,
    summarize_calibration,
)


REPO_ROOT = Path(__file__).resolve().parent.parent
STREAM_CLIP = str(REPO_ROOT / "data" / "golden" / "stream_clip.bin")
ASCII_HEX = str(REPO_ROOT / "data" / "golden" / "ascii.hex")


class ScriptedFakeSerial:
    """Port serial palsu deterministik untuk menguji count, golden, dan timeout."""

    def __init__(self, rx_chunks: List[bytes], on_read_step=None):
        self.tx_data = bytearray()
        self._chunks = list(rx_chunks)
        self._on_read_step = on_read_step
        self.closed = False

    @property
    def in_waiting(self) -> int:
        return sum(len(c) for c in self._chunks)

    def write(self, data: bytes) -> int:
        self.tx_data.extend(data)
        return len(data)

    def read(self, size: int = 4096) -> bytes:
        if self._on_read_step is not None:
            self._on_read_step()
        if not self._chunks:
            return b""
        return self._chunks.pop(0)

    def close(self) -> None:
        self.closed = True


class AdvancingFakeClock:
    """Jam perf_counter tiruan untuk menguji batas timeout tanpa sleep nyata."""

    def __init__(self, step_sec: float = 0.01):
        self.t = 100.0
        self.step_sec = step_sec

    def now(self) -> float:
        return self.t

    def advance(self, delta: float) -> None:
        self.t += delta


def test_discover_and_select_serial_ports():
    """Menguji penemuan VID:PID serta pemilihan port otomatis maupun eksplisit."""
    fake_ports = [
        SimpleNamespace(device="COM1", description="Communications Port", vid=None, pid=None, hwid="ACPI\\PNP0501"),
        SimpleNamespace(device="COM5", description="USB Serial Port (COM5)", vid=0x0403, pid=0x6010, hwid="USB VID:PID=0403:6010"),
        SimpleNamespace(device="COM7", description="Fallback", vid=None, pid=None, hwid="USB VID:PID=1A86:7523"),
    ]
    discovered = discover_serial_ports(port_list=fake_ports)
    assert discovered[0]["vid_pid"] == "N/A"
    assert discovered[1]["device"] == "COM5"
    assert discovered[1]["vid_pid"] == "0403:6010"
    assert discovered[2]["vid_pid"] == "1A86:7523"

    # Otomatis memprioritaskan VID FTDI 0403
    assert select_serial_port(requested_port=None, port_list=fake_ports) == "COM5"
    # Eksplisit mengikuti permintaan pengguna
    assert select_serial_port(requested_port="COM9", port_list=fake_ports) == "COM9"

    # Fallback ke port pertama jika tidak ada FTDI 0403
    non_ftdi = [SimpleNamespace(device="COM8", description="Other", vid=0x1234, pid=0x5678, hwid="")]
    assert select_serial_port(requested_port=None, port_list=non_ftdi) == "COM8"

    with pytest.raises(RuntimeError):
        select_serial_port(requested_port=None, port_list=[])


def test_board_check_fake_fpga_cli_and_unit():
    """Memverifikasi --fake-fpga menghasilkan 1.059 byte per frame dan cocok 100% golden."""
    packets = load_golden_packets(clip_path=STREAM_CLIP, frames=1)
    expected = load_golden_ascii_hex(hex_path=ASCII_HEX, expected_bytes=ASCII_FRAME_LEN)
    assert len(packets) == 1
    assert len(expected) == ASCII_FRAME_LEN

    from python.stream_player import FakeFPGA, FakeTransport

    res = run_board_check(
        transport=FakeTransport(fake_fpga=FakeFPGA()),
        packets=packets,
        expected_ascii=expected,
        timeout=2.0,
    )
    assert res["passed"] is True
    assert res["count_ok"] is True
    assert res["byte_exact"] is True
    assert res["timed_out"] is False
    assert res["received_bytes"] == 1059
    assert res["first_byte_sec"] is not None
    assert res["last_byte_sec"] >= res["first_byte_sec"]

    # Smoke test CLI --fake-fpga 3 frame
    cli = subprocess.run(
        [sys.executable, "python/board_check.py", "--fake-fpga", "--frames", "3", "--timeout", "2.0"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    assert cli.returncode == 0, cli.stderr
    assert "3177 B" in cli.stdout
    assert "COCOK" in cli.stdout
    assert "Status        : PASS" in cli.stdout


def test_board_check_golden_mismatch_detected():
    """Panjang tepat 1.059 B tanpa timeout tetapi 1 byte berbeda wajib gagal."""
    packets = load_golden_packets(clip_path=STREAM_CLIP, frames=1)
    expected = load_golden_ascii_hex(hex_path=ASCII_HEX, expected_bytes=ASCII_FRAME_LEN)

    corrupted = bytearray(expected)
    mismatch_pos = 123
    corrupted[mismatch_pos] = (corrupted[mismatch_pos] + 1) % 256

    fake_ser = ScriptedFakeSerial(rx_chunks=[bytes(corrupted[:500]), bytes(corrupted[500:])])
    res = run_board_check(
        transport=fake_ser,
        packets=packets,
        expected_ascii=expected,
        timeout=2.0,
    )
    assert res["count_ok"] is True
    assert res["timed_out"] is False
    assert res["byte_exact"] is False
    assert res["first_mismatch_index"] == mismatch_pos
    assert res["passed"] is False


def test_board_check_byte_count_mismatch_detected():
    """Jumlah byte berlebih (1.060 B meski 1.059 B awal cocok golden) maupun kurang wajib gagal."""
    packets = load_golden_packets(clip_path=STREAM_CLIP, frames=1)
    expected = load_golden_ascii_hex(hex_path=ASCII_HEX, expected_bytes=ASCII_FRAME_LEN)

    # 1.060 byte diterima cepat sebelum timeout, 1.059 byte pertama persis golden
    fake_ser_extra = ScriptedFakeSerial(rx_chunks=[expected + b"\n"])
    res_extra = run_board_check(
        transport=fake_ser_extra,
        packets=packets,
        expected_ascii=expected,
        timeout=2.0,
    )
    assert res_extra["received_bytes"] == 1060
    assert res_extra["timed_out"] is False
    assert res_extra["count_ok"] is False
    assert res_extra["passed"] is False

    # Data terpotong (500 B saja)
    clk = AdvancingFakeClock()
    fake_ser_short = ScriptedFakeSerial(
        rx_chunks=[expected[:500]],
        on_read_step=lambda: clk.advance(0.6),
    )
    res_short = run_board_check(
        transport=fake_ser_short,
        packets=packets,
        expected_ascii=expected,
        timeout=1.0,
        perf_counter=clk.now,
    )
    assert res_short["received_bytes"] == 500
    assert res_short["count_ok"] is False
    assert res_short["timed_out"] is True
    assert res_short["passed"] is False


def test_board_check_timeout_detected():
    """Timeout wajib terdeteksi baik saat 0 byte maupun saat 1.059 byte tiba melewati batas timeout."""
    packets = load_golden_packets(clip_path=STREAM_CLIP, frames=1)
    expected = load_golden_ascii_hex(hex_path=ASCII_HEX, expected_bytes=ASCII_FRAME_LEN)

    # Kasus A: 0 byte diterima hingga melewati batas timeout
    clk_empty = AdvancingFakeClock()
    fake_empty = ScriptedFakeSerial(rx_chunks=[], on_read_step=lambda: clk_empty.advance(0.4))
    res_empty = run_board_check(
        transport=fake_empty,
        packets=packets,
        expected_ascii=expected,
        timeout=1.0,
        perf_counter=clk_empty.now,
    )
    assert res_empty["received_bytes"] == 0
    assert res_empty["timed_out"] is True
    assert res_empty["passed"] is False

    # Kasus B: seluruh 1.059 byte cocok golden tetapi baru selesai setelah 1.5 s > timeout 1.0 s
    clk_late = AdvancingFakeClock()
    fake_late = ScriptedFakeSerial(
        rx_chunks=[expected],
        on_read_step=lambda: clk_late.advance(1.5),
    )
    res_late = run_board_check(
        transport=fake_late,
        packets=packets,
        expected_ascii=expected,
        timeout=1.0,
        perf_counter=clk_late.now,
    )
    assert res_late["received_bytes"] == 1059
    assert res_late["count_ok"] is True
    assert res_late["byte_exact"] is True
    assert res_late["timed_out"] is True
    assert res_late["passed"] is False


def test_calibrate_av_dry_run_and_answer_parsing(capsys):
    """Memverifikasi calibrate_av mode --dry-run (tanpa audio) dan penguraian jawaban + nilai tengah."""
    assert parse_offsets("-80, -40, 0, 40, 80") == [-80.0, -40.0, 0.0, 40.0, 80.0]
    assert parse_yes_no("y") is True
    assert parse_yes_no("Ya") is True
    assert parse_yes_no("n") is False
    assert parse_yes_no("tidak") is False
    with pytest.raises(ValueError):
        parse_yes_no("maybe")

    called_runner = False

    def forbidden_runner(*args, **kwargs):
        nonlocal called_runner
        called_runner = True
        raise AssertionError("Mode --dry-run dilarang mengeksekusi subprocess stream_player/audio")

    answers_iter = iter(["n", "y", "y", "n", "n"])
    summary = run_calibration(
        offsets=[-80.0, -40.0, 0.0, 40.0, 80.0],
        port="COM5",
        frames=600,
        dry_run=True,
        input_fn=lambda _prompt: next(answers_iter),
        runner=forbidden_runner,
    )
    assert called_runner is False
    assert len(summary["commands"]) == 5
    for cmd in summary["commands"]:
        joined = " ".join(cmd)
        assert "python/stream_player.py" in joined
        assert "--audio-hostapi wasapi" in joined
        assert "--audio-discipline on" in joined
        assert "--max-frames 600" in joined
        assert "--av-offset-ms" in joined

    assert summary["sync_offsets"] == [-40.0, 0.0]
    assert summary["min_offset"] == -40.0
    assert summary["max_offset"] == 0.0
    assert summary["midpoint_offset"] == -20.0

    # Uji CLI main() --dry-run dengan --answers non-interaktif
    rc = calibrate_main(["--dry-run", "--offsets", "-80,-40,0,40,80", "--answers", "n,y,y,y,n"])
    assert rc == 0
    out = capsys.readouterr().out
    assert "[DRY-RUN 1/5]" in out
    assert "--audio-hostapi wasapi" in out
    assert "--audio-discipline on" in out
    assert "--max-frames 600" in out
    assert "-40 ms s.d. 40 ms" in out
    assert "0 ms" in out
    assert summarize_calibration([])["midpoint_offset"] is None
