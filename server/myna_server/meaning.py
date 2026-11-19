"""Search by meaning, as Omi's conversation search does alongside keywords.

Each conversation, note and memory gets a meaning-vector from a small
embedding model; a question is turned into one too, and the closest records
are handed to the writing model with the keyword matches."""

from __future__ import annotations

import time
from typing import Callable

from .store import Store

KINDS = ("conversation", "note", "memory")
QUERY_PREFIX = "Instruct: Given a question, find the conversations, notes and memories that help answer it\nQuery: "

Embed = Callable[[list[str]], list[list[float]]]


def text_of(record: dict) -> str:
    kind = record.get("kind")
    if kind == "memory":
        return str(record.get("content") or "")
    parts = [str(record.get("title") or ""), str(record.get("gist") or ""), str(record.get("overview") or "")]
    for section in record.get("sections") or []:
        parts += [str(b) for b in section.get("bullets") or []]
    parts += [str(item.get("description") or "") for item in record.get("actionItems") or [] if isinstance(item, dict)]
    if kind == "note":
        parts.append(str(record.get("detailedNotes") or "")[:1500])
    return ". ".join(part for part in parts if part)


def index_pending(store: Store, embed: Embed, most: int = 64) -> int:
    """Make meaning-vectors for records that don't have a current one."""
    pending = [row for row in store.unindexed(KINDS, most) if not row.get("discarded") and not row.get("failed")]
    texts = [text_of(row) for row in pending]
    keep = [(row, text) for row, text in zip(pending, texts) if text.strip()]
    if not keep:
        return 0
    vectors = embed([text for _, text in keep])
    now = time.time()
    for (row, _), vector in zip(keep, vectors):
        store.put_vector(row["kind"], row["id"], vector, now)
    return len(vectors)


def related(store: Store, embed: Embed, question: str, most: int = 8, floor: float = 0.35) -> list[dict]:
    """The records closest in meaning to `question`, best first."""
    vectors = embed([QUERY_PREFIX + question])
    if not vectors:
        return []
    out = []
    for score, kind, record_id in store.nearest(vectors[0], KINDS, most):
        if score < floor:
            continue
        record = store.get(kind, record_id)
        if record is not None:
            out.append({"kind": kind, "id": record_id, "score": score, **record})
    return out
