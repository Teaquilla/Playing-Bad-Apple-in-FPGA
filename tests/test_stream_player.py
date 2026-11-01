"""tests/test_stream_player.py
Pengujian unit deterministik untuk python/stream_player.py (Milestone M2 & TASKS T2.8).
"""

import os
import time
import pytest

from python.stream_player import (
    Transport,
    Clock,
    SerialTransport,
    FakeTransport,
    MonotonicClock,
    AudioClock,
    FakeClock,
    FakeFPGA,
    StreamPlayer,
    split_stream_into_packets,
)
from python.stream_encoder import encode_packet


GOLDEN_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "golden")
STREAM_CLIP_BIN = os.path.join(GOLDEN_DIR, "stream_clip.bin")
ASCII_BIN = os.path.join(GOLDEN_DIR, "ascii.bin")


def make_dummy_packet(frame_id: int) -> bytes:
    """Membuat 1 paket valid sederhana untuk pengujian timing."""
    # 64 baris x 128 piksel hitam = 64 byte payload bernilai 128 (0x80)
    payload = bytes([128] * 64)
    return encode_packet(frame_id, payload)


# ------------------------------------------------------------------------------
# Test (a): Jadwal Mengikuti Jam
# ------------------------------------------------------------------------------
def test_schedule_follows_clock():
    """Memverifikasi bahwa jadwal pengiriman tiap frame tepat t0 + n / FPS."""
    clock = FakeClock(start_time=50.0)
    transport = FakeTransport()
    player = StreamPlayer(transport=transport, clock=clock, fps=30.0, av_offset_ms=0.0)

    # Buat 6 frame
    packets = [make_dummy_packet(i) for i in range(6)]
    stats = player.play_packets(packets)
    player.stop_reader()

    assert stats["total_frames"] == 6
    assert stats["sent_frames"] == 6
    assert stats["dropped_frames"] == 0

    # Verifikasi timestamp pengiriman tiap frame: t0 + n * (1/30)
    frame_interval = 1.0 / 30.0
    for n, ts in enumerate(player.send_timestamps):
        expected_t = 50.0 + n * frame_interval
        assert abs(ts - expected_t) < 1e-6, f"Frame {n} terkirim di {ts}, ekspektasi {expected_t}"


# ------------------------------------------------------------------------------
# Test (b): Frame Telat > 2 Frame Dibuang dan Dilaporkan
# ------------------------------------------------------------------------------
def test_late_frames_dropped():
    """Memverifikasi bahwa frame yang terlambat > 2 frame (2/FPS) dibuang tanpa dikirim."""
    clock = FakeClock(start_time=0.0)
    transport = FakeTransport()

    # Saat frame 0 terkirim via transport, simulasikan lonjakan lag 0.15 detik (setara 4,5 frame)
    original_write = transport.write
    write_count = 0
    def laggy_write(data: bytes):
        nonlocal write_count
        original_write(data)
        write_count += 1
        if write_count == 1:
            clock.advance(0.15)

    transport.write = laggy_write

    player = StreamPlayer(transport=transport, clock=clock, fps=30.0, av_offset_ms=0.0)
    packets = [make_dummy_packet(i) for i in range(5)]

    stats = player.play_packets(packets)
    player.stop_reader()

    assert stats["total_frames"] == 5
    # Frame 1 dan Frame 2 terlambat > 2 frame (0.15 > 0.10 dan 0.15 > 0.133), jadi dibuang!
    assert stats["dropped_frames"] >= 2, f"Harus ada frame telat yang dibuang: {stats}"
    assert stats["sent_frames"] + stats["dropped_frames"] == 5
    assert len(player.send_timestamps) == stats["sent_frames"]


# ------------------------------------------------------------------------------
# Test (c): Penulisan dan Pembacaan Bersamaan Tanpa Deadlock (Timeout Keras)
# ------------------------------------------------------------------------------
def test_concurrent_read_write_no_deadlock():
    """Memverifikasi pembacaan simultan dan penulisan berjalan lancar tanpa deadlock."""
    fpga = FakeFPGA()
    transport = FakeTransport(fake_fpga=fpga)
    clock = FakeClock()
    captured_chunks = []

    def on_output(chunk: bytes):
        captured_chunks.append(chunk)

    player = StreamPlayer(
        transport=transport,
        clock=clock,
        fps=30.0,
        on_terminal_output=on_output
    )

    packets = [make_dummy_packet(i) for i in range(20)]

    t_start = time.monotonic()
    stats = player.play_packets(packets)

    # Tunggu seluruh output ASCII terbaca oleh background reader
    for _ in range(50):
        if sum(len(c) for c in captured_chunks) >= 20 * 1059:
            break
        time.sleep(0.01)

    player.stop_reader(timeout=1.0)
    elapsed = time.monotonic() - t_start

    # Timeout keras: eksekusi simulasi tidak boleh memakan waktu > 2 detik
    assert elapsed < 2.0, f"Terjadi kemungkinan deadlock atau stall: elapsed={elapsed}s"
    assert stats["sent_frames"] == 20
    assert stats["dropped_frames"] == 0
    assert fpga.valid_frames_count == 20
    total_received = sum(len(c) for c in captured_chunks)
    assert total_received == 20 * 1059


# ------------------------------------------------------------------------------
# Test (d): ASCII 90 Frame dari FakeFPGA Sama Byte-Exact dengan ascii.bin
# ------------------------------------------------------------------------------
def test_ascii_90_frames_byte_exact():
    """Memverifikasi bahwa 90 frame stream_clip.bin menghasilkan keluaran ASCII 95.310 B byte-exact."""
    assert os.path.exists(STREAM_CLIP_BIN), f"Berkas tidak ditemukan: {STREAM_CLIP_BIN}"
    assert os.path.exists(ASCII_BIN), f"Berkas tidak ditemukan: {ASCII_BIN}"

    with open(STREAM_CLIP_BIN, "rb") as f:
        stream_data = f.read()

    with open(ASCII_BIN, "rb") as f:
        expected_ascii = f.read()

    assert len(expected_ascii) == 95310, f"ascii.bin harus berukuran 95.310 B, terbaca: {len(expected_ascii)}"

    fpga = FakeFPGA()
    transport = FakeTransport(fake_fpga=fpga)
    clock = FakeClock()
    received_bytes = bytearray()

    def on_output(data: bytes):
        received_bytes.extend(data)

    player = StreamPlayer(
        transport=transport,
        clock=clock,
        fps=30.0,
        on_terminal_output=on_output
    )

    stats = player.play_stream(stream_data)

    # Pastikan seluruh 90 frame terproses oleh reader
    for _ in range(100):
        if len(received_bytes) >= 95310:
            break
        time.sleep(0.01)

    player.stop_reader()

    assert stats["total_frames"] == 90
    assert stats["sent_frames"] == 90
    assert stats["dropped_frames"] == 0
    assert fpga.valid_frames_count == 90
    assert len(received_bytes) == 95310, f"Ukuran ASCII berbeda: {len(received_bytes)} != 95310"
    assert bytes(received_bytes) == expected_ascii, "Keluaran ASCII tidak cocok byte-exact terhadap ascii.bin!"


# ------------------------------------------------------------------------------
# Test (e): Opsi --no-audio
# ------------------------------------------------------------------------------
def test_no_audio_mode():
    """Memverifikasi bahwa player bekerja pada mode --no-audio menggunakan MonotonicClock."""
    transport = FakeTransport()
    # Inisialisasi default tanpa audio clock
    player = StreamPlayer(transport=transport, clock=None, fps=30.0)
    assert isinstance(player.clock, MonotonicClock)

    # Tes pemutaran 2 frame cepat
    packets = [make_dummy_packet(0), make_dummy_packet(1)]
    stats = player.play_packets(packets)
    player.stop_reader()

    assert stats["sent_frames"] == 2
    assert stats["dropped_frames"] == 0


# ------------------------------------------------------------------------------
# Test (f): Paket Rusak dari FakeTransport Tidak Membuat Player Macet
# ------------------------------------------------------------------------------
def test_corrupted_packets_do_not_hang_player():
    """Memverifikasi bahwa aliran data korup (checksum salah, fake SOF, dsb) ditangani tanpa freeze."""
    corrupt_bin = os.path.join(GOLDEN_DIR, "stream_corrupt_checksum.bin")
    false_sof_bin = os.path.join(GOLDEN_DIR, "stream_false_sof.bin")

    assert os.path.exists(corrupt_bin)
    assert os.path.exists(false_sof_bin)

    with open(corrupt_bin, "rb") as f:
        corrupt_data = f.read()

    with open(false_sof_bin, "rb") as f:
        false_sof_data = f.read()

    fpga = FakeFPGA()
    transport = FakeTransport(fake_fpga=fpga)
    clock = FakeClock()

    player = StreamPlayer(transport=transport, clock=clock, fps=30.0)

    # 1. Kirim paket korup checksum (harus ditolak oleh FPGA, 0 valid frame)
    t_start = time.monotonic()
    player.play_stream(corrupt_data)
    assert time.monotonic() - t_start < 2.0
    assert fpga.checksum_errors >= 1
    assert fpga.valid_frames_count == 0

    # 2. Kirim stream_false_sof (25B palsu disusul 90 frame valid sejati)
    player.play_stream(false_sof_data)
    player.stop_reader()

    # FPGA harus berhasil resinkronisasi dan menerima 90 frame sejati
    assert fpga.valid_frames_count == 90
    assert fpga.resyncs_count >= 1
