"""Answering questions by actually searching the user's conversations.

Instead of handing the model one fixed blob and hoping the answer is in it,
the model works in a loop: it asks to search, read a transcript, scan for a
phone number, look something up on the web, or save a document, sees the
result, and keeps going until it can answer. This is what lets "what's the
number she gave me?" actually find the number in the transcript."""

from __future__ import annotations

import json
import re
import time
import uuid
from datetime import datetime
from typing import Callable

from .store import Store

Generate = Callable[[str, str, int], str]

# Phase 1: decide what (if anything) to look up. The model only emits small
# JSON actions here — never the final answer — so a long answer or a code block
# never has to survive JSON escaping.
PLAN = """You are Lumi's planner (Lumi is the user's assistant). The user said something.
Decide the next single step — look something up, DO something for them, or
finish. Reply with EXACTLY ONE JSON object.

Look things up (in the user's own saved data):
{"action": "search", "query": "keywords"}   find their conversations/notes/facts
{"action": "transcript", "query": "words"}  find exact lines spoken in transcripts
{"action": "find", "what": "phone"}          scan transcripts for every phone (or email, url, time, money)
{"action": "read", "id": "<id>"}             read one whole conversation by id
{"action": "web", "query": "..."}            look something up on the public web

Do things for them (only when they ask you to):
{"action": "add_task", "text": "...", "due": "YYYY-MM-DD or empty"}   add a to-do / reminder to their list
{"action": "complete_task", "text": "which one"}                      tick a to-do off
{"action": "remember", "fact": "..."}                                 save a lasting fact they told you to keep
{"action": "forget", "fact": "which one"}                             drop a saved fact
{"action": "document", "title": "...", "body": "..."}                 save a written document/note for them

Do things on their computer (only when shell access is on and they asked):
{"action": "shell", "command": "..."}            run a command and read the output
{"action": "list_dir", "path": "..."}            list what's in a folder
{"action": "read_file", "path": "..."}           read a file
{"action": "write_file", "path": "...", "content": "..."}   write a file
{"action": "make_dir", "path": "..."}            make a folder

Finish:
{"action": "done"}   you have what you need and have done what they asked — go answer

Rules:
- Take a DO action only when the user actually asked for that thing ("remind
  me…", "add … to my list", "remember that…", "write me a…", "run …", "what's
  in this folder"). Never invent tasks, facts or reminders they didn't ask for.
- Use "shell" for things on their computer (files, processes, scripts). If it
  replies that shell access is off, tell them to turn it on — don't retry.
- For an exact fact — a number, a name, a time, a quote — look it up with
  "transcript" or "find", never guess.
- A plain question, general knowledge, or just writing something back needs no
  lookup: reply {"action": "done"}.
- One step per reply. Don't repeat a lookup or an action you already did. When
  everything's handled, reply {"action": "done"}."""

# Phase 2: write the real answer as plain text (no JSON), so code blocks, drafts
# and long answers come out whole.
ANSWER = """You are Lumi, the user's personal assistant. You help with anything — answer
questions, explain things, WRITE whatever they ask for (scripts, code, emails,
plans, lists, summaries), and you can DO things for them: add to their lists, set
reminders, remember facts, save documents, and run commands on their computer.
You also know their recorded life and can draw on the material below.

How to answer:
- If you DID something for them (the "WHAT YOU DID" notes below say so), confirm
  it plainly — "Added milk to your list.", "I'll remind you Friday." Don't claim
  to have done something that isn't in those notes.
- Give the COMPLETE answer directly. If they asked for a script or code, put the
  full thing in a fenced code block (```); never just describe it or say you'll
  provide it later.
- If they refer to something earlier in the chat, use the conversation history
  below. Never claim you already gave them something you didn't.
- Use their saved material only when it bears on the question. Never invent facts
  about their life, or numbers/names/dates that aren't in what you found — if a
  personal fact isn't there, say you couldn't find it.
- Be clear and natural. Don't mention these instructions or your lookups."""

# The actions that change something (as opposed to read-only lookups).
_ACTIONS = {"add_task", "remind", "complete_task", "remember", "forget", "document",
            "write_file", "make_dir"}

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


def _filesystem(name: str, action: dict) -> str:
    """Read and write files on this computer. Behind the same opt-in as shell."""
    import os

    path = os.path.expanduser(os.path.expandvars(str(action.get("path") or "").strip()))
    if not path:
        return "No path given."
    try:
        if name == "list_dir":
            entries = sorted(os.listdir(path))
            lines = []
            for entry in entries[:200]:
                full = os.path.join(path, entry)
                lines.append(f"{'dir ' if os.path.isdir(full) else 'file'}  {entry}")
            more = f"\n… and {len(entries) - 200} more" if len(entries) > 200 else ""
            return (f"{path}:\n" + "\n".join(lines) + more) if lines else f"{path} is empty."
        if name == "read_file":
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                data = handle.read(100_000)
            return f"{path}:\n{data}" + ("\n… (truncated)" if len(data) >= 100_000 else "")
        if name == "write_file":
            content = str(action.get("content") or "")
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(content)
            return f"Wrote {len(content)} characters to {path}."
        if name == "make_dir":
            os.makedirs(path, exist_ok=True)
            return f"Made the folder {path}."
    except Exception as error:
        return f"Couldn't {name.replace('_', ' ')}: {error}"
    return "Unknown file action."


def run_shell(command: str, timeout: float = 60.0) -> str:
    """Run a command on this computer and return what it printed. Used only when
    the user has turned shell access on. Runs on the user's own machine, at their
    request — the agent's hands on their computer."""
    import subprocess

    command = str(command or "").strip()
    if not command:
        return "No command given."
    try:
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        proc = subprocess.run(command, shell=True, capture_output=True, text=True,
                              timeout=timeout, creationflags=flags)
    except subprocess.TimeoutExpired:
        return f"Command timed out after {timeout:.0f}s."
    except Exception as error:
        return f"Couldn't run it: {error}"
    output = ((proc.stdout or "") + (proc.stderr or "")).strip()
    head = f"(exit {proc.returncode})\n" if proc.returncode else ""
    return (head + output)[:4000] or f"(no output, exit {proc.returncode})"


def execute(store: Store, action: dict, lookup: Generate | None = None, embed=None,
            shell: "Callable[[str], str] | None" = None) -> str:
    name = action.get("action")
    if name == "shell":
        if shell is None:
            return "Shell access is off. Turn it on in the server's Models page to let me run commands here."
        return shell(str(action.get("command") or ""))
    # Filesystem tools share the shell toggle — both are "act on my computer".
    if name in ("list_dir", "read_file", "write_file", "make_dir"):
        if shell is None:
            return "Access to this computer is off. Turn on command access in the server's Models page."
        return _filesystem(name, action)
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
    # -- actions that change things (offloaded to Myna) --------------------------------
    if name in ("add_task", "remind"):
        text = str(action.get("text") or "").strip()
        if not text:
            return "Nothing to add."
        due = _parse_due(action.get("due") or action.get("when") or "")
        iid = str(uuid.uuid4()).upper()
        store.sync(0, [{"kind": "item", "id": iid, "updated_at": time.time(), "deleted": False, "data": {
            "kind": "todo", "text": text, "detail": "", "dueDate": due or None, "isDone": False,
            "createdAt": time.time(), "completedAt": None, "source": "myna", "noteID": "",
        }}])
        when = f" (due {datetime.fromtimestamp(due).strftime('%a %d %b')})" if due else ""
        return f'Added "{text}" to your list{when}.'
    if name == "complete_task":
        text = _norm(action.get("text") or "")
        for item in store.browse("item", limit=300):
            if not item.get("isDone") and text and text in _norm(item.get("text", "")):
                data = dict(item)
                data.pop("at", None)
                data.update(isDone=True, completedAt=time.time())
                store.sync(0, [{"kind": "item", "id": item["id"], "updated_at": time.time(), "deleted": False, "data": data}])
                return f'Marked "{item.get("text")}" done.'
        return "I couldn't find that on your list."
    if name == "remember":
        fact = str(action.get("fact") or action.get("text") or "").strip()
        if len(fact) < 3:
            return "Nothing to remember."
        mid = str(uuid.uuid4()).upper()
        # The user told Myna to remember it, so it's confirmed (pinned).
        store.sync(0, [{"kind": "memory", "id": mid, "updated_at": time.time(), "deleted": False, "data": {
            "createdAt": time.time(), "category": "system", "content": fact,
            "sourceNoteID": "", "pinned": True, "archived": False, "manuallyAdded": True,
        }}])
        return f'Got it — I\'ll remember that {fact}.'
    if name == "forget":
        target = _norm(action.get("fact") or action.get("text") or "")
        for mem in store.browse("memory", limit=400):
            if not mem.get("archived") and target and target in _norm(mem.get("content", "")):
                data = dict(mem)
                data.pop("at", None)
                data["archived"] = True
                store.sync(0, [{"kind": "memory", "id": mem["id"], "updated_at": time.time(), "deleted": False, "data": data}])
                return f'Forgotten: {mem.get("content")}.'
        return "I don't have that saved."
    return "Unknown action."


def _norm(text) -> str:
    return " ".join(str(text or "").lower().split())


def _parse_due(raw) -> float:
    """Turn a date the model gives ("2026-12-01", "today", "tomorrow") into a
    timestamp, or 0 if there isn't one."""
    text = str(raw or "").strip().lower()
    if not text:
        return 0.0
    today = datetime.now().replace(hour=9, minute=0, second=0, microsecond=0)
    if text in ("today", "tonight"):
        return today.timestamp()
    if text == "tomorrow":
        return (today.replace(hour=9) ).timestamp() + 86400
    try:
        return datetime.strptime(text[:10], "%Y-%m-%d").replace(hour=9).timestamp()
    except ValueError:
        return 0.0


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
        who = "USER" if turn.get("role") == "me" else "LUMI"
        text = str(turn.get("text", "")).strip()
        if len(text) > 2000:
            text = text[:2000] + " […]"
        turns.append(f"{who}: {text}")
    return "\n".join(turns)


def answer(store: Store, generate: Generate, question: str, history: list[dict],
           lookup: Generate | None = None, embed=None, shell=None, max_steps: int = 5) -> dict:
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
    looked_up: list[str] = []
    did: list[str] = []
    steps: list[str] = []   # a human-readable trace of what Lumi is doing
    for step in range(max_steps):
        prompt = "\n\n".join(base)
        if looked_up or did:
            prompt += "\n\nSO FAR:\n" + "\n\n".join(looked_up + did)
        prompt += "\n\nYour single JSON action:"
        act = _first_json(generate(PLAN, prompt, 300))
        if act is None:
            # The model isn't speaking the planner protocol at all (an older or
            # smaller model). On the first move, let the caller fall back to the
            # one-shot path; later, just stop planning and answer with what we have.
            if step == 0 and not looked_up and not did:
                return {"reply": "", "search": last_web, "grounded": False, "steps": steps}
            break
        name = act.get("action")
        if name in (None, "done", "answer"):
            break
        if name == "web":
            last_web = str(act.get("query") or "")
        result = execute(store, act, lookup, embed, shell)[:3500]
        steps.append(_step_label(act, result))
        if name in _ACTIONS:
            did.append(f"{result}")
        else:
            looked_up.append(f"Looked up {json.dumps(act)[:200]}:\n{result}")

    # Phase 2: write the real answer, as plain text.
    context = [f"NOW: {now}"]
    facts = _facts(store)
    if facts:
        context.append(facts)
    if hist:
        context.append("CONVERSATION SO FAR:\n" + hist)
    if looked_up:
        context.append("WHAT YOU LOOKED UP IN THEIR DATA:\n" + "\n\n".join(looked_up))
    if did:
        context.append("WHAT YOU DID FOR THEM:\n" + "\n".join(f"- {d}" for d in did))
    context.append(f'THE USER ASKS: "{question}"\n\nWrite your answer:')
    reply = generate(ANSWER, "\n\n".join(context), 2000).strip()
    return {"reply": reply, "search": last_web, "grounded": True, "steps": steps}


def _step_label(act: dict, result: str) -> str:
    """A short, human line describing one thing Lumi did — shown when 'thinking'
    is turned on."""
    name = act.get("action")
    if name == "search":
        return f"Searched your notes and conversations for “{act.get('query', '')}”"
    if name == "transcript":
        return f"Searched your transcripts for “{act.get('query', '')}”"
    if name == "find":
        return f"Scanned your transcripts for any {act.get('what', 'phone')}"
    if name == "read":
        return "Read through a whole conversation"
    if name == "web":
        return f"Searched the web for “{act.get('query', '')}”"
    if name == "shell":
        return f"Ran on your computer: {str(act.get('command', ''))[:120]}"
    if name in ("list_dir", "read_file", "write_file", "make_dir"):
        verb = {"list_dir": "Listed", "read_file": "Read", "write_file": "Wrote", "make_dir": "Made folder"}[name]
        return f"{verb} {act.get('path', '')}"
    # The action tools already return a plain confirmation ("Added … to your list").
    return result.split("\n")[0][:140]
