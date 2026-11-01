"""python/audio_player.py
Modul Pemutar Audio PC (Opsi A1) untuk Bad Apple!! di Basys 3.

Fitur:
1. AudioDevice (ABC):
   - start, stop, frames_played, output_latency, sample_rate, is_active
2. FakeAudioDevice:
   - Perangkat audio tiruan deterministik untuk pengujian unit tanpa hardware
3. SoundDeviceAudio:
   - Pemutaran stream mentah PCM16 via sounddevice.RawOutputStream (lazy import) tanpa numpy
4. AudioClock:
   - Jam sinkronisasi audio: now() = frames_played / sample_rate - output_latency
"""

from __future__ import annotations
import abc
import os
import time
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


class FakeAudioDevice(AudioDevice):
    """Perangkat audio tiruan deterministik untuk pengujian unit tanpa sound card riil."""

    def __init__(
        self,
        sample_rate: int = 44100,
        latency_sec: float = 0.020,
    ):
        self._sample_rate = sample_rate
        self._latency = latency_sec
        self._frames_played = 0
        self._active = False
        self.stall_simulation = False

    def start(self) -> None:
        self._active = True

    def stop(self) -> None:
        self._active = False

    def advance_frames(self, frames: int) -> None:
        """Memajukan posisi sampel (untuk simulasi)."""
        if self._active and not self.stall_simulation:
            self._frames_played += frames

    def step_seconds(self, seconds: float) -> None:
        """Memajukan waktu sampel audio berdasarkan detik."""
        self.advance_frames(int(seconds * self._sample_rate))

    def set_frames_played(self, frames: int) -> None:
        """Mengatur jumlah frame secara manual (misal untuk simulasi lompatan mundur)."""
        self._frames_played = frames

    def frames_played(self) -> int:
        return self._frames_played

    def output_latency(self) -> float:
        return self._latency

    def sample_rate(self) -> int:
        return self._sample_rate

    def is_active(self) -> bool:
        return self._active


class SoundDeviceAudio(AudioDevice):
    """Implementasi pemutar audio nyata menggunakan pustaka sounddevice (lazy import)."""

    def __init__(self, wav_path: str):
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

        if self._sample_width != 2:
            raise ValueError(f"Hanya format PCM 16-bit yang didukung, terbaca: {self._sample_width * 8}-bit")

        self._frames_played = 0
        self._active = False
        self._latency = 0.0

        # Inisialisasi RawOutputStream dengan buffer mentah tanpa numpy
        self._stream = self._sd.RawOutputStream(
            samplerate=self._sample_rate,
            channels=self._channels,
            dtype="int16",
            callback=self._audio_callback,
        )

    def _audio_callback(self, outdata: memoryview, frames: int, time_info, status) -> None:
        """Callback audio non-blocking sounddevice: mengisi buffer outdata dari berkas WAV."""
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
            self._wav.rewind()
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


class AudioClock:
    """Jam acuan berbasis audio: now() = frames_played / sample_rate - output_latency.

    Rumus Waktu Fisik:
    ------------------
    - `frames_played / sample_rate`: Waktu sampel audio yang telah ditransfer host ke buffer DAC.
    - `output_latency`: Waktu tunda fisik sebelum sampel di buffer DAC dikeluarkan sebagai gelombang suara speaker/earphone.
    - `now() = (frames_played / sample_rate) - output_latency`: Menghitung waktu pemutaran suara yang sedang
      didengar manusia secara fisik saat ini, memastikan frame video tepat sejajar dengan suara fisik.
    """

    def __init__(self, device: AudioDevice):
        self.device = device
        self._last_time: float = 0.0

    def now(self) -> float:
        """Mengembalikan posisi pemutaran audio fisik terkini dalam detik."""
        sr = self.device.sample_rate()
        if sr <= 0:
            return 0.0

        raw_time = (self.device.frames_played() / float(sr)) - self.device.output_latency()
        # Waktu awal tidak boleh negatif
        current_time = max(0.0, raw_time)

        # Jam monotonik: tidak boleh mundur
        if current_time > self._last_time:
            self._last_time = current_time

        return self._last_time

    def sleep_until(self, target_time: float) -> None:
        """Menunggu hingga jam audio mencapai target_time atau hingga audio berhenti/macet."""
        t_start = time.monotonic()
        while self.now() < target_time:
            # Proteksi jika pemutaran audio berhenti atau macet
            if not self.device.is_active():
                break
            # Timeout proteksi stall: jika jam audio tidak maju dalam 0.5 detik
            if time.monotonic() - t_start > 0.5:
                break
            time.sleep(0.001)
