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


# -- models worth trying, without searching -------------------------------------------------

# (model, name, why). A model is a Whisper size, "sherpa:<key>" or a
# Hugging Face faster-whisper repository.
SUGGESTED_SPEECH = (
    ("sherpa:parakeet-v2", "Parakeet v2", "Very accurate English and very fast, on the processor. What Omi uses."),
    ("nyrahealth/faster_CrisperWhisper", "CrisperWhisper",
     "Whisper retrained to write exactly what was said (ums, repeats) and to invent less from silence."),
    ("turbo", "Whisper large-v3 turbo", "Near the most accurate Whisper, several times faster."),
    ("distil-whisper/distil-large-v3.5-ct2", "Distil-Whisper large-v3.5", "English only; fast and close to large-v3."),
    ("large-v3", "Whisper large-v3", "The most accurate Whisper; slowest."),
    ("sherpa:canary", "Canary 180m flash", "Small and quick; English, Spanish, German, French."),
    ("sherpa:parakeet-v3", "Parakeet v3", "Like v2, in 25 languages."),
)

# (job, [(repo, file, name, GB, why)])
SUGGESTED_WRITING = (
    ("For the Main model: writes notes and answers", (
        ("unsloth/Qwen3.6-35B-A3B-MTP-GGUF", "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf", "Qwen 3.6 35B (A3B)", 22.9,
         "Big but light to run: only 3B of it works on each word."),
        ("bartowski/Qwen_Qwen3-30B-A3B-GGUF", "Qwen_Qwen3-30B-A3B-Q4_K_M.gguf", "Qwen 3 30B (A3B)", 18.6,
         "The previous generation of the same idea."),
        ("bartowski/google_gemma-3-27b-it-GGUF", "google_gemma-3-27b-it-Q4_K_M.gguf", "Gemma 3 27B", 16.5,
         "Careful writer; bigger than the card, so slower."),
        ("bartowski/mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF",
         "mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf", "Mistral Small 3.2 24B", 14.3,
         "Good at following instructions exactly."),
    )),
    ("Fits the graphics card: fast and good", (
        ("bartowski/Qwen_Qwen3-14B-GGUF", "Qwen_Qwen3-14B-Q4_K_M.gguf", "Qwen 3 14B", 9.0, "Strong all-rounder."),
        ("bartowski/google_gemma-3-12b-it-GGUF", "google_gemma-3-12b-it-Q4_K_M.gguf", "Gemma 3 12B", 7.3,
         "Natural-sounding summaries."),
        ("bartowski/phi-4-GGUF", "phi-4-Q4_K_M.gguf", "Phi-4 14B", 9.1, "Precise and to the point."),
    )),
    ("Small and quick: for the Helper or Checker job", (
        ("bartowski/Qwen_Qwen3-4B-GGUF", "Qwen_Qwen3-4B-Q4_K_M.gguf", "Qwen 3 4B", 2.5, "Fast anywhere; smart for its size."),
        ("bartowski/google_gemma-3-4b-it-GGUF", "google_gemma-3-4b-it-Q4_K_M.gguf", "Gemma 3 4B", 2.5, "Fast anywhere."),
        ("bartowski/microsoft_Phi-4-mini-instruct-GGUF", "microsoft_Phi-4-mini-instruct-Q4_K_M.gguf", "Phi-4 mini", 2.5,
         "Fast anywhere."),
        ("bartowski/Qwen_Qwen3-1.7B-GGUF", "Qwen_Qwen3-1.7B-Q4_K_M.gguf", "Qwen 3 1.7B", 1.3,
         "Tiny; instant on the processor."),
    )),
)


# -- finding models ----------------------------------------------------------------


def search(kind: str, query: str, most: int = 20) -> list[dict]:
    """Models on Hugging Face matching `query`, most downloaded first."""
    from huggingface_hub import HfApi

    api = HfApi()
    if kind == "speech":
        # CTranslate2 also runs translation and text models; keep speech ones only.
        found = [m for m in api.list_models(search=query or "whisper", filter="ctranslate2", sort="downloads",
                                            limit=most * 4)
                 if is_speech_model(m.id, getattr(m, "tags", None) or [], getattr(m, "pipeline_tag", None))][:most]
    else:
        found = api.list_models(search=query, filter="gguf", sort="downloads", limit=most)
    return [{"repo": m.id, "downloads": getattr(m, "downloads", 0) or 0, "likes": getattr(m, "likes", 0) or 0,
             "updated": str(getattr(m, "last_modified", "") or "")[:10]} for m in found]


def is_speech_model(repo: str, tags: list[str], pipeline: str | None) -> bool:
    """A Whisper speech-recognition model (not a translation or text model)."""
    if pipeline == "automatic-speech-recognition" or "automatic-speech-recognition" in tags:
        return True
    return "whisper" in repo.lower() or "whisper" in [t.lower() for t in tags]


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


# -- getting the model ready ------------------------------------------------------------

# The files faster-whisper loads (the same list it downloads itself).
_WHISPER_FILES = ["config.json", "preprocessor_config.json", "model.bin", "tokenizer.json", "vocabulary.*"]


def download_speech(state: State, repo: str) -> None:
    """Download a Whisper (CTranslate2) model's files, showing progress, into
    the folder faster-whisper loads from. Raises with a plain reason if the
    repository isn't a model this server can run."""
    import fnmatch

    from huggingface_hub import HfApi, snapshot_download

    info = HfApi().model_info(repo, files_metadata=True)
    files = {s.rfilename: s.size or 0 for s in info.siblings or []}
    wanted = {name: size for name, size in files.items()
              if any(fnmatch.fnmatch(name, pattern) for pattern in _WHISPER_FILES)}
    tags = list(getattr(info, "tags", None) or [])
    if not is_speech_model(repo, tags, getattr(info, "pipeline_tag", None)):
        raise RuntimeError("this isn't a speech-recognition model (it looks like a translation or text model); "
                           "only Whisper models can be tried here")
    if "preprocessor_config.json" not in files and "whisper" not in repo.lower():
        raise RuntimeError("this model has no audio settings (preprocessor_config.json), so it can't take speech")
    if "model.bin" not in wanted:
        raise RuntimeError("this repository has no model.bin, so it isn't a faster-whisper (CTranslate2) model; "
                           "look for one with “ct2” or “faster-whisper” in its name")
    total = sum(wanted.values())
    cache = data_dir() / "models" / "whisper"
    done = threading.Event()

    def report() -> None:
        while not done.wait(1):
            got = sum(f.stat().st_size for f in cache.rglob("*.incomplete") if f.is_file())
            state["note"] = (f"Downloading the model: {got / 1e9:.2f} of {total / 1e9:.2f} GB"
                             if total else f"Downloading the model: {got / 1e9:.2f} GB")

    state["note"] = f"Downloading the model ({total / 1e9:.2f} GB)…"
    threading.Thread(target=report, daemon=True).start()
    try:
        try:
            snapshot_download(repo, cache_dir=str(cache), allow_patterns=_WHISPER_FILES, local_files_only=True)
            return   # already cached
        except Exception:
            pass
        snapshot_download(repo, cache_dir=str(cache), allow_patterns=_WHISPER_FILES)
    finally:
        done.set()


def prepare_speech(state: State, candidate, model: str) -> None:
    """Download (when it's a Hugging Face model), then load, before any recording is tried."""
    state["phase"] = "download"
    if "/" in model and not model.startswith("sherpa:"):
        download_speech(state, model)
    state.update(phase="load", note="Loading the model…")
    if hasattr(candidate, "warm"):
        candidate.warm()
    status = str(getattr(candidate, "status", ""))
    if status.startswith("Couldn't") or getattr(candidate, "_model", True) is None:
        raise RuntimeError(status.removeprefix("Couldn't load: ") or "it didn't load")
    state.update(phase="run", note=f"Loaded ({status.lower()}). Transcribing…")


def prepare_writing(state: State, trial) -> None:
    """Download and load the writing model before any conversation is tried."""
    if not hasattr(trial, "warm"):
        return
    state.update(phase="download", note="Downloading and loading the model…")
    stop = threading.Event()

    def follow() -> None:
        while not stop.wait(1):
            state["note"] = str(getattr(trial, "status", "")) or state["note"]

    threading.Thread(target=follow, daemon=True).start()
    try:
        trial.warm()
    finally:
        stop.set()
    status = str(getattr(trial, "status", ""))
    if not status.startswith("Ready"):
        raise RuntimeError(status.removeprefix("Couldn't load: ") or "it didn't load")
    state.update(phase="run", note=f"{status}. Writing up…")


# -- running a trial --------------------------------------------------------------------


def run_speech(state: State, store, candidate, current_name: str, level, stop: threading.Event,
               pause=None) -> None:
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
    failures = 0
    for clip in clips:
        if stop.is_set():
            state["note"] = "Stopped."
            break
        if pause is not None:
            pause()   # live audio first
        if failures >= 3 and not results:
            # It can't run at all: say why, rather than failing every recording.
            state["note"] = f"This model couldn't run: {state.get('first_error', '')}"
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
            failures += 1
            state.setdefault("first_error", str(error)[:400])
            if results:
                state["note"] = f"{failures} recordings failed, the first with: {state['first_error']}"
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
