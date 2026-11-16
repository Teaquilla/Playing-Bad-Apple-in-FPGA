"""python/board_check.py
Alat verifikasi loopback UART cepat PC <-> Basys 3 (tanpa ketergantungan UI berat).

Catatan Mode Switch & Pacing Hardware:
- Pastikan switch hardware Basys 3 pada posisi SW0 = 1 (Mode Streaming UART RX M2;
  SW0 = 0 = Mode Klip ROM M1).
- Hardware FPGA membuang paket baru yang tiba sebelum frame ASCII sebelumnya selesai
  dikirim (~11,5 ms pada 921.600 baud; delayed swap pada frame_buffer). Karena itu,
  pengiriman multi-frame memakai pacing default --pace-fps 30.0 atau opsi --wait-each.
- Keterbatasan model simulasi: FakeFPGA memproses setiap paket secara sinkron di memori
  dan tidak memodelkan frame drop akibat pengiriman paket tanpa pacing.

Fitur:
1. Menemukan port serial via `serial.tools.list_ports` beserta nama dan `VID:PID`.
2. Membuka koneksi 921.600 baud 8N1 (atau FakeFPGA melalui `--fake-fpga`).
3. Mengirim N paket video valid (`--frames 1..90` dari `data/golden/stream_clip.bin`)
   dengan pacing `--pace-fps` (default 30,0 FPS) atau `--wait-each`.
4. Membaca balik aliran ASCII (harapan 1.059 byte per frame), memverifikasi:
   - kesesuaian jumlah byte (`1.059 * N`),
   - kecocokan byte-exact terhadap `data/golden/ascii.hex`,
   - batas waktu `--timeout` beserta latensi byte pertama dan terakhir via `time.perf_counter`.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from python.ascii_renderer import ASCII_FRAME_LEN
from python.stream_player import FakeFPGA, FakeTransport, split_stream_into_packets


DEFAULT_BAUD = 921600
DEFAULT_CLIP = "data/golden/stream_clip.bin"
DEFAULT_GOLDEN_HEX = "data/golden/ascii.hex"
_VID_PID_RE = re.compile(r"VID:PID=([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})")


def _format_vid_pid(port_info: Any) -> str:
    """Mengekstrak string VID:PID heksadesimal (atau 'N/A') dari objek port serial."""
    vid = getattr(port_info, "vid", None)
    pid = getattr(port_info, "pid", None)
    if vid is not None and pid is not None:
        return f"{int(vid):04X}:{int(pid):04X}"
    hwid = getattr(port_info, "hwid", "") or ""
    match = _VID_PID_RE.search(hwid)
    if match:
        return f"{match.group(1).upper()}:{match.group(2).upper()}"
    return "N/A"


def discover_serial_ports(port_list: Optional[Iterable[Any]] = None) -> List[Dict[str, str]]:
    """Menemukan port serial yang tersedia dan mengembalikan device, deskripsi, serta VID:PID."""
    if port_list is None:
        from serial.tools import list_ports

        port_list = list_ports.comports()

    discovered: List[Dict[str, str]] = []
    for p in port_list:
        if isinstance(p, dict):
            device = str(p.get("device", ""))
            desc = str(p.get("description", ""))
            vid_pid = str(p.get("vid_pid", "N/A"))
        else:
            device = str(getattr(p, "device", p))
            desc = str(getattr(p, "description", "") or "")
            vid_pid = _format_vid_pid(p)
        discovered.append({"device": device, "description": desc, "vid_pid": vid_pid})
    return discovered


def select_serial_port(
    requested_port: Optional[str] = None,
    port_list: Optional[Iterable[Any]] = None,
) -> str:
    """Memilih port serial yang diminta atau mencari port FTDI/pertama dari list_ports."""
    if requested_port:
        return requested_port

    ports = discover_serial_ports(port_list=port_list)
    if not ports:
        raise RuntimeError(
            "Tidak ada port serial yang ditemukan melalui list_ports. "
            "Hubungkan Basys 3 atau gunakan --fake-fpga."
        )

    for info in ports:
        if info["vid_pid"].startswith("0403:"):
            return info["device"]
    return ports[0]["device"]


def load_golden_packets(clip_path: str = DEFAULT_CLIP, frames: int = 1) -> List[bytes]:
    """Memuat N paket frame pertama (1..90) dari stream_clip.bin."""
    if frames < 1 or frames > 90:
        raise ValueError(f"--frames harus dalam rentang 1..90, didapat: {frames}")
    if not os.path.exists(clip_path):
        raise FileNotFoundError(f"Berkas clip tidak ditemukan: {clip_path}")

    with open(clip_path, "rb") as f:
        stream_data = f.read()

    packets = split_stream_into_packets(stream_data)
    if len(packets) < frames:
        raise ValueError(
            f"Jumlah paket pada {clip_path} hanya {len(packets)}, kurang dari {frames}."
        )
    return packets[:frames]


def load_golden_ascii_hex(hex_path: str = DEFAULT_GOLDEN_HEX, expected_bytes: int = ASCII_FRAME_LEN) -> bytes:
    """Membaca tepat expected_bytes dari berkas hex golden ASCII (satu byte hex per baris)."""
    if expected_bytes < 0:
        raise ValueError(f"expected_bytes tidak valid: {expected_bytes}")
    if not os.path.exists(hex_path):
        raise FileNotFoundError(f"Berkas golden hex tidak ditemukan: {hex_path}")

    parsed = bytearray()
    with open(hex_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            token = raw_line.strip()
            if not token:
                continue
            parsed.append(int(token, 16))
            if len(parsed) >= expected_bytes:
                break

    if len(parsed) < expected_bytes:
        raise ValueError(
            f"Data golden {hex_path} hanya memiliki {len(parsed)} byte, "
            f"dibutuhkan {expected_bytes} byte."
        )
    return bytes(parsed[:expected_bytes])


def compare_ascii_bytes(received: bytes, expected: bytes) -> Tuple[bool, Optional[int], str]:
    """Membandingkan dua urutan byte secara byte-exact dan melaporkan indeks mismatch pertama."""
    limit = min(len(received), len(expected))
    for i in range(limit):
        if received[i] != expected[i]:
            return (
                False,
                i,
                f"Ketidakcocokan pertama pada byte {i}: ekspektasi 0x{expected[i]:02X}, didapat 0x{received[i]:02X}",
            )
    if len(received) != len(expected):
        return (
            False,
            limit,
            f"Panjang data berbeda: diterima {len(received)} B, ekspektasi {len(expected)} B",
        )
    return True, None, "Cocok 100% byte-exact"


def open_serial_connection(port: str, baud: int = DEFAULT_BAUD, timeout: float = 2.0):
    """Membuka port serial pyserial 8N1 pada laju baud yang ditentukan."""
    import serial

    ser = serial.Serial(
        port=port,
        baudrate=baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=min(0.05, max(0.005, float(timeout))),
        write_timeout=1.0,
    )
    if hasattr(ser, "reset_input_buffer"):
        ser.reset_input_buffer()
    if hasattr(ser, "reset_output_buffer"):
        ser.reset_output_buffer()
    return ser


def run_board_check(
    transport: Any,
    packets: List[bytes],
    expected_ascii: bytes,
    timeout: float = 2.0,
    perf_counter: Callable[[], float] = time.perf_counter,
    pace_fps: Optional[float] = 30.0,
    wait_each: bool = False,
    sleep_fn: Optional[Callable[[float], None]] = None,
) -> Dict[str, Any]:
    """Mengirim paket video dengan pacing/wait-each, membaca balik ASCII, dan memverifikasi hasil.

    Catatan hardware: FPGA membuang paket yang tiba sebelum frame ASCII sebelumnya selesai
    dikirim (~11,5 ms; delayed swap di frame_buffer), sedangkan FakeFPGA tidak memodelkan drop ini.
    """
    if timeout <= 0:
        raise ValueError(f"--timeout harus > 0, didapat: {timeout}")
    if pace_fps is not None and pace_fps < 0:
        raise ValueError(f"--pace-fps harus >= 0, didapat: {pace_fps}")

    expected_bytes = len(expected_ascii)
    received = bytearray()
    send_timestamps: List[float] = []
    first_byte_sec: Optional[float] = None
    last_byte_sec: Optional[float] = None
    timed_out_flag = False

    def _sleep(wait_dt: float) -> None:
        if wait_dt <= 0:
            return
        if sleep_fn is not None:
            sleep_fn(wait_dt)
            return
        clock_obj = getattr(perf_counter, "__self__", None)
        if clock_obj is not None and callable(getattr(clock_obj, "advance", None)):
            clock_obj.advance(wait_dt)
        elif perf_counter is time.perf_counter:
            time.sleep(wait_dt)

    def _record_chunk(chunk: bytes) -> None:
        nonlocal first_byte_sec, last_byte_sec
        now_rx = perf_counter() - t_send
        if first_byte_sec is None:
            first_byte_sec = now_rx
        last_byte_sec = now_rx
        received.extend(chunk)

    t_send = perf_counter()
    for k, pkt in enumerate(packets):
        if (not wait_each) and pace_fps and pace_fps > 0:
            t_target = t_send + (k / pace_fps)
            now = perf_counter()
            wait_dt = t_target - now
            if wait_dt > 0:
                remaining_timeout = (t_send + timeout) - now
                if remaining_timeout <= 0:
                    timed_out_flag = True
                    break
                if wait_dt > remaining_timeout:
                    _sleep(remaining_timeout)
                    timed_out_flag = True
                    break
                _sleep(wait_dt)

        send_timestamps.append(perf_counter())
        transport.write(pkt)

        if wait_each:
            target_rx = (k + 1) * ASCII_FRAME_LEN
            empty_reads = 0
            while len(received) < target_rx:
                now = perf_counter()
                if now - t_send >= timeout:
                    timed_out_flag = True
                    break
                read_len = max(4096, expected_bytes - len(received))
                chunk = transport.read(read_len)
                if chunk:
                    empty_reads = 0
                    _record_chunk(chunk)
                else:
                    empty_reads += 1
                    if perf_counter() - t_send >= timeout or empty_reads >= 10000:
                        timed_out_flag = True
                        break
                    _sleep(0.002)
            if timed_out_flag:
                break
        elif getattr(transport, "in_waiting", 0) > 0:
            early = transport.read(max(4096, expected_bytes - len(received)))
            if early:
                _record_chunk(early)

    empty_reads = 0
    while not timed_out_flag:
        waiting = getattr(transport, "in_waiting", 0)
        if len(received) >= expected_bytes and waiting == 0:
            break

        now = perf_counter()
        if now - t_send >= timeout and len(received) < expected_bytes:
            timed_out_flag = True
            break

        read_len = max(4096, expected_bytes - len(received))
        chunk = transport.read(read_len)
        if chunk:
            empty_reads = 0
            _record_chunk(chunk)
        else:
            empty_reads += 1
            if perf_counter() - t_send >= timeout or empty_reads >= 10000:
                timed_out_flag = True
                break
            _sleep(0.002)

    elapsed_sec = perf_counter() - t_send
    received_bytes = bytes(received)

    count_ok = len(received_bytes) == expected_bytes
    timed_out = bool(timed_out_flag or (elapsed_sec > timeout))
    common_len = min(len(received_bytes), expected_bytes)
    byte_exact, first_mismatch_index, mismatch_detail = compare_ascii_bytes(
        received_bytes[:common_len], expected_ascii[:common_len]
    )

    passed = bool(count_ok and (not timed_out) and byte_exact)
    return {
        "frames": len(packets),
        "expected_bytes": expected_bytes,
        "received_bytes": len(received_bytes),
        "count_ok": count_ok,
        "byte_exact": byte_exact,
        "first_mismatch_index": first_mismatch_index,
        "mismatch_detail": mismatch_detail,
        "timed_out": timed_out,
        "first_byte_sec": first_byte_sec,
        "last_byte_sec": last_byte_sec,
        "elapsed_sec": elapsed_sec,
        "send_timestamps": send_timestamps,
        "passed": passed,
    }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Uji loopback UART 921.600 8N1 PC <-> Basys 3 (kirim paket video, verifikasi ASCII golden). "
            "Wajib set switch SW0 = 1 (Mode Streaming UART RX M2; SW0 = 0 = Mode Klip ROM M1)."
        )
    )
    parser.add_argument(
        "--port",
        type=str,
        default=None,
        help="Port serial UART (mis. COM3). Jika kosong, dideteksi otomatis lewat pyserial list_ports.",
    )
    parser.add_argument(
        "--baud",
        type=int,
        default=DEFAULT_BAUD,
        help=f"Laju baud UART 8N1 (default: {DEFAULT_BAUD}).",
    )
    parser.add_argument(
        "--frames",
        type=int,
        default=1,
        help="Jumlah frame valid dari data/golden untuk dikirim (rentang 1..90, default: 1).",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=2.0,
        help="Batas waktu tunggu penerimaan seluruh byte ASCII dalam detik (default: 2.0).",
    )
    parser.add_argument(
        "--pace-fps",
        type=float,
        default=30.0,
        help="Laju pacing pengiriman antar-paket dalam FPS (default: 30.0; 0 menonaktifkan pacing). Diabaikan jika --wait-each aktif.",
    )
    parser.add_argument(
        "--wait-each",
        action="store_true",
        default=False,
        help="Tunggu hingga 1.059 byte ASCII frame k diterima sebelum mengirim paket k+1 (default: False).",
    )
    parser.add_argument(
        "--fake-fpga",
        action="store_true",
        default=False,
        help="Jalankan terhadap model perilaku FakeFPGA (tanpa board/port fisik).",
    )
    parser.add_argument(
        "--list-ports",
        action="store_true",
        default=False,
        help="Tampilkan daftar port serial terdeteksi beserta VID:PID lalu keluar.",
    )
    parser.add_argument(
        "--clip",
        type=str,
        default=DEFAULT_CLIP,
        help=f"Jalur berkas paket video biner (default: {DEFAULT_CLIP}).",
    )
    parser.add_argument(
        "--golden-hex",
        type=str,
        default=DEFAULT_GOLDEN_HEX,
        help=f"Jalur berkas referensi ASCII hex (default: {DEFAULT_GOLDEN_HEX}).",
    )
    args = parser.parse_args(argv)

    ports = discover_serial_ports() if not args.fake_fpga else []
    if args.list_ports:
        print("Port serial terdeteksi (list_ports):")
        if not ports:
            print("  (tidak ada port serial)")
        else:
            for p in ports:
                print(f"  - {p['device']} | VID:PID={p['vid_pid']} | {p['description']}")
        return 0

    packets = load_golden_packets(clip_path=args.clip, frames=args.frames)
    expected_ascii = load_golden_ascii_hex(
        hex_path=args.golden_hex, expected_bytes=args.frames * ASCII_FRAME_LEN
    )

    print("=" * 60)
    print("        BAD APPLE!! BOARD UART CHECK (921.600 8N1)         ")
    print("=" * 60)
    if args.fake_fpga:
        target_label = "FakeFPGA (boardless)"
        transport: Any = FakeTransport(fake_fpga=FakeFPGA())
    else:
        print("Port terdeteksi:")
        if not ports:
            print("  (tidak ada port dari list_ports)")
        else:
            for p in ports:
                print(f"  - {p['device']} | VID:PID={p['vid_pid']} | {p['description']}")
        selected_port = select_serial_port(requested_port=args.port, port_list=ports)
        target_label = f"{selected_port} @ {args.baud} 8N1"
        transport = open_serial_connection(port=selected_port, baud=args.baud, timeout=args.timeout)

    try:
        res = run_board_check(
            transport=transport,
            packets=packets,
            expected_ascii=expected_ascii,
            timeout=args.timeout,
            pace_fps=args.pace_fps,
            wait_each=args.wait_each,
        )
    finally:
        transport.close()

    t_first = f"{res['first_byte_sec'] * 1000.0:.3f} ms" if res["first_byte_sec"] is not None else "N/A"
    t_last = f"{res['last_byte_sec'] * 1000.0:.3f} ms" if res["last_byte_sec"] is not None else "N/A"

    print(f"Target        : {target_label}")
    print(f"Frame Diuji   : {res['frames']} (harapan {res['expected_bytes']} B)")
    print(f"Byte Diterima : {res['received_bytes']} B (count_ok={res['count_ok']})")
    print(f"Byte-Exact    : {'COCOK' if res['byte_exact'] else 'TIDAK COCOK'} ({res['mismatch_detail']})")
    print(f"Timeout       : {'YA' if res['timed_out'] else 'TIDAK'} (batas {args.timeout:.2f} s)")
    print(f"Waktu Byte #1 : {t_first}")
    print(f"Waktu Byte #N : {t_last}")
    print(f"Status        : {'PASS' if res['passed'] else 'FAIL'}")
    print("=" * 60)
    return 0 if res["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
