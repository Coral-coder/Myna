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

    def use(self, model_name: str) -> None:
        """Switch to another Whisper model; it loads on its next use."""
        with self._lock:
            self._model = None
            self._model_name = model_name
            self.name = _speech_name(model_name)
            self.status = "Not loaded yet (loads on first use)"

    def reload(self) -> None:
        """Drop the loaded model so it loads again with the current settings."""
        with self._lock:
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

        self.status = "Downloading and loading…"
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
                mark.write_text("1")
                self._model = WhisperModel(self._model_name, device="cuda", compute_type="float16", download_root=cache)
                mark.unlink(missing_ok=True)
                self.device = "cuda"
                self.status = "Ready on the graphics card"
            except Exception:
                if not crashed_before:
                    mark.unlink(missing_ok=True)
                self._model = WhisperModel(self._model_name, device="cpu", compute_type="int8", download_root=cache)
                self.device = "cpu"
                why = "" if wants_cpu else (
                    " (loading on the graphics card crashed the server earlier; choose Graphics card again on the Models tab to retry)"
                    if crashed_before else " (the graphics card couldn't be used)"
                )
                self.status = "Ready on the processor" + why
        except Exception as error:
            self.status = f"Couldn't load: {error}"
            raise
        return self._model

    def transcribe(self, samples: np.ndarray) -> str:
        with self._lock:
            model = self._load()
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

    def reload(self) -> None:
        """Stop the runner so it starts again with the current settings."""
        with self._lock:
            self._stop()
            self.status = "Reloading…"

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
            # Where it runs: all on the graphics card, all on the processor, or
            # (no setting) llama.cpp fits what it can on the card by itself.
            device = self._config.llm_device
            layers = {"gpu": ["-ngl", "999"], "cpu": ["-ngl", "0"]}.get(device, [])
            self._process = subprocess.Popen(
                [str(exe), "-m", model, *layers, "-c", str(self._config.llm_context),
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
                            where = {"gpu": "the graphics card", "cpu": "the processor"}.get(
                                device, "the graphics card and processor together"
                            )
                            self.status = f"Ready on {where}"
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
