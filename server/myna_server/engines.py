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

    def warm(self) -> None:
        """Download and load the model now, so the first clip doesn't wait."""
        with self._lock:
            try:
                self._load()
            except Exception:
                pass  # the reason is in `status`

    def _load(self):
        if self._model is not None:
            return self._model
        _add_nvidia_dll_dirs()
        from faster_whisper import WhisperModel

        self.status = "Downloading and loading…"
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


# llama.cpp's own Windows build, which picks the right code for the processor
# it is running on. (The Python binding's prebuilt package used instructions
# some Intel processors lack, and crashed with Windows error 0xc000001d.)
LLAMA_BUILD = "b12400"
LLAMA_ZIP = f"llama-{LLAMA_BUILD}-bin-win-cuda-12.4-x64.zip"
LLAMA_URL = f"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA_BUILD}/{LLAMA_ZIP}"
LLAMA_SHA256 = "15eafe06f3ea80f78b80764e1994fd74b5ffa66b5cf0875a3bd9b3ee41a058ef"
LLAMA_PORT = 8791


class LlamaWriter:
    """A GGUF language model served by llama.cpp's `llama-server`, run beside
    this process and spoken to over localhost."""

    def __init__(self, config: Config) -> None:
        self.name = config.llm_file.removesuffix(".gguf")
        self._config = config
        self._process = None
        self._lock = threading.Lock()
        self.status = "Not loaded yet"

    # -- switching and warming -------------------------------------------------

    def use(self, repo: str, file: str) -> None:
        """Switch to another model. `warm` then downloads and loads it."""
        with self._lock:
            self._stop()
            self._config.llm_repo = repo
            self._config.llm_file = file
            self.name = file.removesuffix(".gguf")
            self.status = "Selected; starting download…"

    def warm(self) -> None:
        """Download and load the model now, so the first request doesn't wait."""
        with self._lock:
            try:
                self._ensure_running()
            except Exception:
                pass  # the reason is in `status`

    def _stop(self) -> None:
        if self._process is not None:
            try:
                self._process.terminate()
                self._process.wait(timeout=15)
            except Exception:
                try:
                    self._process.kill()
                except Exception:
                    pass
        self._process = None

    # -- the runner ------------------------------------------------------------

    def _runner(self) -> Path:
        """llama-server.exe, downloaded once and checked against a known hash."""
        folder = data_dir() / "llama" / LLAMA_BUILD
        exe = folder / "llama-server.exe"
        if exe.exists():
            return exe
        if sys.platform != "win32":
            raise RuntimeError("The writing model runs on the Windows server only.")
        import hashlib
        import urllib.request
        import zipfile

        self.status = "Downloading the model runner (about 320 MB, once)…"
        folder.mkdir(parents=True, exist_ok=True)
        archive = folder / "download.zip"
        digest = hashlib.sha256()
        with urllib.request.urlopen(LLAMA_URL, timeout=60) as reply, open(archive, "wb") as out:
            while True:
                block = reply.read(1 << 20)
                if not block:
                    break
                digest.update(block)
                out.write(block)
        if digest.hexdigest() != LLAMA_SHA256:
            archive.unlink(missing_ok=True)
            raise RuntimeError("The model runner download didn't match its expected checksum.")
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(folder)
        archive.unlink(missing_ok=True)
        if not exe.exists():
            raise RuntimeError("The model runner download didn't contain llama-server.exe.")
        return exe

    def _download_model(self) -> str:
        from huggingface_hub import get_hf_file_metadata, hf_hub_download, hf_hub_url

        cache = data_dir() / "models" / "llm"
        repo, file = self._config.llm_repo, self._config.llm_file
        total = 0
        try:
            total = get_hf_file_metadata(hf_hub_url(repo, file)).size or 0
        except Exception:
            pass
        done = threading.Event()

        def report() -> None:
            while not done.wait(2):
                sizes = [part.stat().st_size for part in cache.rglob("*.incomplete") if part.is_file()]
                if sizes and total:
                    self.status = f"Downloading {file}: {max(sizes) / 1e9:.1f} of {total / 1e9:.1f} GB"
                elif sizes:
                    self.status = f"Downloading {file}: {max(sizes) / 1e9:.1f} GB so far"

        self.status = f"Downloading {file}…"
        threading.Thread(target=report, daemon=True).start()
        try:
            return hf_hub_download(repo_id=repo, filename=file, cache_dir=str(cache))
        finally:
            done.set()

    def _ensure_running(self) -> None:
        if self._process is not None and self._process.poll() is None:
            return
        self._process = None
        try:
            import subprocess
            import urllib.request

            exe = self._runner()
            model = self._download_model()
            _add_nvidia_dll_dirs()
            self.status = "Loading onto the graphics card…"
            if sys.platform == "win32":
                # A runner left over from an earlier run would hold the port
                # (and maybe another model); clear it out first.
                subprocess.run(["taskkill", "/F", "/IM", "llama-server.exe"], capture_output=True,
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            log = open(data_dir() / "llama-server.log", "w", encoding="utf-8", errors="replace")
            flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            self._process = subprocess.Popen(
                [str(exe), "-m", model, "-ngl", "999", "-c", str(self._config.llm_context),
                 "--host", "127.0.0.1", "--port", str(LLAMA_PORT)],
                stdout=log, stderr=subprocess.STDOUT, cwd=str(exe.parent), creationflags=flags,
            )
            import time

            deadline = time.time() + 600
            while time.time() < deadline:
                if self._process.poll() is not None:
                    tail = (data_dir() / "llama-server.log").read_text(encoding="utf-8", errors="replace")[-400:]
                    raise RuntimeError(f"The model runner stopped while loading. {tail.strip()}")
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{LLAMA_PORT}/health", timeout=3) as reply:
                        if reply.status == 200:
                            self.status = "Ready on the graphics card"
                            return
                except Exception:
                    time.sleep(1)
            raise RuntimeError("The model took too long to load.")
        except Exception as error:
            self._stop()
            self.status = f"Couldn't load: {error}"
            raise

    def generate(self, instructions: str, prompt: str, max_tokens: int) -> str:
        import json
        import urllib.request

        with self._lock:
            self._ensure_running()
            body = json.dumps(
                {
                    "messages": [
                        {"role": "system", "content": instructions},
                        {"role": "user", "content": prompt},
                    ],
                    "max_tokens": max_tokens,
                    "temperature": 0.3,
                }
            ).encode()
            request = urllib.request.Request(
                f"http://127.0.0.1:{LLAMA_PORT}/v1/chat/completions",
                data=body,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(request, timeout=600) as reply:
                answer = json.loads(reply.read())
            text = answer["choices"][0]["message"].get("content") or ""
            return _THINK.sub("", text).strip()
