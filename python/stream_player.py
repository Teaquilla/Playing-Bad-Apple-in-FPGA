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
import struct
import threading
import time
from typing import Callable, List, Optional, Tuple, Dict, Any
import numpy as np

# Import modul internal Bad Apple
try:
    from python.stream_encoder import (
        SOF_MARKER,
        EOF_BYTE,
        PAYLOAD_LEN_MIN,
        PAYLOAD_LEN_MAX,
        compute_checksum,
        decode_rle_payload_to_canonical,
    )
    from python.ascii_renderer import render_ascii_frame, ASCII_FRAME_LEN
except ImportError:
    from stream_encoder import (
        SOF_MARKER,
        EOF_BYTE,
        PAYLOAD_LEN_MIN,
        PAYLOAD_LEN_MAX,
        compute_checksum,
        decode_rle_payload_to_canonical,
    )
    from ascii_renderer import render_ascii_frame, ASCII_FRAME_LEN


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
    """Implementasi transport serial nyata menggunakan pyserial (lazy import)."""

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
        with self._lock:
            self._tx_bytes.extend(data)
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


class AudioClock(Clock):
    """Antarmuka abstrak jam audio untuk opsi A1 (pemutaran audio PC)."""

    @abc.abstractmethod
    def get_audio_time(self) -> float:
        """Mengembalikan posisi pemutaran audio saat ini dalam detik."""
        pass

    def now(self) -> float:
        return self.get_audio_time()

    def sleep_until(self, target_time: float) -> None:
        while self.now() < target_time:
            time.sleep(0.001)


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
        self.resyncs_count: int = 0

    def receive_bytes(self, data: bytes) -> None:
        """Menerima aliran byte dari transport dan memproses paket secara bertahap."""
        with self._lock:
            self._rx_buf.extend(data)
            self._process_buffer()

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
                self.resyncs_count += 1
                idx = sof_pos + 1
                continue

            # Paket valid! Dekode RLE ke kanonik lalu render ASCII 1059 B
            try:
                canonical = decode_rle_payload_to_canonical(payload)
                ascii_data = render_ascii_frame(canonical)
                self._output_ascii.extend(ascii_data)
                self.valid_frames_count += 1
            except Exception:
                self.length_errors += 1

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
        self.av_offset_sec = av_offset_ms / 1000.0
        self.on_terminal_output = on_terminal_output

        # State pembacaan latar belakang
        self._reader_thread: Optional[threading.Thread] = None
        self._stop_reader = threading.Event()
        self.received_bytes_count: int = 0
        self.dropped_frames_count: int = 0
        self.sent_frames_count: int = 0
        self.send_timestamps: List[float] = []

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
                    except Exception:
                        pass
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
                except Exception:
                    pass

    def play_packets(self, packets: List[bytes]) -> Dict[str, Any]:
        """Mengirimkan daftar paket frame dengan penjadwalan presisi clock.

        Frame n dijadwalkan pada: t0 + n / FPS + av_offset_sec.
        Bila t_now > t_sched + 2 / FPS, frame terlambat lebih dari 2 frame dan dibuang (drop).
        """
        self.start_reader()
        t0 = self.clock.now()
        frame_interval = 1.0 / self.fps
        drop_threshold = 2.0 * frame_interval

        self.sent_frames_count = 0
        self.dropped_frames_count = 0
        self.send_timestamps.clear()

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
            self.send_timestamps.append(self.clock.now())

        return {
            "total_frames": len(packets),
            "sent_frames": self.sent_frames_count,
            "dropped_frames": self.dropped_frames_count,
            "received_bytes": self.received_bytes_count,
        }

    def play_stream(self, stream_bytes: bytes) -> Dict[str, Any]:
        """Mengurai aliran byte stream dan memutarnya."""
        packets = split_stream_into_packets(stream_bytes)
        return self.play_packets(packets)


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
        help="Offset audio/video dalam milidetik (default: 0 ms [DIASUMSIKAN]).",
    )
    parser.add_argument(
        "--no-audio",
        action="store_true",
        default=True,
        help="Gunakan jam MonotonicClock tanpa sinkronisasi audio (default: True).",
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
    print(f"Port Serial   : {args.port} @ {args.baud} baud (8N1)")
    print(f"Laju Frame    : {args.fps} FPS")
    print(f"A/V Offset    : {args.av_offset_ms} ms [DIASUMSIKAN]")
    print(f"Mode Jam      : MonotonicClock (--no-audio)")
    print(f"Berkas Stream : {args.file} ({len(stream_data)} bytes)")
    print("=" * 60)

    transport = SerialTransport(port=args.port, baudrate=args.baud)
    clock = MonotonicClock()

    def stdout_writer(data: bytes):
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()

    player = StreamPlayer(
        transport=transport,
        clock=clock,
        fps=args.fps,
        av_offset_ms=args.av_offset_ms,
        on_terminal_output=stdout_writer,
    )

    try:
        stats = player.play_stream(stream_data)
        # Berikan waktu sejenak untuk mengosongkan keluaran terakhir
        time.sleep(0.1)
        player.stop_reader()
        transport.close()
        print("\n" + "=" * 60)
        print("RINGKASAN STREAMING:")
        print(f"Total Frame   : {stats['total_frames']}")
        print(f"Frame Terkirim: {stats['sent_frames']}")
        print(f"Frame Dibuang : {stats['dropped_frames']}")
        print(f"Byte Diterima : {stats['received_bytes']}")
        print("=" * 60)
    except KeyboardInterrupt:
        print("\nStreaming dihentikan oleh pengguna.")
        player.stop_reader()
        transport.close()


if __name__ == "__main__":
    main()
