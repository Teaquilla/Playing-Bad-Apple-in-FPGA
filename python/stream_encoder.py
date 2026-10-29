"""Modul Penyandi Aliran Streaming UART (python/stream_encoder.py).

Mengimplementasikan protokol paket streaming resmi sesuai docs/PROTOCOL.md:
[SOF 3B: 0x55 0xAA 0x5A] [FRAME_ID 2B] [PAYLOAD_LEN 2B] [PAYLOAD N B] [EOF 1B: 0xED] [CHECKSUM 1B]
"""

import os
import struct
import numpy as np
from typing import Tuple, List, Optional
import sys

# Tambahkan path python jika dijalankan secara mandiri
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from canonical import FRAME_WIDTH, FRAME_HEIGHT, FRAME_BYTES, unpack_frame, pack_frame
from video_codecs.rle_line import RleLineCodec

SOF_MARKER = bytes([0x55, 0xAA, 0x5A])
EOF_MARKER = bytes([0xED])
EOF_BYTE = 0xED

PAYLOAD_LEN_MIN = 64
PAYLOAD_LEN_MAX = 1024


def compute_checksum(frame_id: int, payload_len: int, payload: bytes) -> int:
    """Menghitung XOR akumulatif 8-bit dari FRAME_ID, PAYLOAD_LEN, PAYLOAD, dan EOF (0xED)."""
    header = struct.pack(">HH", frame_id, payload_len)
    chk = 0
    for b in header:
        chk ^= b
    for b in payload:
        chk ^= b
    chk ^= EOF_BYTE
    return chk


def encode_packet(frame_id: int, rle_payload: bytes) -> bytes:
    """Mengemas payload RLE ke dalam format paket lengkap sesuai PROTOCOL.md.
    
    Melempar ValueError bila panjang payload melebihi PAYLOAD_LEN_MAX (1024 B).
    Batas ini merupakan batasan format resmi (aman karena frame Bad Apple terpadat nyata = 707 B).
    """
    payload_len = len(rle_payload)
    if payload_len < PAYLOAD_LEN_MIN or payload_len > PAYLOAD_LEN_MAX:
        raise ValueError(
            f"Payload RLE frame {frame_id} di luar batas format valid ({payload_len} byte; batas: {PAYLOAD_LEN_MIN}..{PAYLOAD_LEN_MAX} byte)"
        )
    if frame_id < 0 or frame_id > 65535:
        raise ValueError(f"FRAME_ID {frame_id} tidak valid")

    chk = compute_checksum(frame_id, payload_len, rle_payload)
    header = SOF_MARKER + struct.pack(">HH", frame_id, payload_len)
    footer = EOF_MARKER + bytes([chk])
    return header + rle_payload + footer


def encode_canonical_frame(frame_id: int, canonical_bytes: bytes) -> bytes:
    """Mengodekan 1 frame kanonik 1024-byte ke paket streaming RLE."""
    if len(canonical_bytes) != FRAME_BYTES:
        raise ValueError(f"Ukuran frame kanonik {len(canonical_bytes)} != {FRAME_BYTES}")

    pixels_2d = unpack_frame(canonical_bytes)
    # Encode row-by-row menggunakan RleLineCodec
    chunks = []
    for y in range(FRAME_HEIGHT):
        chunks.append(RleLineCodec.encode_row(pixels_2d[y, :]))
    payload = b"".join(chunks)
    return encode_packet(frame_id, payload)


def decode_packet(stream: bytes, offset: int = 0) -> Tuple[int, bytes, int]:
    """Mendekode 1 paket dari aliran bytes dengan perlindungan sinkron palsu.

    Mengembalikan: (frame_id, rle_payload, next_offset)
    Jika sinkron palsu terjadi, pencarian dilanjutkan dari (sof_pos + 1).
    """
    stream_len = len(stream)
    idx = offset

    while idx <= stream_len - 9:  # Minimal ukuran paket = 9 + 64 = 73 B
        # Cari penanda SOF
        sof_pos = stream.find(SOF_MARKER, idx)
        if sof_pos == -1 or sof_pos + 7 > stream_len:
            raise ValueError("Penanda SOF tidak ditemukan atau stream terpotong")

        # Ekstrak FRAME_ID dan PAYLOAD_LEN
        frame_id, payload_len = struct.unpack(">HH", stream[sof_pos + 3 : sof_pos + 7])

        # Validasi batas panjang
        if payload_len < PAYLOAD_LEN_MIN or payload_len > PAYLOAD_LEN_MAX:
            # Sinkron palsu! Lanjut mencari dari 1 byte setelah SOF palsu
            idx = sof_pos + 1
            continue

        packet_total_len = 3 + 4 + payload_len + 1 + 1  # SOF + Hdr + Payload + EOF + Checksum
        if sof_pos + packet_total_len > stream_len:
            # Paket terpotong (truncated)
            raise ValueError(f"Paket terpotong: butuh {packet_total_len} byte dari offset {sof_pos}, sisa stream {stream_len - sof_pos}")

        payload_start = sof_pos + 7
        payload_end = payload_start + payload_len
        payload = stream[payload_start:payload_end]

        eof_val = stream[payload_end]
        received_chk = stream[payload_end + 1]

        # Validasi EOF
        if eof_val != EOF_BYTE:
            # Sinkron palsu! Lanjut dari sof_pos + 1
            idx = sof_pos + 1
            continue

        # Validasi Checksum
        calc_chk = compute_checksum(frame_id, payload_len, payload)
        if calc_chk != received_chk:
            # Checksum mismatch! Jika ini kebetulan data acak mirip paket, lanjut cari dari sof_pos + 1
            idx = sof_pos + 1
            continue

        # Paket valid ditemukan!
        return frame_id, payload, sof_pos + packet_total_len

    raise ValueError("Tidak ada paket valid yang dapat didekode dari offset yang diberikan")


def decode_rle_payload_to_canonical(payload: bytes) -> bytes:
    """Mendekode payload RLE per baris ke frame kanonik 1024-byte."""
    rows = []
    p_offset = 0
    p_len = len(payload)

    for y in range(FRAME_HEIGHT):
        row = np.zeros(FRAME_WIDTH, dtype=np.uint8)
        pos = 0
        current_color = 0

        while pos < FRAME_WIDTH:
            if p_offset >= p_len:
                raise ValueError(f"Payload RLE terpotong pada baris {y}, piksel {pos}")
            run_len = payload[p_offset]
            p_offset += 1

            if run_len > 128:
                raise ValueError(f"Run length {run_len} melebihi batas 128 pada baris {y}")
            if pos + run_len > FRAME_WIDTH:
                raise ValueError(f"Run length membuat baris {y} melebihi 128 piksel: pos={pos}, run={run_len}")

            if current_color == 1:
                row[pos : pos + run_len] = 1

            pos += run_len
            current_color = 1 - current_color

        rows.append(row)

    if p_offset != p_len:
        raise ValueError(f"Sisa byte payload tidak terpakai: tersisa {p_len - p_offset} byte")

    pixels_2d = np.vstack(rows)
    return pack_frame(pixels_2d)


# ==============================================================================
# Generator Vektor Uji Golden & Corrupted
# ==============================================================================

def export_golden_stream(frames_bin_path: str, out_bin_path: str, out_hex_path: Optional[str] = None) -> bytes:
    """Menghasilkan aliran paket streaming dari file frames.bin kanonik."""
    with open(frames_bin_path, "rb") as f:
        raw_frames = f.read()

    total_frames = len(raw_frames) // FRAME_BYTES
    stream_packets = []

    for fid in range(total_frames):
        canonical_bytes = raw_frames[fid * FRAME_BYTES : (fid + 1) * FRAME_BYTES]
        packet = encode_canonical_frame(fid, canonical_bytes)
        stream_packets.append(packet)

    full_stream = b"".join(stream_packets)

    os.makedirs(os.path.dirname(os.path.abspath(out_bin_path)), exist_ok=True)
    with open(out_bin_path, "wb") as f:
        f.write(full_stream)

    if out_hex_path:
        with open(out_hex_path, "w", encoding="utf-8") as f:
            for b in full_stream:
                f.write(f"{b:02X}\n")

    return full_stream


def export_corrupted_vectors(golden_stream: bytes, out_dir: str):
    """Menghasilkan 5 variasi aliran rusak untuk pengujian ketahanan parser & FPGA."""
    os.makedirs(out_dir, exist_ok=True)

    # 1. Checksum salah pada frame pertama
    # Struktur frame 0: SOF(3) + FRAME_ID(2) + LEN(2) + PAYLOAD(N) + EOF(1) + CHK(1)
    fid, payload_len = struct.unpack(">HH", golden_stream[3:7])
    chk_pos = 3 + 4 + payload_len + 1
    corrupt_chk = bytearray(golden_stream[: chk_pos + 1])
    corrupt_chk[chk_pos] ^= 0xFF  # Balik semua bit checksum
    with open(os.path.join(out_dir, "stream_corrupt_checksum.bin"), "wb") as f:
        f.write(corrupt_chk)
    with open(os.path.join(out_dir, "stream_corrupt_checksum.hex"), "w", encoding="utf-8") as f:
        for b in corrupt_chk:
            f.write(f"{b:02X}\n")

    # 2. Paket terpotong (truncated) di tengah payload baris
    trunc_len = 3 + 4 + (payload_len // 2)
    truncated = golden_stream[:trunc_len]
    with open(os.path.join(out_dir, "stream_truncated.bin"), "wb") as f:
        f.write(truncated)
    with open(os.path.join(out_dir, "stream_truncated.hex"), "w", encoding="utf-8") as f:
        for b in truncated:
            f.write(f"{b:02X}\n")

    # 3. Penyisipan byte liar (garbage bytes) sebelum paket
    garbage = bytes([0xAA, 0x12, 0x55, 0x99, 0xED, 0x00])
    with_garbage = garbage + golden_stream
    with open(os.path.join(out_dir, "stream_byte_insertion.bin"), "wb") as f:
        f.write(with_garbage)
    with open(os.path.join(out_dir, "stream_byte_insertion.hex"), "w", encoding="utf-8") as f:
        for b in with_garbage:
            f.write(f"{b:02X}\n")

    # 4. Run length meluap (> 128 piksel pada baris 0)
    # Buat payload baris 0 dengan run = 150
    overflow_row = bytes([150])  # Melebihi 128
    # Isi 63 baris lainnya dengan 128 (hitam polos)
    other_rows = bytes([128] * 63)
    overflow_payload = overflow_row + other_rows
    overflow_packet = encode_packet(0, overflow_payload)
    with open(os.path.join(out_dir, "stream_run_overflow.bin"), "wb") as f:
        f.write(overflow_packet)
    with open(os.path.join(out_dir, "stream_run_overflow.hex"), "w", encoding="utf-8") as f:
        for b in overflow_packet:
            f.write(f"{b:02X}\n")

    # 5. SOF palsu di dalam header/data sampah disusul paket valid sejati
    # Buat header palsu: SOF + LEN_PALSU(0x0010) + data sampah tanpa EOF/checksum cocok
    fake_sof = SOF_MARKER + bytes([0x00, 0x01, 0x00, 0x10]) + bytes([0xAA] * 16) + bytes([0x00, 0x00])
    false_sof_stream = fake_sof + golden_stream
    with open(os.path.join(out_dir, "stream_false_sof.bin"), "wb") as f:
        f.write(false_sof_stream)
    with open(os.path.join(out_dir, "stream_false_sof.hex"), "w", encoding="utf-8") as f:
        for b in false_sof_stream:
            f.write(f"{b:02X}\n")


def evaluate_stream(stream: bytes) -> dict:
    """Mengevaluasi aliran streaming persis seperti perilaku parser hardware FPGA.

    Mengembalikan dictionary:
    - valid_frames: int
    - checksum_errors: int
    - length_errors: int
    - run_errors: int
    - resyncs: int
    - received_fids: List[int]
    """
    res = {
        "valid_frames": 0,
        "checksum_errors": 0,
        "length_errors": 0,
        "run_errors": 0,
        "resyncs": 0,
        "received_fids": [],
    }

    stream_len = len(stream)
    idx = 0

    while idx <= stream_len - 3:
        sof_pos = stream.find(SOF_MARKER, idx)
        if sof_pos == -1:
            # Tidak ada lagi SOF
            break

        if sof_pos > idx:
            # Terdapat byte sampah sebelum SOF -> resinkronisasi
            res["resyncs"] += 1

        # Cek apakah header lengkap (minimal 7 byte dari sof_pos)
        if sof_pos + 7 > stream_len:
            res["length_errors"] += 1
            break

        frame_id, payload_len = struct.unpack(">HH", stream[sof_pos + 3 : sof_pos + 7])

        if payload_len < PAYLOAD_LEN_MIN or payload_len > PAYLOAD_LEN_MAX:
            res["length_errors"] += 1
            res["resyncs"] += 1
            idx = sof_pos + 1
            continue

        packet_total_len = 3 + 4 + payload_len + 1 + 1
        if sof_pos + packet_total_len > stream_len:
            # Paket terpotong (truncated)
            res["length_errors"] += 1
            break

        payload_start = sof_pos + 7
        payload_end = payload_start + payload_len
        payload = stream[payload_start:payload_end]
        eof_val = stream[payload_end]
        chk_val = stream[payload_end + 1]

        if eof_val != EOF_BYTE:
            res["length_errors"] += 1
            res["resyncs"] += 1
            idx = sof_pos + 1
            continue

        calc_chk = compute_checksum(frame_id, payload_len, payload)
        if calc_chk != chk_val:
            res["checksum_errors"] += 1
            idx = sof_pos + 1
            continue

        # Validasi dekompresi RLE
        try:
            decode_rle_payload_to_canonical(payload)
            res["valid_frames"] += 1
            res["received_fids"].append(frame_id)
            idx = sof_pos + packet_total_len
        except ValueError as e:
            res["run_errors"] += 1
            idx = sof_pos + packet_total_len

    return res


def generate_manifest(golden_dir: str, out_manifest_path: str):
    """Menghasilkan berkas teks manifest stream_expected.txt untuk testbench VHDL dan pytest."""
    vector_names = [
        "stream_clip",
        "stream_corrupt_checksum",
        "stream_truncated",
        "stream_byte_insertion",
        "stream_run_overflow",
        "stream_false_sof",
    ]

    lines = [
        "# Manifest Hasil Ekspektasi Pengujian Streaming UART (docs/PROTOCOL.md)",
        "# Format per vektor:",
        "# VECTOR: <nama>",
        "# VALID_FRAMES: <int>",
        "# CHECKSUM_ERRORS: <int>",
        "# LENGTH_ERRORS: <int>",
        "# RUN_ERRORS: <int>",
        "# RESYNCS: <int>",
        "# FIRST_FRAME_ID: <int (-1 jika tidak ada)>",
        "# LAST_FRAME_ID: <int (-1 jika tidak ada)>",
        "",
    ]

    for name in vector_names:
        bin_file = os.path.join(golden_dir, f"{name}.bin")
        if not os.path.exists(bin_file):
            continue
        with open(bin_file, "rb") as f:
            data = f.read()
        eval_res = evaluate_stream(data)
        first_id = eval_res["received_fids"][0] if eval_res["received_fids"] else -1
        last_id = eval_res["received_fids"][-1] if eval_res["received_fids"] else -1

        lines.append(f"VECTOR: {name}")
        lines.append(f"VALID_FRAMES: {eval_res['valid_frames']}")
        lines.append(f"CHECKSUM_ERRORS: {eval_res['checksum_errors']}")
        lines.append(f"LENGTH_ERRORS: {eval_res['length_errors']}")
        lines.append(f"RUN_ERRORS: {eval_res['run_errors']}")
        lines.append(f"RESYNCS: {eval_res['resyncs']}")
        lines.append(f"FIRST_FRAME_ID: {first_id}")
        lines.append(f"LAST_FRAME_ID: {last_id}")
        lines.append("")

    with open(out_manifest_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    golden_bin = "data/golden/frames.bin"
    out_stream_bin = "data/golden/stream_clip.bin"
    out_stream_hex = "data/golden/stream_clip.hex"
    manifest_path = "data/golden/stream_expected.txt"

    print(f"Mengonversi {golden_bin} ke {out_stream_bin}...")
    stream_data = export_golden_stream(golden_bin, out_stream_bin, out_stream_hex)
    print(f"Berhasil menghasilkan {len(stream_data)} byte aliran streaming golden.")

    print("Menghasilkan vektor uji rusak di data/golden/...")
    export_corrupted_vectors(stream_data, "data/golden")
    
    print(f"Menghasilkan manifest di {manifest_path}...")
    generate_manifest("data/golden", manifest_path)
    print("Selesai menghasilkan seluruh vektor uji dan manifest M2.")

