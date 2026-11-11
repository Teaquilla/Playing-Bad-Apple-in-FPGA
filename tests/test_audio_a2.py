"""Unit test untuk python/audio_a2.py (Jalur Audio A2 & AudioFakeFPGA)."""

import os
import struct
import pytest
from audio_a2 import (
    get_audio_packet_payload_len,
    encode_audio_packet,
    decode_audio_packet,
    slice_audio_for_stream,
    AudioFakeFPGA,
)
from stream_encoder import (
    SOF_MARKER,
    EOF_BYTE,
    compute_checksum,
)

GOLDEN_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "golden")


def test_audio_packet_pattern_267_267_266():
    """Menguji pola 267, 267, 266 sampel untuk 3 frame berturut-turut (total tepat 800 sampel per 0,1 detik)."""
    pattern = [get_audio_packet_payload_len(i) for i in range(12)]
    assert pattern == [267, 267, 266, 267, 267, 266, 267, 267, 266, 267, 267, 266]

    # Uji akumulasi 30 frame = 1 detik tepat 8000 sampel
    total_1sec = sum(get_audio_packet_payload_len(i) for i in range(30))
    assert total_1sec == 8000


def test_encode_decode_audio_packet_roundtrip():
    """Menguji penyandian dan penguraian paket audio bolak-balik (round-trip)."""
    raw_samples = bytes([i % 256 for i in range(267)])
    idx = 42

    packet = encode_audio_packet(idx, raw_samples)
    assert len(packet) == 3 + 2 + 2 + 267 + 1 + 1  # 276 bytes

    dec_idx, dec_samples = decode_audio_packet(packet)
    assert dec_idx == idx
    assert dec_samples == raw_samples


def test_audio_packet_payload_len_limits():
    """Memverifikasi bahwa panjang payload audio harus berada dalam batas aman 64 .. 1024 B."""
    valid_samples = bytes([0x80] * 64)
    pkt = encode_audio_packet(0, valid_samples)
    assert len(pkt) == 9 + 64

    # Terlalu pendek (< 64)
    with pytest.raises(ValueError, match="di luar batas aman"):
        encode_audio_packet(0, bytes([0x80] * 63))

    # Terlalu panjang (> 1024)
    with pytest.raises(ValueError, match="di luar batas aman"):
        encode_audio_packet(0, bytes([0x80] * 1025))


def test_audio_packet_checksum_validation():
    """Memverifikasi validasi checksum XOR pada paket audio."""
    samples = bytes([0x55] * 266)
    packet = bytearray(encode_audio_packet(10, samples))

    # Korupkan checksum (byte terakhir)
    packet[-1] ^= 0xFF
    with pytest.raises(ValueError, match="Checksum galat"):
        decode_audio_packet(bytes(packet))


def test_audio_packet_frame_id_bit15():
    """Memverifikasi bahwa bit 15 FRAME_ID wajib bernilai 1 untuk menandai audio."""
    samples = bytes([0xAA] * 266)
    packet = bytearray(encode_audio_packet(5, samples))

    fid = struct.unpack(">H", packet[3:5])[0]
    assert (fid & 0x8000) != 0, "Bit 15 FRAME_ID harus 1"
    assert (fid & 0x7FFF) == 5, "Indeks audio harus tersimpan di bit 0..14"

    # Jika bit 15 dimatikan, decode_audio_packet harus menolak
    packet[3] &= 0x7F
    with pytest.raises(ValueError, match="Bukan paket audio"):
        decode_audio_packet(bytes(packet))


def test_audio_fake_fpga_vs_manifest_expected():
    """Memverifikasi bahwa AudioFakeFPGA menghasilkan hasil identik 100% terhadap stream_expected.txt."""
    manifest_path = os.path.join(GOLDEN_DIR, "stream_expected.txt")
    assert os.path.exists(manifest_path)

    expected: dict = {}
    current_vec = None
    with open(manifest_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("VECTOR:"):
                current_vec = line.split(":", 1)[1].strip()
                expected[current_vec] = {}
            elif current_vec and ":" in line and not line.startswith("#"):
                k, v = line.split(":", 1)
                expected[current_vec][k.strip()] = int(v.strip())

    for vec_name, exp in expected.items():
        bin_path = os.path.join(GOLDEN_DIR, f"{vec_name}.bin")
        assert os.path.exists(bin_path)
        with open(bin_path, "rb") as bf:
            stream_data = bf.read()

        fpga = AudioFakeFPGA()
        fpga.receive_bytes(stream_data)
        fpga.finish()

        assert fpga.valid_frames_count == exp["VALID_FRAMES"], f"Vektor {vec_name} valid_frames mismatch"
        assert fpga.checksum_errors == exp["CHECKSUM_ERRORS"], f"Vektor {vec_name} checksum_errors mismatch"
        assert fpga.length_errors == exp["LENGTH_ERRORS"], f"Vektor {vec_name} length_errors mismatch"
        assert fpga.run_errors == exp["RUN_ERRORS"], f"Vektor {vec_name} run_errors mismatch"
        assert fpga.resyncs_count == exp["RESYNCS"], f"Vektor {vec_name} resyncs mismatch"
        assert fpga.cnt_audio_packets == 0, f"Vektor {vec_name} seharusnya memiliki 0 paket audio"


def test_mixed_stream_video_and_audio_in_audio_fake_fpga():
    """Menguji stream campuran video dan audio berselang-seling.

    Memverifikasi:
    - 90 paket video menghasilkan 90 valid_frames_count dan ASCII 95.310 B byte-exact.
    - 90 paket audio dialihkan ke penampung audio (cnt_audio_packets = 90).
    - 0 galat checksum, 0 galat panjang, 0 resinkronisasi.
    """
    clip_path = os.path.join(GOLDEN_DIR, "stream_clip.bin")
    ascii_path = os.path.join(GOLDEN_DIR, "ascii.bin")
    assert os.path.exists(clip_path)
    assert os.path.exists(ascii_path)

    with open(clip_path, "rb") as f:
        clip_bytes = f.read()
    with open(ascii_path, "rb") as f:
        expected_ascii = f.read()

    # Ekstrak paket-paket video dari stream_clip.bin
    video_packets = []
    idx = 0
    while idx < len(clip_bytes):
        sof = clip_bytes.find(SOF_MARKER, idx)
        if sof == -1:
            break
        _, plen = struct.unpack(">HH", clip_bytes[sof + 3 : sof + 7])
        pkt_len = 9 + plen
        video_packets.append(clip_bytes[sof : sof + pkt_len])
        idx = sof + pkt_len

    assert len(video_packets) == 90

    # Buat stream campuran dengan menyisipkan 1 paket audio per 1 paket video
    mixed_stream = bytearray()
    audio_sample_bytes = bytearray()
    for i, v_pkt in enumerate(video_packets):
        mixed_stream.extend(v_pkt)
        a_len = get_audio_packet_payload_len(i)
        a_samples = bytes([(i * 3 + s) % 256 for s in range(a_len)])
        audio_sample_bytes.extend(a_samples)
        a_pkt = encode_audio_packet(i, a_samples)
        mixed_stream.extend(a_pkt)

    fpga = AudioFakeFPGA()
    # Berikan dalam potongan 1024 B (simulasi UART streaming)
    chunk_size = 1024
    for o in range(0, len(mixed_stream), chunk_size):
        fpga.receive_bytes(mixed_stream[o : o + chunk_size])
    fpga.finish()

    assert fpga.valid_frames_count == 90
    assert fpga.cnt_audio_packets == 90
    assert fpga.checksum_errors == 0
    assert fpga.length_errors == 0
    assert fpga.resyncs_count == 0
    assert bytes(fpga.audio_samples) == bytes(audio_sample_bytes)

    # Baca seluruh keluaran ASCII dan verifikasi byte-exact
    rendered_ascii = fpga.read_ascii(max_bytes=200000)
    assert len(rendered_ascii) == 95310
    assert rendered_ascii == expected_ascii


def test_corrupted_audio_packet_isolation():
    """Memverifikasi bahwa paket audio dengan checksum korup diisolasi (tidak merusak video)."""
    samples = bytes([0x42] * 267)
    bad_audio_pkt = bytearray(encode_audio_packet(0, samples))
    bad_audio_pkt[-1] ^= 0xFF  # Korupkan checksum

    fpga = AudioFakeFPGA()
    fpga.receive_bytes(bad_audio_pkt)
    fpga.finish()

    assert fpga.checksum_errors == 1
    assert fpga.cnt_audio_packets == 0
    assert fpga.valid_frames_count == 0
    assert len(fpga.read_ascii()) == 0
