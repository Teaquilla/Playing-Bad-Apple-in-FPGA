"""tests/test_uart_capture.py
Uji Pytest untuk python/uart_capture.py menggunakan port tiruan PySerial (loop://).

Kasus Uji:
1. Data cocok 100% byte-exact (exit code 0, None mismatch pos).
2. Satu byte rusak (exit code non-zero, menyebut posisi byte pertama yang berbeda).
3. Data terpotong / truncated (exit code non-zero, menyebut posisi byte terpotong).
4. Data bergeser 1 byte (exit code non-zero, menyebut posisi byte pertama yang berbeda).
"""

import os
import subprocess
import sys
import pytest
import serial

from python.uart_capture import capture_and_verify_stream, FRAME_SIZE


@pytest.fixture
def sample_golden_data(tmp_path):
    """Menyediakan 2 frame ASCII valid (2.118 byte) untuk pengujian."""
    # Frame 1
    f1 = bytearray(b"\x1b[H")
    for r in range(16):
        f1.extend(b"#" * 64 + b"\r\n")
    assert len(f1) == FRAME_SIZE

    # Frame 2
    f2 = bytearray(b"\x1b[H")
    for r in range(16):
        f2.extend(b"." * 64 + b"\r\n")
    assert len(f2) == FRAME_SIZE

    data = bytes(f1 + f2)
    golden_file = tmp_path / "test_golden.bin"
    golden_file.write_bytes(data)
    return data, str(golden_file)


def test_uart_capture_match(sample_golden_data):
    """Kasus 1: Data cocok 100% byte-exact."""
    golden_bytes, golden_file = sample_golden_data
    ser = serial.serial_for_url("loop://", timeout=1.0)
    ser.write(golden_bytes)

    success, msg, pos = capture_and_verify_stream(ser, golden_bytes, timeout=1.0)
    ser.close()

    assert success is True
    assert pos is None
    assert "cocok sempurna" in msg

    # Uji CLI / runner
    res = subprocess.run(
        [sys.executable, "-c", f"""
import serial, sys
from python.uart_capture import run_live_serial_capture
ser = serial.serial_for_url('loop://', timeout=1.0)
ser.write(open(r'{golden_file}', 'rb').read())
success, msg, pos = run_live_serial_capture(ser, golden_file=r'{golden_file}', timeout=1.0)
sys.exit(0 if success else 1)
"""],
        capture_output=True,
        text=True
    )
    assert res.returncode == 0


def test_uart_capture_corrupted_byte(sample_golden_data):
    """Kasus 2: Satu byte rusak di posisi sembarang (misal posisi 120)."""
    golden_bytes, golden_file = sample_golden_data
    corrupted = bytearray(golden_bytes)
    corrupted_pos = 120
    # Ubah 1 byte
    corrupted[corrupted_pos] = (corrupted[corrupted_pos] + 1) % 256

    ser = serial.serial_for_url("loop://", timeout=1.0)
    ser.write(bytes(corrupted))

    success, msg, pos = capture_and_verify_stream(ser, golden_bytes, timeout=1.0)
    ser.close()

    assert success is False
    assert pos == corrupted_pos
    assert f"Ketidakcocokan pertama pada byte {corrupted_pos}" in msg

    # Uji verifikasi exit code non-zero via runner
    res = subprocess.run(
        [sys.executable, "-c", f"""
import serial, sys
from python.uart_capture import capture_and_verify_stream
golden = open(r'{golden_file}', 'rb').read()
corrupted = bytearray(golden)
corrupted[{corrupted_pos}] = (corrupted[{corrupted_pos}] + 1) % 256
ser = serial.serial_for_url('loop://', timeout=1.0)
ser.write(bytes(corrupted))
success, msg, pos = capture_and_verify_stream(ser, golden, timeout=1.0)
if not success:
    print(msg, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"""],
        capture_output=True,
        text=True
    )
    assert res.returncode != 0
    assert f"Ketidakcocokan pertama pada byte {corrupted_pos}" in res.stderr


def test_uart_capture_truncated(sample_golden_data):
    """Kasus 3: Data terpotong (hanya menerima sebagian byte lalu timeout)."""
    golden_bytes, golden_file = sample_golden_data
    cut_pos = 500
    truncated = golden_bytes[:cut_pos]

    ser = serial.serial_for_url("loop://", timeout=0.2)
    ser.write(truncated)

    success, msg, pos = capture_and_verify_stream(ser, golden_bytes, timeout=0.2)
    ser.close()

    assert success is False
    assert pos == cut_pos
    assert f"Data terpotong: diterima {cut_pos} byte" in msg
    assert f"terpotong pada posisi {cut_pos}" in msg

    # Uji verifikasi exit code non-zero
    res = subprocess.run(
        [sys.executable, "-c", f"""
import serial, sys
from python.uart_capture import capture_and_verify_stream
golden = open(r'{golden_file}', 'rb').read()
truncated = golden[:{cut_pos}]
ser = serial.serial_for_url('loop://', timeout=0.2)
ser.write(truncated)
success, msg, pos = capture_and_verify_stream(ser, golden, timeout=0.2)
if not success:
    print(msg, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"""],
        capture_output=True,
        text=True
    )
    assert res.returncode != 0
    assert f"Data terpotong: diterima {cut_pos} byte" in res.stderr


def test_uart_capture_shifted(sample_golden_data):
    """Kasus 4: Data bergeser satu byte (prepend extra byte)."""
    golden_bytes, golden_file = sample_golden_data
    # Sisipkan 1 byte sampah di awal sehingga seluruh byte bergeser 1 posisi
    shifted = b"\xFF" + golden_bytes[:-1]

    ser = serial.serial_for_url("loop://", timeout=1.0)
    ser.write(shifted)

    success, msg, pos = capture_and_verify_stream(ser, golden_bytes, timeout=1.0)
    ser.close()

    assert success is False
    assert pos == 0  # Byte ke-0 sudah mismatch (didapat 0xFF, ekspektasi 0x1B)
    assert "Ketidakcocokan pertama pada byte 0" in msg

    # Uji verifikasi exit code non-zero
    res = subprocess.run(
        [sys.executable, "-c", f"""
import serial, sys
from python.uart_capture import capture_and_verify_stream
golden = open(r'{golden_file}', 'rb').read()
shifted = b'\\xFF' + golden[:-1]
ser = serial.serial_for_url('loop://', timeout=1.0)
ser.write(shifted)
success, msg, pos = capture_and_verify_stream(ser, golden, timeout=1.0)
if not success:
    print(msg, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"""],
        capture_output=True,
        text=True
    )
    assert res.returncode != 0
    assert "Ketidakcocokan pertama pada byte 0" in res.stderr
