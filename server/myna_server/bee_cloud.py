"""Pull conversations, transcripts and summaries from Bee's developer API.

Bee's bracelet (even the free tier) records, transcribes and summarizes
conversations on Bee's own servers. This reads them with a developer API
token from the Bee account (docs.bee.computer) so the Myna server can keep a
local copy and run its own write-ups and search on top — Bee does the
far-field capture and transcription it's good at, Myna owns the notes.

Read-only; it only ever GETs the account's own data and sends nothing out but
the token. Mirrors the app's BeeCloudAPI (same base URL, auth and shapes)."""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from datetime import datetime, timezone

BASE = "https://api.developer.bee.amazon.dev"


class BeeError(Exception):
    pass


def _parse_date(value) -> float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        pass
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S"):
        try:
            dt = datetime.strptime(text.replace("Z", "+0000") if fmt.endswith("%z") else text, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except ValueError:
            continue
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


class BeeCloud:
    def __init__(self, token: str, base: str = BASE) -> None:
        self.token = (token or "").strip()
        self.base = base.rstrip("/")

    @property
    def configured(self) -> bool:
        return bool(self.token)

    def _get(self, path: str) -> dict:
        request = urllib.request.Request(
            self.base + path,
            headers={"Authorization": f"Bearer {self.token}", "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as reply:
                return json.loads(reply.read())
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise BeeError("Bee didn't accept the token. Check the developer token in Settings.") from error
            raise BeeError(f"Bee returned HTTP {error.code}.") from error
        except (urllib.error.URLError, ValueError, TimeoutError) as error:
            raise BeeError(f"Couldn't reach Bee: {error}") from error

    def account_name(self) -> str | None:
        record = self._get("/v1/me")
        record = record.get("user") or record
        return record.get("first_name") or record.get("name") or record.get("email")

    def recent_conversations(self, limit: int = 30) -> list[dict]:
        """Finished conversations, newest first: id, start, end, summary, state."""
        body = self._get(f"/v1/conversations?limit={int(limit)}")
        out = []
        for raw in body.get("conversations") or []:
            summary = self._summary(raw)
            if summary and summary["state"].lower() != "in_progress":
                out.append(summary)
        return out

    def conversation(self, bee_id: int) -> dict:
        """One conversation with its full speaker-labelled transcript."""
        body = self._get(f"/v1/conversations/{bee_id}")
        record = body.get("conversation") or body
        summary = self._summary(record)
        if summary is None:
            raise BeeError("Bee sent a conversation Myna couldn't read.")
        transcriptions = record.get("transcriptions") or []
        lines: list[tuple[float, str, str]] = []
        for block in transcriptions:
            for raw in block.get("utterances") or []:
                text = str(raw.get("text") or "").strip()
                if not text:
                    continue
                speaker = str(raw.get("speaker") or "").replace("speaker_", "Speaker ")
                when = _parse_date(raw.get("spoken_at") or raw.get("start")) or summary["start"] or 0.0
                lines.append((when, speaker, text))
        lines.sort(key=lambda row: row[0])
        return {**summary, "lines": lines}

    def facts(self, limit: int = 50) -> list[str]:
        body = self._get(f"/v1/facts?limit={int(limit)}")
        items = body.get("facts") or body.get("items") or []
        return [str(it.get("text") or "").strip() for it in items if str(it.get("text") or "").strip()]

    def todos(self, limit: int = 50) -> list[dict]:
        body = self._get(f"/v1/todos?limit={int(limit)}")
        items = body.get("todos") or body.get("items") or body.get("results") or []
        out = []
        for raw in items:
            text = str(raw.get("text") or raw.get("task") or raw.get("title") or "").strip()
            if not text:
                continue
            completed = bool(raw.get("completed") or raw.get("is_completed")
                             or str(raw.get("state") or "").lower() == "completed")
            out.append({"id": str(raw.get("id") or text), "text": text, "completed": completed,
                        "due": _parse_date(raw.get("alarm_at") or raw.get("due") or raw.get("due_at") or raw.get("date"))})
        return out

    @staticmethod
    def _summary(raw: dict) -> dict | None:
        if not isinstance(raw, dict) or raw.get("id") is None:
            return None
        summary = str(raw.get("summary") or raw.get("short_summary") or "").strip()
        return {
            "bee_id": int(raw["id"]),
            "start": _parse_date(raw.get("start") or raw.get("start_time") or raw.get("created_at")),
            "end": _parse_date(raw.get("end") or raw.get("end_time")),
            "summary": summary,
            "state": str(raw.get("state") or "").strip() or "unknown",
        }


# -- saving Bee conversations into Myna's store ------------------------------------------


def _save(store, kind: str, record_id: str, data: dict, at: float) -> None:
    import time

    store.sync(0, [{"kind": kind, "id": record_id, "updated_at": time.time(), "deleted": False, "data": data}])


def already_have(store, bee_id: int) -> bool:
    return store.get("conversation", f"bee-{bee_id}") is not None


def import_conversations(store, client: "BeeCloud", most: int = 30, owner: str = "") -> int:
    """Pull finished Bee conversations and save a local copy of each (its
    summary plus the speaker-labelled transcript). Returns how many were new."""
    added = 0
    for summary in client.recent_conversations(limit=most):
        bee_id = summary["bee_id"]
        if already_have(store, bee_id):
            continue
        try:
            full = client.conversation(bee_id)
        except BeeError:
            continue
        start = full["start"] or 0.0
        end = full["end"] or start
        # The transcript as Myna utterances (for search and local write-ups).
        for index, (when, speaker, text) in enumerate(full["lines"]):
            _save(store, "utterance", f"bee-{bee_id}-{index}", {
                "text": text, "heardAt": when or start, "duration": 0.0, "engine": "bee",
                "speakerName": speaker, "context": "conversation", "beeId": bee_id,
            }, when or start)
        # The conversation record, carrying Bee's own summary.
        title = _title(full["summary"])
        _save(store, "conversation", f"bee-{bee_id}", {
            "startedAt": start, "endedAt": end, "at": start, "title": title,
            "overview": full["summary"], "gist": full["summary"][:160],
            "source": "bee", "beeId": bee_id, "speakers": sorted({s for _, s, _ in full["lines"] if s}),
            "actionItems": [], "memories": [], "songs": [],
        }, start)
        added += 1
    return added


def _title(summary: str) -> str:
    line = (summary or "").strip().splitlines()[0] if summary.strip() else "Conversation"
    line = line.lstrip("# ").strip()
    words = line.split()
    return " ".join(words[:10]) + ("…" if len(words) > 10 else "") if words else "Conversation"


def myna_writeup(store, conversation_id: str, write, owner: str = "", known_memories=None) -> bool:
    """Run Myna's own writing model over a Bee conversation's transcript and
    store the result alongside Bee's summary, so the phone can show either."""
    from . import conversations

    record = store.get("conversation", conversation_id)
    if record is None or record.get("myna") or record.get("source") != "bee":
        return False
    bee_id = record.get("beeId")
    lines = [u for u in store.browse("utterance", limit=4000) if u.get("beeId") == bee_id]
    if not lines:
        return False
    lines.sort(key=lambda u: u.get("at", 0.0))
    try:
        result = conversations.process(lines, {}, [], known_memories or [], owner, write)
    except Exception:
        return False
    record["myna"] = {key: result.get(key) for key in
                      ("title", "emoji", "category", "gist", "overview", "sections",
                       "actionItems", "events", "memories")}
    _save(store, "conversation", conversation_id, record, float(record.get("startedAt") or 0))
    return True


def needs_writeup(store, most: int = 200) -> list[str]:
    """Bee conversations that don't have a Myna write-up yet, newest first."""
    return [row["id"] for row in store.browse("conversation", limit=most)
            if row.get("source") == "bee" and not row.get("myna")]
