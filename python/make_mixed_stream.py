"""python/make_mixed_stream.py
Pembuat aliran campuran UART (Mixed Video + Audio Stream) deterministik untuk Milestone M4.
Menghasilkan vektor uji aliran campuran dengan 90 frame video dan audio sintetis (pola rampa).
Juga menyediakan oracle perangkat keras AudioFakeFPGA dan pembangkitan manifes hasil evaluasi.
"""

from __future__ import annotations
import argparse
import os
import struct
import sys
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from python.stream_encoder import (
    SOF_MARKER,
    EOF_BYTE,
    PAYLOAD_LEN_MIN,
    PAYLOAD_LEN_MAX,
    compute_checksum,
    decode_rle_payload_to_canonical,
)
from python.stream_player import split_stream_into_packets
from python.ascii_renderer import render_ascii_frame


# -----------------------------------------------------------------------------
# 1. Model Oracle AudioFakeFPGA
# -----------------------------------------------------------------------------
class AudioFakeFPGA:
    """Model perangkat lunak penerima FPGA dengan dukungan paket Audio dan Video.
    
    Digunakan sebagai oracle untuk memverifikasi kebenaran parsing stream campuran.
    """

    def __init__(self, reject_packet_predicate: Optional[Callable[[int, int], bool]] = None):
        self._rx_buf = bytearray()
        self.output_ascii = bytearray()
        self.received_audio_bytes = bytearray()
        self.valid_frames_count: int = 0
        self.checksum_errors: int = 0
        self.length_errors: int = 0
        self.run_errors: int = 0
        self.resyncs_count: int = 0
        self.audio_packets_count: int = 0
        self.received_fids: List[int] = []
        self.received_aud_fids: List[int] = []
        self.reject_predicate = reject_packet_predicate

    def reset(self) -> None:
        self._rx_buf.clear()
        self.output_ascii.clear()
        self.received_audio_bytes.clear()
        self.valid_frames_count = 0
        self.checksum_errors = 0
        self.length_errors = 0
        self.run_errors = 0
        self.resyncs_count = 0
        self.audio_packets_count = 0
        self.received_fids.clear()
        self.received_aud_fids.clear()

    def receive_bytes(self, data: bytes) -> None:
        self._rx_buf.extend(data)
        self._process_buffer()

    def finish(self) -> None:
        if len(self._rx_buf) > 0:
            sof_pos = self._rx_buf.find(SOF_MARKER)
            if sof_pos != -1:
                self.length_errors += 1
            self._rx_buf.clear()

    def _process_buffer(self) -> None:
        idx = 0
        while True:
            buf_len = len(self._rx_buf)
            sof_pos = self._rx_buf.find(SOF_MARKER, idx)
            if sof_pos == -1:
                keep = min(buf_len, 2)
                if keep > 0:
                    del self._rx_buf[: buf_len - keep]
                else:
                    self._rx_buf.clear()
                break

            if sof_pos > idx:
                self.resyncs_count += 1

            if sof_pos + 7 > buf_len:
                del self._rx_buf[:sof_pos]
                break

            frame_id, payload_len = struct.unpack(">HH", self._rx_buf[sof_pos + 3 : sof_pos + 7])

            if payload_len < PAYLOAD_LEN_MIN or payload_len > PAYLOAD_LEN_MAX:
                self.length_errors += 1
                self.resyncs_count += 1
                idx = sof_pos + 1
                continue

            packet_total_len = 3 + 4 + payload_len + 1 + 1
            if sof_pos + packet_total_len > buf_len:
                del self._rx_buf[:sof_pos]
                break

            payload_start = sof_pos + 7
            payload_end = payload_start + payload_len
            payload = bytes(self._rx_buf[payload_start:payload_end])
            eof_val = self._rx_buf[payload_end]
            received_chk = self._rx_buf[payload_end + 1]

            if eof_val != EOF_BYTE:
                self.length_errors += 1
                self.resyncs_count += 1
                idx = sof_pos + 1
                continue

            calc_chk = compute_checksum(frame_id, payload_len, payload)
            if calc_chk != received_chk:
                self.checksum_errors += 1
                idx = sof_pos + 1
                continue

            # Paket valid
            is_audio = (frame_id & 0x8000) != 0
            if is_audio:
                # Periksa apakah paket ditolak oleh FIFO (aud_reject)
                is_rejected = False
                if self.reject_predicate is not None:
                    is_rejected = self.reject_predicate(frame_id, payload_len)

                if not is_rejected:
                    self.audio_packets_count += 1
                    self.received_audio_bytes.extend(payload)
                    self.received_aud_fids.append(frame_id)
            else:
                # Paket Video
                try:
                    canonical = decode_rle_payload_to_canonical(payload)
                    ascii_data = render_ascii_frame(canonical)
                    self.output_ascii.extend(ascii_data)
                    self.valid_frames_count += 1
                    self.received_fids.append(frame_id)
                except ValueError:
                    self.run_errors += 1

            del self._rx_buf[: sof_pos + packet_total_len]
            idx = 0


# -----------------------------------------------------------------------------
# 2. Pembangkitan Paket Audio Sintetis Deterministik
# -----------------------------------------------------------------------------
def make_audio_payload_ramp(start_sample_idx: int, length: int) -> bytes:
    """Menghasilkan payload audio sintetis berupa rampa linear deterministik 8-bit."""
    return bytes([(start_sample_idx + i) % 256 for i in range(length)])


def encode_audio_packet(frame_id: int, payload: bytes) -> bytes:
    """Mengemas payload audio ke dalam format paket stream UART (FID bit 15 = 1)."""
    assert (frame_id & 0x8000) != 0, f"frame_id audio harus memiliki bit 15=1 (didapat {hex(frame_id)})"
    payload_len = len(payload)
    assert PAYLOAD_LEN_MIN <= payload_len <= PAYLOAD_LEN_MAX, f"Panjang payload {payload_len} di luar batas 64..1024"
    header = SOF_MARKER + struct.pack(">HH", frame_id, payload_len)
    chk = compute_checksum(frame_id, payload_len, payload)
    return header + payload + bytes([EOF_BYTE, chk])


def bin_to_hex_lines(bin_data: bytes) -> str:
    """Mengonversi data biner ke format teks baris hex dua-karakter untuk VHDL hread."""
    return "".join(f"{b:02X}\n" for b in bin_data)


# -----------------------------------------------------------------------------
# 3. Pembangkitan Skenario Aliran Campuran
# -----------------------------------------------------------------------------
def load_video_packets_from_clip(clip_path: str = "data/golden/stream_clip.bin") -> List[bytes]:
    with open(clip_path, "rb") as f:
        stream_data = f.read()
    packets = split_stream_into_packets(stream_data)
    assert len(packets) == 90, f"Expected 90 video packets, found {len(packets)}"
    return packets


def build_scenario_packets(scenario: str, video_packets: List[bytes]) -> Tuple[bytes, Optional[Callable[[int, int], bool]]]:
    """Membangun aliran byte lengkap untuk skenario tertentu.
    
    Format urutan:
    - Pre-roll: 4 paket audio (1.068 B = 4 * 267 B), FID = 0x8000..0x8003
    - 90 pasangan: video packet k disusul audio packet k+4 (pola 267, 267, 266 B), FID = 0x8004..0x805D
    """
    total_audio_pkts = 4 + 90
    aud_lengths = [267, 267, 267, 267]
    for k in range(90):
        aud_lengths.append(267 if (k % 3 != 2) else 266)

    # Bangun seluruh payload audio normal
    aud_payloads: List[bytes] = []
    curr_sample = 0
    for length in aud_lengths:
        aud_payloads.append(make_audio_payload_ramp(curr_sample, length))
        curr_sample += length

    reject_predicate = None

    if scenario == "clean":
        pass

    elif scenario == "corrupt_checksum":
        # Paket audio ke-10 (FID 0x800A) dibuat checksum salah
        pass

    elif scenario == "truncated":
        # Stream dipotong di tengah paket audio ke-50
        pass

    elif scenario == "corrupt_eof":
        # Paket audio ke-15 EOF diganti 0xEE (bukan 0xED)
        pass

    elif scenario == "corrupt_len_63":
        # Paket audio ke-20 dibuat dengan LEN = 63 (< 64)
        pass

    elif scenario == "payload_false_sof":
        # Paket audio ke-25 menyisipkan pola 55 AA 5A di dalam payload
        pass

    elif scenario == "aud_reject":
        # Paket audio ke-12 ditolak oleh FIFO (aud_reject = '1')
        def reject_p(fid: int, length: int) -> bool:
            return fid == 0x800C  # Paket audio ke-12 (0x8000 + 12)
        reject_predicate = reject_p

    # Rakit stream
    stream_out = bytearray()
    
    # 1. Pre-roll 4 audio packets
    for i in range(4):
        fid = 0x8000 + i
        payload = aud_payloads[i]
        pkt = bytearray(encode_audio_packet(fid, payload))
        stream_out.extend(pkt)

    # 2. 90 Frame video + 90 Audio
    for k in range(90):
        # Video packet k
        stream_out.extend(video_packets[k])

        # Audio packet k+4
        aud_idx = 4 + k
        fid = 0x8000 + aud_idx
        payload = aud_payloads[aud_idx]

        if scenario == "payload_false_sof" and aud_idx == 25:
            # Sisipkan 55 AA 5A di tengah payload
            mod_payload = bytearray(payload)
            mod_payload[10:13] = b"\x55\xAA\x5A"
            pkt = bytearray(encode_audio_packet(fid, bytes(mod_payload)))

        elif scenario == "corrupt_len_63" and aud_idx == 20:
            # Buat paket cacat dengan LEN = 63
            p63 = payload[:63]
            header = SOF_MARKER + struct.pack(">HH", fid, 63)
            chk = compute_checksum(fid, 63, p63)
            pkt = bytearray(header + p63 + bytes([EOF_BYTE, chk]))

        elif scenario == "corrupt_eof" and aud_idx == 15:
            pkt = bytearray(encode_audio_packet(fid, payload))
            # Ganti byte EOF (posisi len(pkt) - 2) dengan 0xEE
            pkt[-2] = 0xEE

        elif scenario == "corrupt_checksum" and aud_idx == 10:
            pkt = bytearray(encode_audio_packet(fid, payload))
            pkt[-1] ^= 0xFF

        else:
            pkt = bytearray(encode_audio_packet(fid, payload))

        if scenario == "truncated" and aud_idx == 93:
            # Potong paket terakhir di tengah payload dan akhiri stream
            stream_out.extend(pkt[: 7 + 100])
            break

        stream_out.extend(pkt)

    return bytes(stream_out), reject_predicate


def generate_all_scenarios(out_dir: str = "data/golden", video_clip: str = "data/golden/stream_clip.bin") -> Dict[str, dict]:
    os.makedirs(out_dir, exist_ok=True)
    video_packets = load_video_packets_from_clip(video_clip)

    scenarios = [
        "clean",
        "corrupt_checksum",
        "truncated",
        "corrupt_eof",
        "corrupt_len_63",
        "payload_false_sof",
        "aud_reject",
    ]

    manifest_data = {}
    manifest_lines = [
        "# Manifest Hasil Ekspektasi Pengujian Streaming Campuran Audio-Video (Milestone M4)",
        "# Format per vektor:",
        "# VECTOR: <nama>",
        "# VALID_FRAMES: <int>",
        "# CHECKSUM_ERRORS: <int>",
        "# LENGTH_ERRORS: <int>",
        "# RUN_ERRORS: <int>",
        "# RESYNCS: <int>",
        "# AUDIO_PKTS: <int>",
        "# AUDIO_BYTES: <int>",
        "",
    ]

    for sc in scenarios:
        vec_name = f"mixed_stream_{sc}"
        stream_bytes, rej_pred = build_scenario_packets(sc, video_packets)

        bin_path = os.path.join(out_dir, f"{vec_name}.bin")
        hex_path = os.path.join(out_dir, f"{vec_name}.hex")

        with open(bin_path, "wb") as f:
            f.write(stream_bytes)

        with open(hex_path, "w", encoding="utf-8") as f:
            f.write(bin_to_hex_lines(stream_bytes))

        # Evaluasi dengan oracle AudioFakeFPGA
        fpga = AudioFakeFPGA(reject_packet_predicate=rej_pred)
        fpga.receive_bytes(stream_bytes)
        fpga.finish()

        res = {
            "valid_frames": fpga.valid_frames_count,
            "chk_errors": fpga.checksum_errors,
            "len_errors": fpga.length_errors,
            "run_errors": fpga.run_errors,
            "resyncs": fpga.resyncs_count,
            "audio_packets": fpga.audio_packets_count,
            "audio_bytes": len(fpga.received_audio_bytes),
        }
        manifest_data[vec_name] = res

        manifest_lines.extend([
            f"VECTOR: {vec_name}",
            f"VALID_FRAMES: {res['valid_frames']}",
            f"CHECKSUM_ERRORS: {res['chk_errors']}",
            f"LENGTH_ERRORS: {res['len_errors']}",
            f"RUN_ERRORS: {res['run_errors']}",
            f"RESYNCS: {res['resyncs']}",
            f"AUDIO_PKTS: {res['audio_packets']}",
            f"AUDIO_BYTES: {res['audio_bytes']}",
            "",
        ])

    manifest_path = os.path.join(out_dir, "mixed_stream_expected.txt")
    with open(manifest_path, "w", encoding="utf-8") as f:
        f.write("\n".join(manifest_lines) + "\n")

    return manifest_data


def main():
    parser = argparse.ArgumentParser(description="Pembangkit stream biner campuran Audio+Video Bad Apple!!")
    parser.add_argument("--out-dir", default="data/golden", help="Direktori keluaran berkas biner dan manifes")
    parser.add_argument("--video-clip", default="data/golden/stream_clip.bin", help="Jalur stream video 90 frame")
    args = parser.parse_args()

    print(f"Menghasilkan aliran campuran audio+video ke: {args.out_dir}")
    manifest = generate_all_scenarios(args.out_dir, args.video_clip)
    print(f"Selesai! {len(manifest)} skenario berhasil dibuat:")
    for k, v in manifest.items():
        print(f"  - {k:28s}: Video={v['valid_frames']}, AudioPkts={v['audio_packets']}, AudioBytes={v['audio_bytes']}, Err(Chk={v['chk_errors']}, Len={v['len_errors']}, Res={v['resyncs']})")


if __name__ == "__main__":
    main()
