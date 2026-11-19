"""Models working together, and learning from use.

Two different recognizers hear every clip. Where they agree, that is the
transcript. Where one hears speech the other missed, the speech is kept. Where
they disagree, a writing model that knows the wearer's own words (names,
places, terms it has seen before) reconciles them into one transcript.

Nothing here retrains a model. What grows with use is what the server knows:
which recognizer has been closer to the agreed transcript on this person's
audio (so it is trusted more), and the wearer's own vocabulary, which is
handed to the recognizers and to the model that reconciles them."""

from __future__ import annotations

import json
import re
import threading
from collections import Counter
from pathlib import Path
from typing import Callable

from .store import Store
from .tuner import agreement, words

Generate = Callable[[str, str, int], str]

RECONCILE = (
    "Several speech recognizers transcribed the same short recording and disagree in places. Your job is to "
    "check sentence structure and sense: write the single most likely transcript of what was actually said, as "
    "words a person would really say. Rules: use only words that appear in at least one of the versions (you may "
    "fix spelling to match the known words list); where most versions agree, keep that; where they differ, choose "
    "the reading that forms a sensible sentence and matches the known words; keep the speaker's own wording, even "
    "if informal or ungrammatical; never add commentary, never summarise, never answer what was said. If no "
    "version is plausible speech, reply with the single word NONE. Reply with the transcript only. /no_think"
)

# Stock phrases a recognizer makes up from noise; never taken from one model alone.
_INVENTED = {"thank you", "thanks", "thanks for watching", "thank you for watching", "you", "bye", "okay", "so", ""}
# Fillers a recognizer often "hears" in background noise. Kept when another
# recognizer hears them too, or when they come with other words, but never on
# the word of one recognizer alone.
_FILLERS = {"yeah", "yes", "yep", "yup", "yeah yeah", "uh", "um", "uh huh", "mm", "mhm", "mm hmm", "hmm", "oh", "ah",
            "no", "okay", "ok", "right", "so", "and", "the", "i"}


def _bare(text: str) -> str:
    return re.sub(r"[^a-z' ]", "", text.lower()).strip()


def default_partner(primary: str) -> str:
    """A second recognizer of a different kind from the first, on the other
    processor: a Whisper on the graphics card pairs with Parakeet on the CPU."""
    return "turbo" if primary.startswith("sherpa:") else "sherpa:parakeet-v2"


# Recognizers that fail in different ways, in the order they join the panel.
PANEL = ("turbo", "sherpa:parakeet-v2", "sherpa:canary", "distil-large-v3", "sherpa:parakeet-v3")


def panel(primary: str, count: int, first_partner: str = "", picked: list[str] | None = None) -> list[str]:
    """The other recognizers to run beside `primary`, `count` in all counting it.
    `picked` (chosen by hand) replaces the automatic list and is used as given,
    however many. The automatic list keeps to two Whisper models in all."""
    if picked:
        return [model for model in dict.fromkeys(picked) if model and model != primary]
    chosen: list[str] = []
    for model in list(picked or []) or ([first_partner] if first_partner else []) + list(PANEL):
        if len(chosen) >= max(0, min(count, 4) - 1):
            break
        whisper_count = sum(not m.startswith("sherpa:") for m in chosen + [primary])
        if model and model != primary and model not in chosen and (model.startswith("sherpa:") or whisper_count < 2):
            chosen.append(model)
    return chosen


class Learning:
    """What has been learned from use, kept between runs."""

    def __init__(self, path: Path | None) -> None:
        self._path = path
        self._lock = threading.Lock()
        self.trust: dict[str, float] = {}    # model -> how close it runs to the agreed transcript (0..1)
        self.heard: dict[str, int] = {}      # model -> clips it has been judged on
        self.reconciled = 0                  # clips where the models disagreed and were reconciled
        self.rescued = 0                     # clips where one model caught speech the other missed
        self.phantoms: dict[str, int] = {}   # model -> lone fillers it "heard" in noise
        if path is not None and path.exists():
            try:
                saved = json.loads(path.read_text(encoding="utf-8"))
                self.trust = {k: float(v) for k, v in saved.get("trust", {}).items()}
                self.heard = {k: int(v) for k, v in saved.get("heard", {}).items()}
                self.reconciled = int(saved.get("reconciled", 0))
                self.rescued = int(saved.get("rescued", 0))
                self.phantoms = {k: int(v) for k, v in saved.get("phantoms", {}).items()}
            except (json.JSONDecodeError, ValueError, TypeError):
                pass

    def phantom(self, model: str) -> None:
        """A recognizer heard words in what was most likely noise."""
        with self._lock:
            self.phantoms[model] = self.phantoms.get(model, 0) + 1

    def note(self, candidates: dict[str, str], final: str) -> None:
        """Move each model's trust a little toward how well it matched the final text."""
        target = words(final)
        with self._lock:
            for model, text in candidates.items():
                score = agreement(words(text), target)
                seen = self.heard.get(model, 0)
                rate = max(0.02, 1 / (seen + 1))   # quick at first, steady later
                self.trust[model] = self.trust.get(model, score) * (1 - rate) + score * rate
                self.heard[model] = seen + 1

    def save(self) -> None:
        if self._path is None:
            return
        with self._lock:
            data = {"trust": self.trust, "heard": self.heard, "reconciled": self.reconciled, "rescued": self.rescued,
                    "phantoms": self.phantoms}
        try:
            self._path.write_text(json.dumps(data, indent=2), encoding="utf-8")
        except OSError:
            pass


def vocabulary(store: Store, most: int = 60) -> list[str]:
    """The wearer's own words: people they have named, and capitalised words
    that keep coming up in their notes, conversations and memories."""
    out: list[str] = []
    for person in store.browse("person", limit=500):
        name = str(person.get("name") or "").strip()
        if name and not name.lower().startswith("speaker "):
            out.append(name)
    counts: Counter[str] = Counter()
    texts: list[str] = [str(m.get("content") or "") for m in store.browse("memory", limit=300)]
    for row in store.browse("conversation", limit=200):
        texts.append(f"{row.get('title', '')}. {row.get('overview', '')}")
        texts += [str(m.get("content") or "") for m in row.get("memories") or []]
    for row in store.browse("note", limit=200):
        texts.append(f"{row.get('title', '')}. {row.get('overview', '')}")
        texts += [str(name) for name in row.get("people") or []]
    for text in texts:
        # A capitalised word that isn't just the start of a sentence.
        for match in re.finditer(r"(?<![.!?]\s)(?<!^)\b([A-Z][a-zA-Z'\-]{2,})\b", text):
            counts[match.group(1)] += 1
    for word, count in counts.most_common(most * 2):
        if count >= 2 and word not in out:
            out.append(word)
    return out[:most]


def combine(candidates: dict[str, str], learning: Learning, reconcile: Generate | None,
            known_words: list[str]) -> tuple[str, str]:
    """One transcript from several recognizers' versions of the same clip.
    Returns the text and how it was reached: "agreed", "rescued", "reconciled",
    "trusted" or "single"."""
    spoken = {model: text.strip() for model, text in candidates.items()}
    if len(spoken) < 2:
        return next(iter(spoken.values()), ""), "single"
    models = list(spoken)
    texts = [spoken[model] for model in models]
    real = [text for text in texts if re.sub(r"[^a-z' ]", "", text.lower()).strip() not in _INVENTED]

    def most_trusted(options: list[str]) -> str:
        return max(options, key=lambda text: max(learning.trust.get(m, 0.5) for m in models if spoken[m] == text))

    if not real:
        return "", "agreed"                       # nobody heard real speech
    if len(real) == 1:
        if _bare(real[0]) in _FILLERS:
            # Only one recognizer "heard" a lone filler like "Yeah": almost
            # always noise. It also counts against that recognizer's trust.
            learning.phantom(next(m for m in models if spoken[m] == real[0]))
            return "", "filler"
        learning.rescued += 1                     # one caught what the others missed
        return real[0], "rescued"
    lowest = min(agreement(words(a), words(b)) for i, a in enumerate(real) for b in real[i + 1:])
    if lowest >= 0.9:
        return most_trusted(real), "agreed"

    def central() -> str:
        """The version closest to all the others (the consensus), weighted by trust."""
        def pull(text: str) -> float:
            owner_trust = max(learning.trust.get(m, 0.5) for m in models if spoken[m] == text)
            others = [agreement(words(text), words(other)) for other in real if other is not text]
            return (sum(others) / len(others) if others else 0.0) + 0.25 * owner_trust
        return max(real, key=pull)
    if reconcile is not None:
        listed = "\n".join(f"Version {index + 1}: {text}" for index, text in enumerate(real))
        known = ("Known words (names and terms this person uses): " + ", ".join(known_words) + "\n\n") if known_words else ""
        try:
            merged = reconcile(RECONCILE, f"{known}{listed}\n\nTranscript:", 400).strip().strip('"')
        except Exception:
            merged = ""
        if merged.upper() == "NONE":
            return "", "reconciled"
        # Accept it only if it is built from what the recognizers heard.
        heard = set(word for text in real for word in words(text)) | set(word.lower() for word in known_words)
        made = words(merged)
        if made and sum(word in heard for word in made) / len(made) >= 0.85 and len(made) <= 1.5 * max(len(words(t)) for t in real):
            learning.reconciled += 1
            return merged, "reconciled"
    return (central(), "consensus") if len(real) >= 3 else (most_trusted(real), "trusted")
