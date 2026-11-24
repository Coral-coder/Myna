"""Myna's receptionist.

After new conversations come in (from Bee or from this phone), Myna reads them
on its own and does what a good assistant would without being asked: it learns
lasting facts about the user, writes down follow-ups they shouldn't drop, drafts
the odd document they'd want (meeting notes, a plan, a summary), and — only when
it genuinely matters — sends them a message. Nothing here needs the user to ask
for it; it runs quietly whenever `reflect()` is called after a sync.

Everything it learns is saved the same way the rest of Myna saves things, so it
shows up on the phone: facts as memories, follow-ups as list items, documents as
notes, and its messages as a new "message" kind the phone turns into a
notification."""

from __future__ import annotations

import json
import time
import uuid
from datetime import datetime
from typing import Callable

from .store import Store

Generate = Callable[[str, str, int], str]

# A deterministic namespace so the same conversation always maps to the same
# follow-up/document ids — re-running a reflection never duplicates them.
_NS = uuid.UUID("c0ffee00-0000-4000-8000-a5ec0ffee000")

INSTRUCTIONS = """You are Lumi, a sharp, warm personal assistant who looks after one person.
You've just read a conversation of theirs. Do what a thoughtful assistant would
do with it — WITHOUT being asked:

1. LEARN: note any lasting fact about the person or their world that's worth
   remembering (a preference, a relationship, a job, an address, a recurring
   plan, a decision). Not small talk, not one-off chatter. Short, plain facts.
2. FOLLOW UP: anything they said they'd do, need to do, or be reminded of —
   turn it into a clear to-do. Include a due date only if one was actually said.
3. DOCUMENT: if this conversation is the kind they'd want written up — a
   meeting with decisions and actions, a plan, a set of instructions, notes
   worth keeping — write that document. Otherwise don't.
4. MESSAGE: decide if you should reach out to them right now. Only if something
   genuinely needs their attention soon (a deadline, a promise they might drop,
   something important they'd thank you for flagging). Most conversations need
   NO message. When in doubt, don't send one.

Reply with ONE JSON object and nothing else:
{
  "remember": ["a lasting fact", "..."],
  "followups": [{"text": "what to do", "due": "YYYY-MM-DD or empty"}],
  "documents": [{"title": "...", "body": "the full document, markdown ok"}],
  "message": {"send": false, "text": "a short, human message to the user, or empty"}
}
Leave any list empty if there's nothing for it. Never invent facts, numbers or
dates that weren't in the conversation."""


def _norm(text: str) -> str:
    return " ".join(str(text or "").lower().split())


def _digest(record: dict, store: Store) -> str:
    """A compact picture of one conversation for the receptionist to read."""
    myna = record.get("myna") or {}
    title = myna.get("title") or record.get("title") or "Conversation"
    overview = myna.get("overview") or record.get("overview") or ""
    when = ""
    try:
        when = datetime.fromtimestamp(float(record.get("startedAt") or record.get("createdAt") or 0)).strftime("%A %d %B, %H:%M")
    except (TypeError, ValueError, OverflowError, OSError):
        pass
    parts = [f"CONVERSATION: {title}", f"WHEN: {when}", f"SUMMARY: {overview}"]
    points = myna.get("keyPoints") or record.get("keyPoints") or []
    if points:
        parts.append("KEY POINTS:\n" + "\n".join(f"- {p}" for p in points[:12]))
    # The transcript itself — this is where the exact words (names, numbers) live.
    transcript = record.get("transcript")
    if not transcript:
        bee_id = record.get("beeId") or record.get("id")
        lines = sorted((u for u in store.browse("utterance", limit=4000) if u.get("beeId") == bee_id),
                       key=lambda u: u.get("at", 0.0))
        transcript = "\n".join(f'{u.get("speakerName") or ""}: {u.get("text", "")}'.strip(": ") for u in lines)
    if transcript:
        parts.append("TRANSCRIPT:\n" + str(transcript)[:5000])
    return "\n\n".join(parts)


def _parse(raw: str) -> dict:
    start, end = raw.find("{"), raw.rfind("}")
    if start >= 0 and end > start:
        try:
            data = json.loads(raw[start:end + 1])
            if isinstance(data, dict):
                return data
        except (json.JSONDecodeError, ValueError):
            pass
    return {}


def _learn(store: Store, facts: list, known: set[str]) -> int:
    saved = 0
    for fact in facts:
        text = fact.get("content") if isinstance(fact, dict) else fact
        text = str(text or "").strip()
        if len(text) < 4 or _norm(text) in known:
            continue
        known.add(_norm(text))
        mid = str(uuid.uuid4()).upper()
        store.sync(0, [{"kind": "memory", "id": mid, "updated_at": time.time(), "deleted": False, "data": {
            # Not pinned: Myna worked it out, the user hasn't confirmed it — it's
            # "known" and usable, but shown as unconfirmed, not asserted as fact.
            "createdAt": time.time(), "category": "system", "content": text,
            "sourceNoteID": "", "pinned": False, "archived": False, "manuallyAdded": False,
        }}])
        saved += 1
    return saved


def _follow_up(store: Store, items: list, conv_id: str, open_items: set[str]) -> int:
    saved = 0
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            item = {"text": item}
        text = str(item.get("text") or "").strip()
        if len(text) < 3 or _norm(text) in open_items:
            continue
        open_items.add(_norm(text))
        due = 0.0
        raw_due = str(item.get("due") or "").strip()
        if raw_due:
            try:
                due = datetime.strptime(raw_due[:10], "%Y-%m-%d").timestamp()
            except ValueError:
                due = 0.0
        iid = str(uuid.uuid5(_NS, f"todo:{conv_id}:{_norm(text)}")).upper()
        store.sync(0, [{"kind": "item", "id": iid, "updated_at": time.time(), "deleted": False, "data": {
            "kind": "todo", "text": text, "detail": "", "dueDate": due or None, "isDone": False,
            "createdAt": time.time(), "completedAt": None, "source": "myna", "noteID": "",
        }}])
        saved += 1
    return saved


def _document(store: Store, docs: list, conv_id: str) -> int:
    saved = 0
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        title = str(doc.get("title") or "").strip()
        body = str(doc.get("body") or "").strip()
        if len(body) < 40:
            continue
        nid = str(uuid.uuid5(_NS, f"doc:{conv_id}:{_norm(title)}")).upper()
        now = time.time()
        store.sync(0, [{"kind": "note", "id": nid, "updated_at": now, "deleted": False, "data": {
            "createdAt": now, "startedAt": now, "endedAt": now, "title": title or "Document",
            "overview": body[:200], "detailedNotes": body, "keyPoints": [], "decisions": [],
            "actionItems": [], "detectedEvents": [], "followUps": [], "transcript": "",
            "modelName": "Lumi", "sourceRef": "reception", "placeName": "", "people": [],
        }}])
        saved += 1
    return saved


def send_message(store: Store, text: str, topic: str = "", source: str = "reception") -> str:
    """Queue a message from Myna to the user. The phone shows it as a
    notification the next time it syncs. Returns the message id."""
    text = str(text or "").strip()
    if not text:
        return ""
    mid = str(uuid.uuid4()).upper()
    store.sync(0, [{"kind": "message", "id": mid, "updated_at": time.time(), "deleted": False, "data": {
        "createdAt": time.time(), "text": text, "topic": topic, "source": source, "seen": False,
    }}])
    return mid


def remind_due(store: Store, within_hours: float = 24.0) -> int:
    """Message the user about to-dos coming due (or overdue) that haven't been
    flagged yet. Cheap and deterministic — no model needed — so it's safe to
    run on every sync. Each item is only ever reminded once."""
    reminded = set(filter(None, store.get_meta("reminded_items", "").split(",")))
    horizon = time.time() + within_hours * 3600
    sent = 0
    changed = False
    for item in store.browse("item", limit=300):
        if item.get("isDone") or item["id"] in reminded:
            continue
        due = item.get("dueDate")
        if not isinstance(due, (int, float)) or due <= 0 or due > horizon:
            continue
        when = datetime.fromtimestamp(due)
        overdue = due < time.time()
        text = item.get("text") or "a to-do"
        if overdue:
            msg = f"Heads up — \"{text}\" was due {when.strftime('%A')}. Want me to help with it?"
        else:
            # %-I/%p aren't portable (Windows), so format the hour by hand.
            hour = when.hour % 12 or 12
            ampm = "am" if when.hour < 12 else "pm"
            clock = f"{hour}{ampm}" if when.minute == 0 else f"{hour}:{when.minute:02d}{ampm}"
            msg = f"Reminder: \"{text}\" is due {when.strftime('%A')} at {clock}."
        if send_message(store, msg, topic="reminder", source="reminder"):
            reminded.add(item["id"])
            changed = True
            sent += 1
    if changed:
        store.set_meta("reminded_items", ",".join(sorted(reminded))[:20000])
    return sent


def reflect(store: Store, generate: Generate, most: int = 4) -> dict:
    """Read conversations newer than last time and act on them. Safe to call
    after every sync; it only looks at what it hasn't seen yet."""
    since = float(store.get_meta("reception_at", "0") or "0")
    fresh = [row for row in store.browse("conversation", limit=200)
             if not row.get("discarded") and not row.get("failed") and float(row.get("at") or 0) > since]
    fresh.sort(key=lambda row: float(row.get("at") or 0))
    fresh = fresh[:most]
    # Due-item reminders run regardless of whether there are new conversations.
    due_messages = remind_due(store)
    if not fresh:
        return {"conversations": 0, "learned": 0, "followups": 0, "documents": 0, "messages": due_messages}

    known = {_norm(m.get("content", "")) for m in store.browse("memory", limit=400) if m.get("content")}
    open_items = {_norm(i.get("text", "")) for i in store.browse("item", limit=200) if not i.get("isDone")}
    totals = {"conversations": 0, "learned": 0, "followups": 0, "documents": 0, "messages": due_messages}
    high = since
    for record in fresh:
        high = max(high, float(record.get("at") or 0))
        try:
            result = _parse(generate(INSTRUCTIONS, _digest(record, store), 1400))
        except Exception:
            continue
        totals["conversations"] += 1
        totals["learned"] += _learn(store, result.get("remember") or [], known)
        totals["followups"] += _follow_up(store, result.get("followups") or [], record["id"], open_items)
        totals["documents"] += _document(store, result.get("documents") or [], record["id"])
        message = result.get("message") or {}
        if isinstance(message, dict) and message.get("send") and str(message.get("text") or "").strip():
            if send_message(store, message["text"], topic=record.get("title", ""), source="reception"):
                totals["messages"] += 1
    store.set_meta("reception_at", repr(high))
    return totals
