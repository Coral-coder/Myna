"""The server's API: are you there, transcribe this, write this, and keep the
phone's records in step with the database here."""

from __future__ import annotations

import hmac
import ipaddress
import time
from collections import deque

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from . import __version__
from .audio import AudioError, decode_wav, resample_to_16k
from .config import Config
from . import browse, catalog
from .engines import Transcriber, Writer
from .store import KINDS, Store

# Largest clip accepted: ten minutes of 16 kHz 16-bit mono, with headroom.
MAX_AUDIO_BYTES = 24 * 1024 * 1024

# Tailscale hands out addresses in this range; together with this computer
# itself, these are the only callers the server answers unless LAN is enabled.
_TAILNET = ipaddress.ip_network("100.64.0.0/10")
_TAILNET_V6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")


class SyncRequest(BaseModel):
    since: int = 0
    changes: list[dict] = Field(default_factory=list, max_length=5000)


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


def create_app(
    config: Config, transcriber: Transcriber, writer: Writer, allow_lan: bool = False, store: Store | None = None
) -> FastAPI:
    store = store or Store(":memory:")
    app = FastAPI(title="Myna server", version=__version__)
    started = time.time()
    stats = {"transcribed": 0, "generated": 0}
    # What the server has just done, newest last, for the Live page.
    activity: deque[dict] = deque(maxlen=200)

    def note(kind: str, engine: str, took: float, text: str, audio_seconds: float = 0.0, failed: bool = False) -> None:
        activity.append(
            {
                "at": time.time(),
                "kind": kind,
                "engine": engine,
                "took": round(took, 2),
                "audio_seconds": round(audio_seconds, 1),
                "text": text[:600],
                "failed": failed,
            }
        )

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
            "records": sum(store.counts().values()),
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
        try:
            text = await run_in_threadpool(transcriber.transcribe, resample_to_16k(samples, rate))
        except Exception as error:
            note("transcribe", transcriber.name, time.perf_counter() - began, str(error), seconds, failed=True)
            raise HTTPException(status_code=500, detail=f"Transcription failed: {error}") from error
        stats["transcribed"] += 1
        note("transcribe", transcriber.name, time.perf_counter() - began, text, seconds)
        return {
            "text": text,
            "audio_seconds": round(seconds, 3),
            "took_seconds": round(time.perf_counter() - began, 3),
            "engine": transcriber.name,
        }

    @app.post("/v1/generate")
    async def generate(payload: GenerateRequest, _: None = Depends(paired)) -> dict:
        began = time.perf_counter()
        try:
            text = await run_in_threadpool(writer.generate, payload.instructions, payload.prompt, payload.max_tokens)
        except Exception as error:
            note("generate", writer.name, time.perf_counter() - began, str(error), failed=True)
            raise HTTPException(status_code=500, detail=f"Writing failed: {error}") from error
        stats["generated"] += 1
        note("generate", writer.name, time.perf_counter() - began, text)
        return {"text": text, "took_seconds": round(time.perf_counter() - began, 3), "engine": writer.name}

    @app.post("/v1/sync")
    async def sync(payload: SyncRequest, _: None = Depends(paired)) -> dict:
        return await run_in_threadpool(store.sync, payload.since, payload.changes)

    @app.get("/browse", response_class=HTMLResponse)
    def browse_list(kind: str = "utterance", q: str = "", before: float | None = None, _: None = Depends(paired)) -> str:
        return browse.list_page(store, kind if kind in KINDS else "utterance", q, before)

    def engines_state() -> dict:
        return {
            "transcriber": transcriber.name,
            "transcriber_status": getattr(transcriber, "status", ""),
            "writer": writer.name,
            "writer_status": getattr(writer, "status", ""),
        }

    @app.get("/browse/live", response_class=HTMLResponse)
    def browse_live(_: None = Depends(paired)) -> str:
        return browse.live_page(store)

    @app.get("/browse/live.json")
    def browse_live_json(_: None = Depends(paired)) -> dict:
        return {**engines_state(), **stats, "events": list(activity)[-80:]}

    @app.get("/browse/models", response_class=HTMLResponse)
    def browse_models(_: None = Depends(paired)) -> str:
        return browse.models_page(store, config, engines_state())

    @app.post("/browse/models")
    async def choose_model(request: Request, _: None = Depends(paired)):
        from urllib.parse import parse_qs

        from fastapi.responses import RedirectResponse

        form = {key: values[0] for key, values in parse_qs((await request.body()).decode()).items()}
        speech = form.get("speech", "").strip()
        repo, file = form.get("repo", "").strip(), form.get("file", "").strip()
        import threading

        # A chosen model starts downloading and loading straight away, in the
        # background; the Models and Live pages show how far along it is.
        if speech and hasattr(transcriber, "use"):
            await run_in_threadpool(transcriber.use, speech)
            config.stt_model = speech
            if hasattr(transcriber, "warm"):
                threading.Thread(target=transcriber.warm, daemon=True).start()
        if repo and file.endswith(".gguf") and hasattr(writer, "use"):
            await run_in_threadpool(writer.use, repo, file)
            config.llm_repo, config.llm_file = repo, file
            if hasattr(writer, "warm"):
                threading.Thread(target=writer.warm, daemon=True).start()
        if getattr(app.state, "save_config", True):
            config.save()
        return RedirectResponse("/browse/models", status_code=303)

    @app.get("/browse/playlist")
    def browse_playlist(_: None = Depends(paired)):
        from fastapi.responses import PlainTextResponse

        return PlainTextResponse(
            browse.playlist_text(store), headers={"Content-Disposition": 'attachment; filename="myna-heard-music.txt"'}
        )

    @app.get("/browse/note", response_class=HTMLResponse)
    def browse_note(id: str, _: None = Depends(paired)) -> str:
        return browse.note_page(store, id)

    return app
