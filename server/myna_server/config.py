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
    llm_repo: str = "google/gemma-4-12B-it-qat-q4_0-gguf"
    llm_file: str = "gemma-4-12b-it-qat-q4_0.gguf"
    llm_context: int = 8192
    # Where each model runs: the writing model on "gpu", "shared" (split with
    # the processor) or "cpu"; speech on "auto" (graphics card) or "cpu".
    llm_device: str = "gpu"
    stt_device: str = "auto"

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
        config.save(path)
        return config

    def save(self, path: Path | None = None) -> None:
        path = path or data_dir() / "config.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=2), encoding="utf-8")
