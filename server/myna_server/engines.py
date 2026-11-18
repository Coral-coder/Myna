"""The models that do the work. Loaded on first use, kept in memory after.

The server talks to them through two small interfaces so the API can be tested
without a graphics card: anything with `transcribe` / `generate` will do.
"""

from __future__ import annotations

import os
import re
import sys
import threading
from pathlib import Path
from typing import Protocol

import numpy as np

from .config import Config, data_dir


class Transcriber(Protocol):
    name: str

    def transcribe(self, samples: np.ndarray) -> str: ...


class Writer(Protocol):
    name: str

    def generate(self, instructions: str, prompt: str, max_tokens: int) -> str: ...


def _add_nvidia_dll_dirs() -> None:
    """On Windows the CUDA libraries arrive as pip packages; make them findable."""
    if sys.platform != "win32":
        return
    for entry in sys.path:
        root = Path(entry) / "nvidia"
        if not root.is_dir():
            continue
        for bin_dir in root.glob("*/bin"):
            os.add_dll_directory(str(bin_dir))
            os.environ["PATH"] = f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"


# Whisper invents these when it is given near-silence or noise.
_ALWAYS_INVENTED = (
    "thanks for watching",
    "thank you for watching",
    "subtitles by",
    "please subscribe",
    "like and subscribe",
    "see you in the next video",
)
_INVENTED_WHEN_UNSURE = {"thank you", "thanks", "you", "bye", "bye bye", "okay", "so", "i", "the", "oh", "hmm", ""}


def _bare(text: str) -> str:
    return re.sub(r"[^a-z' ]+", "", text.lower()).strip()


def keep_segments(segments) -> list[str]:
    """The text of the segments that are really speech.

    A segment is left out when Whisper itself rates it as probably not speech,
    or when it is one of the stock phrases Whisper makes up from quiet audio and
    Whisper wasn't confident about it. Quiet real speech scores as speech and is
    kept.
    """
    kept = []
    for segment in segments:
        text = segment.text.strip()
        bare = _bare(text)
        no_speech = getattr(segment, "no_speech_prob", 0.0) or 0.0
        confidence = getattr(segment, "avg_logprob", 0.0) or 0.0
        if any(phrase in bare for phrase in _ALWAYS_INVENTED):
            continue
        if no_speech > 0.6 and confidence < -0.7:
            continue
        if bare in _INVENTED_WHEN_UNSURE and (no_speech > 0.25 or confidence < -0.6):
            continue
        kept.append(text)
    return kept


class WhisperTranscriber:
    """faster-whisper on the graphics card, falling back to the processor."""

    def __init__(self, config: Config) -> None:
        self.name = f"whisper-{config.stt_model}"
        self._model_name = config.stt_model
        self._model = None
        self._lock = threading.Lock()
        self.device = "unloaded"
        self.status = "Not loaded yet (loads on first use)"

    def use(self, model_name: str) -> None:
        """Switch to another Whisper model; it loads on its next use."""
        with self._lock:
            self._model = None
            self._model_name = model_name
            self.name = f"whisper-{model_name}"
            self.status = "Not loaded yet (loads on first use)"

    def _load(self):
        if self._model is not None:
            return self._model
        _add_nvidia_dll_dirs()
        from faster_whisper import WhisperModel

        self.status = "Loading (the first time, this downloads the model)…"
        cache = str(data_dir() / "models" / "whisper")
        try:
            try:
                self._model = WhisperModel(self._model_name, device="cuda", compute_type="float16", download_root=cache)
                self.device = "cuda"
                self.status = "Ready on the graphics card"
            except Exception:
                self._model = WhisperModel(self._model_name, device="cpu", compute_type="int8", download_root=cache)
                self.device = "cpu"
                self.status = "Ready on the processor (the graphics card couldn't be used)"
        except Exception as error:
            self.status = f"Couldn't load: {error}"
            raise
        return self._model

    def transcribe(self, samples: np.ndarray) -> str:
        with self._lock:
            model = self._load()
            segments, _ = model.transcribe(
                samples,
                language="en",
                beam_size=5,
                # Keep quiet, far-away speech: the filter below judges whether
                # a stretch is speech at all (not how loud it is), with a low
                # bar, so only stretches with no speech in them are left out
                # (Whisper invents words when given pure silence).
                vad_filter=True,
                vad_parameters={"threshold": 0.15, "min_silence_duration_ms": 600, "speech_pad_ms": 400},
                condition_on_previous_text=False,
            )
            return " ".join(keep_segments(segments)).strip()


_THINK = re.compile(r"<think>.*?</think>", re.DOTALL)


class LlamaWriter:
    """A GGUF language model run by llama.cpp inside this process."""

    def __init__(self, config: Config) -> None:
        self.name = config.llm_file.removesuffix(".gguf")
        self._config = config
        self._model = None
        self._lock = threading.Lock()
        self.status = "Not loaded yet (loads on first use)"

    def use(self, repo: str, file: str) -> None:
        """Switch to another model; it downloads and loads on its next use."""
        with self._lock:
            self._model = None
            self._config.llm_repo = repo
            self._config.llm_file = file
            self.name = file.removesuffix(".gguf")
            self.status = "Not loaded yet (loads on first use)"

    def _load(self):
        if self._model is not None:
            return self._model
        _add_nvidia_dll_dirs()
        from huggingface_hub import hf_hub_download
        from llama_cpp import Llama

        self.status = "Loading (the first time, this downloads several GB)…"
        try:
            path = hf_hub_download(
                repo_id=self._config.llm_repo,
                filename=self._config.llm_file,
                cache_dir=str(data_dir() / "models" / "llm"),
            )
            self._model = Llama(model_path=path, n_gpu_layers=-1, n_ctx=self._config.llm_context, verbose=False)
            self.status = "Ready"
        except Exception as error:
            self.status = f"Couldn't load: {error}"
            raise
        return self._model

    def generate(self, instructions: str, prompt: str, max_tokens: int) -> str:
        with self._lock:
            model = self._load()
            reply = model.create_chat_completion(
                messages=[
                    {"role": "system", "content": instructions},
                    {"role": "user", "content": prompt},
                ],
                max_tokens=max_tokens,
                temperature=0.3,
            )
            text = reply["choices"][0]["message"]["content"] or ""
            return _THINK.sub("", text).strip()
