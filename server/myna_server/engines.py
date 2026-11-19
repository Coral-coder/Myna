"""The models that do the work. Loaded on first use, kept in memory after.

The server talks to them through two small interfaces so the API can be tested
without a graphics card: anything with `transcribe` / `generate` will do.
"""

from __future__ import annotations

import json
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
_INVENTED_WHEN_UNSURE = {"thank you", "thanks", "you", "bye", "bye bye", "okay", "so", "i", "the", "oh", "hmm",
                         "yeah", "yes", "uh", "um", "mm", "mhm", ""}


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
        # Quiet, far-away speech scores poorly on both counts, so only drop a
        # segment when Whisper is nearly sure there was no speech at all.
        if no_speech > 0.85 and confidence < -1.0:
            continue
        if bare in _INVENTED_WHEN_UNSURE and (no_speech > 0.25 or confidence < -0.6):
            continue
        kept.append(text)
    return kept


def _speech_name(model: str) -> str:
    return model.removeprefix("sherpa:") if model.startswith("sherpa:") else f"whisper-{model}"


def load_sherpa(key: str, report=lambda text: None):
    """Download (once) and load one of the non-Whisper transcribers."""
    import sherpa_onnx
    from huggingface_hub import hf_hub_download

    from .catalog import SHERPA

    family, repo, files, _ = SHERPA[key]
    cache = str(data_dir() / "models" / "sherpa")
    paths = []
    for index, name in enumerate(files):
        report(f"Downloading {key} ({index + 1} of {len(files)})…")
        paths.append(hf_hub_download(repo_id=repo, filename=name, cache_dir=cache))
    report("Loading…")
    threads = max(2, min(8, (os.cpu_count() or 4) // 2))
    make = sherpa_onnx.OfflineRecognizer
    if family in ("nemo_transducer", "transducer"):
        return make.from_transducer(encoder=paths[0], decoder=paths[1], joiner=paths[2], tokens=paths[3],
                                    num_threads=threads, model_type=family)
    if family == "canary":
        return make.from_nemo_canary(encoder=paths[0], decoder=paths[1], tokens=paths[2], num_threads=threads)
    if family == "moonshine":
        return make.from_moonshine(preprocessor=paths[0], encoder=paths[1], uncached_decoder=paths[2],
                                   cached_decoder=paths[3], tokens=paths[4], num_threads=threads)
    if family == "sense_voice":
        return make.from_sense_voice(model=paths[0], tokens=paths[1], num_threads=threads, language="auto", use_itn=True)
    raise RuntimeError(f"Unknown transcriber family: {family}")


def decode_sherpa(model, key: str, samples: np.ndarray) -> str:
    """Transcribe 16 kHz audio with a loaded sherpa-onnx model, a stretch at a time."""
    from .catalog import SHERPA

    step = int(SHERPA[key][3] * 16000)
    pieces = []
    for start in range(0, len(samples), step):
        stream = model.create_stream()
        stream.accept_waveform(16000, samples[start : start + step])
        model.decode_stream(stream)
        text = stream.result.text.strip()
        if text:
            pieces.append(text)
    return " ".join(pieces)


class WhisperTranscriber:
    """The chosen transcriber: a Whisper size on faster-whisper (graphics card,
    falling back to the processor), or one of the sherpa-onnx models."""

    def __init__(self, config: Config) -> None:
        self.name = _speech_name(config.stt_model)
        self._model_name = config.stt_model
        self._config = config
        self._model = None
        self._lock = threading.Lock()
        self.device = "unloaded"
        self.status = "Not loaded yet (loads on first use)"
        # The wearer's own words, given to Whisper as words to listen for.
        self.hotwords = ""
        # The main recognizer is never unloaded to make room for another model.
        self.essential = False

    def _budget_key(self) -> str:
        return f"{self.name}@{id(self)}"

    def _unload_for_room(self) -> bool:
        """Called by the memory budget: free this model unless it is in use."""
        if not self._lock.acquire(blocking=False):
            return False
        try:
            self._model = None
            self.device = "unloaded"
            self.status = "Unloaded to make room; loads again when needed"
            return True
        finally:
            self._lock.release()

    def use(self, model_name: str) -> None:
        """Switch to another Whisper model; it loads on its next use."""
        from .memory import budget

        with self._lock:
            budget.forget(self._budget_key())
            self._model = None
            self._model_name = model_name
            self.name = _speech_name(model_name)
            self.status = "Not loaded yet (loads on first use)"

    def force_reset(self) -> None:
        """Stop and unload now, without waiting for a stuck request to finish.
        A sherpa model's helper process is killed (which ends a stuck request
        at once). It loads again on next use."""
        if self._model_name.startswith("sherpa:"):
            from .sidecar import helper

            helper.kill()
        from .memory import budget

        budget.forget(self._budget_key())
        self._model = None
        self.status = "Stopped; reloading…"

    def reload(self) -> None:
        """Drop the loaded model so it loads again with the current settings."""
        from .memory import budget

        with self._lock:
            budget.forget(self._budget_key())
            self._model = None
            # Choosing where it runs again is also the way to retry the
            # graphics card after it crashed.
            (data_dir() / "loading-whisper-on-gpu").unlink(missing_ok=True)
            self.status = "Reloading…"

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
        if self._model_name.startswith("sherpa:"):
            def report(text: str) -> None:
                self.status = text

            # These run in the helper process (see sidecar.py).
            from .sidecar import helper

            try:
                helper.call("stt_load", self._model_name.removeprefix("sherpa:"), report=report)
                self._model = "helper"
                self.device = "cpu"
                self.status = "Ready on the processor"
            except Exception as error:
                self.status = f"Couldn't load: {error}"
                raise
            return self._model
        _add_nvidia_dll_dirs()
        from faster_whisper import WhisperModel

        from .memory import GB, WHISPER_GB, budget

        self.status = "Downloading and loading…"
        size = WHISPER_GB.get(self._model_name, 2.0) * GB
        cache = str(data_dir() / "models" / "whisper")
        # If loading onto the graphics card killed the worker last time, the
        # mark below is still there: use the processor instead of crashing again.
        mark = data_dir() / "loading-whisper-on-gpu"
        crashed_before = mark.exists()
        try:
            wants_cpu = self._config.stt_device == "cpu"
            try:
                if wants_cpu:
                    raise RuntimeError("processor chosen")
                if crashed_before:
                    raise RuntimeError("the graphics card crashed the server last time")
                # Make room on the card first; if it can't be made, use the processor.
                if not budget.make_room(self._budget_key(), "gpu", size):
                    raise RuntimeError("not enough room on the graphics card")
                mark.write_text("1")
                with budget.loading:
                    self._model = WhisperModel(self._model_name, device="cuda", compute_type="float16",
                                               download_root=cache)
                mark.unlink(missing_ok=True)
                self.device = "cuda"
                self.status = "Ready on the graphics card"
            except Exception:
                if not crashed_before:
                    mark.unlink(missing_ok=True)
                budget.make_room(self._budget_key(), "ram", size)
                with budget.loading:
                    self._model = WhisperModel(self._model_name, device="cpu", compute_type="int8",
                                               download_root=cache)
                self.device = "cpu"
                why = "" if wants_cpu else (
                    " (loading on the graphics card crashed the server earlier; choose Graphics card again on the Models tab to retry)"
                    if crashed_before else " (the graphics card couldn't be used)"
                )
                self.status = "Ready on the processor" + why
        except Exception as error:
            self.status = f"Couldn't load: {error}"
            raise
        budget.register(self._budget_key(), "gpu" if self.device == "cuda" else "ram", size,
                        self._unload_for_room, keep=self.essential)
        return self._model

    def transcribe(self, samples: np.ndarray) -> str:
        from .memory import budget

        with self._lock:
            model = self._load()
            budget.touch(self._budget_key())
            if self._model_name.startswith("sherpa:"):
                from .sidecar import helper

                try:
                    return helper.call("stt", self._model_name.removeprefix("sherpa:"), samples)
                except Exception as error:
                    self._model = None
                    self.status = f"Stopped: {error}"
                    raise
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
                # Skip stretches of silence over two seconds that Whisper
                # would otherwise fill with made-up words.
                word_timestamps=True,
                hallucination_silence_threshold=2.0,
                hotwords=self.hotwords or None,
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
LLAMA_PORTS = {"llm": 8791, "helper": 8792, "summary": 8793, "checker": 8794, "embedder": 8795}
_strays_cleared = False


def is_moe(model_file: str) -> bool:
    """A mixture-of-experts model: only a small part of it works on each word."""
    return bool(re.search(r"A\d+B|gpt-oss|moe|mixtral", model_file, re.IGNORECASE))


def runner_args(device: str, model: str, context: int, port: int, threads: int, mtp: bool = False,
                embedding: bool = False) -> list[str]:
    """llama-server's options for where a model runs. Only options this
    llama.cpp build (b12400) accepts; an unknown one stops the model loading.

    gpu: everything on the card.
    shared: llama.cpp's own fitting decides the split (it is on by default and
    only works while the layers are left unset): as much as fits on the card,
    and for a mixture-of-experts model the overflow is the expert weights,
    which sit in memory while everything every word uses stays on the card.
    The model is read fully into memory (no memory-mapping, so nothing is
    paged back in from disk mid-answer) and the processor's share runs on the
    fast cores only.
    cpu: everything on the processor, read fully into memory.
    """
    args = ["-m", model, "-c", str(context), "--host", "127.0.0.1", "--port", str(port),
            # Notes and answers don't need the model's visible "thinking"; it only costs time.
            "--reasoning", "off",
            # One request at a time (the server sends them one by one), so all
            # the working memory goes to that one, and MTP requires it.
            "-np", "1"]
    if embedding:
        # Meaning-vectors instead of text; Qwen3-Embedding pools on the last token.
        args += ["--embedding", "--pooling", "last"]
    if mtp:
        # The model drafts the next words with its own built-in head and checks them in one pass.
        args += ["--spec-type", "draft-mtp", "--spec-draft-n-max", "2"]
    if device == "gpu":
        return args + ["-ngl", "999"]
    args += ["-lm", "none", "-t", str(threads)]
    if device == "cpu":
        return args + ["-ngl", "0"]
    return args


def cpu_threads(configured: int = 0) -> int:
    """Threads for work on the processor: the fast cores only. On a chip with
    fast and efficient cores (like the i9-14900K's 8 + 16), spreading the work
    onto the efficient ones makes it slower, not faster."""
    if configured > 0:
        return configured
    return max(2, min(8, (os.cpu_count() or 8) // 4))


def fit_text(text: str, most: int) -> str:
    """Shorten text to at most `most` characters, keeping its start and end
    (where the question and the latest material usually are)."""
    if len(text) <= most:
        return text
    head = most * 2 // 3
    tail = most - head - 40
    return text[:head] + "\n[… shortened to fit …]\n" + text[-max(tail, 0):]


class Speeds:
    """How fast each writing model actually runs on this computer, measured
    from every real request (llama-server reports its own timings), and kept
    between runs."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.table: dict[str, dict] = {}
        self._loaded = False

    def _path(self) -> Path:
        return data_dir() / "speeds.json"

    def _load(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        try:
            self.table = json.loads(self._path().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.table = {}

    def record(self, model_file: str, device: str, timings: dict) -> None:
        writing = float(timings.get("predicted_per_second") or 0)
        reading = float(timings.get("prompt_per_second") or 0)
        if writing <= 0:
            return
        drafted = float(timings.get("draft_n") or 0)
        accepted = float(timings.get("draft_n_accepted") or 0)
        with self._lock:
            self._load()
            row = self.table.setdefault(model_file, {"writing": writing, "reading": reading, "requests": 0})
            mix = 0.8 if row["requests"] else 0.0   # running average, recent requests count more
            row["writing"] = row["writing"] * mix + writing * (1 - mix)
            if reading > 0:
                row["reading"] = row.get("reading", reading) * mix + reading * (1 - mix)
            if drafted > 0:
                row["accepted"] = row.get("accepted", accepted / drafted) * mix + (accepted / drafted) * (1 - mix)
            row["requests"] += 1
            row["device"] = device
            try:
                self._path().write_text(json.dumps(self.table, indent=1), encoding="utf-8")
            except OSError:
                pass

    def get(self, model_file: str) -> dict:
        with self._lock:
            self._load()
            return dict(self.table.get(model_file) or {})


speeds = Speeds()


# The writing-model jobs, in order: a job whose model is the same file as an
# earlier job's uses that one's runner, so the model is loaded once.
_SHARE_ORDER = ("llm", "helper", "summary", "checker")
_WRITERS: dict[str, "LlamaWriter"] = {}
_ROLE_NAMES = {"llm": "Main", "helper": "Helper", "summary": "Summary", "checker": "Checker"}


class LlamaWriter:
    """A GGUF language model served by llama.cpp's `llama-server`, run beside
    this process and spoken to over localhost."""

    def __init__(self, config: Config, role: str = "llm") -> None:
        # `role` picks which settings this one reads: the main model ("llm"),
        # the small helper, or the end-of-day summary model. Each has its own
        # runner on its own port.
        self._role = role
        self._port = LLAMA_PORTS[role]
        self._config = config
        self.name = self._file.removesuffix(".gguf")
        self._process = None
        self._lock = threading.Lock()
        self.status = "Not loaded yet" if self._file else "Not chosen"
        _WRITERS[role] = self

    def _twin(self) -> "LlamaWriter | None":
        """An earlier job running the same model file, whose runner this job uses."""
        if self._role not in _SHARE_ORDER or not self.chosen:
            return None
        for role in _SHARE_ORDER[: _SHARE_ORDER.index(self._role)]:
            other = _WRITERS.get(role)
            if other is not None and other._config is self._config and other.chosen \
                    and (other._repo, other._file) == (self._repo, self._file):
                return other
        return None

    def _shared(self, twin: "LlamaWriter") -> None:
        """Using `twin`'s runner: free this job's own copy if one is loaded."""
        if self._process is not None:
            with self._lock:
                self._stop()
        self.status = f"Same model as {_ROLE_NAMES.get(twin._role, twin._role)}: loaded once, shared"

    @property
    def _repo(self) -> str:
        return getattr(self._config, f"{self._role}_repo")

    @property
    def _file(self) -> str:
        return getattr(self._config, f"{self._role}_file")

    @property
    def _device(self) -> str:
        return getattr(self._config, f"{self._role}_device")

    @property
    def chosen(self) -> bool:
        return bool(self._repo and self._file)

    def force_stop(self) -> None:
        """Kill the model's runner now, even in the middle of an answer (the
        waiting request then fails at once). It loads again on next use."""
        from .memory import budget

        budget.forget(self._budget_key())
        process = self._process
        if process is not None:
            try:
                process.kill()
            except Exception:
                pass
        self._process = None
        self.status = "Stopped; reloading…" if self.chosen else "Not chosen"

    def stop(self) -> None:
        """Unload the model (frees its memory); it loads again on next use."""
        with self._lock:
            if self._process is not None:
                self._stop()
                self.status = "Unloaded (loads on next use)"

    # -- switching and warming -------------------------------------------------

    def use(self, repo: str, file: str) -> None:
        """Switch to another model. `warm` then downloads and loads it."""
        with self._lock:
            self._stop()
            setattr(self._config, f"{self._role}_repo", repo)
            setattr(self._config, f"{self._role}_file", file)
            self.name = file.removesuffix(".gguf")
            self.status = "Selected; starting download…" if file else "Not chosen"

    def reload(self) -> None:
        """Stop the runner so it starts again with the current settings."""
        with self._lock:
            self._stop()
            self.status = "Reloading…"

    def warm(self) -> None:
        """Download and load the model now, so the first request doesn't wait."""
        if not self.chosen:
            return
        twin = self._twin()
        if twin is not None:
            self._shared(twin)
            return
        with self._lock:
            try:
                self._ensure_running()
            except Exception:
                self._fall_back()

    def _fall_back(self) -> bool:
        """The main model couldn't load: switch to the fallback model, once,
        and load that. Returns True if it is now running."""
        repo = getattr(self._config, f"{self._role}_fallback_repo", "")
        file = getattr(self._config, f"{self._role}_fallback_file", "")
        if not repo or not file or (repo, file) == (self._repo, self._file):
            return False
        failed = f"{self._file} couldn't load ({self.status.removeprefix('Couldn' + chr(39) + 't load: ')[:200]})"
        setattr(self._config, f"{self._role}_repo", repo)
        setattr(self._config, f"{self._role}_file", file)
        setattr(self._config, f"{self._role}_device", "gpu")
        self.name = file.removesuffix(".gguf")
        try:
            self._config.save()
        except Exception:
            pass
        try:
            self._ensure_running()
            self.status = f"{self.status}. Switched to this because {failed}."
            return True
        except Exception:
            return False

    def _budget_key(self) -> str:
        return f"{self.name}@{self._role}"

    def _unload_for_room(self) -> bool:
        """Called by the memory budget to free this model's memory. Refuses
        (returns False) if the model is in use right now."""
        if not self._lock.acquire(blocking=False):
            return False
        try:
            self._stop()
            self.status = "Unloaded to make room; loads again when needed"
            return True
        finally:
            self._lock.release()

    def _stop(self) -> None:
        from .memory import budget

        budget.forget(self._budget_key())
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
        repo, file = self._repo, self._file
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
            global _strays_cleared
            if sys.platform == "win32" and not _strays_cleared:
                # Runners left over from an earlier run of the worker would
                # hold the ports (and maybe other models); clear them out once.
                _strays_cleared = True
                subprocess.run(["taskkill", "/F", "/IM", "llama-server.exe"], capture_output=True,
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            log_path = data_dir() / f"llama-server-{self._role}.log"
            log = open(log_path, "w", encoding="utf-8", errors="replace")
            flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            # Where it runs: all on the graphics card, all on the processor, or
            # (no setting) llama.cpp fits what it can on the card by itself.
            from .memory import GB, budget, file_size

            device = self._device
            size = file_size(model) + 1.0 * GB * max(1.0, self._config.llm_context / 8192)
            key = self._budget_key()
            # Make room first, unloading idle models if needed. If the card
            # still can't take it, share it with the processor instead.
            if device == "gpu" and not budget.make_room(key, "gpu", size):
                device = "shared"
            if device in ("cpu", "shared"):
                budget.make_room(key, "ram", size)
            if device == "shared":
                # Free idle models off the card so the fitting can use more of it.
                budget.make_room(key, "gpu", min(size, 9 * GB))
            arguments = runner_args(device, model, self._config.llm_context, self._port,
                                    cpu_threads(getattr(self._config, "cpu_threads", 0)),
                                    mtp="mtp" in self._repo.lower(), embedding=self._role == "embedder")
            import time

            budget.loading.acquire()   # one model loads at a time
            loading = True
            try:
                self._process = subprocess.Popen(
                    [str(exe), *arguments],
                    stdout=log, stderr=subprocess.STDOUT, cwd=str(exe.parent), creationflags=flags,
                )
            except Exception:
                loading = False
                budget.loading.release()
                raise

            def loaded() -> None:
                nonlocal loading
                if loading:
                    loading = False
                    budget.loading.release()

            deadline = time.time() + 600
            try:
                while time.time() < deadline:
                    if self._process.poll() is not None:
                        tail = log_path.read_text(encoding="utf-8", errors="replace")[-400:]
                        raise RuntimeError(f"The model runner stopped while loading. {tail.strip()}")
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{self._port}/health", timeout=3) as reply:
                            if reply.status == 200:
                                where = {"gpu": "the graphics card", "cpu": "the processor"}.get(
                                    device, "the graphics card and processor together"
                                )
                                self.status = f"Ready on {where}"
                                budget.register(key, "gpu" if device == "gpu" else "ram", size,
                                                self._unload_for_room, keep=self._role == "checker")
                                return
                    except Exception:
                        time.sleep(1)
                raise RuntimeError("The model took too long to load.")
            finally:
                loaded()
        except Exception as error:
            self._stop()
            self.status = f"Couldn't load: {error}"
            raise

    def embed(self, texts: list[str]) -> list[list[float]]:
        """Meaning-vectors for `texts` (the embedder role)."""
        import urllib.request

        if not self.chosen or not texts:
            return []
        from .memory import budget

        with self._lock:
            self._ensure_running()
            budget.touch(self._budget_key())
            body = json.dumps({"input": [fit_text(text, 6000) for text in texts]}).encode()
            request = urllib.request.Request(f"http://127.0.0.1:{self._port}/v1/embeddings", data=body,
                                             headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=300) as reply:
                answer = json.loads(reply.read())
        rows = sorted(answer.get("data") or [], key=lambda row: row.get("index", 0))
        return [row["embedding"] for row in rows]

    def generate(self, instructions: str, prompt: str, max_tokens: int) -> str:
        twin = self._twin()
        if twin is not None:
            self._shared(twin)
            return twin.generate(instructions, prompt, max_tokens)
        import json
        import urllib.error
        import urllib.request

        if not self.chosen:
            raise RuntimeError("no model has been chosen for this")
        from .memory import budget

        with self._lock:
            try:
                self._ensure_running()
            except Exception:
                if not self._fall_back():
                    raise
            budget.touch(self._budget_key())
            # Keep the request inside the model's context: roughly 3 characters
            # per token, leaving room for the instructions and the answer.
            context = int(self._config.llm_context)
            max_tokens = max(64, min(max_tokens, context // 3))
            room = max(2000, (context - max_tokens - 256) * 3 - len(instructions))
            prompt = fit_text(prompt, room)
            answer = None
            for attempt in range(3):
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
                    f"http://127.0.0.1:{self._port}/v1/chat/completions",
                    data=body,
                    headers={"Content-Type": "application/json"},
                )
                try:
                    with urllib.request.urlopen(request, timeout=600) as reply:
                        answer = json.loads(reply.read())
                    break
                except urllib.error.HTTPError as error:
                    detail = error.read().decode("utf-8", "replace")[:300]
                    # Too long for the context after all: cut it further and try again.
                    if error.code == 400 and attempt < 2 and re.search(r"context|exceed|too long|n_ctx", detail, re.I):
                        prompt = fit_text(prompt, int(len(prompt) * 0.6))
                        continue
                    raise RuntimeError(f"the writing model refused the request ({error.code}): {detail}") from error
            speeds.record(self._file, self._device, answer.get("timings") or {})
            text = answer["choices"][0]["message"].get("content") or ""
            return _THINK.sub("", text).strip()


VOICE_MODEL_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx"
VOICE_MODEL_SHA256 = "5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94"


class Voices:
    """Who is speaking when. Splits a clip into stretches by speaker and gives
    each speaker a voice print: the same voice model the phone uses, so the
    phone can match the prints against the people it already knows. The work is
    done in the helper process (see sidecar.py)."""

    def __init__(self) -> None:
        self.status = "Not loaded yet"

    def _report(self, text: str) -> None:
        self.status = text

    def force_reset(self) -> None:
        from .sidecar import helper

        helper.kill()
        self.status = "Stopped; reloading…"

    def warm(self) -> None:
        from .sidecar import helper

        try:
            helper.call("voices_load", report=self._report)
            self.status = "Ready"
        except Exception as error:
            self.status = f"Not available: {error}"

    def split(self, samples: np.ndarray) -> list[tuple[float, float, int]]:
        from .sidecar import helper

        try:
            pieces = helper.call("split", samples, report=self._report)
            self.status = "Ready"
            return pieces
        except Exception as error:
            self.status = f"Not available: {error}"
            raise

    def print_of(self, samples: np.ndarray) -> list[float]:
        from .sidecar import helper

        return helper.call("print", samples, report=self._report)


class VoicesLocal:
    """The voice models themselves, loaded in whichever process calls this."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._splitter = None
        self._extractor = None
        self.status = "Not loaded yet"

    def load(self, report=lambda text: None) -> None:
        with self._lock:
            report("Downloading the voice models…")
            self._load()

    def _voice_model(self) -> str:
        import hashlib
        import urllib.request

        path = data_dir() / "models" / "voices" / "wespeaker_en_voxceleb_resnet34.onnx"
        if path.exists():
            return str(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(VOICE_MODEL_URL, timeout=60) as reply:
            data = reply.read()
        if hashlib.sha256(data).hexdigest() != VOICE_MODEL_SHA256:
            raise RuntimeError("The voice model download didn't match its expected checksum.")
        path.write_bytes(data)
        return str(path)

    def _load(self) -> None:
        if self._splitter is not None:
            return
        import sherpa_onnx
        from huggingface_hub import hf_hub_download

        self.status = "Downloading the voice models…"
        try:
            voice = self._voice_model()
            segmentation = hf_hub_download(
                repo_id="csukuangfj/sherpa-onnx-pyannote-segmentation-3-0", filename="model.onnx",
                cache_dir=str(data_dir() / "models" / "voices"),
            )
            threads = max(2, min(8, (os.cpu_count() or 4) // 2))
            embedding = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=voice, num_threads=threads)
            self._splitter = sherpa_onnx.OfflineSpeakerDiarization(
                sherpa_onnx.OfflineSpeakerDiarizationConfig(
                    segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
                        pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=segmentation),
                        num_threads=threads,
                    ),
                    embedding=embedding,
                    clustering=sherpa_onnx.FastClusteringConfig(num_clusters=-1, threshold=0.5),
                    min_duration_on=0.3,
                    min_duration_off=0.5,
                )
            )
            self._extractor = sherpa_onnx.SpeakerEmbeddingExtractor(embedding)
            self.status = "Ready"
        except Exception as error:
            self.status = f"Couldn't load: {error}"
            raise

    def warm(self) -> None:
        with self._lock:
            try:
                self._load()
            except Exception:
                pass

    def split(self, samples: np.ndarray) -> list[tuple[float, float, int]]:
        """(start, end, speaker number) for each stretch of speech, in order.
        `samples` is 16 kHz mono."""
        with self._lock:
            self._load()
            found = self._splitter.process(samples).sort_by_start_time()
            return [(float(piece.start), float(piece.end), int(piece.speaker)) for piece in found]

    def print_of(self, samples: np.ndarray) -> list[float]:
        """The voice print of one speaker's audio (16 kHz mono)."""
        with self._lock:
            self._load()
            stream = self._extractor.create_stream()
            stream.accept_waveform(16000, samples)
            stream.input_finished()
            return [round(float(value), 5) for value in self._extractor.compute(stream)]


def by_speaker(pieces: list[tuple[float, float, int]], gap: float = 1.0, shortest: float = 0.4) -> list[tuple[float, float, int]]:
    """Join neighbouring stretches by the same speaker and drop slivers."""
    joined: list[list] = []
    for start, end, speaker in pieces:
        if joined and joined[-1][2] == speaker and start - joined[-1][1] <= gap:
            joined[-1][1] = end
        else:
            joined.append([start, end, speaker])
    return [(start, end, speaker) for start, end, speaker in joined if end - start >= shortest]


VAD_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
VAD_SHA256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"


class SpeechDetector:
    """Silero voice activity detection (as Omi gates audio before its
    recognizers), with a low bar so faint, far-away speech still counts.
    Runs in whichever process calls it (the helper process, in practice)."""

    def __init__(self) -> None:
        self._config = None

    def _model(self) -> str:
        import hashlib
        import urllib.request

        path = data_dir() / "models" / "vad" / "silero_vad.onnx"
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(VAD_URL, timeout=60) as reply:
                data = reply.read()
            if hashlib.sha256(data).hexdigest() != VAD_SHA256:
                raise RuntimeError("The speech detector download didn't match its expected checksum.")
            path.write_bytes(data)
        return str(path)

    def speech_seconds(self, samples: np.ndarray) -> float:
        """How many seconds of `samples` (16 kHz mono) hold speech."""
        import sherpa_onnx

        if self._config is None:
            config = sherpa_onnx.VadModelConfig()
            config.silero_vad.model = self._model()
            config.silero_vad.threshold = 0.3
            config.silero_vad.min_silence_duration = 0.3
            config.silero_vad.min_speech_duration = 0.15
            config.sample_rate = 16000
            self._config = config
        detector = sherpa_onnx.VoiceActivityDetector(self._config, buffer_size_in_seconds=max(30, len(samples) // 16000 + 5))
        step = self._config.silero_vad.window_size
        for start in range(0, len(samples) - step + 1, step):
            detector.accept_waveform(samples[start : start + step])
        detector.flush()
        total = 0
        while not detector.empty():
            total += len(detector.front.samples)
            detector.pop()
        return total / 16000
