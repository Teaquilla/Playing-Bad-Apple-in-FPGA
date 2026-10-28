import numpy as np
import pytest
from ascii_renderer import render_ascii_frame, ASCII_FRAME_LEN, DEFAULT_RAMP
from canonical import pack_frame, FRAME_WIDTH, FRAME_HEIGHT


def test_ascii_frame_length():
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    out = render_ascii_frame(frame)
    assert len(out) == 1059
    assert out.startswith(b"\x1b[H")


def test_all_black_frame():
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    out = render_ascii_frame(frame)
    assert len(out) == 1059
    # Potong header 3 byte \x1b[H
    body = out[3:].decode("ascii")
    lines = body.split("\r\n")
    # 16 baris + 1 string kosong di akhir setelah split \r\n
    assert len(lines) == 17
    assert lines[-1] == ""
    for line in lines[:-1]:
        assert line == " " * 64


def test_all_white_frame():
    frame = np.ones((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    out = render_ascii_frame(frame)
    assert len(out) == 1059
    body = out[3:].decode("ascii")
    lines = body.split("\r\n")
    assert len(lines) == 17
    for line in lines[:-1]:
        assert line == "@" * 64


def test_hand_calculated_pattern():
    """Uji pola yang dihitung tangan:
    Blok (cx=0, cy=0) memiliki tepat 4 piksel putih (tingkat 4 -> '=' pada ramp " .:-=+*#@").
    Blok (cx=1, cy=0) memiliki tepat 1 piksel putih (tingkat 1 -> '.' pada ramp).
    Blok (cx=2, cy=0) memiliki tepat 8 piksel putih (tingkat 8 -> '@' pada ramp).
    Blok lainnya hitam (tingkat 0 -> ' ').
    """
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)

    # Blok (0, 0): x=0..1, y=0..3. Isi 4 piksel putih (misal 2 baris pertama)
    frame[0, 0] = 1
    frame[0, 1] = 1
    frame[1, 0] = 1
    frame[1, 1] = 1
    # White count = 4 -> '='

    # Blok (1, 0): x=2..3, y=0..3. Isi 1 piksel putih
    frame[0, 2] = 1
    # White count = 1 -> '.'

    # Blok (2, 0): x=4..5, y=0..3. Isi 8 piksel putih
    frame[0:4, 4:6] = 1
    # White count = 8 -> '@'

    out = render_ascii_frame(frame)
    body = out[3:].decode("ascii")
    first_line = body.split("\r\n")[0]
    assert len(first_line) == 64
    assert first_line[0] == "="
    assert first_line[1] == "."
    assert first_line[2] == "@"
    assert first_line[3:] == " " * 61


def test_invert_mode():
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    out = render_ascii_frame(frame, invert=True)
    body = out[3:].decode("ascii")
    first_line = body.split("\r\n")[0]
    # Hitam di-invert menjadi putih (@)
    assert first_line == "@" * 64


def test_packed_bytes_input():
    frame = np.ones((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    packed = pack_frame(frame)
    out = render_ascii_frame(packed)
    assert len(out) == 1059
    assert out[3:3+64] == b"@" * 64
