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


class WhisperTranscriber:
    """faster-whisper on the graphics card, falling back to the processor."""

    def __init__(self, config: Config) -> None:
        self.name = f"whisper-{config.stt_model}"
        self._model_name = config.stt_model
        self._model = None
        self._lock = threading.Lock()
        self.device = "unloaded"

    def _load(self):
        if self._model is not None:
            return self._model
        _add_nvidia_dll_dirs()
        from faster_whisper import WhisperModel

        cache = str(data_dir() / "models" / "whisper")
        try:
            self._model = WhisperModel(self._model_name, device="cuda", compute_type="float16", download_root=cache)
            self.device = "cuda"
        except Exception:
            self._model = WhisperModel(self._model_name, device="cpu", compute_type="int8", download_root=cache)
            self.device = "cpu"
        return self._model

    def transcribe(self, samples: np.ndarray) -> str:
        with self._lock:
            model = self._load()
            segments, _ = model.transcribe(
                samples,
                language="en",
                beam_size=5,
                vad_filter=False,
                condition_on_previous_text=False,
            )
            return " ".join(segment.text.strip() for segment in segments).strip()


_THINK = re.compile(r"<think>.*?</think>", re.DOTALL)


class LlamaWriter:
    """A GGUF language model run by llama.cpp inside this process."""

    def __init__(self, config: Config) -> None:
        self.name = config.llm_file.removesuffix(".gguf")
        self._config = config
        self._model = None
        self._lock = threading.Lock()

    def _load(self):
        if self._model is not None:
            return self._model
        _add_nvidia_dll_dirs()
        from huggingface_hub import hf_hub_download
        from llama_cpp import Llama

        path = hf_hub_download(
            repo_id=self._config.llm_repo,
            filename=self._config.llm_file,
            cache_dir=str(data_dir() / "models" / "llm"),
        )
        self._model = Llama(model_path=path, n_gpu_layers=-1, n_ctx=self._config.llm_context, verbose=False)
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
