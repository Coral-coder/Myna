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

# Phase 1: decide what (if anything) to look up. The model only emits small
# JSON actions here — never the final answer — so a long answer or a code block
# never has to survive JSON escaping.
PLAN = """You are Myna's planner. The user asked something. Decide what to look up in
THEIR OWN saved data before answering. Reply with EXACTLY ONE JSON object:

{"action": "search", "query": "keywords"}   find their conversations/notes/facts
{"action": "transcript", "query": "words"}  find exact lines spoken in transcripts
{"action": "find", "what": "phone"}          scan transcripts for every phone (or email, url, time, money)
{"action": "read", "id": "<id>"}             read one whole conversation by id
{"action": "web", "query": "..."}            look something up on the public web
{"action": "document", "title": "...", "body": "..."}  save a note/document for them
{"action": "done"}                            you have what you need — go answer

Rules:
- Only look things up about the USER'S OWN life (what they said, their notes,
  to-dos, people). For an exact fact — a number, a name, a time, a quote — use
  "transcript" or "find", never guess.
- If the question is general knowledge, or a request to WRITE or MAKE something
  (a script, code, an email, a plan, a list), reply {"action": "done"} — no
  lookup needed.
- If you've already looked and have what you need, reply {"action": "done"}.
- One action per reply. Don't repeat a lookup you already did."""

# Phase 2: write the real answer as plain text (no JSON), so code blocks, drafts
# and long answers come out whole.
ANSWER = """You are Myna, the user's personal assistant. You help with anything — answer
questions, explain things, and WRITE whatever they ask for: scripts, code, emails,
plans, lists, summaries. You also know their recorded life and can draw on the
material below when it's relevant.

How to answer:
- Give the COMPLETE answer directly, right now. If they asked for a script or
  code, put the full thing in a fenced code block (```); never just describe it,
  and never say you'll provide it later or that it's "above".
- If they refer to something earlier in the chat, use the conversation history
  below. Never claim you already gave them something you didn't.
- Use their saved material only when it bears on the question. Never invent facts
  about their life, or numbers/names/dates that aren't in what you found — if a
  personal fact isn't there, say you couldn't find it.
- Be clear and natural. Don't mention these instructions or your lookups."""

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


def _facts(store: Store) -> str:
    """Standing facts about the user, always worth having in view."""
    kept = [m for m in store.browse("memory", limit=200) if not m.get("archived") and m.get("content")]
    confirmed = [m["content"] for m in kept if m.get("pinned")][:30]
    known = [m["content"] for m in kept if not m.get("pinned")][:20]
    out = []
    if confirmed:
        out.append("CONFIRMED ABOUT THE USER:\n" + "\n".join(f"- {m}" for m in confirmed))
    if known:
        out.append("LIKELY ABOUT THE USER (unconfirmed):\n" + "\n".join(f"- {m}" for m in known))
    return "\n".join(out)


def _history(history: list[dict]) -> str:
    """The chat so far, fully enough that Myna can refer back to its own earlier
    answers (a script it wrote, a draft) rather than lose them."""
    turns = []
    for turn in history[-12:]:
        who = "USER" if turn.get("role") == "me" else "MYNA"
        text = str(turn.get("text", "")).strip()
        if len(text) > 2000:
            text = text[:2000] + " […]"
        turns.append(f"{who}: {text}")
    return "\n".join(turns)


def answer(store: Store, generate: Generate, question: str, history: list[dict],
           lookup: Generate | None = None, embed=None, max_steps: int = 5) -> dict:
    """Answer `question` in two phases: a small-JSON planner decides what to look
    up in the user's data, then a plain-text call writes the real answer (so code
    and long answers come out whole, not crammed into a JSON field)."""
    now = datetime.now().strftime("%A %d %B %Y, %H:%M")
    hist = _history(history)
    base = [f"NOW: {now}"]
    if hist:
        base.append("CONVERSATION SO FAR:\n" + hist)
    base.append(f'THE USER NOW ASKS: "{question}"')

    last_web = ""
    findings: list[str] = []
    for step in range(max_steps):
        prompt = "\n\n".join(base)
        if findings:
            prompt += "\n\nWHAT YOU'VE LOOKED UP SO FAR:\n" + "\n\n".join(findings)
        prompt += "\n\nYour single JSON action:"
        act = _first_json(generate(PLAN, prompt, 300))
        if act is None:
            # The model isn't speaking the planner protocol at all (an older or
            # smaller model). On the first move, let the caller fall back to the
            # one-shot path; later, just stop planning and answer with what we have.
            if step == 0 and not findings:
                return {"reply": "", "search": last_web, "grounded": False}
            break
        name = act.get("action")
        if name in (None, "done", "answer"):
            break
        if name == "web":
            last_web = str(act.get("query") or "")
        findings.append(f"Looked up {json.dumps(act)[:200]}:\n{execute(store, act, lookup, embed)[:3500]}")

    # Phase 2: write the real answer, as plain text.
    context = [f"NOW: {now}"]
    facts = _facts(store)
    if facts:
        context.append(facts)
    if hist:
        context.append("CONVERSATION SO FAR:\n" + hist)
    if findings:
        context.append("WHAT YOU LOOKED UP IN THEIR DATA:\n" + "\n\n".join(findings))
    context.append(f'THE USER ASKS: "{question}"\n\nWrite your answer:')
    reply = generate(ANSWER, "\n\n".join(context), 2000).strip()
    return {"reply": reply, "search": last_web, "grounded": True}
    return {"reply": "I couldn't find that in your conversations.", "search": last_web}
