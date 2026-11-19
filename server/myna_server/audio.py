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


def level(samples: np.ndarray, target: float = 0.8, most: float = 8.0) -> np.ndarray:
    """Bring quiet audio up to a working loudness before it is transcribed.

    Speech from across a room arrives very quiet, and the models do much better
    when it isn't. The gain is set from the loud end of the clip (so a single
    click doesn't decide it) and capped, so near-silence isn't blown up into
    noise. Omi uses the same bounded peak gain (0.8 of full scale; it caps at
    4x, this allows 8x for far-field speech). The earlier 30x cap blew room
    noise up far enough for recognizers to "hear" words in it.
    """
    if samples.size == 0:
        return samples
    loud = float(np.percentile(np.abs(samples), 99.5))
    if loud <= 1e-5:
        return samples
    gain = min(target / loud, most)
    if gain <= 1.05:
        return samples
    return np.clip(samples * gain, -1.0, 1.0).astype(np.float32)


def loudness(samples: np.ndarray) -> float:
    """How loud a clip is overall (root mean square)."""
    return float(np.sqrt(np.mean(np.square(samples)))) if samples.size else 0.0
