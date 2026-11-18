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
    stt_model: str = "large-v3-turbo"
    # Language model: a Hugging Face GGUF repo and file for llama.cpp.
    llm_repo: str = "bartowski/Qwen_Qwen3-14B-GGUF"
    llm_file: str = "Qwen_Qwen3-14B-Q4_K_M.gguf"
    llm_context: int = 16384

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
