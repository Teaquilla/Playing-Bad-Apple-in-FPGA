"""tests/test_mixed_stream.py
Pengujian unit untuk pembangkit aliran campuran Audio+Video dan oracle AudioFakeFPGA (Milestone M4).
"""

import os
import sys
from pathlib import Path
import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from python.make_mixed_stream import (
    AudioFakeFPGA,
    build_scenario_packets,
    load_video_packets_from_clip,
    make_audio_payload_ramp,
    encode_audio_packet,
)


@pytest.fixture(scope="module")
def video_packets():
    clip_path = "data/golden/stream_clip.bin"
    if not os.path.exists(clip_path):
        pytest.skip(f"Berkas golden clip {clip_path} tidak ditemukan")
    return load_video_packets_from_clip(clip_path)


def test_audio_ramp_deterministic():
    """Memverifikasi determinisme dan rentang sampel audio sintetis."""
    p1 = make_audio_payload_ramp(0, 267)
    p2 = make_audio_payload_ramp(0, 267)
    assert p1 == p2
    assert len(p1) == 267
    assert p1[0] == 0
    assert p1[255] == 255
    assert p1[256] == 0


def test_audio_packet_encoding():
    """Memverifikasi pengemasan paket audio dengan bit 15 FRAME_ID aktif."""
    payload = bytes([10, 20, 30] * 30)  # 90 B
    pkt = encode_audio_packet(0x8001, payload)
    assert pkt[:3] == b"\x55\xAA\x5A"
    assert pkt[3:5] == b"\x80\x01"
    assert pkt[5:7] == bytes([0x00, 90])
    assert pkt[-2] == 0xED
    # Validasi checksum di akhir paket
    from python.stream_encoder import compute_checksum
    expected_chk = compute_checksum(0x8001, 90, payload)
    assert pkt[-1] == expected_chk


def test_scenario_clean_manifest(video_packets):
    """Memverifikasi skenario clean menghasilkan 90 frame video dan 94 paket audio tanpa galat."""
    stream_bytes, rej = build_scenario_packets("clean", video_packets)
    fpga = AudioFakeFPGA(reject_packet_predicate=rej)
    fpga.receive_bytes(stream_bytes)
    fpga.finish()

    assert fpga.valid_frames_count == 90
    assert fpga.audio_packets_count == 94
    assert len(fpga.received_audio_bytes) == 25068
    assert fpga.checksum_errors == 0
    assert fpga.length_errors == 0
    assert fpga.run_errors == 0
    assert fpga.resyncs_count == 0


def test_scenario_corrupt_checksum_manifest(video_packets):
    """Memverifikasi skenario corrupt_checksum mendeteksi tepat 1 galat checksum pada audio."""
    stream_bytes, rej = build_scenario_packets("corrupt_checksum", video_packets)
    fpga = AudioFakeFPGA(reject_packet_predicate=rej)
    fpga.receive_bytes(stream_bytes)
    fpga.finish()

    assert fpga.valid_frames_count == 90
    assert fpga.audio_packets_count == 93
    assert fpga.checksum_errors == 1
    assert fpga.length_errors == 0


def test_scenario_truncated_manifest(video_packets):
    """Memverifikasi skenario truncated mendeteksi paket audio terpotong pada akhir stream."""
    stream_bytes, rej = build_scenario_packets("truncated", video_packets)
    fpga = AudioFakeFPGA(reject_packet_predicate=rej)
    fpga.receive_bytes(stream_bytes)
    fpga.finish()

    assert fpga.valid_frames_count == 90
    assert fpga.audio_packets_count == 93
    assert fpga.length_errors == 1


def test_scenario_corrupt_eof_manifest(video_packets):
    """Memverifikasi skenario corrupt_eof mendeteksi galat EOF."""
    stream_bytes, rej = build_scenario_packets("corrupt_eof", video_packets)
    fpga = AudioFakeFPGA(reject_packet_predicate=rej)
    fpga.receive_bytes(stream_bytes)
    fpga.finish()

    assert fpga.valid_frames_count == 90
    assert fpga.audio_packets_count == 93
    assert fpga.length_errors == 1


def test_scenario_corrupt_len_63_manifest(video_packets):
    """Memverifikasi skenario corrupt_len_63 menolak paket dengan panjang < 64."""
    stream_bytes, rej = build_scenario_packets("corrupt_len_63", video_packets)
    fpga = AudioFakeFPGA(reject_packet_predicate=rej)
    fpga.receive_bytes(stream_bytes)
    fpga.finish()

    assert fpga.valid_frames_count == 90
    assert fpga.audio_packets_count == 93
    assert fpga.length_errors == 1


def test_scenario_payload_false_sof_manifest(video_packets):
    """Memverifikasi kemunculan pola 55 AA 5A di dalam payload audio tidak mengacaukan parser."""
    stream_bytes, rej = build_scenario_packets("payload_false_sof", video_packets)
    fpga = AudioFakeFPGA(reject_packet_predicate=rej)
    fpga.receive_bytes(stream_bytes)
    fpga.finish()

    assert fpga.valid_frames_count == 90
    assert fpga.audio_packets_count == 94
    assert len(fpga.received_audio_bytes) == 25068
    assert fpga.checksum_errors == 0
    assert fpga.length_errors == 0
    assert fpga.resyncs_count == 0


def test_scenario_aud_reject_manifest(video_packets):
    """Memverifikasi paket audio yang ditolak FIFO dikomit di transport tanpa dicatat ke audio buffer."""
    stream_bytes, rej = build_scenario_packets("aud_reject", video_packets)
    fpga = AudioFakeFPGA(reject_packet_predicate=rej)
    fpga.receive_bytes(stream_bytes)
    fpga.finish()

    assert fpga.valid_frames_count == 90
    assert fpga.audio_packets_count == 93
    assert fpga.checksum_errors == 0
    assert fpga.length_errors == 0
