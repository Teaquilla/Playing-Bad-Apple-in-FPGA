"""python/audio_player.py
Modul Pemutar Audio PC (Opsi A1) untuk Bad Apple!! di Basys 3.

Fitur:
1. AudioDevice (ABC):
   - start, stop, frames_played, output_latency, sample_rate, is_active
   - start_sec, start_sample, last_callback_mono
2. FakeAudioDevice:
   - Perangkat audio tiruan deterministik untuk pengujian unit tanpa hardware
3. SoundDeviceAudio:
   - Pemutaran stream mentah PCM16 via sounddevice.RawOutputStream (lazy import) tanpa numpy
   - Mendukung start_sec untuk menggeser posisi awal audio berkas WAV
4. AudioClock:
   - Jam sinkronisasi audio fisik:
     now() = start_sec + frames_played / sample_rate - output_latency + dt_interp
   - Interpolasi mikrodetik di antara panggilan callback menggunakan time.monotonic()
   - Deteksi audio stall/berhenti: jika audio tidak maju > stall_timeout_sec (default 100 ms),
     jatuh kembali (fallback) ke MonotonicClock yang berjangkar di nilai audio terakhir
   - sleep_until menjamin tidak terjadi pengiriman burst frame saat audio berhenti
"""

from __future__ import annotations
import abc
import os
import time
import warnings
import wave
from typing import Optional


class AudioDevice(abc.ABC):
    """Antarmuka perangkat audio abstrak untuk pemutar audio PC (opsi A1)."""

    @abc.abstractmethod
    def start(self) -> None:
        """Memulai pemutaran audio."""
        pass

    @abc.abstractmethod
    def stop(self) -> None:
        """Menghentikan pemutaran audio."""
        pass

    @abc.abstractmethod
    def frames_played(self) -> int:
        """Mengembalikan jumlah total sampel frame audio yang telah diputar."""
        pass

    @abc.abstractmethod
    def output_latency(self) -> float:
        """Mengembalikan estimasi latensi perangkat keras output dalam detik."""
        pass

    @abc.abstractmethod
    def sample_rate(self) -> int:
        """Mengembalikan laju sampel audio dalam Hz."""
        pass

    @abc.abstractmethod
    def is_active(self) -> bool:
        """Memeriksa apakah perangkat audio sedang aktif memutar."""
        pass

    @abc.abstractmethod
    def start_sec(self) -> float:
        """Mengembalikan posisi awal audio dalam detik."""
        pass

    @abc.abstractmethod
    def start_sample(self) -> int:
        """Mengembalikan posisi awal audio dalam sampel."""
        pass

    @abc.abstractmethod
    def last_callback_mono(self) -> float:
        """Mengembalikan timestamp time.monotonic() dari callback/pemajuan sampel terakhir."""
        pass


class FakeAudioDevice(AudioDevice):
    """Perangkat audio tiruan deterministik untuk pengujian unit tanpa sound card riil."""

    def __init__(
        self,
        sample_rate: int = 44100,
        latency_sec: float = 0.020,
        start_sec: float = 0.0,
    ):
        self._sample_rate = sample_rate
        self._latency = latency_sec
        self._start_sec = max(0.0, start_sec)
        self._start_sample = int(round(self._start_sec * self._sample_rate))
        self._frames_played = 0
        self._active = False
        self._last_advance_mono = time.monotonic()
        self.stall_simulation = False

    def start(self) -> None:
        self._active = True
        self._last_advance_mono = time.monotonic()

    def stop(self) -> None:
        self._active = False

    def advance_frames(self, frames: int) -> None:
        """Memajukan posisi sampel (untuk simulasi)."""
        if self._active and not self.stall_simulation:
            self._frames_played += frames
            self._last_advance_mono = time.monotonic()

    def step_seconds(self, seconds: float) -> None:
        """Memajukan waktu sampel audio berdasarkan detik."""
        self.advance_frames(int(seconds * self._sample_rate))

    def set_frames_played(self, frames: int) -> None:
        """Mengatur jumlah frame secara manual (misal untuk simulasi lompatan mundur)."""
        self._frames_played = frames
        self._last_advance_mono = time.monotonic()

    def frames_played(self) -> int:
        return self._frames_played

    def output_latency(self) -> float:
        return self._latency

    def sample_rate(self) -> int:
        return self._sample_rate

    def is_active(self) -> bool:
        return self._active

    def start_sec(self) -> float:
        return self._start_sec

    def start_sample(self) -> int:
        return self._start_sample

    def last_callback_mono(self) -> float:
        return self._last_advance_mono


class SoundDeviceAudio(AudioDevice):
    """Implementasi pemutar audio nyata menggunakan pustaka sounddevice (lazy import)."""

    def __init__(self, wav_path: str, start_sec: float = 0.0):
        if not os.path.exists(wav_path):
            raise FileNotFoundError(f"Berkas audio tidak ditemukan: {wav_path}")

        try:
            import sounddevice as sd
        except ImportError as e:
            raise ImportError(
                "Pustaka 'sounddevice' diperlukan untuk pemutaran audio riil. "
                "Jalankan: pip install sounddevice==0.5.6 --only-binary=:all:"
            ) from e

        self._sd = sd
        self.wav_path = wav_path
        self._wav = wave.open(wav_path, "rb")

        self._channels = self._wav.getnchannels()
        self._sample_width = self._wav.getsampwidth()
        self._sample_rate = self._wav.getframerate()
        self._bytes_per_frame = self._channels * self._sample_width
        self._total_wav_frames = self._wav.getnframes()

        if self._sample_width != 2:
            raise ValueError(f"Hanya format PCM 16-bit yang didukung, terbaca: {self._sample_width * 8}-bit")

        self._start_sec = max(0.0, start_sec)
        self._start_sample = min(self._total_wav_frames, int(round(self._start_sec * self._sample_rate)))

        self._frames_played = 0
        self._active = False
        self._latency = 0.0
        self._last_callback_mono = time.monotonic()

        # Inisialisasi RawOutputStream dengan buffer mentah tanpa numpy
        self._stream = self._sd.RawOutputStream(
            samplerate=self._sample_rate,
            channels=self._channels,
            dtype="int16",
            callback=self._audio_callback,
        )

    def _audio_callback(self, outdata: memoryview, frames: int, time_info, status) -> None:
        """Callback audio non-blocking sounddevice: mengisi buffer outdata dari berkas WAV."""
        self._last_callback_mono = time.monotonic()
        needed_bytes = frames * self._bytes_per_frame
        data = self._wav.readframes(frames)
        read_bytes = len(data)

        if read_bytes < needed_bytes:
            # EOF atau underrun: salin data yang ada dan isi sisanya dengan hening (0x00)
            outdata[:read_bytes] = data
            outdata[read_bytes:] = b"\x00" * (needed_bytes - read_bytes)
            actual_frames = read_bytes // self._bytes_per_frame
            self._frames_played += actual_frames
        else:
            outdata[:] = data
            self._frames_played += frames

        # Catat estimasi latensi output dari DAC
        if hasattr(time_info, "outputBufferDacTime") and hasattr(time_info, "currentTime"):
            self._latency = max(0.0, time_info.outputBufferDacTime - time_info.currentTime)
        elif self._stream is not None:
            self._latency = self._stream.latency[1]

    def start(self) -> None:
        if not self._active:
            self._frames_played = 0
            self._wav.setpos(self._start_sample)
            self._last_callback_mono = time.monotonic()
            self._stream.start()
            self._active = True

    def stop(self) -> None:
        if self._active:
            self._stream.stop()
            self._active = False

    def close(self) -> None:
        self.stop()
        if self._stream:
            self._stream.close()
        if self._wav:
            self._wav.close()

    def frames_played(self) -> int:
        return self._frames_played

    def output_latency(self) -> float:
        return self._latency

    def sample_rate(self) -> int:
        return self._sample_rate

    def is_active(self) -> bool:
        return self._active

    def start_sec(self) -> float:
        return self._start_sec

    def start_sample(self) -> int:
        return self._start_sample

    def last_callback_mono(self) -> float:
        return self._last_callback_mono


class AudioClock:
    """Jam acuan berbasis audio dengan interpolasi halus dan fallback anti-stall.

    Rumus Waktu Fisik:
    ------------------
    - `base_audio = start_sec + (frames_played / sample_rate) - output_latency`
    - `dt_interp = time.monotonic() - last_callback_mono` (interpolasi di antara callback)
    - `now() = base_audio + dt_interp`

    Proteksi Stall & Fallback:
    --------------------------
    - Jika audio aktif namun waktu sejak callback terakhir melebihi `stall_timeout_sec`
      (default: 100 ms), atau audio berhenti setelah berjalan, jam otomatis beralih ke
      MonotonicClock yang berjangkar pada posisi waktu audio terakhir.
    - Peringatan UserWarning dicatat tepat satu kali.
    - Pemanggilan `sleep_until(target_time)` tetap menunda eksekusi hingga target_time
      tercapai pada laju real-time sehingga TIDAK terjadi pengiriman burst frame.
    """

    def __init__(
        self,
        device: AudioDevice,
        stall_timeout_sec: float = 0.100,
        enable_interpolation: bool = True
    ):
        self.device = device
        self.stall_timeout_sec = max(0.010, stall_timeout_sec)
        self.enable_interpolation = enable_interpolation
        self._last_time: float = 0.0
        self._started: bool = False
        self._stalled: bool = False
        self._anchor_audio_time: float = 0.0
        self._anchor_mono_time: float = time.monotonic()
        self._stall_warning_emitted: bool = False

    @property
    def is_stalled(self) -> bool:
        return self._stalled

    def now(self) -> float:
        """Mengembalikan posisi pemutaran audio fisik terkini dalam detik."""
        sr = self.device.sample_rate()
        if sr <= 0:
            return 0.0

        now_mono = time.monotonic()

        if not self._stalled:
            base_audio = self.device.start_sec() + (self.device.frames_played() / float(sr)) - self.device.output_latency()

            if self.device.is_active():
                self._started = True

            dt_callback = max(0.0, now_mono - self.device.last_callback_mono()) if self.enable_interpolation else 0.0

            # Periksa apakah terjadi stall saat sedang aktif atau berhenti setelah sempat berjalan
            is_stalled_condition = False
            if self._started:
                if not self.device.is_active():
                    is_stalled_condition = True
                elif dt_callback > self.stall_timeout_sec:
                    is_stalled_condition = True

            if is_stalled_condition:
                self._stalled = True
                self._anchor_audio_time = max(self._last_time, base_audio + min(dt_callback, self.stall_timeout_sec))
                self._anchor_mono_time = now_mono
                if not self._stall_warning_emitted:
                    warnings.warn(
                        f"Audio playback stall detected (tidak maju > {self.stall_timeout_sec*1000:.0f} ms). "
                        f"Beralih ke MonotonicClock berjangkar di {self._anchor_audio_time:.4f}s.",
                        UserWarning,
                        stacklevel=2
                    )
                    self._stall_warning_emitted = True
            else:
                raw_time = base_audio + dt_callback
                if raw_time > self._last_time:
                    self._last_time = raw_time
                return max(0.0, self._last_time)

        if self._stalled:
            current_time = self._anchor_audio_time + (now_mono - self._anchor_mono_time)
            if current_time > self._last_time:
                self._last_time = current_time
            return max(0.0, self._last_time)

    def sleep_until(self, target_time: float) -> None:
        """Menunggu hingga jam mencapai target_time dengan interpolasi halus tanpa burst."""
        while True:
            cur = self.now()
            remaining = target_time - cur
            if remaining <= 0.0:
                break
            sleep_chunk = min(remaining, 0.002)
            time.sleep(sleep_chunk)
