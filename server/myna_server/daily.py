"""The end-of-day summary: what happened, where and when, the conversations,
and what is left to do. Written from everything the phone saved that day.

A long day is too much for one pass, so it is read in stretches first (by the
small helper model when one is chosen, otherwise by the summary model itself),
and the summary is then written from those condensed stretches."""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Callable

from .store import Store

Generate = Callable[[str, str, int], str]

CONDENSE = (
    "You are condensing one stretch of a person's day, from a transcript of what was heard around them. "
    "Write a few plain sentences: what was going on, who was involved, what was decided or promised, and any "
    "facts worth keeping (names, times, places, numbers). Leave out filler, and anything marked as media "
    "(audiobook, music, tv, podcast) except to note that it was playing. Do not invent anything."
)

WRITE = (
    "You are the user's secretary writing their end-of-day summary from your notes on the day. Write it in "
    "plain language, in these sections, leaving out a section that has nothing in it:\n"
    "The day in brief - three or four sentences.\n"
    "Where and when - the places they were and roughly when, in order.\n"
    "Conversations - each one: when, who with if known, what it was about, what came of it.\n"
    "Photos and screenshots - what they show or say, if any are listed.\n"
    "Music heard - if any.\n"
    "To follow up - promises made, things to do, open questions.\n"
    "Use only what is in the notes. Do not invent anything. No preamble."
)


def _clock(seconds) -> str:
    try:
        return datetime.fromtimestamp(float(seconds)).strftime("%H:%M")
    except (TypeError, ValueError, OverflowError, OSError):
        return ""


def day_bounds(day: str) -> tuple[float, float]:
    start = datetime.strptime(day, "%Y-%m-%d")
    return start.timestamp(), (start + timedelta(days=1)).timestamp()


def gather(store: Store, day: str) -> dict:
    """Everything saved for `day` (YYYY-MM-DD), oldest first."""
    start, end = day_bounds(day)

    def within(kind: str, limit: int = 5000) -> list[dict]:
        rows = [row for row in store.browse(kind, limit=limit, before=end) if row["at"] >= start]
        return list(reversed(rows))

    return {
        "lines": within("utterance"),
        "notes": within("note", 200),
        "talks": [talk for talk in within("conversation", 300) if not talk.get("discarded")],
        "songs": within("song", 200),
        "items": within("item", 300),
    }


def stretches(lines: list[dict], size: int = 6000) -> list[str]:
    """The day's transcript cut into pieces a model can read in one go."""
    names: dict[str, str] = {}
    pieces: list[str] = []
    current = ""
    for line in lines:
        kind = line.get("context") or ""
        tag = f" ({kind})" if kind and kind != "conversation" else ""
        who = line.get("speakerName") or names.get(line.get("speaker", ""), "")
        text = f"[{_clock(line['at'])}]{tag} {who + ': ' if who else ''}{line.get('text', '')}\n"
        if current and len(current) + len(text) > size:
            pieces.append(current)
            current = ""
        current += text
    if current:
        pieces.append(current)
    return pieces


def summarize(store: Store, day: str, condense: Generate, write: Generate, progress=lambda text: None) -> str:
    """Write the summary for `day` and return it. Empty if nothing was saved."""
    material = gather(store, day)
    if not material["lines"] and not material["notes"] and not material["talks"]:
        return ""
    parts: list[str] = []
    pieces = stretches(material["lines"])
    for index, piece in enumerate(pieces):
        progress(f"Reading the day ({index + 1} of {len(pieces)})…")
        first = piece.split("]", 1)[0].lstrip("[")
        parts.append(f"From {first}: " + condense(CONDENSE, piece, 350).strip())

    notes = []
    for note in material["notes"]:
        place = f" at {note.get('placeName')}" if note.get("placeName") else ""
        people = f" with {', '.join(note.get('people') or [])}" if note.get("people") else ""
        notes.append(f"- {_clock(note['at'])}{place}{people}: {note.get('title', '')}. {note.get('overview', '')}")
        for task in note.get("actionItems") or []:
            if isinstance(task, dict) and task.get("task"):
                notes.append(f"    to do: {task['task']}")
        if note.get("photoText"):
            notes.append(f"    photos taken then say: {str(note['photoText'])[:400]}")
    for talk in material["talks"]:
        notes.append(f"- {_clock(talk['at'])}: {talk.get('title', '')}. {talk.get('overview', '')}")
        for task in talk.get("actionItems") or []:
            if task.get("description"):
                notes.append(f"    to do: {task['description']}")
        for memory in talk.get("memories") or []:
            notes.append(f"    learned: {memory.get('content', '')}")
    places = sorted({(note.get("placeName"), _clock(note["at"])) for note in material["notes"] if note.get("placeName")},
                    key=lambda pair: pair[1])

    prompt = f"DAY: {datetime.strptime(day, '%Y-%m-%d').strftime('%A %d %B %Y')}\n\n"
    if parts:
        prompt += "WHAT WAS HEARD, IN ORDER:\n" + "\n".join(parts) + "\n\n"
    if notes:
        prompt += "CONVERSATIONS WRITTEN UP:\n" + "\n".join(notes) + "\n\n"
    if places:
        prompt += "PLACES: " + "; ".join(f"{name} around {when}" for name, when in places) + "\n\n"
    if material["songs"]:
        prompt += "MUSIC HEARD: " + "; ".join(f"{s.get('title')} - {s.get('artist')}" for s in material["songs"]) + "\n\n"
    added = [item for item in material["items"] if item.get("text")]
    if added:
        prompt += "ADDED TO LISTS: " + "; ".join(f"{i.get('text')}{' (done)' if i.get('isDone') else ''}" for i in added[:40]) + "\n\n"
    progress("Writing the summary…")
    return write(WRITE, prompt[:24000] + "Write the summary now.", 1400).strip()
