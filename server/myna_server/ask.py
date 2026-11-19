"""The server's Ask tab: answer a question from everything saved here, and
from the web when the saved data doesn't cover it."""

from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Callable

from .store import Store

_STOP = {
    "the", "and", "for", "that", "this", "with", "what", "when", "where", "which", "who", "how", "did", "does", "have",
    "has", "was", "were", "are", "you", "your", "about", "from", "they", "them", "there", "been", "would", "could",
    "should", "tell", "say", "said", "any", "some", "into", "last", "just", "can", "will", "not", "but", "his", "her",
}

INSTRUCTIONS = (
    "You are Myna, the user's personal assistant and memory, answering on their home computer. You are given "
    "pieces of what they have said and saved, and the conversation so far. Answer the question that was asked, "
    "plainly and briefly. Use the saved material when it is relevant; never recite unrelated material. For "
    "anything about the world that the material doesn't cover (news, facts, people, places, prices, weather, "
    "how-to), ask for a web search instead of guessing. Never invent facts about the user's life. Reply with "
    'one JSON object and nothing else: {"reply": "your answer", "search": "a web search query, or empty"}. '
    "If you set search, leave reply empty; you will be asked again with the results."
)


def _when(seconds) -> str:
    try:
        return datetime.fromtimestamp(float(seconds)).strftime("%a %d %b %H:%M")
    except (TypeError, ValueError, OverflowError, OSError):
        return ""


def gather(store: Store, question: str, wide: bool = False) -> str:
    """The saved material most likely to matter for `question`. `wide` takes
    several times as much, for a helper model to sift."""
    scale = 4 if wide else 1
    words = [w for w in re.findall(r"[a-z0-9']{3,}", question.lower()) if w not in _STOP][:8]
    parts: list[str] = []

    kept = [m for m in store.browse("memory", limit=200) if not m.get("archived") and m.get("content")]
    confirmed = [m["content"] for m in kept if m.get("pinned")]
    others = [m["content"] for m in kept if not m.get("pinned")]
    if confirmed:
        parts.append("CONFIRMED BY THE USER (trust these):\n" + "\n".join(f"- {m}" for m in confirmed[:40]))
    if others:
        parts.append("WHAT YOU KNOW ABOUT THE USER:\n" + "\n".join(f"- {m}" for m in others[:25]))

    seen: set[str] = set()
    matched: list[str] = []
    for word in words:
        for row in store.browse("utterance", word, limit=8 * scale):
            if row["id"] not in seen:
                seen.add(row["id"])
                matched.append(f"[{_when(row['at'])}] {row.get('text', '')}")
        for row in store.browse("note", word, limit=3 * scale):
            if row["id"] not in seen:
                seen.add(row["id"])
                matched.append(f"[note, {_when(row['at'])}] {row.get('title', '')}: {row.get('overview', '')}")
    if matched:
        parts.append("FROM THE USER'S TRANSCRIPT AND NOTES (matching the question):\n" + "\n".join(matched[: 40 * scale]))

    # Conversations as written up: what was decided, to do, and remembered.
    talks = []
    for word in words:
        for row in store.browse("conversation", word, limit=3 * scale):
            if row["id"] not in seen and not row.get("discarded"):
                seen.add(row["id"])
                todo = "; ".join(item.get("description", "") for item in row.get("actionItems") or [])
                talks.append(f"[conversation, {_when(row['at'])}] {row.get('title', '')}: {row.get('overview', '')}"
                             + (f" To do: {todo}." if todo else ""))
    if talks:
        parts.append("CONVERSATIONS (matching the question):\n" + "\n".join(talks[: 10 * scale]))
    # Suggested but not yet confirmed; kept ones are memories above, rejected ones are never used.
    learned = [m.get("content", "") for row in store.browse("conversation", limit=60)
               for m in row.get("memories") or [] if isinstance(m, dict) and not m.get("status")]
    if learned:
        parts.append("NOTICED IN CONVERSATIONS, NOT YET CONFIRMED (may be wrong):\n"
                     + "\n".join(f"- {m}" for m in learned[:30] if m))

    recent = store.browse("utterance", limit=25 * scale)
    if recent:
        lines = [f"[{_when(row['at'])}] {row.get('text', '')}" for row in reversed(recent)]
        parts.append("THE MOST RECENT THINGS HEARD:\n" + "\n".join(lines))

    open_items = [i for i in store.browse("item", limit=60) if not i.get("isDone")]
    if open_items:
        parts.append("OPEN LIST ITEMS:\n" + "\n".join(f"- ({i.get('kind', '')}) {i.get('text', '')}" for i in open_items[:30]))
    return "\n\n".join(parts)[: 9000 * scale]


def _parse(raw: str) -> tuple[str, str]:
    start, end = raw.find("{"), raw.rfind("}")
    if start >= 0 and end > start:
        try:
            data = json.loads(raw[start : end + 1])
            return str(data.get("reply") or "").strip(), str(data.get("search") or "").strip()
        except (json.JSONDecodeError, AttributeError):
            pass
    return raw.strip(), ""


PICK = (
    "You are preparing material for another assistant. Below is saved material about a person and a question "
    "they asked. Copy out, word for word, only the lines that help answer the question, keeping their times. "
    "If nothing helps, reply with the single word NONE. Add nothing of your own."
)


def answer(
    store: Store,
    generate: Callable[[str, str, int], str],
    lookup: Callable[[str], str],
    question: str,
    history: list[dict],
    pick: Callable[[str, str, int], str] | None = None,
    embed: Callable[[list[str]], list[list[float]]] | None = None,
) -> dict:
    """One turn: the reply, and the web search made for it (if any). When a
    helper model is given as `pick`, it reads a much larger slice of the saved
    material first and hands the main model only what bears on the question."""
    now = datetime.now().strftime("%A %d %B %Y, %H:%M")
    material = gather(store, question)
    if embed is not None:
        # Records close in meaning to the question, even without shared words.
        try:
            from .meaning import related, text_of

            close = related(store, embed, question)
            if close:
                lines = [f"[{row['kind']}, {_when(row.get('startedAt') or row.get('createdAt') or 0)}] {text_of(row)[:500]}"
                         for row in close]
                material = "RELATED BY MEANING:\n" + "\n".join(lines) + "\n\n" + material
        except Exception:
            pass  # search by meaning is a bonus; the keyword material still goes
    if pick is not None:
        try:
            wide = gather(store, question, wide=True)
            chosen = pick(PICK, f"{wide}\n\nQUESTION: {question}", 900).strip()
            if chosen and chosen.upper() != "NONE":
                material = "PICKED OUT OF THE USER'S SAVED MATERIAL AS RELEVANT:\n" + chosen
        except Exception:
            pass  # the helper is optional; carry on with the usual material
    earlier = "\n".join(
        f"{'USER' if turn.get('role') == 'me' else 'YOU'}: {str(turn.get('text', ''))[:500]}" for turn in history[-10:]
    )
    base = f"NOW: {now}\n\n{material}\n\n"
    if earlier:
        base += f"EARLIER IN THIS CHAT:\n{earlier}\n\n"
    reply, search = _parse(generate(INSTRUCTIONS, base + f'THE USER ASKS: "{question}"\n\nJSON:', 700))
    searched = ""
    if search:
        searched = search
        found = lookup(search) or "Nothing useful was found."
        prompt = base + f'WEB RESULTS for "{search}":\n{found}\n\nTHE USER ASKS: "{question}"\n\nAnswer now from these results. JSON:'
        reply, _ = _parse(generate(INSTRUCTIONS, prompt, 700))
    return {"reply": reply or "I don't have an answer for that.", "searched": searched}
