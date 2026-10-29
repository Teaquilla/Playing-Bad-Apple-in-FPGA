"""Unit Tests untuk Protokol Streaming UART (tests/test_stream_encoder.py).

Memverifikasi implementasi python/stream_encoder.py sesuai docs/PROTOCOL.md:
- Round-trip decode aliran golden terhadap data/golden/frames.bin (90 frame kanonik)
- Deteksi checksum salah
- Deteksi paket terpotong (truncated)
- Penanganan byte sampah (garbage byte insertion) & resinkronisasi
- Deteksi run length melebihi 128 piksel
- Resinkronisasi dari sinkron palsu (false SOF pattern di dalam header/sampah)
"""

import os
import pytest
import numpy as np

from python.canonical import FRAME_BYTES, unpack_frame
from python.stream_encoder import (
    SOF_MARKER,
    EOF_MARKER,
    EOF_BYTE,
    PAYLOAD_LEN_MAX,
    compute_checksum,
    encode_packet,
    encode_canonical_frame,
    decode_packet,
    decode_rle_payload_to_canonical,
    evaluate_stream,
    export_golden_stream,
    export_corrupted_vectors,
)


def test_checksum_computation():
    """Memverifikasi perhitungan XOR checksum."""
    frame_id = 0x0102
    payload_len = 0x0040  # 64 bytes
    payload = bytes([i % 256 for i in range(64)])
    
    chk = compute_checksum(frame_id, payload_len, payload)
    
    # Verifikasi XOR manual
    expected = 0x01 ^ 0x02 ^ 0x00 ^ 0x40 ^ EOF_BYTE
    for b in payload:
        expected ^= b
    assert chk == expected


def test_packet_structure_and_limits():
    """Memverifikasi batas ukuran payload pada encode_packet."""
    # Payload terlalu pendek (< 64 byte)
    with pytest.raises(ValueError, match="di luar batas format valid"):
        encode_packet(0, bytes([1] * 63))

    # Payload terlalu panjang (> 1024 byte)
    with pytest.raises(ValueError, match="di luar batas format valid"):
        encode_packet(0, bytes([1] * 1025))

    # Payload valid (64 byte)
    pkt = encode_packet(10, bytes([1] * 64))
    assert len(pkt) == 3 + 2 + 2 + 64 + 1 + 1  # 73 bytes
    assert pkt[:3] == SOF_MARKER
    assert pkt[-2] == EOF_BYTE


def test_roundtrip_golden_stream():
    """Memverifikasi round-trip decode seluruh 90 frame klip streaming terhadap frames.bin."""
    frames_bin_path = "data/golden/frames.bin"
    assert os.path.exists(frames_bin_path), f"Berkas {frames_bin_path} tidak ditemukan"

    with open(frames_bin_path, "rb") as f:
        golden_raw = f.read()

    num_frames = len(golden_raw) // FRAME_BYTES
    assert num_frames == 90

    # Buat stream dari golden frames
    stream_packets = []
    for fid in range(num_frames):
        orig_canon = golden_raw[fid * FRAME_BYTES : (fid + 1) * FRAME_BYTES]
        pkt = encode_canonical_frame(fid, orig_canon)
        stream_packets.append(pkt)
    full_stream = b"".join(stream_packets)

    # Decode kembali satu per satu
    offset = 0
    for fid in range(num_frames):
        dec_fid, dec_payload, next_offset = decode_packet(full_stream, offset)
        assert dec_fid == fid
        assert next_offset > offset

        # Rekonstruksi ke kanonik
        recon_canon = decode_rle_payload_to_canonical(dec_payload)
        expected_canon = golden_raw[fid * FRAME_BYTES : (fid + 1) * FRAME_BYTES]
        assert recon_canon == expected_canon, f"Ketidakcocokan pada frame {fid}"

        offset = next_offset

    assert offset == len(full_stream)


def test_corrupted_checksum_rejection():
    """Memverifikasi bahwa paket dengan checksum salah ditolak."""
    raw_canon = bytes([0] * FRAME_BYTES)  # Frame hitam polos
    valid_pkt = encode_canonical_frame(0, raw_canon)

    # Balik 1 bit checksum (byte terakhir)
    corrupted_pkt = bytearray(valid_pkt)
    corrupted_pkt[-1] ^= 0x01

    with pytest.raises(ValueError, match="Penanda SOF tidak ditemukan atau stream terpotong"):
        decode_packet(bytes(corrupted_pkt), 0)


def test_truncated_packet_rejection():
    """Memverifikasi bahwa stream yang terpotong di tengah paket ditolak."""
    raw_canon = bytes([0] * FRAME_BYTES)
    valid_pkt = encode_canonical_frame(0, raw_canon)

    # Potong paket sebelum EOF dan Checksum
    truncated_pkt = valid_pkt[: len(valid_pkt) - 5]

    with pytest.raises(ValueError, match="Paket terpotong"):
        decode_packet(truncated_pkt, 0)


def test_byte_insertion_and_resync():
    """Memverifikasi bahwa byte sampah sebelum paket diabaikan dan decoder berhasil sinkron."""
    raw_canon = bytes([0] * FRAME_BYTES)
    valid_pkt = encode_canonical_frame(5, raw_canon)

    # Sisipkan byte liar acak termasuk pola mirip SOF parsial
    garbage = bytes([0x12, 0x55, 0x99, 0xAA, 0xED, 0x55, 0xAA, 0x00])
    stream_with_garbage = garbage + valid_pkt

    fid, payload, next_offset = decode_packet(stream_with_garbage, 0)
    assert fid == 5
    recon = decode_rle_payload_to_canonical(payload)
    assert recon == raw_canon


def test_run_length_overflow_rejection():
    """Memverifikasi bahwa run length > 128 memicu galat saat dekompresi kanonik."""
    # Buat payload dengan run 150 pada baris pertama
    bad_payload = bytes([150]) + bytes([128] * 63)
    with pytest.raises(ValueError, match="melebihi batas 128"):
        decode_rle_payload_to_canonical(bad_payload)


def test_false_sof_resync():
    """Memverifikasi bahwa pola SOF palsu diabaikan dan parser mencari dari sof_pos + 1 untuk menemukan frame valid."""
    raw_canon = bytes([0] * FRAME_BYTES)
    valid_pkt = encode_canonical_frame(42, raw_canon)

    # Buat pola false SOF yang memiliki penanda 0x55 0xAA 0x5A tetapi length tidak valid (< 64)
    fake_sof_short = SOF_MARKER + bytes([0x00, 0x01, 0x00, 0x10]) + bytes([0x00] * 16) + bytes([0xED, 0x00])

    # Buat pola false SOF dengan length valid tetapi EOF salah
    fake_sof_bad_eof = SOF_MARKER + bytes([0x00, 0x01, 0x00, 0x40]) + bytes([0x00] * 64) + bytes([0xEE, 0x00])

    combined_stream = fake_sof_short + fake_sof_bad_eof + valid_pkt

    # Parser harus melewati kedua false SOF dan menemukan frame 42
    fid, payload, next_offset = decode_packet(combined_stream, 0)
    assert fid == 42
    recon = decode_rle_payload_to_canonical(payload)
    assert recon == raw_canon


def test_payload_len_max_format_limit():
    """Memverifikasi bahwa payload melebihi PAYLOAD_LEN_MAX (1024 B) melempar galat."""
    too_large_payload = bytes([1] * (PAYLOAD_LEN_MAX + 1))
    with pytest.raises(ValueError, match="di luar batas format valid"):
        encode_packet(1, too_large_payload)


def test_manifest_consistency():
    """Memverifikasi berkas manifest data/golden/stream_expected.txt terhadap hasil evaluasi stream."""
    manifest_path = "data/golden/stream_expected.txt"
    assert os.path.exists(manifest_path), f"Manifest {manifest_path} belum ada"

    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest_text = f.read()

    # Pastikan setiap vektor terdefinisi dalam manifest
    vectors = [
        "stream_clip",
        "stream_corrupt_checksum",
        "stream_truncated",
        "stream_byte_insertion",
        "stream_run_overflow",
        "stream_false_sof",
    ]
    for vec in vectors:
        assert f"VECTOR: {vec}" in manifest_text
        bin_path = f"data/golden/{vec}.bin"
        assert os.path.exists(bin_path)
        with open(bin_path, "rb") as bf:
            data = bf.read()
        eval_res = evaluate_stream(data)
        assert f"VALID_FRAMES: {eval_res['valid_frames']}" in manifest_text
        assert f"CHECKSUM_ERRORS: {eval_res['checksum_errors']}" in manifest_text
        assert f"LENGTH_ERRORS: {eval_res['length_errors']}" in manifest_text
        assert f"RUN_ERRORS: {eval_res['run_errors']}" in manifest_text
        assert f"RESYNCS: {eval_res['resyncs']}" in manifest_text
