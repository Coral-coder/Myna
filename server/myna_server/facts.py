"""Confirming what Myna learns, as Bee does with its facts.

A write-up suggests memories about the wearer; they wait here until the
wearer keeps or rejects them. Kept ones become memories on the phone too
(marked pinned, i.e. confirmed); rejected ones are never used, and the
memory writer is told not to suggest them again."""

from __future__ import annotations

import time
import uuid

from .store import Store


def _save(store: Store, kind: str, record_id: str, data: dict) -> None:
    store.sync(0, [{"kind": kind, "id": record_id, "updated_at": time.time(), "deleted": False, "data": data}])


def pending(store: Store, most: int = 100) -> list[dict]:
    """Suggested memories not yet kept or rejected, newest first."""
    out = []
    for row in store.browse("conversation", limit=400):
        if row.get("discarded") or row.get("failed"):
            continue
        for index, memory in enumerate(row.get("memories") or []):
            if isinstance(memory, dict) and not memory.get("status") and memory.get("content"):
                out.append({"conversation": row["id"], "index": index, "content": memory["content"],
                            "category": memory.get("category", "system"), "title": row.get("title", ""), "at": row["at"]})
    return out[:most]


def rejected(store: Store) -> list[str]:
    return [m["content"] for row in store.browse("conversation", limit=400)
            for m in row.get("memories") or [] if isinstance(m, dict) and m.get("status") == "rejected"]


def decide(store: Store, conversation_id: str, index: int, keep: bool) -> bool:
    record = store.get("conversation", conversation_id)
    memories = (record or {}).get("memories") or []
    if not 0 <= index < len(memories) or not isinstance(memories[index], dict):
        return False
    memory = memories[index]
    memory["status"] = "kept" if keep else "rejected"
    if keep:
        memory_id = str(uuid.uuid4()).upper()
        memory["memoryId"] = memory_id
        _save(store, "memory", memory_id, {
            "createdAt": time.time(), "category": memory.get("category", "system"), "content": memory["content"],
            "sourceNoteID": "", "pinned": True, "archived": False, "manuallyAdded": False,
        })
    _save(store, "conversation", conversation_id, record)
    return True


def mark(store: Store, memory_id: str, action: str) -> bool:
    """Confirm or forget one of the phone's memories."""
    record = store.get("memory", memory_id)
    if record is None or action not in ("confirm", "forget"):
        return False
    if action == "confirm":
        record["pinned"] = True
    else:
        record["archived"] = True
    _save(store, "memory", memory_id, record)
    return True
