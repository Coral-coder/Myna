"""Choosing the transcription model by itself.

While nothing is being recorded, the server takes the hardest recent
recordings (the quietest ones, and ones the current model heard nothing in),
runs every candidate model over them, and keeps the one that does best.

There is no correct transcript to mark against, so a model is judged by how
well it agrees with the others on each recording: speech that several models
independently hear the same way is very likely what was said, and words only
one model "hears" are very likely invented. A model that is too slow to keep
up is not chosen however well it scores."""

from __future__ import annotations

import re
from difflib import SequenceMatcher

# Tried in this order; each downloads the first time it is tried.
CANDIDATES = (
    "sherpa:parakeet-v2",
    "sherpa:parakeet-v3",
    "turbo",
    "large-v3",
    "distil-large-v3",
    "sherpa:sensevoice",
    "sherpa:canary",
)


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def agreement(mine: list[str], theirs: list[str]) -> float:
    """How alike two transcripts of the same recording are, 0 to 1."""
    if not mine and not theirs:
        return 1.0
    if not mine or not theirs:
        return 0.0
    return SequenceMatcher(None, mine, theirs, autojunk=False).ratio()


def score(results: dict[str, list[str]]) -> dict[str, float]:
    """`results[model]` is that model's text for each test recording, in the
    same order. Returns each model's average agreement with the others."""
    models = list(results)
    if len(models) < 2:
        return {model: 1.0 for model in models}
    spoken = {model: [words(text) for text in texts] for model, texts in results.items()}
    count = min(len(texts) for texts in spoken.values())
    out = {}
    for model in models:
        total = 0.0
        for index in range(count):
            others = [agreement(spoken[model][index], spoken[other][index]) for other in models if other != model]
            total += sum(others) / len(others)
        out[model] = total / count if count else 0.0
    return out


def choose(scores: dict[str, float], speeds: dict[str, float], fastest_needed: float = 2.0, close: float = 0.03) -> str:
    """The best-scoring model that keeps up with real time; among models that
    score about the same, the fastest."""
    able = {model: value for model, value in scores.items() if speeds.get(model, 0.0) >= fastest_needed} or scores
    best = max(able.values())
    near = [model for model, value in able.items() if value >= best - close]
    return max(near, key=lambda model: speeds.get(model, 0.0))


def hardest(clips: list[dict], heard_nothing: set[int], most: int = 24, total_seconds: float = 420.0) -> list[dict]:
    """The recordings to test on: the ones the current model got nothing from,
    then the quietest, at least three seconds long, up to a few minutes in all.
    Each clip needs "id", "seconds" and "loudness"."""
    usable = [clip for clip in clips if clip["seconds"] >= 3 and clip["loudness"] > 0.0004]
    usable.sort(key=lambda clip: (clip["id"] not in heard_nothing, clip["loudness"]))
    picked, spent = [], 0.0
    for clip in usable:
        if len(picked) >= most or spent + clip["seconds"] > total_seconds:
            continue
        picked.append(clip)
        spent += clip["seconds"]
    return picked
