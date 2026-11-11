"""Modul Audio Jalur A2 (FPGA Streaming Audio PCM 8-bit 8 kHz).

Mengimplementasikan:
1. Konversi berkas audio WAV 44,1 kHz stereo menjadi PCM 8-bit unsigned mono 8 kHz (via FFmpeg).
2. Pola pemotongan sampel audio per frame (pola 267, 267, 266 sampel per 3 frame = 800 sampel per 0,1 s).
3. Penyandian dan penguraian paket audio streaming sesuai docs/PROTOCOL.md (D-14):
   SOF (3B: 0x55 0xAA 0x5A) | FRAME_ID (2B: bit 15 = 1) | PAYLOAD_LEN (2B) | PAYLOAD (N B) | EOF (1B: 0xED) | CHK (1B)
4. Model perangkat lunak AudioFakeFPGA (ekstensi FakeFPGA untuk audio dan video multiplexing).
"""

import os
import sys
import struct
import subprocess
from typing import List, Tuple, Optional, Dict, Any

# Pastikan path python modul tersedia
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stream_encoder import (
    SOF_MARKER,
    EOF_BYTE,
    PAYLOAD_LEN_MIN,
    PAYLOAD_LEN_MAX,
    compute_checksum,
    decode_rle_payload_to_canonical,
)
from stream_player import FakeFPGA as BaseFakeFPGA, render_ascii_frame


def get_audio_packet_payload_len(frame_index: int) -> int:
    """Mengembalikan panjang payload audio untuk frame tertentu.

    Laju audio 8.000 Hz pada 30 FPS = 266,666... sampel/frame.
    Menggunakan pola periodik 3 frame: 267, 267, 266 sampel.
    Total per 3 frame = 267 + 267 + 266 = 800 sampel (tepat 8.000 sampel/detik).
    """
    if (frame_index % 3) in (0, 1):
        return 267
    else:
        return 266


def convert_wav_to_pcm_u8(input_wav_path: str, output_pcm_path: Optional[str] = None) -> bytes:
    """Mengonversi WAV 44,1 kHz stereo menjadi PCM unsigned 8-bit mono 8 kHz menggunakan FFmpeg.

    Parameter filter:
    - Low-pass cut-off 3.600 Hz (mencegah aliasing di bawah batas Nyquist 4 kHz).
    - Sample rate: 8.000 Hz.
    - Channels: 1 (mono).
    - Format: pcm_u8.
    """
    if not os.path.exists(input_wav_path):
        raise FileNotFoundError(f"Berkas audio masukan tidak ditemukan: {input_wav_path}")

    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        input_wav_path,
        "-af",
        "lowpass=f=3600",
        "-ar",
        "8000",
        "-ac",
        "1",
        "-f",
        "u8",
        "-c:a",
        "pcm_u8",
    ]

    if output_pcm_path:
        cmd.append(output_pcm_path)
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with open(output_pcm_path, "rb") as f:
            pcm_data = f.read()
    else:
        cmd.append("pipe:1")
        res = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        pcm_data = res.stdout

    return pcm_data


def slice_audio_for_stream(pcm_bytes: bytes, num_frames: int = 6532) -> List[bytes]:
    """Memotong data PCM menjadi list muatan paket audio untuk setiap frame sesuai pola 267, 267, 266."""
    packets: List[bytes] = []
    offset = 0
    total_len = len(pcm_bytes)

    for f_idx in range(num_frames):
        chunk_len = get_audio_packet_payload_len(f_idx)
        if offset + chunk_len <= total_len:
            chunk = pcm_bytes[offset : offset + chunk_len]
        elif offset < total_len:
            # Sisa akhir: padding dengan level hening 0x80
            chunk = pcm_bytes[offset:] + bytes([0x80] * (chunk_len - (total_len - offset)))
        else:
            # Lewat akhir lagu: level hening 0x80 penuh
            chunk = bytes([0x80] * chunk_len)

        packets.append(chunk)
        offset += chunk_len

    return packets


def encode_audio_packet(index: int, samples: bytes) -> bytes:
    """Mengemas muatan sampel audio menjadi paket serial streaming resmi.

    Format paket (D-14):
    - SOF: 0x55, 0xAA, 0x5A (3B)
    - FRAME_ID: 0x8000 | (index & 0x7FFF) (2B, big-endian) -> bit 15 = '1' menandai paket audio
    - PAYLOAD_LEN: len(samples) (2B, big-endian)
    - PAYLOAD: samples (N B, rentang 64 .. 1024)
    - EOF: 0xED (1B)
    - CHECKSUM: XOR dari header, payload, dan EOF (1B)
    """
    payload_len = len(samples)
    if payload_len < PAYLOAD_LEN_MIN or payload_len > PAYLOAD_LEN_MAX:
        raise ValueError(
            f"Panjang payload audio {payload_len} di luar batas aman [{PAYLOAD_LEN_MIN}..{PAYLOAD_LEN_MAX}]"
        )

    # Bit 15 di-set '1' untuk menandai paket audio
    frame_id = 0x8000 | (index & 0x7FFF)

    header = SOF_MARKER + struct.pack(">HH", frame_id, payload_len)
    chk = compute_checksum(frame_id, payload_len, samples)
    footer = bytes([EOF_BYTE, chk])

    return header + samples + footer


def decode_audio_packet(packet_bytes: bytes) -> Tuple[int, bytes]:
    """Mendekode satu paket audio serial utuh dan memvalidasi keabsahannya.

    Mengembalikan tuple: (audio_index, payload_samples).
    Membangkitkan ValueError jika struktur paket atau checksum cacat.
    """
    if len(packet_bytes) < 9:
        raise ValueError(f"Ukuran paket terlalu pendek ({len(packet_bytes)} B < 9 B)")

    if packet_bytes[:3] != SOF_MARKER:
        raise ValueError(f"SOF marker tidak valid: {packet_bytes[:3].hex()}")

    frame_id, payload_len = struct.unpack(">HH", packet_bytes[3:7])

    if (frame_id & 0x8000) == 0:
        raise ValueError(f"Bukan paket audio: bit 15 FRAME_ID bernilai 0 (FRAME_ID={frame_id:#06x})")

    if len(packet_bytes) != 3 + 4 + payload_len + 2:
        raise ValueError(
            f"Ukuran paket {len(packet_bytes)} B tidak cocok dengan PAYLOAD_LEN {payload_len} B"
        )

    eof_val = packet_bytes[-2]
    if eof_val != EOF_BYTE:
        raise ValueError(f"EOF marker tidak valid: {eof_val:#04x} (diharapkan {EOF_BYTE:#04x})")

    payload = packet_bytes[7 : 7 + payload_len]
    received_chk = packet_bytes[-1]
    calc_chk = compute_checksum(frame_id, payload_len, payload)

    if calc_chk != received_chk:
        raise ValueError(
            f"Checksum galat: terhitung {calc_chk:#04x} != diterima {received_chk:#04x}"
        )

    audio_index = frame_id & 0x7FFF
    return audio_index, payload


class AudioFakeFPGA(BaseFakeFPGA):
    """Model perangkat keras FakeFPGA yang mendukung penerimaan video dan audio secara multiplexed.

    - Paket Video (bit 15 FRAME_ID = '0'):
      Didekode ke format kanonik 1024 B, dirender ke ASCII 1059 B, menaikkan valid_frames_count,
      dan mencatat FRAME_ID pada received_fids.
    - Paket Audio (bit 15 FRAME_ID = '1'):
      Dialihkan ke antrean audio (audio_samples & audio_packets), menaikkan cnt_audio_packets.
      TIDAK menaikkan valid_frames_count, TIDAK masuk received_fids, dan TIDAK menghasilkan ASCII.
    - Aturan deteksi galat (checksum_errors, length_errors, resyncs_count) identik untuk semua tipe paket.
    """

    def __init__(self):
        super().__init__()
        self.cnt_audio_packets: int = 0
        self.audio_samples: bytearray = bytearray()
        self.audio_packets: List[Tuple[int, bytes]] = []

    def reset(self) -> None:
        """Mereset seluruh status video dan audio."""
        super().reset()
        self.cnt_audio_packets = 0
        self.audio_samples.clear()
        self.audio_packets.clear()

    def _process_buffer(self) -> None:
        """Mengurai aliran byte serial untuk paket video dan paket audio."""
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

            # Paket Lolos Validasi! Periksa tipe paket berdasarkan bit 15 FRAME_ID:
            if (frame_id & 0x8000) != 0:
                # -------------------------------------------------------------
                # PAKET AUDIO (D-14): Alihkan ke penampung audio
                # -------------------------------------------------------------
                self.audio_samples.extend(payload)
                self.audio_packets.append((frame_id & 0x7FFF, payload))
                self.cnt_audio_packets += 1
                # TIDAK menaikkan valid_frames_count, received_fids, atau _output_ascii!
            else:
                # -------------------------------------------------------------
                # PAKET VIDEO: Dekode RLE ke kanonik lalu render ASCII 1059 B
                # -------------------------------------------------------------
                try:
                    canonical = decode_rle_payload_to_canonical(payload)
                    ascii_data = render_ascii_frame(canonical)
                    self._output_ascii.extend(ascii_data)
                    self.valid_frames_count += 1
                    self.received_fids.append(frame_id)
                except ValueError:
                    self.run_errors += 1

            del self._rx_buf[: sof_pos + packet_total_len]
            idx = 0


# Alias FakeFPGA di modul ini menunjuk ke AudioFakeFPGA
FakeFPGA = AudioFakeFPGA
