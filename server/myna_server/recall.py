"""Answering questions by actually searching the user's conversations.

Instead of handing the model one fixed blob and hoping the answer is in it,
the model works in a loop: it asks to search, read a transcript, scan for a
phone number, look something up on the web, or save a document, sees the
result, and keeps going until it can answer. This is what lets "what's the
number she gave me?" actually find the number in the transcript."""

from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Callable

from .store import Store

Generate = Callable[[str, str, int], str]

TOOLS = """You are Myna. You answer the user's questions about their own life from
their recorded conversations, notes and lists. You can look things up before
answering. Reply with EXACTLY ONE JSON object and nothing else — one of:

{"action": "search", "query": "keywords"}
    Find conversations and notes about something. Returns their ids and gists.
{"action": "transcript", "query": "keywords"}
    Find the exact spoken lines in the transcripts. Use this for quotes, names,
    numbers, decisions — anything said word for word.
{"action": "find", "what": "phone"}
    Scan the transcripts for every phone number (or "email", "url", "time",
    "money"), each with the line it was said in.
{"action": "read", "id": "<id>"}
    Read one whole conversation (its summary and full transcript) by id.
{"action": "web", "query": "..."}
    Look something up on the public web (weather, facts) — NOT personal info.
{"action": "document", "title": "...", "body": "..."}
    Save a document/note for the user (e.g. a summary they asked you to write).
{"action": "answer", "text": "your answer to the user", "search": ""}
    Give the final answer. Put a web query in "search" only if you used the web.

Rules:
- For exact facts (a number, a name, a time, a quote) use "transcript" or
  "find" — never answer such a thing from memory or a gist.
- Keep looking until you have the fact or are sure it isn't there. Try a few
  different searches before giving up.
- NEVER invent a number, name, date or fact. If it isn't in the user's data,
  say you couldn't find it and what you searched.
- Answer in plain language, concise, in the user's own terms."""

_PATTERNS = {
    "phone": r"(?:\+?\d[\d().\-\s]{6,}\d)",
    "email": r"[\w.+-]+@[\w-]+\.[\w.-]+",
    "url": r"(?:https?://\S+|\b[\w-]+\.(?:com|org|net|io|gov|edu|co)\b\S*)",
    "time": r"\b\d{1,2}(?::\d{2})?\s?(?:a\.?m\.?|p\.?m\.?|AM|PM)\b|\b\d{1,2}:\d{2}\b",
    "money": r"[$£€]\s?\d[\d,]*(?:\.\d{2})?|\b\d+\s?(?:dollars|pounds|euros|bucks)\b",
}


def _when(seconds) -> str:
    try:
        return datetime.fromtimestamp(float(seconds)).strftime("%a %d %b %H:%M")
    except (TypeError, ValueError, OverflowError, OSError):
        return ""


def _first_json(text: str) -> dict | None:
    start = text.find("{")
    while start != -1:
        depth = 0
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        obj = json.loads(text[start:i + 1])
                        if isinstance(obj, dict) and "action" in obj:
                            return obj
                    except ValueError:
                        break
        start = text.find("{", start + 1)
    return None


def execute(store: Store, action: dict, lookup: Generate | None = None, embed=None) -> str:
    name = action.get("action")
    if name == "search":
        query = str(action.get("query") or "")
        out: list[str] = []
        # What Myna has learned about the user — the quickest place to find a
        # standing fact (where they live, who someone is, a preference).
        for row in store.browse("memory", query, limit=10):
            if row.get("archived") or not row.get("content"):
                continue
            tag = "fact, confirmed" if row.get("pinned") else "fact"
            out.append(f'[{tag}] {row.get("content")}')
        for kind in ("conversation", "note"):
            for row in store.browse(kind, query, limit=8):
                if row.get("discarded") or row.get("failed"):
                    continue
                gist = (row.get("overview") or row.get("gist") or "")[:200]
                out.append(f'[{kind} id={row.get("id")}] {_when(row.get("at"))} — {row.get("title", "")}: {gist}')
        if not out and embed is not None:
            try:
                from .meaning import related, text_of
                for row in related(store, embed, query):
                    out.append(f'[{row["kind"]} id={row["id"]}] {_when(row.get("at"))} — {text_of(row)[:200]}')
            except Exception:
                pass
        return "\n".join(out[:12]) or "No conversations or notes match that."
    if name == "transcript":
        query = str(action.get("query") or "")
        rows = store.browse("utterance", query, limit=30)
        lines = [f'[{_when(r.get("at"))}] {(r.get("speakerName") or "").strip()}: {r.get("text", "")}'.replace(": :", ":")
                 for r in rows]
        return "\n".join(lines) or "No spoken lines match that."
    if name == "find":
        what = str(action.get("what") or "phone").lower()
        pattern = _PATTERNS.get(what, _PATTERNS["phone"])
        found: list[str] = []
        seen: set[str] = set()
        for r in store.browse("utterance", limit=5000):
            text = r.get("text", "")
            for match in re.findall(pattern, text):
                hit = (match if isinstance(match, str) else match[0]).strip()
                key = re.sub(r"\D", "", hit) if what == "phone" else hit.lower()
                if len(key) < (7 if what == "phone" else 1) or key in seen:
                    continue
                seen.add(key)
                found.append(f'{hit}   — said {_when(r.get("at"))}: "{text[:90]}"')
        return "\n".join(found[:25]) or f"No {what} found anywhere in the transcripts."
    if name == "read":
        rid = str(action.get("id") or "")
        rec = store.get("conversation", rid) or store.get("note", rid)
        if rec is None:
            return "No conversation or note with that id."
        head = f'{rec.get("title", "")}\n{rec.get("overview", "")}\n'
        transcript = rec.get("transcript")
        if not transcript:
            bee_id = rec.get("beeId")
            lines = sorted((u for u in store.browse("utterance", limit=4000) if u.get("beeId") == bee_id),
                           key=lambda u: u.get("at", 0.0))
            transcript = "\n".join(f'{u.get("speakerName") or ""}: {u.get("text", "")}' for u in lines)
        return (head + "\nTRANSCRIPT:\n" + str(transcript))[:6000]
    if name == "web":
        if lookup is None:
            return "The web isn't available."
        try:
            return lookup(str(action.get("query") or ""))[:2000]
        except Exception as error:
            return f"Web lookup failed: {error}"
    if name == "document":
        import time
        import uuid

        title = str(action.get("title") or "Document")
        body = str(action.get("body") or "")
        note_id = str(uuid.uuid4()).upper()
        store.sync(0, [{"kind": "note", "id": note_id, "updated_at": time.time(), "deleted": False, "data": {
            "createdAt": time.time(), "startedAt": time.time(), "endedAt": time.time(),
            "title": title, "overview": body[:200], "detailedNotes": body, "keyPoints": [], "decisions": [],
            "actionItems": [], "detectedEvents": [], "followUps": [], "transcript": "",
            "modelName": "Myna", "sourceRef": "ask", "placeName": "", "people": [],
        }}])
        return f'Saved the document "{title}".'
    return "Unknown action."


def answer(store: Store, generate: Generate, question: str, history: list[dict],
           lookup: Generate | None = None, embed=None, max_steps: int = 6) -> dict:
    """Answer `question` by letting the model search the user's data in a loop."""
    now = datetime.now().strftime("%A %d %B %Y, %H:%M")
    trail: list[str] = [f"NOW: {now}"]
    if history:
        earlier = "\n".join(f"{'USER' if t.get('role') == 'me' else 'YOU'}: {str(t.get('text', ''))[:400]}"
                            for t in history[-8:])
        trail.append("EARLIER IN THIS CHAT:\n" + earlier)
    trail.append(f'THE USER ASKS: "{question}"')

    last_web = ""
    for step in range(max_steps):
        force = step == max_steps - 1
        prompt = "\n\n".join(trail)
        prompt += ('\n\nYou have looked enough. Reply now with an {"action":"answer",...} object.'
                   if force else "\n\nYour single JSON action:")
        raw = generate(TOOLS, prompt, 700)
        act = _first_json(raw)
        if act is None:
            # On the very first move with no action, the model isn't speaking
            # the tool protocol (an older/smaller model). Hand back an empty
            # reply so the caller falls back to the one-shot answer. After a
            # lookup, plain prose is a real answer — keep it.
            if step == 0:
                return {"reply": "", "search": last_web}
            return {"reply": raw.strip(), "search": last_web}
        if act.get("action") == "answer":
            return {"reply": str(act.get("text") or ""), "search": str(act.get("search") or last_web)}
        if act.get("action") == "web":
            last_web = str(act.get("query") or "")
        observation = execute(store, act, lookup, embed)
        trail.append(f"YOU LOOKED UP: {json.dumps(act)[:300]}\nRESULT:\n{observation[:4000]}")
    return {"reply": "I couldn't find that in your conversations.", "search": last_web}
