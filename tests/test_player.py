import numpy as np
import pytest
from player import frame_to_braille, frame_to_halfblock
from canonical import FRAME_WIDTH, FRAME_HEIGHT


def test_braille_renderer():
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    braille_out = frame_to_braille(frame)
    assert braille_out.startswith("\x1b[H")
    lines = braille_out[3:].strip().split("\n")
    assert len(lines) == 16
    for line in lines:
        assert len(line) == 64
        # U+2800 adalah spasi braille (kosong)
        assert line == chr(0x2800) * 64

    # Test full dots
    white_frame = np.ones((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    braille_white = frame_to_braille(white_frame)
    lines_w = braille_white[3:].strip().split("\n")
    for line in lines_w:
        assert line == chr(0x28FF) * 64


def test_halfblock_renderer():
    frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    hb_out = frame_to_halfblock(frame)
    assert hb_out.startswith("\x1b[H")
    # Hapus prefix \x1b[H dan trailing \n
    body = hb_out[3:].rstrip("\n")
    lines = body.split("\n")
    assert len(lines) == 32
    for line in lines:
        assert len(line) == 128
        assert line == " " * 128

    white_frame = np.ones((FRAME_HEIGHT, FRAME_WIDTH), dtype=np.uint8)
    hb_white = frame_to_halfblock(white_frame)
    body_w = hb_white[3:].rstrip("\n")
    lines_w = body_w.split("\n")
    assert len(lines_w) == 32
    for line in lines_w:
        assert len(line) == 128
        assert line == "█" * 128

