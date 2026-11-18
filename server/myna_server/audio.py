"""Reading the audio the phone sends: 16-bit mono WAV."""

from __future__ import annotations

import io
import wave

import numpy as np


class AudioError(ValueError):
    pass


def decode_wav(data: bytes) -> tuple[np.ndarray, int]:
    """Return (samples in -1..1 as float32, sample rate)."""
    try:
        with wave.open(io.BytesIO(data), "rb") as wav:
            channels = wav.getnchannels()
            width = wav.getsampwidth()
            rate = wav.getframerate()
            frames = wav.readframes(wav.getnframes())
    except (wave.Error, EOFError) as error:
        raise AudioError(f"not a WAV file: {error}") from error
    if width != 2:
        raise AudioError(f"expected 16-bit audio, got {width * 8}-bit")
    samples = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    return samples, rate


def resample_to_16k(samples: np.ndarray, rate: int) -> np.ndarray:
    """Linear resampling; the phone already sends 16 kHz, so this is rarely used."""
    if rate == 16000 or samples.size == 0:
        return samples
    duration = samples.size / rate
    target = int(round(duration * 16000))
    source_positions = np.linspace(0, samples.size - 1, num=target)
    return np.interp(source_positions, np.arange(samples.size), samples).astype(np.float32)
