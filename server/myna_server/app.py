"""The server's API: are you there, transcribe this, write this, and keep the
phone's records in step with the database here."""

from __future__ import annotations

import hmac
import os
import ipaddress
import threading
import time
import wave

import numpy as np
from collections import deque

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from . import __version__
from .audio import AudioError, decode_wav, level, loudness, resample_to_16k
from .config import Config
from . import ask, blend, browse, catalog, conversations, daily, memory, tuner, web
from .engines import Transcriber, Writer, by_speaker
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


class AskRequest(BaseModel):
    question: str = Field(min_length=1, max_length=4000)
    history: list[dict] = Field(default_factory=list, max_length=40)


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
    config: Config,
    transcriber: Transcriber,
    writer: Writer,
    allow_lan: bool = False,
    store: Store | None = None,
    voices=None,
    helper=None,
    summarizer=None,
    audio_dir=None,
    partner_for=None,
    learning_path=None,
    checker=None,
) -> FastAPI:
    store = store or Store(":memory:")
    roles = {"llm": writer, "helper": helper, "summary": summarizer, "checker": checker}

    def chosen(model) -> bool:
        return model is not None and getattr(model, "chosen", True)

    # -- recognizers working together -------------------------------------------

    learning = blend.Learning(learning_path)
    partner = {"model": "", "engine": None}
    known_words = {"at": 0.0, "list": []}
    blend_stats = {"last": ""}

    def vocabulary() -> list[str]:
        """The wearer's own words, refreshed every ten minutes."""
        if time.time() - known_words["at"] > 600:
            known_words["at"] = time.time()
            try:
                known_words["list"] = blend.vocabulary(store)
            except Exception:
                pass
            if hasattr(transcriber, "hotwords"):
                transcriber.hotwords = ", ".join(known_words["list"][:40])
        return known_words["list"]

    engines_made: dict = {}

    def others():
        """The other recognizers on the panel, made on first need."""
        if not config.blend or partner_for is None or tune_state["running"]:
            return []
        out = []
        # Two Whisper models fit on the graphics card; any further Whisper
        # models chosen run on the processor instead, so there is no limit.
        on_card = 0 if config.stt_model.startswith("sherpa:") or config.stt_device == "cpu" else 1
        for model in blend.panel(config.stt_model, config.blend_count, config.blend_partner, config.blend_models):
            device = None
            if not model.startswith("sherpa:"):
                if on_card < 2 and config.stt_device != "cpu":
                    on_card += 1
                else:
                    device = "cpu"
            key = f"{model}@{device or 'auto'}"
            if key not in engines_made:
                engines_made[key] = partner_for(model, device) if device else partner_for(model)
            out.append(engines_made[key])
        partner["engine"] = out[0] if out else None
        partner["model"] = ", ".join(engine.name for engine in out)
        return out

    def hear(audio) -> str:
        """Transcribe one stretch with every recognizer on the panel, combined
        into one transcript; the checker settles disagreements."""
        words_known = vocabulary()
        first = transcriber.transcribe(audio)
        panel_now = others()
        if not panel_now:
            return first
        candidates = {transcriber.name: first}
        for engine in panel_now:
            try:
                candidates[engine.name] = engine.transcribe(audio)
            except Exception:
                pass  # one recognizer failing never stops the others
        if len(candidates) < 2:
            return first
        reconcile = checker.generate if chosen(checker) else (helper.generate if chosen(helper) else None)
        text, how = blend.combine(candidates, learning, reconcile, words_known)
        learning.note(candidates, text)
        blend_stats["last"] = how
        if sum(learning.heard.values()) % 20 == 0:
            learning.save()
        return text
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
        raw_audio = resample_to_16k(samples, rate)
        # Quiet (far-away) speech is brought up to a working level first.
        audio = level(raw_audio)

        def work() -> tuple[str, list[dict]]:
            """The text, and (when the voice models are there) the clip split
            by speaker, each stretch with its speaker's voice print."""
            if voices is None:
                return hear(audio), []
            try:
                pieces = by_speaker(voices.split(audio))
            except Exception:
                return hear(audio), []
            if not pieces:
                return hear(audio), []
            prints: dict[int, list[float]] = {}
            for speaker in {piece[2] for piece in pieces}:
                own = np.concatenate([audio[int(a * 16000) : int(b * 16000)] for a, b, who in pieces if who == speaker])
                try:
                    prints[speaker] = voices.print_of(own[: 16000 * 30])
                except Exception:
                    prints[speaker] = []
            out = []
            if len(prints) == 1:
                # One speaker: transcribe the clip whole (better than in pieces).
                whole = hear(audio)
                if whole:
                    out.append({"text": whole, "start": round(pieces[0][0], 2),
                                "duration": round(pieces[-1][1] - pieces[0][0], 2), "voice": prints[pieces[0][2]]})
                return whole, out
            # Every part of the clip is transcribed: each speaker's turns, and
            # also the stretches between them, where the speaker separation
            # found nobody but faint or distant speech may still be.
            spans: list[tuple[float, float, int | None]] = []
            cursor = 0.0
            for start, end, speaker in pieces:
                if start - cursor >= 1.0:
                    spans.append((cursor, start, None))
                spans.append((start, end, speaker))
                cursor = end
            if len(audio) / 16000 - cursor >= 1.0:
                spans.append((cursor, len(audio) / 16000, None))
            for start, end, speaker in spans:
                said = hear(audio[int(start * 16000) : int(end * 16000)])
                if said:
                    out.append({"text": said, "start": round(start, 2), "duration": round(end - start, 2),
                                "voice": prints[speaker] if speaker is not None else []})
            return " ".join(piece["text"] for piece in out), out

        try:
            text, segments = await run_in_threadpool(work)
        except Exception as error:
            note("transcribe", transcriber.name, time.perf_counter() - began, str(error), seconds, failed=True)
            raise HTTPException(status_code=500, detail=f"Transcription failed: {error}") from error
        stats["transcribed"] += 1
        note("transcribe", transcriber.name, time.perf_counter() - began, text, seconds)
        # Keep the audio for a few days, with what this model heard in it, so
        # another model can be tried on the same recording later.
        if audio_dir is not None and config.keep_audio_days > 0:
            try:
                heard_at = time.time() - seconds
                folder = audio_dir / time.strftime("%Y-%m-%d", time.localtime(heard_at))
                folder.mkdir(parents=True, exist_ok=True)
                path = folder / f"{int(heard_at * 1000)}.wav"
                with wave.open(str(path), "wb") as out:
                    out.setnchannels(1)
                    out.setsampwidth(2)
                    out.setframerate(16000)
                    out.writeframes((np.clip(raw_audio, -1, 1) * 32767).astype("<i2").tobytes())
                clip = store.add_clip(heard_at, seconds, str(path))
                store.add_transcript(clip, transcriber.name, text, time.perf_counter() - began)
            except Exception:
                pass  # keeping the audio is a convenience; never fail the transcription over it
        return {
            "text": text,
            "audio_seconds": round(seconds, 3),
            "took_seconds": round(time.perf_counter() - began, 3),
            "engine": transcriber.name,
            "segments": segments,
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
        status = talk_state.get("status", "") if kind == "conversation" else daily_state.get("status", "")
        return browse.list_page(store, kind if kind in KINDS else "utterance", q, before, status)

    def engines_state() -> dict:
        return {
            "transcriber": transcriber.name,
            "transcriber_status": getattr(transcriber, "status", ""),
            "writer": writer.name,
            "writer_status": getattr(writer, "status", ""),
            "voices_status": getattr(voices, "status", "") if voices is not None else "",
            "helper": getattr(helper, "name", "") if chosen(helper) else "",
            "helper_status": getattr(helper, "status", "") if helper is not None else "",
            "summary": getattr(summarizer, "name", "") if chosen(summarizer) else "",
            "summary_status": getattr(summarizer, "status", "") if summarizer is not None else "",
            "checker_status": getattr(checker, "status", "") if checker is not None else "",
            "reset_status": reset_state["status"],
            "memory": memory.budget.snapshot(),
            "reprocess": dict(reprocess),
            "tune": {"running": tune_state["running"], "status": tune_state["status"]},
            "blend": {
                "on": bool(config.blend and partner_for is not None),
                "partner": getattr(partner["engine"], "name", "") or "",
                "partner_status": getattr(partner["engine"], "status", "") or "",
                "last": blend_stats["last"],
                "reconciled": learning.reconciled,
                "rescued": learning.rescued,
            },
            "daily": dict(daily_state),
        }

    # -- trying a transcription model on the kept recordings -------------------

    reprocess = {"running": False, "done": 0, "total": 0, "model": "", "note": ""}

    def run_reprocess(hours: float) -> None:
        model = transcriber.name
        try:
            clips = store.clips_since(time.time() - hours * 3600, without_model=model)
            reprocess.update(running=True, done=0, total=len(clips), model=model, note="")
            for clip in clips:
                if transcriber.name != model:
                    reprocess["note"] = "Stopped: the model was changed part-way."
                    break
                try:
                    with wave.open(clip["path"], "rb") as source:
                        raw = source.readframes(source.getnframes())
                    audio = level(np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0)
                    began = time.perf_counter()
                    text = transcriber.transcribe(audio)
                    store.add_transcript(clip["id"], model, text, time.perf_counter() - began)
                except Exception as error:
                    reprocess["note"] = f"A clip failed: {error}"
                reprocess["done"] += 1
            if not reprocess["note"]:
                reprocess["note"] = "Finished." if clips else "Nothing to do: this model has already done every kept recording in that span."
        finally:
            reprocess["running"] = False

    @app.post("/browse/reprocess")
    async def start_reprocess(request: Request, _: None = Depends(paired)):
        from urllib.parse import parse_qs

        from fastapi.responses import RedirectResponse

        form = {key: values[0] for key, values in parse_qs((await request.body()).decode()).items()}
        try:
            hours = min(max(float(form.get("hours", "24")), 0.25), 24 * 30)
        except ValueError:
            hours = 24
        if not reprocess["running"]:
            reprocess.update(running=True, done=0, total=0, model=transcriber.name, note="Starting…")
            threading.Thread(target=run_reprocess, args=(hours,), daemon=True).start()
        return RedirectResponse("/browse/compare", status_code=303)

    @app.get("/browse/compare", response_class=HTMLResponse)
    def browse_compare(hours: float = 24, _: None = Depends(paired)) -> str:
        together = {
            "on": bool(config.blend and partner_for is not None),
            "partner": ", ".join(blend.panel(config.stt_model, config.blend_count, config.blend_partner, config.blend_models)),
            "trust": dict(learning.trust), "heard": dict(learning.heard),
            "reconciled": learning.reconciled, "rescued": learning.rescued,
            "phantoms": dict(learning.phantoms),
            "words": list(known_words["list"]),
            "arbiter": checker.name if chosen(checker) else (helper.name if chosen(helper) else ""),
            "count": config.blend_count,
        }
        return browse.compare_page(store, transcriber.name, dict(reprocess), hours, config.keep_audio_days,
                                   dict(tune_state), config.auto_tune, together)

    @app.post("/browse/blend")
    async def set_blend(request: Request, _: None = Depends(paired)):
        from urllib.parse import parse_qs

        from fastapi.responses import RedirectResponse

        form = {key: values[0] for key, values in parse_qs((await request.body()).decode()).items()}
        if form.get("blend") in ("on", "off"):
            config.blend = form["blend"] == "on"
        if "partner" in form and (form["partner"] == "" or form["partner"] in {key for key, _, _ in catalog.SPEECH}):
            config.blend_partner = form["partner"]
        if form.get("count", "").isdigit():
            config.blend_count = min(max(int(form["count"]), 2), 4)
            config.blend_models = []
        speech_keys = {key for key, _, _ in catalog.SPEECH}
        if "listening" in form:
            # The checkbox list: every ticked model listens alongside the main one.
            ticked = [m for m in parse_qs((await request.body()).decode()).get("model", []) if m in speech_keys]
            config.blend_models = [m for m in ticked if m != config.stt_model]
            config.blend = bool(config.blend_models)
        elif form.get("listen") in speech_keys:
            wanted = form["listen"]
            current = list(config.blend_models) or blend.panel(config.stt_model, config.blend_count, config.blend_partner)
            if wanted in current:
                current.remove(wanted)
            else:
                current.append(wanted)
            config.blend_models = current
            config.blend = bool(current)   # nothing listening alongside = just the main one
        if form.get("listen") == "auto":
            config.blend_models = []
        back = form.get("back", "")
        if getattr(app.state, "save_config", True):
            config.save()
        if back == "models":
            return RedirectResponse("/browse/models", status_code=303)
        if getattr(app.state, "save_config", True):
            config.save()
        return RedirectResponse("/browse/compare", status_code=303)

    # -- choosing the transcription model by itself ----------------------------

    tune_state = {"running": False, "status": "", "report": []}

    def run_tune() -> str:
        """Try the candidate models on the hardest recent recordings and keep
        the best. Returns the chosen model ("" if nothing was done). Stops and
        puts things back if recording starts again."""
        if tune_state["running"] or reprocess["running"] or not hasattr(transcriber, "use"):
            return ""
        tune_state.update(running=True, status="Picking the hardest recordings…", report=[])
        original = config.stt_model
        busy_at = store.last_clip_at()
        try:
            clips = store.clips_since(time.time() - 3 * 86400)
            for clip in clips:
                try:
                    with wave.open(clip["path"], "rb") as source:
                        clip["audio"] = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
                    clip["loudness"] = loudness(clip["audio"])
                except Exception:
                    clip["audio"], clip["loudness"] = None, 0.0
            nothing = set(store.clips_heard_nothing(time.time() - 3 * 86400))
            tests = tuner.hardest([clip for clip in clips if clip["audio"] is not None], nothing)
            if len(tests) < 6:
                tune_state["status"] = "Not enough recordings yet to tune on (needs at least six of three seconds or more)."
                return ""
            candidates = [model for model in getattr(app.state, "tune_candidates", tuner.CANDIDATES)]
            if original not in candidates:
                candidates.append(original)
            results: dict[str, list[str]] = {}
            speeds: dict[str, float] = {}
            audio_seconds = sum(clip["seconds"] for clip in tests)
            for number, model in enumerate(candidates):
                tune_state["status"] = f"Trying {model} ({number + 1} of {len(candidates)}) on {len(tests)} hard recordings…"
                try:
                    transcriber.use(model)
                    texts, spent = [], 0.0
                    for clip in tests:
                        if store.last_clip_at() != busy_at:
                            tune_state["status"] = "Stopped: recording started again. It will try again when things are quiet."
                            return ""
                        began = time.perf_counter()
                        text = transcriber.transcribe(level(clip["audio"]))
                        took = time.perf_counter() - began
                        spent += took
                        texts.append(text)
                        store.add_transcript(clip["id"], transcriber.name, text, took)
                    results[model] = texts
                    speeds[model] = audio_seconds / spent if spent > 0 else 0.0
                except Exception as error:
                    tune_state["report"].append({"model": model, "note": f"couldn't run: {error}"})
            if len(results) < 2:
                tune_state["status"] = "Couldn't compare: fewer than two models ran."
                return ""
            scores = tuner.score(results)
            winner = tuner.choose(scores, speeds)
            for model in results:
                tune_state["report"].append({
                    "model": model, "agreement": round(scores[model], 3), "speed": round(speeds[model], 1),
                    "words": sum(len(tuner.words(text)) for text in results[model]), "chosen": model == winner,
                })
            tune_state["report"].sort(key=lambda row: -row.get("agreement", 0))
            original = winner  # what `finally` puts in place
            config.tuned_at = time.time()
            tune_state["status"] = (
                f"Tuned {time.strftime('%d %b %H:%M')}: {winner} did best on {len(tests)} hard recordings "
                f"({audio_seconds / 60:.1f} minutes of audio)."
            )
            return winner
        except Exception as error:
            tune_state["status"] = f"Tuning failed: {error}"
            return ""
        finally:
            try:
                if transcriber.name != original or config.stt_model != original:
                    transcriber.use(original)
                config.stt_model = original
                if getattr(app.state, "save_config", True):
                    config.save()
                if hasattr(transcriber, "warm"):
                    threading.Thread(target=transcriber.warm, daemon=True).start()
            finally:
                tune_state["running"] = False

    app.state.run_tune = run_tune

    @app.post("/browse/tune")
    async def start_tune(_: None = Depends(paired)):
        from fastapi.responses import RedirectResponse

        threading.Thread(target=run_tune, daemon=True).start()
        return RedirectResponse("/browse/compare", status_code=303)

    # -- stopping and reloading models that have hung --------------------------

    reset_state = {"status": ""}

    def reset(which: str) -> str:
        """Stop a model at once (even mid-request) and load it again. "all"
        restarts the whole worker, which frees every bit of memory it holds."""
        stamp = time.strftime("%H:%M:%S")
        if which == "all":
            reset_state["status"] = f"{stamp}: restarting the whole server; back in a minute or two."

            def leave() -> None:
                time.sleep(1.5)  # let the page answer first
                getattr(app.state, "exit", lambda: os._exit(3))()

            threading.Thread(target=leave, daemon=True).start()
            return reset_state["status"]
        done = []
        if which in ("transcriber", "recognition"):
            if hasattr(transcriber, "force_reset"):
                transcriber.force_reset()
                done.append(transcriber.name)
            for engine in list(engines_made.values()):
                if hasattr(engine, "force_reset"):
                    engine.force_reset()
            engines_made.clear()
            if voices is not None and hasattr(voices, "force_reset"):
                voices.force_reset()
            done.append("the other recognizers and the voice models")

            def again() -> None:
                if hasattr(transcriber, "warm"):
                    transcriber.warm()
                if voices is not None and hasattr(voices, "warm"):
                    voices.warm()

            threading.Thread(target=again, daemon=True).start()
        elif which in roles and roles[which] is not None:
            model = roles[which]
            if hasattr(model, "force_stop"):
                model.force_stop()
            done.append(getattr(model, "name", which))
            if which != "summary" and hasattr(model, "warm"):
                threading.Thread(target=model.warm, daemon=True).start()
        reset_state["status"] = f"{stamp}: stopped and reloading {', '.join(done) or 'nothing'}."
        return reset_state["status"]

    app.state.reset = reset

    @app.post("/browse/reset")
    async def start_reset(request: Request, _: None = Depends(paired)):
        from urllib.parse import parse_qs

        from fastapi.responses import RedirectResponse

        form = {key: values[0] for key, values in parse_qs((await request.body()).decode()).items()}
        reset(form.get("which", ""))
        back = form.get("back", "live")
        return RedirectResponse("/browse/models" if back == "models" else "/browse/live", status_code=303)

    # -- writing up finished conversations, the way Omi does --------------------

    talk_state = {"running": False, "status": ""}

    def run_conversations(most: int = 2) -> int:
        """Write up conversations that have finished since the last one handled."""
        if talk_state["running"] or tune_state["running"] or daily_state["running"]:
            return 0
        talk_state["running"] = True
        try:
            def progress(text: str) -> None:
                talk_state["status"] = text

            cheap = helper.generate if chosen(helper) else None
            handled = conversations.run_pending(store, writer.generate, cheap, time.time(), config.owner_name,
                                                most, progress)
            if most > 2:  # the button: also try again the ones that failed before
                progress("Trying again the conversations that failed…")
                handled += conversations.retry_failed(store, writer.generate, cheap, time.time(), config.owner_name)
            if handled:
                talk_state["status"] = f"Wrote up {handled} conversation{'s' if handled != 1 else ''} at {time.strftime('%H:%M')}."
            return handled
        except Exception as error:
            talk_state["status"] = f"Couldn't write up a conversation: {error}"
            return 0
        finally:
            talk_state["running"] = False

    app.state.run_conversations = run_conversations

    @app.post("/browse/conversations")
    async def start_conversations(_: None = Depends(paired)):
        from fastapi.responses import RedirectResponse

        threading.Thread(target=run_conversations, args=(20,), daemon=True).start()
        return RedirectResponse("/browse?kind=conversation", status_code=303)

    @app.get("/browse/conversation", response_class=HTMLResponse)
    def browse_conversation(id: str, _: None = Depends(paired)) -> str:
        return browse.conversation_page(store, id)

    # -- the end-of-day summary -------------------------------------------------

    daily_state = {"running": False, "status": ""}

    def run_daily(day: str) -> str:
        """Write (or rewrite) the summary for `day`, YYYY-MM-DD."""
        if daily_state["running"]:
            return ""
        daily_state.update(running=True, status="Starting…")
        own_model = chosen(summarizer)
        try:
            write = summarizer.generate if own_model else writer.generate
            condense = helper.generate if chosen(helper) else write
            if own_model and hasattr(writer, "stop"):
                writer.stop()  # make room for the summary model

            def progress(text: str) -> None:
                daily_state["status"] = text

            text = daily.summarize(store, day, condense, write, progress)
            if text:
                start, _ = daily.day_bounds(day)
                store.sync(0, [{
                    "kind": "daily", "id": day, "updated_at": time.time(), "deleted": False,
                    "data": {"day": start, "date": day, "text": text, "writtenAt": time.time(),
                             "model": summarizer.name if own_model else writer.name},
                }])
                daily_state["status"] = f"Wrote the summary for {day}."
            else:
                daily_state["status"] = f"Nothing was saved on {day} to summarise."
            return text
        except Exception as error:
            daily_state["status"] = f"The summary for {day} failed: {error}"
            return ""
        finally:
            if own_model and hasattr(summarizer, "stop"):
                summarizer.stop()
            daily_state["running"] = False

    app.state.run_daily = run_daily

    @app.post("/browse/daily")
    async def start_daily(request: Request, _: None = Depends(paired)):
        from urllib.parse import parse_qs

        from fastapi.responses import RedirectResponse

        form = {key: values[0] for key, values in parse_qs((await request.body()).decode()).items()}
        day = form.get("day") or time.strftime("%Y-%m-%d")
        try:
            daily.day_bounds(day)
        except ValueError:
            day = time.strftime("%Y-%m-%d")
        threading.Thread(target=run_daily, args=(day,), daemon=True).start()
        return RedirectResponse("/browse?kind=daily", status_code=303)

    @app.get("/browse/ask", response_class=HTMLResponse)
    def browse_ask(_: None = Depends(paired)) -> str:
        return browse.ask_page(store)

    @app.post("/browse/ask.json")
    async def browse_ask_json(payload: AskRequest, _: None = Depends(paired)) -> dict:
        began = time.perf_counter()
        lookup = getattr(app.state, "web_lookup", web.lookup)
        try:
            pick = helper.generate if chosen(helper) else None
            result = await run_in_threadpool(
                ask.answer, store, writer.generate, lookup, payload.question, payload.history, pick
            )
        except Exception as error:
            note("generate", writer.name, time.perf_counter() - began, str(error), failed=True)
            raise HTTPException(status_code=500, detail=f"Couldn't answer: {error}") from error
        stats["generated"] += 1
        note("generate", writer.name, time.perf_counter() - began, f"Ask: {payload.question} → {result['reply']}")
        return result

    @app.get("/browse/live", response_class=HTMLResponse)
    def browse_live(_: None = Depends(paired)) -> str:
        return browse.live_page(store, engines_state())

    @app.get("/browse/live.json")
    def browse_live_json(_: None = Depends(paired)) -> dict:
        return {**engines_state(), **stats, "events": list(activity)[-80:]}

    @app.get("/browse/models", response_class=HTMLResponse)
    def browse_models(_: None = Depends(paired)) -> str:
        listening = blend.panel(config.stt_model, config.blend_count, config.blend_partner, config.blend_models)
        readout = {row["model"]: row for row in store.model_readout(time.time() - 7 * 86400)}
        return browse.models_page(store, config, engines_state(), listening, dict(learning.trust), readout)

    @app.post("/browse/models")
    async def choose_model(request: Request, _: None = Depends(paired)):
        from urllib.parse import parse_qs

        from fastapi.responses import RedirectResponse

        form = {key: values[0] for key, values in parse_qs((await request.body()).decode()).items()}
        speech = form.get("speech", "").strip()
        repo, file = form.get("repo", "").strip(), form.get("file", "").strip()
        # A chosen model starts downloading and loading straight away, in the
        # background; the Models and Live pages show how far along it is.
        llm_device, stt_device = form.get("llm_device", ""), form.get("stt_device", "")
        if stt_device in {key for key, _, _ in catalog.STT_DEVICES} and stt_device != config.stt_device:
            config.stt_device = stt_device
            if hasattr(transcriber, "reload"):
                await run_in_threadpool(transcriber.reload)
                threading.Thread(target=transcriber.warm, daemon=True).start()
        if llm_device in {key for key, _, _ in catalog.LLM_DEVICES} and llm_device != config.llm_device:
            config.llm_device = llm_device
            if hasattr(writer, "reload"):
                await run_in_threadpool(writer.reload)
                threading.Thread(target=writer.warm, daemon=True).start()
        role = form.get("role", "llm")
        if role not in roles:
            role = "llm"
        target = roles[role]
        device_keys = {key for key, _, _ in catalog.LLM_DEVICES}
        for other in ("helper", "summary", "checker"):
            wanted = form.get(f"{other}_device", "")
            if wanted in device_keys and wanted != getattr(config, f"{other}_device"):
                setattr(config, f"{other}_device", wanted)
                if roles[other] is not None and hasattr(roles[other], "reload"):
                    await run_in_threadpool(roles[other].reload)
        if form.get("clear") in ("helper", "summary", "checker") and roles[form["clear"]] is not None:
            await run_in_threadpool(roles[form["clear"]].use, "", "")
        if repo and file.endswith(".gguf"):
            # A model too big for the card can't run wholly on it: share it.
            size = next((gb for r, f, _, gb, _ in catalog.WRITING if r == repo and f == file), 0)
            if size > catalog.FITS_CARD_GB and getattr(config, f"{role}_device") == "gpu":
                setattr(config, f"{role}_device", "shared")
        if speech and hasattr(transcriber, "use"):
            await run_in_threadpool(transcriber.use, speech)
            config.stt_model = speech
            if hasattr(transcriber, "warm"):
                threading.Thread(target=transcriber.warm, daemon=True).start()
        if repo and file.endswith(".gguf") and target is not None and hasattr(target, "use"):
            await run_in_threadpool(target.use, repo, file)
            setattr(config, f"{role}_repo", repo)
            setattr(config, f"{role}_file", file)
            # The main model and the helper load now. The summary model loads
            # only when a summary is written, so it doesn't hold memory all day.
            if role not in ("summary",) and hasattr(target, "warm"):
                threading.Thread(target=target.warm, daemon=True).start()
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
