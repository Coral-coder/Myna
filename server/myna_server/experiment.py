"""Trying new models: find one on Hugging Face, run it over the last few
hours, read the results beside what the current model did, then keep it or
throw it out.

Speech models are Whisper models in CTranslate2 form (what faster-whisper
runs), or the built-in sherpa models; writing models are GGUF files."""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

from .config import data_dir

State = dict


def new_state() -> State:
    return {"kind": "", "model": "", "repo": "", "file": "", "hours": 3, "running": False, "done": 0, "total": 0,
            "note": "", "results": [], "summary": {}, "started": 0.0}


# -- finding models ----------------------------------------------------------------


def search(kind: str, query: str, most: int = 20) -> list[dict]:
    """Models on Hugging Face matching `query`, most downloaded first."""
    from huggingface_hub import HfApi

    api = HfApi()
    if kind == "speech":
        found = api.list_models(search=query or "whisper", filter="ctranslate2", sort="downloads", limit=most)
    else:
        found = api.list_models(search=query, filter="gguf", sort="downloads", limit=most)
    return [{"repo": m.id, "downloads": getattr(m, "downloads", 0) or 0, "likes": getattr(m, "likes", 0) or 0,
             "updated": str(getattr(m, "last_modified", "") or "")[:10]} for m in found]


def gguf_files(repo: str) -> list[dict]:
    """The model files in a GGUF repository, with their sizes (split files
    are counted as one, by their first part)."""
    from huggingface_hub import HfApi

    info = HfApi().model_info(repo, files_metadata=True)
    out = []
    for sibling in info.siblings or []:
        name = sibling.rfilename
        if not name.endswith(".gguf") or "mmproj" in name.lower():
            continue
        if "-of-" in name and "-00001-of-" not in name:
            continue
        out.append({"file": name, "gb": round((sibling.size or 0) / 1e9, 1)})
    return sorted(out, key=lambda row: row["gb"])


# -- what was tried before ------------------------------------------------------------


def _history_path() -> Path:
    return data_dir() / "experiments.json"


def history() -> list[dict]:
    try:
        return json.loads(_history_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def remember(entry: dict) -> None:
    rows = [entry] + history()
    try:
        _history_path().write_text(json.dumps(rows[:100], indent=1), encoding="utf-8")
    except OSError:
        pass


# -- running a trial --------------------------------------------------------------------


def run_speech(state: State, store, candidate, current_name: str, level, stop: threading.Event) -> None:
    """Transcribe the kept recordings of the last few hours with `candidate`."""
    import wave

    import numpy as np

    from .cleanup import clean
    from .tuner import agreement, words

    clips = store.clips_since(time.time() - state["hours"] * 3600)
    state.update(total=len(clips), done=0)
    took_total = audio_total = 0.0
    agree: list[float] = []
    results = []
    for clip in clips:
        if stop.is_set():
            state["note"] = "Stopped."
            break
        try:
            with wave.open(clip["path"], "rb") as source:
                raw = source.readframes(source.getnframes())
            audio = level(np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0)
            began = time.perf_counter()
            text = clean(candidate.transcribe(audio))
            took = time.perf_counter() - began
            store.add_transcript(clip["id"], candidate.name, text, took)
            took_total += took
            audio_total += float(clip.get("seconds") or 0)
            before = clean(store.transcript_of(clip["id"], current_name) or "")
            if before or text:
                agree.append(agreement(words(before), words(text)))
            results.append({"at": clip["at"], "before": before, "after": text})
        except Exception as error:
            state["note"] = f"A clip failed: {error}"
        state["done"] += 1
    state["results"] = results[-60:][::-1]
    state["summary"] = {
        "clips": len(results),
        "pace": round(audio_total / took_total, 1) if took_total else 0,
        "agreement": round(sum(agree) / len(agree), 2) if agree else 0,
        "heard_more": sum(1 for r in results if r["after"] and not r["before"]),
        "heard_less": sum(1 for r in results if r["before"] and not r["after"]),
    }


def run_writing(state: State, store, generate, owner: str, stop: threading.Event, most: int = 8) -> None:
    """Write up again the conversations of the last few hours with the new model."""
    from . import conversations

    since = time.time() - state["hours"] * 3600
    talks = [row for row in store.browse("conversation", limit=200)
             if row["at"] >= since and not row.get("discarded") and not row.get("failed")][:most]
    state.update(total=len(talks), done=0)
    names = {person["id"]: person.get("name", "") for person in store.browse("person", limit=1000)}
    known = [m.get("content", "") for m in store.browse("memory", limit=300) if m.get("content")]
    results = []
    began_all = time.perf_counter()
    for row in talks:
        if stop.is_set():
            state["note"] = "Stopped."
            break
        start, end = float(row.get("startedAt") or row["at"]), float(row.get("endedAt") or row["at"])
        lines = conversations._real(line for line in store.browse("utterance", limit=4000, before=end + 1)
                                    if line["at"] >= start - 1)
        try:
            if lines:
                began = time.perf_counter()
                new = conversations.process(lines, names, [], known, owner, generate)
                results.append({"at": row["at"], "id": row["id"], "before": row, "after": new,
                                "took": round(time.perf_counter() - began, 1)})
        except Exception as error:
            state["note"] = f"A write-up failed: {error}"
        state["done"] += 1
    state["results"] = results
    state["summary"] = {"conversations": len(results), "seconds": round(time.perf_counter() - began_all)}
