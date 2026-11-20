"""Settings kept between runs: the pairing token and which models to use."""

from __future__ import annotations

import json
import os
import secrets
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path


def data_dir() -> Path:
    """Where the server keeps its settings and downloaded models."""
    override = os.environ.get("MYNA_SERVER_HOME")
    if override:
        return Path(override)
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / "MynaServer"
    return Path.home() / ".myna-server"


@dataclass
class Config:
    # The phone must present this on every request. Made once, on first run.
    token: str = field(default_factory=lambda: secrets.token_urlsafe(32))
    port: int = 8787
    # Speech-to-text model for faster-whisper.
    stt_model: str = "turbo"
    # Language model: a Hugging Face GGUF repo and file for llama.cpp. Gemma 4
    # 12B (about 7 GB) leaves room on a 12 GB card for Whisper beside it.
    llm_repo: str = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF"
    llm_file: str = "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
    # If the main model can't load, the server switches to this one instead.
    llm_fallback_repo: str = "google/gemma-4-12B-it-qat-q4_0-gguf"
    llm_fallback_file: str = "gemma-4-12b-it-qat-q4_0.gguf"
    # Set once the faster default has been offered (so a model chosen by hand
    # is never changed again).
    upgraded_to: str = ""
    llm_context: int = 16384
    # Where each model runs: the writing model on "gpu", "shared" (split with
    # the processor) or "cpu"; speech on "auto" (graphics card) or "cpu".
    llm_device: str = "auto"
    # Threads for model work on the processor. 0 = the fast cores (8 on an i9-14900K).
    cpu_threads: int = 0
    stt_device: str = "auto"
    # A second, smaller model that reads a lot of material and picks out what
    # matters, so the main model gets the relevant part. Empty = not used.
    helper_repo: str = ""
    helper_file: str = ""
    helper_device: str = "auto"
    # The model that writes the end-of-day summary. Empty = the main model.
    summary_repo: str = ""
    summary_file: str = ""
    summary_device: str = "auto"
    # Write the day's summary once nothing has been heard for this long.
    daily_summary: bool = True
    idle_minutes: int = 45
    # Received audio is kept this many days, so a different transcription
    # model can be tried on the same recordings. 0 = don't keep audio.
    keep_audio_days: int = 7
    # Choose the transcription model by itself: while nothing is being
    # recorded, try the candidates on the hardest recent recordings and keep
    # the best. At most once in this many hours.
    # Write up each finished conversation the way Omi does (see conversations.py).
    conversations: bool = True
    # The wearer's name, for memories ("Sam prefers…"). Empty = "the wearer".
    owner_name: str = ""
    # Two recognizers hear every clip and are combined into one transcript
    # (see blend.py). The partner is chosen automatically when left empty.
    # Where transcripts come from: "local" (Myna transcribes bracelet/phone
    # audio here) or "bee" (pull finished transcripts and summaries from Bee's
    # developer API — Bee's cloud does the transcription; the recognizer, the
    # speaker models and the speech gate don't load at all).
    transcribe_source: str = "local"
    # Bee developer API token (from developer.bee.computer), for the "bee" source.
    bee_token: str = ""
    # How often to pull new Bee conversations, in minutes.
    bee_sync_minutes: int = 10
    # Simple mode (Omi-style): one recognizer, one writing model, nothing else
    # loaded — no recognizer panel, no checker/helper/summary/embedder, no
    # per-clip speaker splitting, no auto-tuning. Keeps a 12 GB card breathing.
    simple_mode: bool = True
    # Tell speakers apart on each clip (pyannote + WeSpeaker, on the processor).
    # Independent of simple mode — the lean layers are the recognizer panel and
    # the extra writing-model roles, not this.
    speakers: bool = True
    blend: bool = False
    blend_partner: str = ""
    # How many recognizers hear each clip, counting the one in use (2 to 4).
    blend_count: int = 3
    # The recognizers chosen by hand to listen alongside the one in use.
    # Empty = chosen automatically.
    blend_models: list = field(default_factory=list)
    # A light language model that checks the recognizers' versions make sense
    # as sentences and settles disagreements. Runs on the processor.
    checker_repo: str = "bartowski/Qwen_Qwen3-1.7B-GGUF"
    checker_file: str = "Qwen_Qwen3-1.7B-Q4_K_M.gguf"
    checker_device: str = "auto"
    # A small model that turns text into meaning-vectors, so Ask can find a
    # conversation by what it was about, not only by matching words (as
    # Omi's search does). Runs on the processor.
    embedder_repo: str = "Qwen/Qwen3-Embedding-0.6B-GGUF"
    embedder_file: str = "Qwen3-Embedding-0.6B-Q8_0.gguf"
    embedder_device: str = "auto"
    # A writing model being tried on the Experiment tab (not used for anything else).
    trial_repo: str = ""
    trial_file: str = ""
    trial_device: str = "auto"
    # Skip clips the speech detector finds no speech in (Omi gates its
    # recognizers the same way). The bar is low so far-away speech passes.
    speech_gate: bool = True
    auto_tune: bool = False
    tune_every_hours: int = 24
    tuned_at: float = 0.0

    @classmethod
    def load(cls, path: Path | None = None) -> "Config":
        path = path or data_dir() / "config.json"
        if path.exists():
            try:
                raw = json.loads(path.read_text(encoding="utf-8"))
                known = {k: v for k, v in raw.items() if k in cls.__dataclass_fields__}
                config = cls(**known)
            except (json.JSONDecodeError, TypeError):
                config = cls()
        else:
            config = cls()
        # One-time move to the faster default for anyone still on the old one.
        if config.upgraded_to == "":
            if config.llm_file == "gemma-4-12b-it-qat-q4_0.gguf":
                config.llm_repo, config.llm_file = cls.llm_repo, cls.llm_file
                config.llm_device = "shared"
            config.upgraded_to = "qwen3.6-mtp"
        if config.upgraded_to == "qwen3.6-mtp":
            # Long conversations didn't fit in 8192 and were refused (HTTP 400).
            config.llm_context = max(config.llm_context, cls.llm_context)
            config.upgraded_to = "context-16k"
        if config.upgraded_to == "context-16k":
            # Every model is now placed automatically (processor or graphics
            # card, by measured speed) unless chosen by hand afterwards.
            for role in ("llm", "helper", "summary", "checker", "embedder"):
                setattr(config, f"{role}_device", "auto")
            config.stt_device = "auto"
            config.upgraded_to = "auto-devices"
        if config.upgraded_to == "auto-devices":
            # The server was doing too much at once for a 12 GB card. Simple
            # mode: one recognizer, one writer, nothing else. Also drop the
            # 23 GB shared model to one that fits the card, unless chosen by hand.
            config.simple_mode = True
            config.blend = False
            config.auto_tune = False
            config.upgraded_to = "simple-mode"
        if config.upgraded_to == "simple-mode":
            # Keep the lean layers, but the big hybrid writer and speaker
            # separation are wanted back — the overload was running everything
            # at once, not these on their own.
            config.speakers = True
            if config.llm_file == "gemma-4-12b-it-qat-q4_0.gguf":
                config.llm_repo, config.llm_file = cls.llm_repo, cls.llm_file
            config.upgraded_to = "big-and-speakers"
        config.save(path)
        return config

    def save(self, path: Path | None = None) -> None:
        path = path or data_dir() / "config.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=2), encoding="utf-8")
