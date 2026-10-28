"""Skrip Penerima dan Pemverifikasi Aliran UART Terminal Bad Apple (T1.10).

Dapat beroperasi dalam dua mode:
1. Mode Hardware (Serial Live): Membaca port serial COM (FTDI Basys 3) pada 921.600 baud,
   merender video ASCII langsung ke terminal ANSI, dan membandingkan byte dengan data golden.
2. Mode Uji Offline (--file / --mock): Memverifikasi integritas berkas rekaman/golden
   (seperti data/golden/ascii.bin) untuk memastikan parser frame, header ANSI,
   dan kalkulasi hash bekerja 100% tanpa membutuhkan board fisik.
"""

import argparse
import hashlib
import os
import sys
import time

FRAME_SIZE = 1059       # 3 byte header ANSI (\x1b[H) + 16 baris x (64 char + \r\n)
TOTAL_FRAMES_M1 = 90
TOTAL_BYTES_M1 = FRAME_SIZE * TOTAL_FRAMES_M1  # 95.310 byte


def verify_ascii_frame(frame_bytes: bytes, frame_num: int) -> bool:
    """Memvalidasi integritas 1 frame ASCII kanonik (1.059 byte)."""
    if len(frame_bytes) != FRAME_SIZE:
        print(f"[ERROR] Frame {frame_num}: panjang {len(frame_bytes)} != {FRAME_SIZE}", file=sys.stderr)
        return False

    # Header ANSI \x1b[H
    if frame_bytes[:3] != b"\x1b[H":
        print(f"[ERROR] Frame {frame_num}: header ANSI tidak cocok {frame_bytes[:3]}", file=sys.stderr)
        return False

    # Tiap baris 64 byte + \r\n
    idx = 3
    for row in range(16):
        row_chars = frame_bytes[idx : idx + 64]
        crlf = frame_bytes[idx + 64 : idx + 66]
        if crlf != b"\r\n":
            print(f"[ERROR] Frame {frame_num} Baris {row}: terminator bukan \\r\\n ({crlf})", file=sys.stderr)
            return False
        idx += 66

    return True


def run_offline_verification(file_path: str, live_render: bool = False, fps: float = 30.0) -> bool:
    """Menguji verifikasi aliran ASCII secara offline dari berkas."""
    print(f"=== UJI OFFLINE UART CAPTURE ===")
    print(f"Membaca berkas: {file_path}")

    if not os.path.exists(file_path):
        print(f"[ERROR] Berkas tidak ditemukan: {file_path}", file=sys.stderr)
        return False

    with open(file_path, "rb") as f:
        data = f.read()

    total_bytes = len(data)
    num_frames = total_bytes // FRAME_SIZE
    print(f"Total byte dibaca : {total_bytes} byte")
    print(f"Total frame penuh : {num_frames} frame (sisa: {total_bytes % FRAME_SIZE} byte)")

    hasher = hashlib.sha256()
    hasher.update(data)
    print(f"SHA-256 Stream    : {hasher.hexdigest()}")

    all_valid = True
    delay = 1.0 / fps if live_render else 0.0

    for i in range(num_frames):
        chunk = data[i * FRAME_SIZE : (i + 1) * FRAME_SIZE]
        if not verify_ascii_frame(chunk, i):
            all_valid = False
            break

        if live_render:
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            if delay > 0:
                time.sleep(delay)

    if all_valid and total_bytes % FRAME_SIZE == 0:
        print(f"\n[PASS] Seluruh {num_frames} frame terverifikasi valid secara struktural dan format ANSI byte-exact!")
        return True
    else:
        print(f"\n[FAIL] Terdapat inkonsistensi struktur frame!", file=sys.stderr)
        return False


def capture_and_verify_stream(
    ser,
    golden_bytes: bytes,
    timeout: float = 2.0,
    render: bool = False
) -> tuple[bool, str, int | None]:
    """
    Membaca aliran dari objek serial (atau URL seperti loop://) hingga sepanjang len(golden_bytes)
    dan memverifikasi kesesuaian byte-exact terhadap golden_bytes.

    Returns:
        (success: bool, message: str, first_mismatch_pos: int | None)
    """
    total_expected = len(golden_bytes)
    captured = bytearray()
    first_mismatch_pos = None
    mismatch_msg = ""

    # Baca byte per byte atau chunk
    while len(captured) < total_expected:
        needed = total_expected - len(captured)
        chunk = ser.read(needed)
        if not chunk:
            # Timeout / data terpotong
            first_mismatch_pos = len(captured)
            mismatch_msg = (
                f"[ERROR] Data terpotong: diterima {len(captured)} byte, "
                f"ekspektasi {total_expected} byte (terpotong pada posisi {first_mismatch_pos})"
            )
            return False, mismatch_msg, first_mismatch_pos

        for b in chunk:
            idx = len(captured)
            exp = golden_bytes[idx]
            captured.append(b)

            if b != exp and first_mismatch_pos is None:
                first_mismatch_pos = idx
                mismatch_msg = (
                    f"[ERROR] Ketidakcocokan pertama pada byte {idx}: "
                    f"ekspektasi 0x{exp:02X} ('{chr(exp) if 32 <= exp < 127 else '?' }'), "
                    f"didapat 0x{b:02X} ('{chr(b) if 32 <= b < 127 else '?' }')"
                )
                return False, mismatch_msg, first_mismatch_pos

        if render:
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()

    if first_mismatch_pos is not None:
        return False, mismatch_msg, first_mismatch_pos

    return True, f"[PASS] Seluruh {total_expected} byte cocok sempurna secara byte-exact!", None


def run_live_serial_capture(
    port,
    baud: int = 921600,
    max_frames: int = TOTAL_FRAMES_M1,
    golden_file: str = None,
    render: bool = False,
    timeout: float = 2.0
) -> tuple[bool, str, int | None]:
    """Menangkap aliran live dari virtual COM port Basys 3 (FTDI), URL loop://, atau objek Serial."""
    try:
        import serial
    except ImportError:
        msg = "[ERROR] Pyserial belum terpasang. Jalankan: pip install pyserial"
        print(msg, file=sys.stderr)
        return False, msg, None

    should_close = True
    if isinstance(port, str):
        print(f"=== MENYAMBUNG KE PORT SERIAL ===")
        print(f"Port: {port}, Baud: {baud}")
        try:
            ser = serial.serial_for_url(port, baudrate=baud, timeout=timeout)
        except Exception as e:
            msg = f"[ERROR] Gagal membuka port serial: {e}"
            print(msg, file=sys.stderr)
            return False, msg, None
    else:
        ser = port
        should_close = False

    try:
        if golden_file:
            if not os.path.exists(golden_file):
                msg = f"[ERROR] Berkas golden tidak ditemukan: {golden_file}"
                print(msg, file=sys.stderr)
                return False, msg, None
            with open(golden_file, "rb") as f:
                golden_bytes = f.read()

            success, msg, pos = capture_and_verify_stream(ser, golden_bytes, timeout=timeout, render=render)
            if success:
                print(msg)
            else:
                print(msg, file=sys.stderr)
            return success, msg, pos

        # Mode pasif (tanpa golden file, hanya render/buffer)
        captured = bytearray()
        frame_count = 0
        start_time = time.time()

        print(f"Merekam hingga {max_frames} frame...")
        while frame_count < max_frames:
            if len(captured) < 3:
                b = ser.read(1)
                if not b:
                    continue
                captured.extend(b)
                if len(captured) == 3 and bytes(captured[:3]) != b"\x1b[H":
                    captured.pop(0)
                continue

            remaining = FRAME_SIZE - len(captured)
            chunk = ser.read(remaining)
            if chunk:
                captured.extend(chunk)

            if len(captured) == FRAME_SIZE:
                frame_bytes = bytes(captured)
                if render:
                    sys.stdout.buffer.write(frame_bytes)
                    sys.stdout.buffer.flush()
                frame_count += 1
                captured.clear()

        elapsed = time.time() - start_time
        print(f"\nPerekaman selesai: {frame_count} frame dalam {elapsed:.2f} detik ({frame_count/elapsed:.1f} FPS)")
        return True, "Perekaman selesai", None

    except KeyboardInterrupt:
        print("\nPerekaman dihentikan pengguna.")
        return True, "Perekaman dihentikan pengguna", None
    finally:
        if should_close:
            ser.close()


def main():
    parser = argparse.ArgumentParser(description="Penerima dan Pemverifikasi UART Bad Apple")
    parser.add_argument("--port", type=str, default="", help="Port serial COM (misal: COM3) atau loop://")
    parser.add_argument("--baud", type=int, default=921600, help="Baud rate (default: 921600)")
    parser.add_argument("--file", type=str, default="", help="Jalur berkas ASCII untuk uji offline")
    parser.add_argument("--golden", type=str, default="", help="Jalur berkas golden referensi untuk memverifikasi aliran serial")
    parser.add_argument("--render", action="store_true", help="Render ANSI visual ke terminal saat uji offline/live")
    parser.add_argument("--fps", type=float, default=30.0, help="FPS saat me-render (default: 30)")
    args = parser.parse_args()

    if args.file:
        success = run_offline_verification(args.file, live_render=args.render, fps=args.fps)
        sys.exit(0 if success else 1)
    elif args.port:
        success, msg, _ = run_live_serial_capture(
            args.port,
            baud=args.baud,
            golden_file=args.golden,
            render=args.render
        )
        sys.exit(0 if success else 1)
    else:
        # Default: uji offline terhadap data golden ascii.bin jika ada
        default_golden = "data/golden/ascii.bin"
        if os.path.exists(default_golden):
            success = run_offline_verification(default_golden, live_render=args.render, fps=args.fps)
            sys.exit(0 if success else 1)
        else:
            parser.print_help()
            sys.exit(1)


if __name__ == "__main__":
    main()

