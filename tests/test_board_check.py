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
    DEFAULT_AUDIO_START_SEC,
    DEFAULT_CLIP,
    DEFAULT_FRAMES,
    DEFAULT_START_FRAME,
    build_stream_player_cmd,
    main as calibrate_main,
    parse_offsets,
    parse_yes_no,
    run_calibration,
    summarize_calibration,
    validate_clip_frame_count,
)
from python.stream_player import FakeClock, FakeFPGA, FakeTransport


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


def test_calibrate_av_default_cmd_and_alignment():
    """Memverifikasi default build_stream_player_cmd (stream full, start 300 saja tanpa duplikasi --audio-start-sec, 600 frame)."""
    assert DEFAULT_CLIP == "data/stream_full.bin"
    assert DEFAULT_START_FRAME == 300
    assert DEFAULT_AUDIO_START_SEC == 10.0
    assert DEFAULT_FRAMES == 600

    cmd = build_stream_player_cmd(0.0)
    joined = " ".join(cmd)
    assert "--clip data/stream_full.bin" in joined
    assert "--start-frame 300" in joined
    assert "--audio-start-sec" not in joined
    assert "--max-frames 600" in joined
    assert DEFAULT_START_FRAME == pytest.approx(DEFAULT_AUDIO_START_SEC * 30.0)


def test_audio_start_sample_fake_backend_three_cases(monkeypatch):
    """Merekam sampel awal audio dengan --audio-backend fake untuk:
    (a) --start-frame 300 saja,
    (b) --audio-start-sec 10.0 saja pada klip 90 frame,
    (c) kombinasi yang dibangun build_stream_player_cmd bawaan calibrate_av (harapan 441.000, bukan 882.000).
    """
    import python.stream_player as sp

    wav_path = REPO_ROOT / "data" / "audio" / "bad_apple.wav"
    if not wav_path.exists():
        pytest.skip("data/audio/bad_apple.wav tidak tersedia")

    recorded = []
    orig_fake_audio = sp.FakeAudioDevice
    orig_fake_fpga = sp.FakeFPGA

    class RecordingFakeAudioDevice(orig_fake_audio):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            recorded.append(
                {
                    "start_sec": self.start_sec(),
                    "start_sample": self.start_sample(),
                    "sample_rate": self.sample_rate(),
                }
            )

    fpgas = []

    class RecordingFakeFPGA(orig_fake_fpga):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            fpgas.append(self)

    monkeypatch.setattr(sp, "FakeAudioDevice", RecordingFakeAudioDevice)
    monkeypatch.setattr(sp, "FakeFPGA", RecordingFakeFPGA)

    # (a) --start-frame 300 saja pada stream_full.bin
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "python/stream_player.py",
            "--fake-fpga",
            "--no-display",
            "--file",
            "data/stream_full.bin",
            "--audio",
            "data/audio/bad_apple.wav",
            "--audio-backend",
            "fake",
            "--start-frame",
            "300",
            "--max-frames",
            "2",
        ],
    )
    sp.main()
    assert len(recorded) == 1
    assert recorded[-1]["sample_rate"] == 44100
    assert recorded[-1]["start_sec"] == pytest.approx(10.0)
    assert recorded[-1]["start_sample"] == 441000
    assert fpgas[-1].received_fids == [300, 301]

    # (b) --audio-start-sec 10.0 saja pada klip 90 frame
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "python/stream_player.py",
            "--fake-fpga",
            "--no-display",
            "--clip",
            "data/golden/stream_clip.bin",
            "--audio",
            "data/audio/bad_apple.wav",
            "--audio-backend",
            "fake",
            "--audio-start-sec",
            "10.0",
            "--max-frames",
            "2",
        ],
    )
    sp.main()
    assert len(recorded) == 2
    assert recorded[-1]["sample_rate"] == 44100
    assert recorded[-1]["start_sec"] == pytest.approx(10.0)
    assert recorded[-1]["start_sample"] == 441000

    # (c) Kombinasi yang dibangun build_stream_player_cmd (calibrate_av bawaan)
    default_cmd = build_stream_player_cmd(0.0)
    assert "--start-frame" in default_cmd
    assert "--audio-start-sec" not in default_cmd, (
        "calibrate_av bawaan tidak boleh meneruskan --audio-start-sec bersamaan dengan --start-frame (risiko hitung ganda)"
    )

    # Evaluasi aditif: bila kedua opsi diteruskan bersamaan dan ditafsirkan aditif, total akan menjadi 882.000
    sf_val = int(default_cmd[default_cmd.index("--start-frame") + 1]) if "--start-frame" in default_cmd else 0
    as_val = float(default_cmd[default_cmd.index("--audio-start-sec") + 1]) if "--audio-start-sec" in default_cmd else 0.0
    fps_val = float(default_cmd[default_cmd.index("--fps") + 1])
    additive_samples = int(round((as_val + (sf_val / fps_val)) * 44100))
    assert additive_samples == 441000, f"Risiko hitung ganda aditif: didapat {additive_samples} != 441000"

    run_cmd = build_stream_player_cmd(0.0, frames=2, fake_fpga=True, no_display=True)
    monkeypatch.setattr(sys, "argv", run_cmd[1:] + ["--audio-backend", "fake"])
    sp.main()
    assert len(recorded) == 3
    assert recorded[-1]["sample_rate"] == 44100
    assert recorded[-1]["start_sec"] == pytest.approx(10.0)
    assert recorded[-1]["start_sample"] == 441000
    assert fpgas[-1].received_fids == [300, 301]


def test_calibrate_av_start_frame_audio_mismatch_raises():
    """Ketidakcocokan start_frame vs audio_start_sec * fps wajib melempar ValueError."""
    with pytest.raises(ValueError, match="tidak konsisten"):
        build_stream_player_cmd(0.0, start_frame=0, audio_start_sec=10.0, fps=30.0)

    with pytest.raises(ValueError, match="tidak konsisten"):
        build_stream_player_cmd(0.0, start_frame=300, audio_start_sec=5.0, fps=30.0)


def test_calibrate_av_clip_frame_count_bounds():
    """Memvalidasi batas jumlah paket clip: 600 frame pada stream_clip.bin gagal, pada stream_full.bin lolos."""
    # data/golden/stream_clip.bin hanya berisi 90 frame
    with pytest.raises(ValueError, match="melebihi jumlah paket"):
        validate_clip_frame_count(STREAM_CLIP, start_frame=0, frames=600)

    with pytest.raises(ValueError, match="melebihi jumlah paket"):
        build_stream_player_cmd(
            0.0,
            clip="data/golden/stream_clip.bin",
            start_frame=0,
            audio_start_sec=0.0,
            frames=600,
        )

    with pytest.raises(ValueError):
        validate_clip_frame_count(STREAM_CLIP, start_frame=0, frames=0)

    with pytest.raises(ValueError):
        validate_clip_frame_count(STREAM_CLIP, start_frame=-1, frames=10)

    # data/stream_full.bin berisi 1000 paket -> [300, 900) valid
    full_clip = str(REPO_ROOT / "data" / "stream_full.bin")
    total_pkts = validate_clip_frame_count(full_clip, start_frame=300, frames=600)
    assert total_pkts == 1000
    cmd = build_stream_player_cmd(
        -20.0,
        clip="data/stream_full.bin",
        start_frame=300,
        audio_start_sec=10.0,
        frames=600,
    )
    assert "--av-offset-ms" in cmd and "-20" in cmd


def test_board_check_pacing_default_and_custom_fps():
    """Memverifikasi pacing default 30.0 FPS dan kustom 50.0 FPS dengan jam tiruan."""
    packets = load_golden_packets(clip_path=STREAM_CLIP, frames=5)
    expected = load_golden_ascii_hex(hex_path=ASCII_HEX, expected_bytes=5 * ASCII_FRAME_LEN)

    # Default pace_fps=30.0 via AdvancingFakeClock (memakai .advance otomatis)
    clk_default = AdvancingFakeClock()
    res_default = run_board_check(
        transport=FakeTransport(fake_fpga=FakeFPGA()),
        packets=packets,
        expected_ascii=expected,
        timeout=2.0,
        perf_counter=clk_default.now,
    )
    assert res_default["passed"] is True
    assert len(res_default["send_timestamps"]) == 5
    for k in range(1, 5):
        dt = res_default["send_timestamps"][k] - res_default["send_timestamps"][k - 1]
        assert dt >= (1.0 / 30.0) - 1e-6
        assert abs(dt - (1.0 / 30.0)) < 1e-6

    # Custom pace_fps=50.0 dengan FakeClock + sleep_fn eksplisit
    clk_50 = FakeClock(start_time=20.0)
    sleeps: List[float] = []

    def fake_sleep(dt: float) -> None:
        sleeps.append(dt)
        clk_50.advance(dt)

    res_50 = run_board_check(
        transport=FakeTransport(fake_fpga=FakeFPGA()),
        packets=packets,
        expected_ascii=expected,
        timeout=2.0,
        perf_counter=clk_50.now,
        pace_fps=50.0,
        sleep_fn=fake_sleep,
    )
    assert res_50["passed"] is True
    assert len(res_50["send_timestamps"]) == 5
    assert len(sleeps) == 4
    for k in range(1, 5):
        dt = res_50["send_timestamps"][k] - res_50["send_timestamps"][k - 1]
        assert dt >= (1.0 / 50.0) - 1e-6
        assert abs(dt - (1.0 / 50.0)) < 1e-6


def test_board_check_wait_each_waits_for_1059_bytes_per_frame():
    """Memverifikasi wait_each=True menunggu 1.059 byte penuh per frame sebelum paket berikutnya dikirim."""
    packets = load_golden_packets(clip_path=STREAM_CLIP, frames=3)
    expected = load_golden_ascii_hex(hex_path=ASCII_HEX, expected_bytes=3 * ASCII_FRAME_LEN)

    class WaitEachTrackingTransport:
        def __init__(self, expected_bytes: bytes, stall_on_first: bool = False):
            self.expected_bytes = expected_bytes
            self.stall_on_first = stall_on_first
            self.writes: List[bytes] = []
            self.rx_bytes_before_write: List[int] = []
            self.rx_bytes_delivered = 0
            self._pending_chunks: List[bytes] = []

        @property
        def in_waiting(self) -> int:
            return sum(len(c) for c in self._pending_chunks)

        def write(self, data: bytes) -> None:
            idx = len(self.writes)
            self.rx_bytes_before_write.append(self.rx_bytes_delivered)
            self.writes.append(data)
            frame_slice = self.expected_bytes[idx * ASCII_FRAME_LEN : (idx + 1) * ASCII_FRAME_LEN]
            if self.stall_on_first and idx == 0:
                self._pending_chunks.append(frame_slice[:500])
            else:
                self._pending_chunks.extend([frame_slice[:500], b"", frame_slice[500:]])

        def read(self, size: int = 4096) -> bytes:
            if not self._pending_chunks:
                return b""
            chunk = self._pending_chunks.pop(0)
            self.rx_bytes_delivered += len(chunk)
            return chunk

        def close(self) -> None:
            pass

    clk = FakeClock(start_time=0.0)
    tr = WaitEachTrackingTransport(expected)
    res = run_board_check(
        transport=tr,
        packets=packets,
        expected_ascii=expected,
        timeout=2.0,
        perf_counter=clk.now,
        wait_each=True,
    )
    assert res["passed"] is True
    assert res["received_bytes"] == 3 * ASCII_FRAME_LEN
    assert len(res["send_timestamps"]) == 3
    assert tr.rx_bytes_before_write == [0, ASCII_FRAME_LEN, 2 * ASCII_FRAME_LEN]

    # Jika frame ke-0 tidak kunjung lengkap sebelum timeout, paket berikutnya tidak boleh dikirim
    clk_stall = FakeClock(start_time=0.0)
    tr_stall = WaitEachTrackingTransport(expected, stall_on_first=True)
    res_stall = run_board_check(
        transport=tr_stall,
        packets=packets,
        expected_ascii=expected,
        timeout=0.1,
        perf_counter=clk_stall.now,
        wait_each=True,
    )
    assert res_stall["timed_out"] is True
    assert res_stall["passed"] is False
    assert len(tr_stall.writes) == 1


def test_board_check_90_frames_pace_30_timeout_from_last_packet():
    """Dengan jam palsu: 90 frame @ pace 30 FPS (~3,0 s) & timeout 2,0 s wajib lulus,
    dan timeout tetap terdeteksi bila tidak ada byte setelah paket terakhir dikirim.
    """
    packets = load_golden_packets(clip_path=STREAM_CLIP, frames=90)
    expected = load_golden_ascii_hex(hex_path=ASCII_HEX, expected_bytes=90 * ASCII_FRAME_LEN)

    # Skenario 1: seluruh 95.310 byte diterima segera setelah paket ke-90 dikirim -> PASS
    clk_pass = FakeClock(start_time=10.0)
    res_pass = run_board_check(
        transport=FakeTransport(fake_fpga=FakeFPGA()),
        packets=packets,
        expected_ascii=expected,
        timeout=2.0,
        perf_counter=clk_pass.now,
        pace_fps=30.0,
    )
    assert res_pass["passed"] is True
    assert res_pass["timed_out"] is False
    assert res_pass["count_ok"] is True
    assert res_pass["byte_exact"] is True
    assert res_pass["received_bytes"] == 90 * ASCII_FRAME_LEN
    assert len(res_pass["send_timestamps"]) == 90
    assert res_pass["elapsed_sec"] == pytest.approx(89.0 / 30.0, abs=1e-6)

    # Skenario 2: 0 byte tiba setelah paket terakhir dikirim -> timeout terdeteksi 2.0 s setelah paket ke-90
    clk_fail = FakeClock(start_time=10.0)
    silent_transport = ScriptedFakeSerial(rx_chunks=[])
    res_fail = run_board_check(
        transport=silent_transport,
        packets=packets,
        expected_ascii=expected,
        timeout=2.0,
        perf_counter=clk_fail.now,
        pace_fps=30.0,
    )
    assert res_fail["received_bytes"] == 0
    assert res_fail["timed_out"] is True
    assert res_fail["passed"] is False
    assert len(res_fail["send_timestamps"]) == 90
    assert res_fail["elapsed_sec"] >= (89.0 / 30.0) + 2.0 - 1e-6
