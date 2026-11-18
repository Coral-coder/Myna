"""The home database: everything the phone has heard and written, kept here.

One SQLite file holds every record as JSON, whatever its kind (a line of
transcript, a note, a memory, a list item, a person). The phone sends what
changed and asks for what it hasn't seen; the newest edit of a record wins.
Deleted records are kept, marked deleted, so nothing is lost by mistake.
"""

from __future__ import annotations

import json
import sqlite3
import threading
from pathlib import Path
from typing import Any

KINDS = ("utterance", "note", "memory", "item", "person", "song", "daily")

# Which field of a record places it in time, per kind.
_TIME_FIELDS = {
    "utterance": ("heardAt",),
    "note": ("startedAt", "createdAt"),
    "memory": ("createdAt",),
    "item": ("createdAt",),
    "person": ("createdAt",),
    "song": ("lastHeard", "firstHeard"),
    "daily": ("day",),
}


def _strings(value: Any) -> list[str]:
    """Every piece of text inside a record, for searching."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [text for item in value.values() for text in _strings(item)]
    if isinstance(value, list):
        return [text for item in value for text in _strings(item)]
    return []


class Store:
    def __init__(self, path: Path | str):
        self._lock = threading.Lock()
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        with self._lock, self._db:
            self._db.execute("PRAGMA journal_mode=WAL")
            self._db.execute(
                """CREATE TABLE IF NOT EXISTS records (
                    kind TEXT NOT NULL,
                    id TEXT NOT NULL,
                    data TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    seq INTEGER NOT NULL,
                    sort_at REAL NOT NULL DEFAULT 0,
                    search TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY (kind, id)
                )"""
            )
            self._db.execute("CREATE INDEX IF NOT EXISTS records_seq ON records (seq)")
            self._db.execute("CREATE INDEX IF NOT EXISTS records_time ON records (kind, deleted, sort_at)")
            # Received audio (kept a few days) and what each transcription
            # model made of it, for comparing models on the same recordings.
            self._db.execute(
                """CREATE TABLE IF NOT EXISTS clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    at REAL NOT NULL,
                    seconds REAL NOT NULL,
                    path TEXT NOT NULL
                )"""
            )
            self._db.execute(
                """CREATE TABLE IF NOT EXISTS transcripts (
                    clip_id INTEGER NOT NULL,
                    model TEXT NOT NULL,
                    text TEXT NOT NULL,
                    took REAL NOT NULL,
                    made_at REAL NOT NULL,
                    PRIMARY KEY (clip_id, model)
                )"""
            )
            self._db.execute("CREATE INDEX IF NOT EXISTS clips_at ON clips (at)")

    def _cursor(self) -> int:
        row = self._db.execute("SELECT COALESCE(MAX(seq), 0) AS top FROM records").fetchone()
        return int(row["top"])

    def sync(self, since: int, changes: list[dict]) -> dict:
        """Take the caller's changes, and return what changed here after `since`
        (leaving out what the caller just sent)."""
        accepted: set[tuple[str, str]] = set()
        with self._lock, self._db:
            seq = self._cursor()
            for change in changes:
                kind, record_id = change.get("kind"), change.get("id")
                if kind not in KINDS or not isinstance(record_id, str) or not record_id:
                    continue
                updated_at = float(change.get("updated_at") or 0)
                deleted = 1 if change.get("deleted") else 0
                data = change.get("data")
                current = self._db.execute(
                    "SELECT updated_at, data FROM records WHERE kind = ? AND id = ?", (kind, record_id)
                ).fetchone()
                if current is not None and current["updated_at"] >= updated_at:
                    continue  # what is here is as new or newer
                if deleted or not isinstance(data, dict):
                    if current is None:
                        continue
                    seq += 1
                    self._db.execute(
                        "UPDATE records SET deleted = 1, updated_at = ?, seq = ? WHERE kind = ? AND id = ?",
                        (updated_at, seq, kind, record_id),
                    )
                else:
                    seq += 1
                    sort_at = 0.0
                    for name in _TIME_FIELDS[kind]:
                        if isinstance(data.get(name), (int, float)):
                            sort_at = float(data[name])
                            break
                    self._db.execute(
                        """INSERT INTO records (kind, id, data, updated_at, deleted, seq, sort_at, search)
                           VALUES (?, ?, ?, ?, 0, ?, ?, ?)
                           ON CONFLICT (kind, id) DO UPDATE SET data = excluded.data,
                               updated_at = excluded.updated_at, deleted = 0, seq = excluded.seq,
                               sort_at = excluded.sort_at, search = excluded.search""",
                        (kind, record_id, json.dumps(data), updated_at, seq, sort_at, " ".join(_strings(data)).lower()),
                    )
                accepted.add((kind, record_id))
            rows = self._db.execute(
                "SELECT kind, id, data, updated_at, deleted FROM records WHERE seq > ? ORDER BY seq LIMIT 2000",
                (int(since),),
            ).fetchall()
            more = len(rows) == 2000
            top = seq if not more else int(
                self._db.execute(
                    "SELECT seq FROM records WHERE kind = ? AND id = ?", (rows[-1]["kind"], rows[-1]["id"])
                ).fetchone()["seq"]
            )
        out = [
            {
                "kind": row["kind"],
                "id": row["id"],
                "updated_at": row["updated_at"],
                "deleted": bool(row["deleted"]),
                "data": None if row["deleted"] else json.loads(row["data"]),
            }
            for row in rows
            if (row["kind"], row["id"]) not in accepted
        ]
        return {"changes": out, "cursor": top, "more": more}

    def browse(self, kind: str, query: str = "", limit: int = 300, before: float | None = None) -> list[dict]:
        """Records of one kind, newest first, optionally only those containing `query`."""
        sql = "SELECT id, data, sort_at FROM records WHERE kind = ? AND deleted = 0"
        args: list[Any] = [kind]
        for word in query.lower().split():
            sql += " AND instr(search, ?) > 0"
            args.append(word)
        if before is not None:
            sql += " AND sort_at < ?"
            args.append(before)
        sql += " ORDER BY sort_at DESC LIMIT ?"
        args.append(limit)
        with self._lock:
            rows = self._db.execute(sql, args).fetchall()
        return [{"id": row["id"], "at": row["sort_at"], **json.loads(row["data"])} for row in rows]

    def get(self, kind: str, record_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT data FROM records WHERE kind = ? AND id = ? AND deleted = 0", (kind, record_id)
            ).fetchone()
        return json.loads(row["data"]) if row else None

    def counts(self) -> dict[str, int]:
        with self._lock:
            rows = self._db.execute("SELECT kind, COUNT(*) AS n FROM records WHERE deleted = 0 GROUP BY kind").fetchall()
        found = {row["kind"]: int(row["n"]) for row in rows}
        return {kind: found.get(kind, 0) for kind in KINDS}

    # -- received audio and model comparison -----------------------------------

    def add_clip(self, at: float, seconds: float, path: str) -> int:
        with self._lock, self._db:
            return int(self._db.execute("INSERT INTO clips (at, seconds, path) VALUES (?, ?, ?)", (at, seconds, path)).lastrowid)

    def add_transcript(self, clip_id: int, model: str, text: str, took: float) -> None:
        import time

        with self._lock, self._db:
            self._db.execute(
                """INSERT INTO transcripts (clip_id, model, text, took, made_at) VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT (clip_id, model) DO UPDATE SET text = excluded.text, took = excluded.took,
                       made_at = excluded.made_at""",
                (clip_id, model, text, took, time.time()),
            )

    def clips_since(self, since: float, without_model: str | None = None) -> list[dict]:
        """Kept clips heard after `since`, oldest first; optionally only those
        `without_model` hasn't transcribed yet."""
        sql = "SELECT id, at, seconds, path FROM clips WHERE at >= ?"
        args: list[Any] = [since]
        if without_model is not None:
            sql += " AND id NOT IN (SELECT clip_id FROM transcripts WHERE model = ?)"
            args.append(without_model)
        with self._lock:
            rows = self._db.execute(sql + " ORDER BY at", args).fetchall()
        return [dict(row) for row in rows]

    def last_clip_at(self) -> float:
        with self._lock:
            row = self._db.execute("SELECT COALESCE(MAX(at), 0) AS latest FROM clips").fetchone()
        return float(row["latest"])

    def model_readout(self, since: float) -> list[dict]:
        """For each model: how many clips it did, how much audio, how long it
        took, and how many words it produced."""
        with self._lock:
            rows = self._db.execute(
                """SELECT t.model AS model, COUNT(*) AS clips, SUM(c.seconds) AS audio, SUM(t.took) AS took,
                          SUM(CASE WHEN t.text = '' THEN 1 ELSE 0 END) AS empty,
                          SUM(LENGTH(t.text) - LENGTH(REPLACE(t.text, ' ', '')) + (t.text != '')) AS words
                   FROM transcripts t JOIN clips c ON c.id = t.clip_id WHERE c.at >= ?
                   GROUP BY t.model ORDER BY MAX(t.made_at) DESC""",
                (since,),
            ).fetchall()
        return [dict(row) for row in rows]

    def side_by_side(self, since: float, limit: int = 40) -> list[dict]:
        """The latest clips, each with what every model heard in it."""
        with self._lock:
            clips = self._db.execute(
                "SELECT id, at, seconds FROM clips WHERE at >= ? ORDER BY at DESC LIMIT ?", (since, limit)
            ).fetchall()
            out = []
            for clip in clips:
                texts = self._db.execute(
                    "SELECT model, text, took FROM transcripts WHERE clip_id = ? ORDER BY made_at", (clip["id"],)
                ).fetchall()
                out.append({"at": clip["at"], "seconds": clip["seconds"], "texts": [dict(t) for t in texts]})
        return out

    def drop_clips_before(self, before: float) -> list[str]:
        """Forget clips older than `before`; returns their file paths to delete."""
        with self._lock, self._db:
            rows = self._db.execute("SELECT id, path FROM clips WHERE at < ?", (before,)).fetchall()
            self._db.execute("DELETE FROM transcripts WHERE clip_id IN (SELECT id FROM clips WHERE at < ?)", (before,))
            self._db.execute("DELETE FROM clips WHERE at < ?", (before,))
        return [row["path"] for row in rows]
