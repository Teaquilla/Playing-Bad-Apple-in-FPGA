"""python/stream_player.py
Modul Host Pengirim Streaming UART Bad Apple (Milestone M2 & TASKS T2.8).

Fitur:
1. Transport Abstraksi:
   - Transport (ABC): write, read, close
   - SerialTransport: Menggunakan pyserial (lazy import agar tes unit tidak tergantung pyserial)
   - FakeTransport: Pengujian deterministik di memori
2. Jam Abstraksi:
   - Clock (ABC): now, sleep_until
   - MonotonicClock: Berbasis time.monotonic
   - FakeClock: Jam terkendali untuk tes deterministik tanpa sleep nyata
   - AudioClock: Antarmuka abstrak untuk sinkronisasi audio (opsi A1)
3. Model Perangkat Keras FakeFPGA:
   - Memvalidasi paket (SOF, FRAME_ID, PAYLOAD_LEN, EOF, CHECKSUM, resync)
   - Mendekode payload RLE kanonik dan me-render ASCII 1.059 B per frame valid
4. Penjadwalan Frame:
   - Waktu kirim frame n: t0 + n / FPS + (av_offset_ms / 1000.0)
   - Frame telat > 2 frame (t_now > t_sched + 2/FPS) dibuang (drop) tanpa dikirim
   - Pembacaan RsTx secara bersamaan via background reader thread (FPGA mengirim ~31,8 KB/s)
"""

from __future__ import annotations
import abc
import os
import sys
import struct
import threading
import time
from typing import Callable, List, Optional, Tuple, Dict, Any
import numpy as np

import wave
from pathlib import Path

# Pastikan akar direktori repositori terdaftar di sys.path
_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

# Import modul internal Bad Apple (gaya impor absolut konsisten)
from python.stream_encoder import (
    SOF_MARKER,
    EOF_BYTE,
    PAYLOAD_LEN_MIN,
    PAYLOAD_LEN_MAX,
    compute_checksum,
    decode_rle_payload_to_canonical,
)
from python.ascii_renderer import render_ascii_frame, ASCII_FRAME_LEN
from python.audio_player import SoundDeviceAudio, FakeAudioDevice, AudioClock


# ==============================================================================
# 1. Antarmuka & Implementasi Transport
# ==============================================================================

class Transport(abc.ABC):
    """Antarmuka abstrak untuk lapisan transmisi data byte."""

    @abc.abstractmethod
    def write(self, data: bytes) -> None:
        """Mengirimkan aliran byte ke perangkat."""
        pass

    @abc.abstractmethod
    def read(self, max_bytes: int = 4096) -> bytes:
        """Membaca byte yang tersedia dari perangkat."""
        pass

    @abc.abstractmethod
    def close(self) -> None:
        """Menutup koneksi transport."""
        pass


class SerialTransport(Transport):
    """Implementasi transport serial nyata menggunakan pyserial (lazy import). [DIASUMSIKAN sampai board fisik atau loopback adapter diuji]."""

    def __init__(self, port: str, baudrate: int = 921600, timeout: float = 0.05):
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        try:
            import serial  # Lazy import
        except ImportError as e:
            raise ImportError(
                "Pustaka 'pyserial' diperlukan untuk SerialTransport. "
                "Jalankan: pip install pyserial"
            ) from e

        self._ser = serial.Serial(
            port=self.port,
            baudrate=self.baudrate,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=self.timeout,
            write_timeout=1.0,
        )

    def write(self, data: bytes) -> None:
        if self._ser and self._ser.is_open:
            self._ser.write(data)

    def read(self, max_bytes: int = 4096) -> bytes:
        if self._ser and self._ser.is_open:
            return self._ser.read(max_bytes)
        return b""

    def close(self) -> None:
        if self._ser and self._ser.is_open:
            self._ser.close()


class FakeTransport(Transport):
    """Transport tiruan berbasis memori untuk pengujian deterministik."""

    def __init__(self, fake_fpga: Optional[FakeFPGA] = None):
        self.fake_fpga = fake_fpga
        self._tx_bytes = bytearray()
        self._rx_bytes = bytearray()
        self._lock = threading.Lock()
        self._closed = False

    def write(self, data: bytes) -> None:
        if self._closed:
            raise RuntimeError("Transport sudah ditutup")
        acquired = self._lock.acquire(timeout=1.0)
        if not acquired:
            raise TimeoutError("Deadlock: timeout 1.0 detik terlampaui saat menunggu lock transport")
        try:
            self._tx_bytes.extend(data)
        finally:
            self._lock.release()
        if self.fake_fpga is not None:
            self.fake_fpga.receive_bytes(data)

    def read(self, max_bytes: int = 4096) -> bytes:
        if self._closed:
            return b""
        if self.fake_fpga is not None:
            return self.fake_fpga.read_ascii(max_bytes)
        with self._lock:
            chunk = bytes(self._rx_bytes[:max_bytes])
            del self._rx_bytes[:max_bytes]
            return chunk

    def feed_rx(self, data: bytes) -> None:
        """Memasukkan data ke buffer pembacaan (untuk simulasi)."""
        with self._lock:
            self._rx_bytes.extend(data)

    def get_tx_data(self) -> bytes:
        with self._lock:
            return bytes(self._tx_bytes)

    def close(self) -> None:
        self._closed = True


# ==============================================================================
# 2. Antarmuka & Implementasi Jam (Clock)
# ==============================================================================

class Clock(abc.ABC):
    """Antarmuka waktu abstrak."""

    @abc.abstractmethod
    def now(self) -> float:
        """Mengembalikan timestamp saat ini dalam detik."""
        pass

    @abc.abstractmethod
    def sleep_until(self, target_time: float) -> None:
        """Menunda eksekusi hingga target_time tercapai."""
        pass


class MonotonicClock(Clock):
    """Jam berbasis time.monotonic untuk mode mandiri tanpa audio (--no-audio)."""

    def now(self) -> float:
        return time.monotonic()

    def sleep_until(self, target_time: float) -> None:
        delta = target_time - self.now()
        if delta > 0:
            time.sleep(delta)


# AudioClock diimpor langsung dari python.audio_player


class FakeClock(Clock):
    """Jam simulasi deterministik tanpa delay nyata."""

    def __init__(self, start_time: float = 0.0):
        self._current_time: float = start_time
        self.sleep_calls: List[float] = []

    def now(self) -> float:
        return self._current_time

    def advance(self, seconds: float) -> None:
        self._current_time += seconds

    def sleep_until(self, target_time: float) -> None:
        self.sleep_calls.append(target_time)
        if target_time > self._current_time:
            self._current_time = target_time


# ==============================================================================
# 3. Model Perilaku FakeFPGA
# ==============================================================================

class FakeFPGA:
    """Model penerima FPGA: memvalidasi paket serial dan menghasilkan ASCII 1059 B per frame."""

    def __init__(self):
        self._rx_buf = bytearray()
        self._output_ascii = bytearray()
        self._lock = threading.Lock()
        self.valid_frames_count: int = 0
        self.checksum_errors: int = 0
        self.length_errors: int = 0
        self.run_errors: int = 0
        self.resyncs_count: int = 0
        self.received_fids: List[int] = []

    def reset(self) -> None:
        """Mereset seluruh status dan penghitung FakeFPGA."""
        with self._lock:
            self._rx_buf.clear()
            self._output_ascii.clear()
            self.valid_frames_count = 0
            self.checksum_errors = 0
            self.length_errors = 0
            self.run_errors = 0
            self.resyncs_count = 0
            self.received_fids.clear()

    def receive_bytes(self, data: bytes) -> None:
        """Menerima aliran byte dari transport dan memproses paket secara bertahap."""
        with self._lock:
            self._rx_buf.extend(data)
            self._process_buffer()

    def finish(self) -> None:
        """Menandakan akhir transmisi stream dan memeriksa apakah ada paket terpotong di buffer."""
        with self._lock:
            if len(self._rx_buf) > 0:
                sof_pos = self._rx_buf.find(SOF_MARKER)
                if sof_pos != -1:
                    # Paket terpotong (truncated)
                    self.length_errors += 1
                self._rx_buf.clear()

    def _process_buffer(self) -> None:
        """Mengurai paket sesuai aturan PROTOCOL.md dengan dukungan resinkronisasi spekulatif."""
        idx = 0
        while True:
            buf_len = len(self._rx_buf)
            # Cari SOF marker (0x55, 0xAA, 0x5A)
            sof_pos = self._rx_buf.find(SOF_MARKER, idx)
            if sof_pos == -1:
                # Simpan 2 byte terakhir untuk kemungkinan SOF terpotong
                keep = min(buf_len, 2)
                if keep > 0:
                    del self._rx_buf[: buf_len - keep]
                else:
                    self._rx_buf.clear()
                break

            # Jika ada byte sampah sebelum SOF pertama yang valid
            if sof_pos > idx:
                self.resyncs_count += 1

            # Tunggu minimal header (SOF 3B + FID 2B + LEN 2B = 7B)
            if sof_pos + 7 > buf_len:
                # Belum cukup byte untuk membaca header, pertahankan dari sof_pos
                del self._rx_buf[:sof_pos]
                break

            frame_id, payload_len = struct.unpack(">HH", self._rx_buf[sof_pos + 3 : sof_pos + 7])

            # Validasi panjang payload (64 .. 1024)
            if payload_len < PAYLOAD_LEN_MIN or payload_len > PAYLOAD_LEN_MAX:
                self.length_errors += 1
                self.resyncs_count += 1
                idx = sof_pos + 1
                continue

            packet_total_len = 3 + 4 + payload_len + 1 + 1  # 9 + payload_len
            if sof_pos + packet_total_len > buf_len:
                # Paket belum lengkap di buffer, pertahankan dari sof_pos
                del self._rx_buf[:sof_pos]
                break

            payload_start = sof_pos + 7
            payload_end = payload_start + payload_len
            payload = bytes(self._rx_buf[payload_start:payload_end])
            eof_val = self._rx_buf[payload_end]
            received_chk = self._rx_buf[payload_end + 1]

            # Validasi EOF
            if eof_val != EOF_BYTE:
                self.length_errors += 1
                self.resyncs_count += 1
                idx = sof_pos + 1
                continue

            # Validasi Checksum
            calc_chk = compute_checksum(frame_id, payload_len, payload)
            if calc_chk != received_chk:
                self.checksum_errors += 1
                idx = sof_pos + 1
                continue

            # Paket valid! Dekode RLE ke kanonik lalu render ASCII 1059 B
            try:
                canonical = decode_rle_payload_to_canonical(payload)
                ascii_data = render_ascii_frame(canonical)
                self._output_ascii.extend(ascii_data)
                self.valid_frames_count += 1
                self.received_fids.append(frame_id)
            except ValueError:
                self.run_errors += 1

            # Buang paket yang sudah diproses dari buffer
            del self._rx_buf[: sof_pos + packet_total_len]
            idx = 0

    def read_ascii(self, max_bytes: int = 4096) -> bytes:
        with self._lock:
            chunk = bytes(self._output_ascii[:max_bytes])
            del self._output_ascii[:max_bytes]
            return chunk


# ==============================================================================
# 4. Stream Player & Penjadwal
# ==============================================================================

def split_stream_into_packets(stream: bytes) -> List[bytes]:
    """Memotong aliran byte streaming menjadi daftar paket individual."""
    packets = []
    idx = 0
    stream_len = len(stream)
    while idx <= stream_len - 9:
        sof_pos = stream.find(SOF_MARKER, idx)
        if sof_pos == -1 or sof_pos + 7 > stream_len:
            break
        _, payload_len = struct.unpack(">HH", stream[sof_pos + 3 : sof_pos + 7])
        packet_len = 3 + 4 + payload_len + 1 + 1
        if sof_pos + packet_len > stream_len:
            break
        packets.append(stream[sof_pos : sof_pos + packet_len])
        idx = sof_pos + packet_len
    return packets


class StreamPlayer:
    """Pemutar streaming UART: menjadwalkan dan mentransmisikan frame pada 30 FPS simultan dengan pembacaan terminal."""

    def __init__(
        self,
        transport: Transport,
        clock: Optional[Clock] = None,
        fps: float = 30.0,
        av_offset_ms: float = 0.0,  # Default 0 ms [DIASUMSIKAN]
        on_terminal_output: Optional[Callable[[bytes], None]] = None,
    ):
        self.transport = transport
        self.clock = clock if clock is not None else MonotonicClock()
        self.fps = fps
        self.av_offset_ms = av_offset_ms
        self.av_offset_sec = av_offset_ms / 1000.0
        self.on_terminal_output = on_terminal_output

        # Validasi batas negatif av_offset_ms
        min_offset_ms = -(2.0 / self.fps) * 1000.0
        if self.av_offset_ms < min_offset_ms:
            raise ValueError(
                f"--av-offset-ms ({self.av_offset_ms} ms) tidak boleh lebih negatif dari batas "
                f"minimum {min_offset_ms:.2f} ms pada {self.fps} FPS karena akan membuat frame awal "
                f"langsung terbuang sebagai frame telat."
            )

        # State pembacaan latar belakang
        self._reader_thread: Optional[threading.Thread] = None
        self._stop_reader = threading.Event()
        self.received_bytes_count: int = 0
        self.total_frames_count: int = 0
        self.dropped_frames_count: int = 0
        self.sent_frames_count: int = 0
        self.send_timestamps: List[float] = []
        self.mono_timestamps: List[float] = []
        self.clock_timestamps: List[float] = []
        self.scheduled_timestamps: List[float] = []
        self.reader_errors_count: int = 0
        self.first_reader_error: Optional[Exception] = None

    def start_reader(self) -> None:
        """Memulai thread pembacaan simultan untuk menerima keluaran ASCII dari FPGA."""
        if self._reader_thread is not None and self._reader_thread.is_alive():
            return
        self._stop_reader.clear()
        self._reader_thread = threading.Thread(target=self._reader_worker, daemon=True)
        self._reader_thread.start()

    def stop_reader(self, timeout: float = 2.0) -> None:
        """Menghentikan thread pembacaan simultan."""
        self._stop_reader.set()
        if self._reader_thread is not None and self._reader_thread.is_alive():
            self._reader_thread.join(timeout=timeout)
            self._reader_thread = None

    def _reader_worker(self) -> None:
        """Worker loop untuk membaca data serial secara non-blocking terhadap thread pengirim."""
        while not self._stop_reader.is_set():
            data = self.transport.read(4096)
            if data:
                self.received_bytes_count += len(data)
                if self.on_terminal_output:
                    try:
                        self.on_terminal_output(data)
                    except Exception as e:
                        self.reader_errors_count += 1
                        if self.first_reader_error is None:
                            self.first_reader_error = e
            else:
                time.sleep(0.001)

        # Drain sisa data yang masih ada di transport saat stop dipanggil
        while True:
            data = self.transport.read(4096)
            if not data:
                break
            self.received_bytes_count += len(data)
            if self.on_terminal_output:
                try:
                    self.on_terminal_output(data)
                except Exception as e:
                    self.reader_errors_count += 1
                    if self.first_reader_error is None:
                        self.first_reader_error = e

    def get_stats(self) -> Dict[str, Any]:
        """Mengembalikan statistik terkini pemutaran dan pembacaan stream."""
        stats = {
            "total_frames": self.total_frames_count,
            "sent_frames": self.sent_frames_count,
            "dropped_frames": self.dropped_frames_count,
            "received_bytes": self.received_bytes_count,
            "reader_errors": self.reader_errors_count,
            "first_reader_error": repr(self.first_reader_error) if self.first_reader_error else None,
            "send_timestamps": list(self.send_timestamps),
            "mono_timestamps": list(self.mono_timestamps),
            "clock_timestamps": list(self.clock_timestamps),
            "scheduled_timestamps": list(self.scheduled_timestamps),
        }
        if hasattr(self.clock, "callback_flags"):
            stats["audio_callback_flags"] = self.clock.callback_flags()
        if hasattr(self.clock, "get_discipline_stats"):
            stats["discipline_stats"] = self.clock.get_discipline_stats()
        return stats

    def play_packets(
        self,
        packets: List[bytes],
        start_frame: int = 0,
        max_frames: Optional[int] = None
    ) -> Dict[str, Any]:
        """Mengirimkan daftar paket frame dengan penjadwalan presisi clock.

        Frame n dijadwalkan pada: t0 + n / FPS + av_offset_sec.
        Bila t_now > t_sched + 2 / FPS, frame terlambat lebih dari 2 frame dan dibuang (drop).
        """
        if start_frame > 0 or max_frames is not None:
            end_idx = None if max_frames is None else start_frame + max_frames
            packets = packets[start_frame:end_idx]

        self.total_frames_count = len(packets)
        self.start_reader()
        t0 = self.clock.now()
        frame_interval = 1.0 / self.fps
        drop_threshold = 2.0 * frame_interval

        self.sent_frames_count = 0
        self.dropped_frames_count = 0
        self.send_timestamps.clear()
        self.mono_timestamps.clear()
        self.clock_timestamps.clear()
        self.scheduled_timestamps.clear()

        for n, packet in enumerate(packets):
            t_sched = t0 + (n * frame_interval) + self.av_offset_sec
            t_now = self.clock.now()

            # Pemeriksaan keterlambatan > 2 frame
            if t_now > t_sched + drop_threshold:
                # Frame terlambat: buang tanpa dikirim
                self.dropped_frames_count += 1
                continue

            # Tunggu hingga jadwal pengiriman tiba
            if t_now < t_sched:
                self.clock.sleep_until(t_sched)

            # Kirim paket ke FPGA
            self.transport.write(packet)
            self.sent_frames_count += 1
            now_clock = self.clock.now()
            self.send_timestamps.append(now_clock)
            self.mono_timestamps.append(time.monotonic())
            self.clock_timestamps.append(now_clock)
            self.scheduled_timestamps.append(t_sched)

        return self.get_stats()

    def play_stream(
        self,
        stream_bytes: bytes,
        start_frame: int = 0,
        max_frames: Optional[int] = None
    ) -> Dict[str, Any]:
        """Mengurai aliran byte stream dan memutarnya."""
        packets = split_stream_into_packets(stream_bytes)
        return self.play_packets(packets, start_frame=start_frame, max_frames=max_frames)


# ==============================================================================
# 5. CLI Entry Point
# ==============================================================================

def main() -> None:
    import argparse
    import sys

    parser = argparse.ArgumentParser(
        description="Bad Apple!! UART Stream Player ke FPGA Digilent Basys 3"
    )
    parser.add_argument(
        "--port",
        type=str,
        default="COM3",
        help="Port serial UART (misal: COM3 pada Windows, /dev/ttyUSB0 pada Linux).",
    )
    parser.add_argument(
        "--baud",
        type=int,
        default=921600,
        help="Laju baud UART (default: 921600 baud, 8N1).",
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=30.0,
        help="Laju frame per detik (default: 30 FPS).",
    )
    parser.add_argument(
        "--av-offset-ms",
        type=float,
        default=0.0,
        help="Offset audio/video dalam milidetik (positif = video lebih lambat dari jam acuan). Nilai tidak boleh lebih negatif dari -(2/FPS)*1000 ms (default: 0 ms [DIASUMSIKAN]).",
    )
    parser.add_argument(
        "--audio",
        type=str,
        default=None,
        help="Jalur berkas audio WAV untuk sinkronisasi pemutaran audio PC opsi A1 (default: None, menggunakan MonotonicClock).",
    )
    parser.add_argument(
        "--audio-backend",
        type=str,
        choices=["sounddevice", "fake"],
        default="sounddevice",
        help="Backend pemutar audio: sounddevice (audio fisik nyata) atau fake (simulasi tanpa suara).",
    )
    parser.add_argument(
        "--audio-hostapi",
        type=str,
        choices=["default", "mme", "directsound", "wasapi"],
        default="default",
        help="Host API audio PortAudio/sounddevice yang digunakan (default: default).",
    )
    parser.add_argument(
        "--audio-device",
        type=int,
        default=None,
        help="Indeks perangkat output audio spesifik (default: None, menggunakan perangkat default host API).",
    )
    parser.add_argument(
        "--audio-discipline",
        type=str,
        choices=["on", "off"],
        default="off",
        help="Disiplin jam audio berbasis regresi linear jendela geser ~2 s (default: off).",
    )
    parser.add_argument(
        "--audio-stall-ms",
        type=float,
        default=100.0,
        help="Batas waktu toleransi stall/macet audio dalam milidetik sebelum fallback ke MonotonicClock (default: 100 ms).",
    )
    parser.add_argument(
        "--audio-start-sec",
        type=float,
        default=None,
        help="Posisi awal audio dalam detik (default: dihitung dari start-frame / FPS).",
    )
    parser.add_argument(
        "--fake-fpga",
        action="store_true",
        default=False,
        help="Jalankan simulasi seluruh pipeline terhadap model FakeFPGA tanpa board hardware fisik.",
    )
    parser.add_argument(
        "--start-frame",
        type=int,
        default=0,
        help="Indeks frame awal pemutaran (default: 0).",
    )
    parser.add_argument(
        "--max-frames",
        type=int,
        default=None,
        help="Jumlah maksimum frame yang akan dimainkan (default: seluruh frame).",
    )
    parser.add_argument(
        "--ascii-out",
        type=str,
        default=None,
        help="Jalur berkas untuk menyimpan byte mentah aliran ASCII yang diterima dari FPGA.",
    )
    parser.add_argument(
        "--no-display",
        action="store_true",
        default=False,
        help="Matikan pencetakan tampilan aliran ASCII ke stdout (default: False).",
    )
    parser.add_argument(
        "--file",
        "--clip",
        dest="file",
        type=str,
        default="data/golden/stream_clip.bin",
        help="Jalur berkas aliran paket biner (.bin) yang akan dikirim.",
    )

    args = parser.parse_args()

    if not os.path.exists(args.file):
        print(f"Error: Berkas streaming tidak ditemukan: {args.file}", file=sys.stderr)
        sys.exit(1)

    with open(args.file, "rb") as f:
        stream_data = f.read()

    print("=" * 60)
    print("      BAD APPLE!! UART STREAM PLAYER (DIGILENT BASYS 3)     ")
    print("=" * 60)
    if args.fake_fpga:
        print("Target Device : Model Perilaku FakeFPGA (Simulasi Boardless)")
    else:
        print(f"Port Serial   : {args.port} @ {args.baud} baud (8N1)")
    print(f"Laju Frame    : {args.fps} FPS")
    print(f"A/V Offset    : {args.av_offset_ms} ms [DIASUMSIKAN]")
    if args.audio:
        if args.audio_backend == "fake":
            print(f"Mode Jam      : AudioClock Fake ({args.audio})")
        else:
            api_str = f", HostAPI: {args.audio_hostapi}" if args.audio_hostapi != "default" else ""
            dev_str = f", Dev: {args.audio_device}" if args.audio_device is not None else ""
            print(f"Mode Jam      : AudioClock SoundDevice ({args.audio}{api_str}{dev_str})")
    else:
        print("Mode Jam      : MonotonicClock (Tanpa Audio)")
    print(f"Tampilan      : {'NONAKTIF (--no-display)' if args.no_display else 'AKTIF (sys.stdout.buffer)'}")
    if args.ascii_out:
        print(f"Simpan ASCII  : {args.ascii_out}")
    if args.start_frame > 0 or args.max_frames is not None:
        print(f"Rentang Frame : Start={args.start_frame}, Max={args.max_frames}")
    print(f"Berkas Stream : {args.file} ({len(stream_data)} bytes)")
    print("=" * 60)

    # Inisialisasi Transport
    if args.fake_fpga:
        fpga_sim = FakeFPGA()
        transport = FakeTransport(fake_fpga=fpga_sim)
    else:
        transport = SerialTransport(port=args.port, baudrate=args.baud)

    # Inisialisasi Jam (Clock) & Audio
    audio_dev = None
    if args.audio:
        if args.audio_start_sec is not None:
            audio_start_sec = args.audio_start_sec
        elif args.start_frame > 0:
            audio_start_sec = args.start_frame / args.fps
        else:
            audio_start_sec = 0.0

        stall_sec = args.audio_stall_ms / 1000.0
        if args.audio_backend == "fake":
            sr = 44100
            if os.path.exists(args.audio):
                try:
                    with wave.open(args.audio, "rb") as wf:
                        sr = wf.getframerate()
                except Exception:
                    pass
            audio_dev = FakeAudioDevice(sample_rate=sr, latency_sec=0.020, start_sec=audio_start_sec, auto_advance=True)
        else:
            audio_dev = SoundDeviceAudio(
                args.audio,
                start_sec=audio_start_sec,
                hostapi=args.audio_hostapi,
                device=args.audio_device,
            )
        discipline_enabled = (args.audio_discipline == "on")
        clock = AudioClock(audio_dev, stall_timeout_sec=stall_sec, discipline=discipline_enabled)
    else:
        clock = MonotonicClock()

    ascii_file = open(args.ascii_out, "wb") if args.ascii_out else None

    def output_handler(data: bytes):
        if not args.no_display:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        if ascii_file is not None:
            ascii_file.write(data)
            ascii_file.flush()

    player = StreamPlayer(
        transport=transport,
        clock=clock,
        fps=args.fps,
        av_offset_ms=args.av_offset_ms,
        on_terminal_output=output_handler,
    )

    try:
        packets = split_stream_into_packets(stream_data)
        if audio_dev is not None:
            audio_dev.start()

        player.play_packets(
            packets,
            start_frame=args.start_frame,
            max_frames=args.max_frames
        )
        # Berikan waktu sejenak untuk mengosongkan keluaran terakhir
        time.sleep(0.1)
        player.stop_reader()
        transport.close()
        if audio_dev is not None:
            audio_dev.stop()
            audio_dev.close()
        if ascii_file is not None:
            ascii_file.close()

        stats = player.get_stats()
        print("\n" + "=" * 60)
        print("RINGKASAN STREAMING:")
        print(f"Total Frame   : {stats['total_frames']}")
        print(f"Frame Terkirim: {stats['sent_frames']}")
        print(f"Frame Dibuang : {stats['dropped_frames']}")
        print(f"Byte Diterima : {stats['received_bytes']}")
        if stats.get("reader_errors", 0) > 0:
            print(f"Galat Pembaca : {stats['reader_errors']} (Pertama: {stats['first_reader_error']})")
        print("=" * 60)
    except KeyboardInterrupt:
        print("\nStreaming dihentikan oleh pengguna.")
        player.stop_reader()
        transport.close()
        if audio_dev is not None:
            audio_dev.stop()
            audio_dev.close()
        if ascii_file is not None:
            ascii_file.close()


if __name__ == "__main__":
    main()
