"""The server's API. Three things: are you there, transcribe this, write this."""

from __future__ import annotations

import hmac
import ipaddress
import time

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from . import __version__
from .audio import AudioError, decode_wav, resample_to_16k
from .config import Config
from .engines import Transcriber, Writer

# Largest clip accepted: ten minutes of 16 kHz 16-bit mono, with headroom.
MAX_AUDIO_BYTES = 24 * 1024 * 1024

# Tailscale hands out addresses in this range; together with this computer
# itself, these are the only callers the server answers unless LAN is enabled.
_TAILNET = ipaddress.ip_network("100.64.0.0/10")
_TAILNET_V6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")


class GenerateRequest(BaseModel):
    instructions: str = ""
    prompt: str
    max_tokens: int = Field(default=1024, ge=1, le=8192)


def _allowed(host: str | None, allow_lan: bool) -> bool:
    if host is None:
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return host in {"testclient", "localhost"}
    if address.is_loopback or address in _TAILNET or address in _TAILNET_V6:
        return True
    return allow_lan and address.is_private


def create_app(config: Config, transcriber: Transcriber, writer: Writer, allow_lan: bool = False) -> FastAPI:
    app = FastAPI(title="Myna server", version=__version__)
    started = time.time()
    stats = {"transcribed": 0, "generated": 0}

    @app.middleware("http")
    async def only_known_networks(request: Request, call_next):
        client = request.client.host if request.client else None
        if not _allowed(client, allow_lan):
            from fastapi.responses import JSONResponse

            return JSONResponse({"detail": "This server only answers over your private network."}, status_code=403)
        return await call_next(request)

    def paired(authorization: str | None = Header(default=None)) -> None:
        expected = f"Bearer {config.token}"
        if authorization is None or not hmac.compare_digest(authorization.encode(), expected.encode()):
            raise HTTPException(status_code=401, detail="Not paired with this server.")

    @app.get("/health")
    def health(_: None = Depends(paired)) -> dict:
        return {
            "ok": True,
            "version": __version__,
            "uptime": round(time.time() - started),
            "transcriber": transcriber.name,
            "writer": writer.name,
            **stats,
        }

    @app.post("/v1/transcribe")
    async def transcribe(request: Request, _: None = Depends(paired)) -> dict:
        body = await request.body()
        if not body:
            raise HTTPException(status_code=400, detail="No audio received.")
        if len(body) > MAX_AUDIO_BYTES:
            raise HTTPException(status_code=413, detail="That clip is too long; send it in shorter pieces.")
        try:
            samples, rate = decode_wav(body)
        except AudioError as error:
            raise HTTPException(status_code=400, detail=str(error)) from error
        seconds = samples.size / rate if rate else 0.0
        began = time.perf_counter()
        text = await run_in_threadpool(transcriber.transcribe, resample_to_16k(samples, rate))
        stats["transcribed"] += 1
        return {
            "text": text,
            "audio_seconds": round(seconds, 3),
            "took_seconds": round(time.perf_counter() - began, 3),
            "engine": transcriber.name,
        }

    @app.post("/v1/generate")
    async def generate(payload: GenerateRequest, _: None = Depends(paired)) -> dict:
        began = time.perf_counter()
        text = await run_in_threadpool(writer.generate, payload.instructions, payload.prompt, payload.max_tokens)
        stats["generated"] += 1
        return {"text": text, "took_seconds": round(time.perf_counter() - began, 3), "engine": writer.name}

    return app
