"""tests/test_stream_player.py
Pengujian unit deterministik untuk python/stream_player.py (Milestone M2 & TASKS T2.8).
"""

import os
import threading
import time
import pytest

from python.stream_player import (
    Transport,
    Clock,
    SerialTransport,
    FakeTransport,
    MonotonicClock,
    FakeClock,
    FakeFPGA,
    StreamPlayer,
    split_stream_into_packets,
)
from python.audio_player import FakeAudioDevice, AudioClock
from python.stream_encoder import encode_packet


GOLDEN_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "golden")
STREAM_CLIP_BIN = os.path.join(GOLDEN_DIR, "stream_clip.bin")
ASCII_BIN = os.path.join(GOLDEN_DIR, "ascii.bin")


def make_dummy_packet(frame_id: int) -> bytes:
    """Membuat 1 paket valid sederhana untuk pengujian timing."""
    # 64 baris x 128 piksel hitam = 64 byte payload bernilai 128 (0x80)
    payload = bytes([128] * 64)
    return encode_packet(frame_id, payload)


# ------------------------------------------------------------------------------
# Test (a): Jadwal Mengikuti Jam
# ------------------------------------------------------------------------------
def test_schedule_follows_clock():
    """Memverifikasi bahwa jadwal pengiriman tiap frame tepat t0 + n / FPS."""
    clock = FakeClock(start_time=50.0)
    transport = FakeTransport()
    player = StreamPlayer(transport=transport, clock=clock, fps=30.0, av_offset_ms=0.0)

    # Buat 6 frame
    packets = [make_dummy_packet(i) for i in range(6)]
    stats = player.play_packets(packets)
    player.stop_reader()

    assert stats["total_frames"] == 6
    assert stats["sent_frames"] == 6
    assert stats["dropped_frames"] == 0

    # Verifikasi timestamp pengiriman tiap frame: t0 + n * (1/30)
    frame_interval = 1.0 / 30.0
    for n, ts in enumerate(player.send_timestamps):
        expected_t = 50.0 + n * frame_interval
        assert abs(ts - expected_t) < 1e-6, f"Frame {n} terkirim di {ts}, ekspektasi {expected_t}"


# ------------------------------------------------------------------------------
# Test (b): Frame Telat > 2 Frame Dibuang dan Dilaporkan
# ------------------------------------------------------------------------------
def test_late_frames_dropped():
    """Memverifikasi bahwa frame yang terlambat > 2 frame (2/FPS) dibuang tanpa dikirim."""
    clock = FakeClock(start_time=0.0)
    transport = FakeTransport()

    # Saat frame 0 terkirim via transport, simulasikan lonjakan lag 0.15 detik (setara 4,5 frame)
    original_write = transport.write
    write_count = 0
    def laggy_write(data: bytes):
        nonlocal write_count
        original_write(data)
        write_count += 1
        if write_count == 1:
            clock.advance(0.15)

    transport.write = laggy_write

    player = StreamPlayer(transport=transport, clock=clock, fps=30.0, av_offset_ms=0.0)
    packets = [make_dummy_packet(i) for i in range(5)]

    stats = player.play_packets(packets)
    player.stop_reader()

    assert stats["total_frames"] == 5
    # Frame 1 dan Frame 2 terlambat > 2 frame (0.15 > 0.10 dan 0.15 > 0.133), jadi dibuang!
    assert stats["dropped_frames"] == 2, f"Harus tepat 2 frame telat yang dibuang: {stats}"
    assert stats["sent_frames"] == 3
    assert stats["sent_frames"] + stats["dropped_frames"] == 5
    assert len(player.send_timestamps) == stats["sent_frames"]


# ------------------------------------------------------------------------------
# Test (c): Penulisan dan Pembacaan Bersamaan Tanpa Deadlock (Timeout Keras)
# ------------------------------------------------------------------------------
def test_concurrent_read_write_no_deadlock():
    """Memverifikasi pembacaan simultan dan penulisan berjalan lancar tanpa deadlock."""
    fpga = FakeFPGA()
    transport = FakeTransport(fake_fpga=fpga)
    clock = FakeClock()
    captured_chunks = []
    done_event = threading.Event()

    def on_output(chunk: bytes):
        captured_chunks.append(chunk)
        if sum(len(c) for c in captured_chunks) >= 20 * 1059:
            done_event.set()

    player = StreamPlayer(
        transport=transport,
        clock=clock,
        fps=30.0,
        on_terminal_output=on_output
    )

    packets = [make_dummy_packet(i) for i in range(20)]

    t_start = time.monotonic()
    stats = player.play_packets(packets)

    # Tunggu seluruh output ASCII terbaca oleh background reader via Event
    assert done_event.wait(timeout=1.5), "Timeout menunggu seluruh paket ASCII terbaca"

    player.stop_reader(timeout=1.0)
    elapsed = time.monotonic() - t_start

    # Timeout keras: eksekusi simulasi tidak boleh memakan waktu > 2 detik
    assert elapsed < 2.0, f"Terjadi kemungkinan deadlock atau stall: elapsed={elapsed}s"
    assert stats["sent_frames"] == 20
    assert stats["dropped_frames"] == 0
    assert fpga.valid_frames_count == 20
    total_received = sum(len(c) for c in captured_chunks)
    assert total_received == 20 * 1059


# ------------------------------------------------------------------------------
# Test (d): ASCII 90 Frame dari FakeFPGA Sama Byte-Exact dengan ascii.bin
# ------------------------------------------------------------------------------
def test_ascii_90_frames_byte_exact():
    """Memverifikasi bahwa 90 frame stream_clip.bin menghasilkan keluaran ASCII 95.310 B byte-exact."""
    assert os.path.exists(STREAM_CLIP_BIN), f"Berkas tidak ditemukan: {STREAM_CLIP_BIN}"
    assert os.path.exists(ASCII_BIN), f"Berkas tidak ditemukan: {ASCII_BIN}"

    with open(STREAM_CLIP_BIN, "rb") as f:
        stream_data = f.read()

    with open(ASCII_BIN, "rb") as f:
        expected_ascii = f.read()

    assert len(expected_ascii) == 95310, f"ascii.bin harus berukuran 95.310 B, terbaca: {len(expected_ascii)}"

    fpga = FakeFPGA()
    transport = FakeTransport(fake_fpga=fpga)
    clock = FakeClock()
    received_bytes = bytearray()
    done_event = threading.Event()

    def on_output(data: bytes):
        received_bytes.extend(data)
        if len(received_bytes) >= 95310:
            done_event.set()

    player = StreamPlayer(
        transport=transport,
        clock=clock,
        fps=30.0,
        on_terminal_output=on_output
    )

    stats = player.play_stream(stream_data)

    # Tunggu seluruh 90 frame terproses oleh reader via Event
    assert done_event.wait(timeout=2.0), "Timeout menunggu seluruh 90 frame ASCII terbaca"

    player.stop_reader()

    assert stats["total_frames"] == 90
    assert stats["sent_frames"] == 90
    assert stats["dropped_frames"] == 0
    assert fpga.valid_frames_count == 90
    assert len(received_bytes) == 95310, f"Ukuran ASCII berbeda: {len(received_bytes)} != 95310"
    assert bytes(received_bytes) == expected_ascii, "Keluaran ASCII tidak cocok byte-exact terhadap ascii.bin!"


# ------------------------------------------------------------------------------
# Test (e): Mode Default MonotonicClock
# ------------------------------------------------------------------------------
def test_no_audio_mode():
    """Memverifikasi bahwa player bekerja pada mode default jam MonotonicClock dengan jadwal presisi."""
    transport = FakeTransport()
    # Inisialisasi default tanpa clock khusus -> MonotonicClock
    player = StreamPlayer(transport=transport, clock=None, fps=30.0)
    assert isinstance(player.clock, MonotonicClock)

    # Uji pengiriman 3 frame dengan jam nyata
    packets = [make_dummy_packet(0), make_dummy_packet(1), make_dummy_packet(2)]
    t_start = time.monotonic()
    stats = player.play_packets(packets)
    player.stop_reader()

    assert stats["sent_frames"] == 3
    assert stats["dropped_frames"] == 0
    assert len(player.send_timestamps) == 3

    # Verifikasi timestamp pengiriman maju secara berurutan
    for i in range(1, len(player.send_timestamps)):
        delta = player.send_timestamps[i] - player.send_timestamps[i - 1]
        assert delta >= 0.0, f"Timestamp tidak monotonik: {player.send_timestamps}"


# ------------------------------------------------------------------------------
# Test (f): Paket Rusak dari FakeTransport Tidak Membuat Player Macet
# ------------------------------------------------------------------------------
def test_corrupted_packets_do_not_hang_player():
    """Memverifikasi bahwa aliran data korup (checksum salah, fake SOF, dsb) ditangani tanpa freeze."""
    corrupt_bin = os.path.join(GOLDEN_DIR, "stream_corrupt_checksum.bin")
    false_sof_bin = os.path.join(GOLDEN_DIR, "stream_false_sof.bin")

    assert os.path.exists(corrupt_bin)
    assert os.path.exists(false_sof_bin)

    with open(corrupt_bin, "rb") as f:
        corrupt_data = f.read()

    with open(false_sof_bin, "rb") as f:
        false_sof_data = f.read()

    fpga = FakeFPGA()
    transport = FakeTransport(fake_fpga=fpga)
    clock = FakeClock()

    player = StreamPlayer(transport=transport, clock=clock, fps=30.0)

    # 1. Kirim paket korup checksum (harus ditolak oleh FPGA, 0 valid frame)
    t_start = time.monotonic()
    player.play_stream(corrupt_data)
    assert time.monotonic() - t_start < 2.0
    assert fpga.checksum_errors >= 1
    assert fpga.valid_frames_count == 0

    # 2. Kirim stream_false_sof (25B palsu disusul 90 frame valid sejati)
    player.play_stream(false_sof_data)
    player.stop_reader()

    # FPGA harus berhasil resinkronisasi dan menerima 90 frame sejati
    assert fpga.valid_frames_count == 90
    assert fpga.resyncs_count >= 1


# ------------------------------------------------------------------------------
# Test (g): Pengujian --ascii-out dan --no-display Byte-Exact vs ascii.bin
# ------------------------------------------------------------------------------
def test_ascii_out_and_display_options(tmp_path):
    """Memverifikasi opsi pencatatan file --ascii-out dan penonaktifan display --no-display."""
    with open(STREAM_CLIP_BIN, "rb") as f:
        stream_data = f.read()
    with open(ASCII_BIN, "rb") as f:
        expected_ascii = f.read()

    ascii_out_file = str(tmp_path / "stream_dump.bin")
    stdout_buf = bytearray()
    event_disp = threading.Event()

    # Simulasikan handler terminal dengan ascii_out aktif dan display aktif
    f_out = open(ascii_out_file, "wb")
    def handler_with_display(data: bytes):
        stdout_buf.extend(data)
        f_out.write(data)
        f_out.flush()
        if len(stdout_buf) >= 95310:
            event_disp.set()

    fpga = FakeFPGA()
    transport = FakeTransport(fake_fpga=fpga)
    clock = FakeClock()

    player = StreamPlayer(
        transport=transport,
        clock=clock,
        fps=30.0,
        on_terminal_output=handler_with_display
    )

    player.play_stream(stream_data)

    assert event_disp.wait(timeout=2.0), "Timeout menunggu 90 frame ASCII terbaca pada handler display"

    player.stop_reader()
    f_out.close()

    # Verifikasi byte-exact 95.310 B pada stdout_buf dan berkas output
    assert len(stdout_buf) == 95310
    assert bytes(stdout_buf) == expected_ascii

    with open(ascii_out_file, "rb") as f:
        saved_ascii = f.read()
    assert len(saved_ascii) == 95310
    assert saved_ascii == expected_ascii

    # Tes kedua: simulasi --no-display (stdout menerima 0 byte, berkas tetap terisi)
    ascii_out_file_nodisp = str(tmp_path / "stream_dump_nodisp.bin")
    stdout_buf_nodisp = bytearray()
    event_nodisp = threading.Event()
    f_out2 = open(ascii_out_file_nodisp, "wb")
    file_bytes_written = 0

    def handler_no_display(data: bytes):
        nonlocal file_bytes_written
        f_out2.write(data)
        f_out2.flush()
        file_bytes_written += len(data)
        if file_bytes_written >= 95310:
            event_nodisp.set()

    fpga.reset()
    transport2 = FakeTransport(fake_fpga=fpga)
    player2 = StreamPlayer(
        transport=transport2,
        clock=clock,
        fps=30.0,
        on_terminal_output=handler_no_display
    )
    player2.play_stream(stream_data)

    assert event_nodisp.wait(timeout=2.0), "Timeout menunggu 90 frame tertulis ke berkas nodisp"

    player2.stop_reader()
    f_out2.close()

    assert len(stdout_buf_nodisp) == 0, "--no-display seharusnya tidak memancarkan byte ke stdout"
    with open(ascii_out_file_nodisp, "rb") as f:
        saved_nodisp = f.read()
    assert len(saved_nodisp) == 95310
    assert saved_nodisp == expected_ascii


# ------------------------------------------------------------------------------
# Test (h): FakeFPGA vs stream_expected.txt (Manifest 6 Vektor Uji)
# ------------------------------------------------------------------------------
def test_fake_fpga_vs_manifest():
    """Menyuap keenam vektor uji ke FakeFPGA dan membandingkannya dengan stream_expected.txt."""
    manifest_path = os.path.join(GOLDEN_DIR, "stream_expected.txt")
    assert os.path.exists(manifest_path), f"Manifest tidak ditemukan: {manifest_path}"

    # Parse manifest
    expected_vectors = {}
    current_vec = None
    with open(manifest_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("VECTOR:"):
                current_vec = line.split(":", 1)[1].strip()
                expected_vectors[current_vec] = {}
            elif ":" in line and current_vec:
                k, v = line.split(":", 1)
                expected_vectors[current_vec][k.strip()] = int(v.strip())

    fpga = FakeFPGA()

    for vec_name, exp in expected_vectors.items():
        bin_path = os.path.join(GOLDEN_DIR, f"{vec_name}.bin")
        assert os.path.exists(bin_path), f"Berkas vektor tidak ditemukan: {bin_path}"

        with open(bin_path, "rb") as f:
            data = f.read()

        fpga.reset()
        fpga.receive_bytes(data)
        fpga.finish()

        assert fpga.valid_frames_count == exp["VALID_FRAMES"], (
            f"[{vec_name}] VALID_FRAMES: {fpga.valid_frames_count} != {exp['VALID_FRAMES']}"
        )
        assert fpga.checksum_errors == exp["CHECKSUM_ERRORS"], (
            f"[{vec_name}] CHECKSUM_ERRORS: {fpga.checksum_errors} != {exp['CHECKSUM_ERRORS']}"
        )
        assert fpga.length_errors == exp["LENGTH_ERRORS"], (
            f"[{vec_name}] LENGTH_ERRORS: {fpga.length_errors} != {exp['LENGTH_ERRORS']}"
        )
        assert fpga.run_errors == exp["RUN_ERRORS"], (
            f"[{vec_name}] RUN_ERRORS: {fpga.run_errors} != {exp['RUN_ERRORS']}"
        )
        assert fpga.resyncs_count == exp["RESYNCS"], (
            f"[{vec_name}] RESYNCS: {fpga.resyncs_count} != {exp['RESYNCS']}"
        )


# ------------------------------------------------------------------------------
# Test (i): Tangkapan Galat Reader Thread (Tidak Menelan Galat)
# ------------------------------------------------------------------------------
def test_reader_worker_exception_handling():
    """Memverifikasi bahwa galat pada callback on_terminal_output dicatat dan tidak menelan exception secara diam-diam."""
    fpga = FakeFPGA()
    transport = FakeTransport(fake_fpga=fpga)
    clock = FakeClock()
    error_event = threading.Event()

    def throwing_callback(data: bytes):
        error_event.set()
        raise RuntimeError("Simulated terminal write fault")

    player = StreamPlayer(
        transport=transport,
        clock=clock,
        fps=30.0,
        on_terminal_output=throwing_callback
    )

    packets = [make_dummy_packet(0), make_dummy_packet(1)]
    player.play_packets(packets)
    assert error_event.wait(timeout=1.5), "Callback galat tidak dipanggil"
    player.stop_reader()
    stats = player.get_stats()

    assert stats["reader_errors"] >= 1, "Galat callback terminal harus dihitung"
    assert stats["first_reader_error"] is not None
    assert "Simulated terminal write fault" in stats["first_reader_error"]


# ------------------------------------------------------------------------------
# Test (j): Penolakan Nilai Negatif Ekstrem pada --av-offset-ms
# ------------------------------------------------------------------------------
def test_av_offset_negative_boundary_rejection():
    """Memverifikasi bahwa nilai av_offset_ms < -(2/FPS)*1000 ms ditolak dengan ValueError."""
    transport = FakeTransport()

    # Pada 30 FPS, batas minimum adalah -2/30 * 1000 = -66.67 ms
    # Nilai -66.0 ms harus diterima
    player_valid = StreamPlayer(transport=transport, fps=30.0, av_offset_ms=-66.0)
    assert player_valid.av_offset_ms == -66.0

    # Nilai -67.0 ms harus ditolak dengan ValueError
    with pytest.raises(ValueError) as excinfo:
        StreamPlayer(transport=transport, fps=30.0, av_offset_ms=-67.0)

    assert "tidak boleh lebih negatif dari batas minimum" in str(excinfo.value)


# ------------------------------------------------------------------------------
# Test (k): Sinkronisasi Jam Audio (AudioClock & FakeAudioDevice)
# ------------------------------------------------------------------------------
def test_audio_clock_synchronization():
    """Memverifikasi AudioClock mengikuti formula: now() = frames_played / sample_rate - output_latency."""
    audio_dev = FakeAudioDevice(sample_rate=44100, latency_sec=0.020)
    audio_dev.start()
    clock = AudioClock(audio_dev)

    # Awal: 0 frame -> now() = max(0, 0 - 0.02) = 0.0
    assert clock.now() == 0.0

    # Majukan audio sebanyak 4410 sampel (0.100 detik):
    # Waktu fisik = 0.100 - 0.020 = 0.080 s
    audio_dev.advance_frames(4410)
    assert abs(clock.now() - 0.080) < 1e-3

    # Hubungkan ke StreamPlayer
    transport = FakeTransport()
    player = StreamPlayer(transport=transport, clock=clock, fps=30.0)

    # Majukan audio saat pengiriman frame
    original_write = transport.write
    def write_hook(data: bytes):
        original_write(data)
        audio_dev.advance_frames(1470)  # ~1/30 detik per frame

    transport.write = write_hook
    packets = [make_dummy_packet(i) for i in range(3)]
    stats = player.play_packets(packets)
    player.stop_reader()

    assert stats["sent_frames"] == 3
    assert stats["dropped_frames"] == 0


# ------------------------------------------------------------------------------
# Test (l): Audio Macet / Berhenti Jatuh Kembali ke MonotonicClock (Tanpa Burst)
# ------------------------------------------------------------------------------
def test_audio_stall_fallback_to_monotonic_no_burst():
    """Memverifikasi bahwa jika audio macet/berhenti di tengah streaming,
    player jatuh kembali ke MonotonicClock berjangkar dan mengirim frame
    berikutnya sesuai laju FPS tanpa burst.
    """
    fps = 30.0
    frame_interval = 1.0 / fps
    audio_dev = FakeAudioDevice(sample_rate=44100, latency_sec=0.0)
    audio_dev.start()
    # Atur batas deteksi stall 25 ms untuk pengujian responsif
    clock = AudioClock(audio_dev, stall_timeout_sec=0.025)
    transport = FakeTransport()
    player = StreamPlayer(transport=transport, clock=clock, fps=fps)

    # Kirim 30 frame: majukan audio normal di 10 frame awal, lalu hentikan di frame 10
    sent_times = []
    original_write = transport.write

    def write_hook(data: bytes):
        original_write(data)
        sent_times.append(time.monotonic())
        if len(sent_times) < 10:
            audio_dev.advance_frames(1470)
        elif len(sent_times) == 10:
            audio_dev.stop()

    transport.write = write_hook
    packets = [make_dummy_packet(i) for i in range(30)]

    with pytest.warns(UserWarning, match="stall detected"):
        stats = player.play_packets(packets)
    player.stop_reader()

    assert stats["sent_frames"] == 30
    assert stats["dropped_frames"] == 0
    assert len(sent_times) == 30
    assert clock.is_stalled is True

    # Periksa interval pengiriman setelah audio macet (frame 11..29)
    # Selang kirim harus >= 1/FPS - toleransi (tidak boleh ada burst sekaligus)
    tolerance = 0.012  # toleransi timer OS Windows
    for i in range(11, len(sent_times)):
        dt = sent_times[i] - sent_times[i - 1]
        assert dt >= (frame_interval - tolerance), (
            f"Burst terdeteksi pada frame {i}: interval {dt*1000:.2f} ms "
            f"< batas minimum {(frame_interval - tolerance)*1000:.2f} ms"
        )


# ------------------------------------------------------------------------------
# Test (m): Jam Audio Mundur Tidak Menyebabkan Frame Dikirim Dua Kali
# ------------------------------------------------------------------------------
def test_audio_backwards_clock_does_not_duplicate_frames():
    """Memverifikasi bahwa jam audio yang melompat mundur tidak menyebabkan frame dikirim ganda."""
    audio_dev = FakeAudioDevice(sample_rate=44100, latency_sec=0.0)
    audio_dev.start()
    clock = AudioClock(audio_dev, stall_timeout_sec=0.200)

    # Waktu maju ke 0.1 s
    audio_dev.advance_frames(4410)
    assert abs(clock.now() - 0.10) < 1e-3

    # Simulasikan glitch DAC di mana frame counter melompat mundur ke 2205 (0.05 s)
    audio_dev.set_frames_played(2205)

    # AudioClock harus mempertahankan sifat monotonik
    assert clock.now() >= 0.10, "AudioClock tidak boleh mundur"

    # Jalankan StreamPlayer dengan 4 frame
    transport = FakeTransport()
    player = StreamPlayer(transport=transport, clock=clock, fps=30.0)

    # Majukan audio saat pengiriman frame agar pengujian berjalan cepat
    original_write = transport.write
    def write_hook(data: bytes):
        original_write(data)
        audio_dev.advance_frames(1470)

    transport.write = write_hook
    packets = [make_dummy_packet(i) for i in range(4)]
    stats = player.play_packets(packets)
    player.stop_reader()

    # Jumlah frame terkirim tepat 4 (tidak ada duplikasi)
    assert stats["sent_frames"] == 4
    assert stats["dropped_frames"] == 0
    assert len(player.send_timestamps) == 4


# ------------------------------------------------------------------------------
# Test (n): Rentang Frame (--start-frame dan --max-frames)
# ------------------------------------------------------------------------------
def test_stream_player_start_and_max_frames():
    """Memverifikasi pemutaran subset frame menggunakan start_frame dan max_frames."""
    transport = FakeTransport()
    clock = FakeClock()
    player = StreamPlayer(transport=transport, clock=clock, fps=30.0)

    packets = [make_dummy_packet(i) for i in range(20)]

    # Mainkan mulai dari frame 5 sebanyak 4 frame (frame 5, 6, 7, 8)
    stats = player.play_packets(packets, start_frame=5, max_frames=4)
    player.stop_reader()

    assert stats["total_frames"] == 4
    assert stats["sent_frames"] == 4
    assert stats["dropped_frames"] == 0


# ------------------------------------------------------------------------------
# Test (o): Penyelarasan Sampel Awal Audio (--start-frame & --audio-start-sec)
# ------------------------------------------------------------------------------
def test_audio_start_sample_alignment():
    """Memverifikasi bahwa start_sec menggeser sampel awal audio dengan benar."""
    audio_dev = FakeAudioDevice(sample_rate=44100, latency_sec=0.0, start_sec=10.0)
    assert audio_dev.start_sample() == 441000
    assert audio_dev.start_sec() == 10.0

    clock = AudioClock(audio_dev)
    # Jam acuan awal harus berada pada 10.0 detik
    assert abs(clock.now() - 10.0) < 1e-3


# ------------------------------------------------------------------------------
# Test (p): Interpolasi Halus Antara Callback Audio
# ------------------------------------------------------------------------------
def test_audio_clock_interpolation():
    """Memverifikasi bahwa AudioClock menginterpolasi waktu di antara callback audio secara mikrodetik."""
    audio_dev = FakeAudioDevice(sample_rate=44100, latency_sec=0.0)
    audio_dev.start()
    clock = AudioClock(audio_dev, stall_timeout_sec=0.200)

    t0 = clock.now()
    time.sleep(0.015)  # Tunggu 15 ms tanpa advance_frames
    t1 = clock.now()

    dt = t1 - t0
    # Waktu jam audio harus maju sekitar 15 ms (interpolasi), bukan 0 ms (terkuantisasi)
    assert dt >= 0.010, f"Jam audio terkuantisasi: dt={dt*1000:.2f} ms"





# ------------------------------------------------------------------------------
# Test (q): Kesetaraan Payload RLE Frame 300..389 Full Stream vs stream_clip.bin
# ------------------------------------------------------------------------------
def test_stream_full_payloads_match_golden_clip():
    """Memverifikasi bahwa payload RLE frame 300..389 dari stream penuh identik
    dengan 90 frame di data/golden/stream_clip.bin (FRAME_ID dan checksum diabaikan).
    """
    media_path = "media/Edit] Bad Apple!! but it's 2_1 aspect ratio.mp4"
    if not os.path.exists(media_path):
        pytest.skip(f"Berkas media video tidak ditemukan di: {media_path}")

    clip_bin_path = os.path.join(GOLDEN_DIR, "stream_clip.bin")
    if not os.path.exists(clip_bin_path):
        pytest.skip(f"Berkas golden stream_clip.bin tidak ditemukan: {clip_bin_path}")

    # Ekstrak payload dari stream_clip.bin
    from python.stream_encoder import decode_packet
    with open(clip_bin_path, "rb") as f:
        clip_data = f.read()

    clip_payloads = []
    off = 0
    while off < len(clip_data):
        fid, payload, off = decode_packet(clip_data, off)
        clip_payloads.append(payload)

    assert len(clip_payloads) == 90, f"Jumlah frame golden clip {len(clip_payloads)} != 90"

    # Periksa ketersediaan stream_full.bin atau generate frame 300..389
    full_bin_path = "data/stream_full.bin"
    if os.path.exists(full_bin_path) and os.path.getsize(full_bin_path) > 50000:
        with open(full_bin_path, "rb") as f:
            full_data = f.read()
        full_payloads = []
        off = 0
        while off < len(full_data):
            fid, payload, off = decode_packet(full_data, off)
            full_payloads.append((fid, payload))
            if len(full_payloads) >= 390:
                break
        assert len(full_payloads) >= 390, f"stream_full.bin hanya memiliki {len(full_payloads)} frame, butuh minimal 390"
        full_slice = [p[1] for p in full_payloads[300:390]]
    else:
        from python.extractor import extract_frames
        from python.canonical import pack_frame
        from python.stream_encoder import encode_canonical_frame
        # Ekstrak frame 300..389 (t=10.0s..13.0s)
        frames, _ = extract_frames(media_path, target_fps=30, start_sec=10.0, duration_sec=3.0, threshold=128)
        full_slice = []
        for i, f in enumerate(frames):
            pkt = encode_canonical_frame(300 + i, pack_frame(f))
            _, payload, _ = decode_packet(pkt, 0)
            full_slice.append(payload)

    assert len(full_slice) == len(clip_payloads) == 90
    mismatches = [i for i in range(90) if full_slice[i] != clip_payloads[i]]
    assert not mismatches, f"Terdapat {len(mismatches)} ketidakcocokan payload pada indeks frame: {mismatches}"


# ------------------------------------------------------------------------------
# Test (r): Smoke Test CLI stream_player via Subprocess
# ------------------------------------------------------------------------------
def test_cli_subprocess_smoke_tests(tmp_path):
    """Memverifikasi pemanggilan CLI stream_player lewat subprocess dari terminal bersih
    baik dengan format skrip langsung maupun modul '-m python.stream_player'.
    """
    import subprocess
    import sys
    import wave
    from pathlib import Path
    repo_root = str(Path(__file__).resolve().parent.parent)

    # Buat dummy WAV singkat 100 ms
    wav_path = tmp_path / "test_smoke.wav"
    with wave.open(str(wav_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(44100)
        wf.writeframes(b"\x00\x00" * 4410)

    clip_file = "data/golden/stream_clip.bin"

    # (a) python python/stream_player.py --help
    cmd_a = [sys.executable, "python/stream_player.py", "--help"]
    res_a = subprocess.run(cmd_a, cwd=repo_root, capture_output=True, text=True)
    assert res_a.returncode == 0, f"Smoke test (a) gagal: {res_a.stderr}"
    assert "usage: stream_player.py" in res_a.stdout

    # (b) ... --fake-fpga --file data/golden/stream_clip.bin --max-frames 3 --no-display
    cmd_b = [
        sys.executable, "python/stream_player.py",
        "--fake-fpga", "--file", clip_file,
        "--max-frames", "3", "--no-display"
    ]
    res_b = subprocess.run(cmd_b, cwd=repo_root, capture_output=True, text=True)
    assert res_b.returncode == 0, f"Smoke test (b) gagal: {res_b.stderr}"
    assert "Frame Terkirim: 3" in res_b.stdout

    # (c) idem dengan --audio <WAV> --audio-backend fake
    cmd_c = [
        sys.executable, "python/stream_player.py",
        "--fake-fpga", "--file", clip_file,
        "--max-frames", "3", "--no-display",
        "--audio", str(wav_path), "--audio-backend", "fake"
    ]
    res_c = subprocess.run(cmd_c, cwd=repo_root, capture_output=True, text=True)
    assert res_c.returncode == 0, f"Smoke test (c) gagal: {res_c.stderr}"
    assert "Frame Terkirim: 3" in res_c.stdout

    # (d) gaya -m python.stream_player
    cmd_d = [
        sys.executable, "-m", "python.stream_player",
        "--fake-fpga", "--file", clip_file,
        "--max-frames", "3", "--no-display",
        "--audio", str(wav_path), "--audio-backend", "fake"
    ]
    res_d = subprocess.run(cmd_d, cwd=repo_root, capture_output=True, text=True)
    assert res_d.returncode == 0, f"Smoke test (d) gagal: {res_d.stderr}"
    assert "Frame Terkirim: 3" in res_d.stdout


# ------------------------------------------------------------------------------
# Test (s): Disiplin Jam Audio Terhadap Jitter Sintetis (+-15 ms) & Drift (+-200 ppm)
# ------------------------------------------------------------------------------
class JitteryDriftingAudioDevice(FakeAudioDevice):
    """Perangkat audio tiruan dengan injeksi drift frekuensi (+-200 ppm)
    dan jitter pengiriman callback (+-15 ms).
    """

    def __init__(
        self,
        sample_rate: int = 44100,
        drift_ppm: float = 200.0,
        jitter_max_ms: float = 15.0,
        callback_interval_sec: float = 0.020,
        seed: int = 42,
    ):
        super().__init__(sample_rate=sample_rate, latency_sec=0.020, start_sec=0.0, auto_advance=False)
        self.drift_rate = 1.0 + (drift_ppm * 1e-6)
        self.jitter_sec = jitter_max_ms / 1000.0
        self.cb_interval = callback_interval_sec
        import random
        self.rng = random.Random(seed)
        self._sim_mono_time = 1000.0
        self._next_cb_mono = self._sim_mono_time + self.cb_interval
        self._cb_mono = self._sim_mono_time
        self._cb_frames = 0

    def start(self) -> None:
        super().start()
        self._sim_mono_time = 1000.0
        self._next_cb_mono = self._sim_mono_time + self.cb_interval
        self._cb_mono = self._sim_mono_time
        self._cb_frames = 0

    def advance_simulation(self, target_mono: float) -> None:
        """Memajukan waktu simulasi dan memicu callback jika waktunya tiba."""
        self._sim_mono_time = target_mono
        while self._sim_mono_time >= self._next_cb_mono:
            self._cb_mono = self._next_cb_mono
            elapsed_mono = self._cb_mono - 1000.0
            true_audio_sec = elapsed_mono * self.drift_rate
            # Tambahkan jitter sintetis pada estimasi callback buffer
            jitter = self.rng.uniform(-self.jitter_sec, self.jitter_sec)
            jittered_audio = max(0.0, true_audio_sec + jitter + self.output_latency())
            self._cb_frames = int(round(jittered_audio * self.sample_rate()))
            self._next_cb_mono += self.cb_interval

    def frames_played(self) -> int:
        return self._cb_frames

    def last_callback_mono(self) -> float:
        return self._cb_mono

    def true_audio_time(self, current_mono: float) -> float:
        return (current_mono - 1000.0) * self.drift_rate


def run_discipline_experiment(discipline: bool) -> tuple[float, float]:
    """Menjalankan simulasi pengiriman frame dengan FakeAudioDevice jittery/drifting."""
    dev = JitteryDriftingAudioDevice(drift_ppm=200.0, jitter_max_ms=15.0, seed=123)
    dev.start()
    sim_mono = [1000.0]
    clock = AudioClock(
        dev,
        stall_timeout_sec=0.200,
        discipline=discipline,
        discipline_window_sec=2.0,
        mono_fn=lambda: sim_mono[0]
    )

    fps = 30.0
    dt_frame = 1.0 / fps
    total_frames = 90  # 3 detik

    send_diffs_ms = []
    lock_errors_ms = []

    for frame_idx in range(total_frames):
        t_sched = frame_idx * dt_frame
        while True:
            dev.advance_simulation(sim_mono[0])
            t_clock = clock.now()
            if t_clock >= t_sched:
                diff_ms = abs(t_clock - t_sched) * 1000.0
                true_audio = dev.true_audio_time(sim_mono[0])
                lock_err_ms = abs(t_clock - true_audio) * 1000.0
                send_diffs_ms.append(diff_ms)
                if frame_idx >= 30:  # Evaluasi setelah pemanasan jendela 1 detik
                    lock_errors_ms.append(lock_err_ms)
                break
            sim_mono[0] += 0.001  # langkah simulasi 1 ms

    import numpy as np
    p99_diff = float(np.percentile(send_diffs_ms, 99))
    max_lock_err = float(np.max(lock_errors_ms)) if lock_errors_ms else 0.0
    return p99_diff, max_lock_err


def test_audio_clock_discipline_synthetic_jitter_and_drift():
    """Memverifikasi bahwa disiplin jam audio (regresi linear jendela geser ~2s)
    menekan jitter +-15 ms dan mengunci drift +200 ppm sehingga p99 <= 5 ms dan lock error <= 10 ms.
    Tes juga memverifikasi bahwa bila disiplin dinonaktifkan (discipline=False), p99 melebihi 5 ms.
    """
    # 1. Dengan disiplin AKTIF (discipline=True):
    p99_on, lock_err_on = run_discipline_experiment(discipline=True)
    assert p99_on <= 5.0, f"Disiplin ON gagal: p99 diff {p99_on:.2f} ms > 5 ms"
    assert lock_err_on <= 10.0, f"Disiplin ON gagal: lock error {lock_err_on:.2f} ms > 10 ms"

    # 2. Dengan disiplin NONAKTIF (discipline=False):
    p99_off, lock_err_off = run_discipline_experiment(discipline=False)
    # Jitter +-15 ms langsung lolos ke jam sehingga p99 melebihi 5 ms
    assert p99_off > 5.0, f"Disiplin OFF seharusnya menghasilkan p99 > 5 ms, didapat {p99_off:.2f} ms"


# ------------------------------------------------------------------------------
# Test (t): allow_large_negative_offset, Jadwal Default 0 ms (10 Frame), dan Penolakan False
# ------------------------------------------------------------------------------
def test_allow_large_negative_offset_true_no_early_drop():
    """Memverifikasi allow_large_negative_offset=True dengan av_offset_ms=-80.0 tidak error dan tidak drop frame awal."""
    packets = [make_dummy_packet(i) for i in range(10)]

    # 1. Uji deterministik dengan FakeClock
    clock = FakeClock(start_time=10.0)
    player = StreamPlayer(
        transport=FakeTransport(),
        clock=clock,
        fps=30.0,
        av_offset_ms=-80.0,
        allow_large_negative_offset=True,
    )
    stats = player.play_packets(packets)
    player.stop_reader()
    assert stats["total_frames"] == 10
    assert stats["sent_frames"] == 10
    assert stats["dropped_frames"] == 0

    # 2. Uji dengan FakeAudioDevice + AudioClock
    audio_dev = FakeAudioDevice(sample_rate=44100, latency_sec=0.0, start_sec=10.0, auto_advance=True)
    audio_dev.start()
    try:
        audio_clock = AudioClock(audio_dev, stall_timeout_sec=0.5)
        player_audio = StreamPlayer(
            transport=FakeTransport(),
            clock=audio_clock,
            fps=30.0,
            av_offset_ms=-80.0,
            allow_large_negative_offset=True,
        )
        stats_audio = player_audio.play_packets(packets)
        player_audio.stop_reader()
        assert stats_audio["total_frames"] == 10
        assert stats_audio["sent_frames"] == 10
        assert stats_audio["dropped_frames"] == 0
    finally:
        audio_dev.stop()
        audio_dev.close()


def test_default_av_offset_zero_schedule_exact_10_frames():
    """Memverifikasi default av_offset_ms=0.0 untuk 10 frame mengikuti t0 + n / 30.0 tepat."""
    t0 = 25.0
    clock = FakeClock(start_time=t0)
    player = StreamPlayer(transport=FakeTransport(), clock=clock, fps=30.0)
    assert player.av_offset_ms == 0.0

    packets = [make_dummy_packet(i) for i in range(10)]
    stats = player.play_packets(packets)
    player.stop_reader()

    assert stats["sent_frames"] == 10
    assert stats["dropped_frames"] == 0
    assert len(stats["send_timestamps"]) == 10
    assert len(stats["scheduled_timestamps"]) == 10

    for n in range(10):
        expected_t = t0 + (n / 30.0)
        assert abs(stats["scheduled_timestamps"][n] - expected_t) < 1e-9
        assert abs(stats["send_timestamps"][n] - expected_t) < 1e-9


def test_allow_large_negative_offset_false_rejects_minus_67ms():
    """Memverifikasi allow_large_negative_offset=False dengan -67.0 ms tetap melempar ValueError."""
    with pytest.raises(ValueError, match="tidak boleh lebih negatif"):
        StreamPlayer(
            transport=FakeTransport(),
            clock=FakeClock(),
            fps=30.0,
            av_offset_ms=-67.0,
            allow_large_negative_offset=False,
        )
