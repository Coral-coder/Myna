"""The pages the server's own window shows for looking through the database."""

from __future__ import annotations

import html
from datetime import datetime
from urllib.parse import quote

from .store import Store

TABS = (("utterance", "Transcript"), ("note", "Notes"), ("memory", "Memories"), ("item", "Lists"), ("person", "People"))

_STYLE = """<style>
body{font:15px/1.5 system-ui,sans-serif;max-width:760px;margin:28px auto;padding:0 20px;color:#1b1c1d;background:#e9e9e6}
a{color:inherit}
nav{display:flex;gap:16px;flex-wrap:wrap;border-bottom:1px solid #0002;padding-bottom:10px;margin-bottom:14px}
nav a{text-decoration:none;font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;color:#6c6d6b}
nav a.on{color:#1b1c1d;border-bottom:1px solid #1b1c1d}
input{font:inherit;width:100%;box-sizing:border-box;padding:8px 10px;border:1px solid #0003;border-radius:8px;background:#fff8}
.day{font:11px ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;color:#9b9c99;margin:22px 0 6px}
.row{padding:7px 0;border-bottom:1px solid #00000012}
.t{font:11px ui-monospace,monospace;color:#9b9c99;margin-right:8px}
.who{color:#6c6d6b;margin-right:6px}
.dim{color:#6c6d6b;font-size:13px}
h1{font-weight:300;font-size:24px;margin:6px 0}
h2{font:11px ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;color:#9b9c99;margin:20px 0 4px}
pre{white-space:pre-wrap;font:13px/1.5 system-ui,sans-serif}
</style>"""


def _e(value) -> str:
    return html.escape(str(value if value is not None else ""))


def _when(seconds, fmt: str) -> str:
    try:
        return datetime.fromtimestamp(float(seconds)).strftime(fmt)
    except (TypeError, ValueError, OverflowError, OSError):
        return ""


def _frame(active: str, query: str, body: str, counts: dict[str, int]) -> str:
    links = []
    for kind, title in TABS:
        on = ' class="on"' if kind == active else ""
        links.append(f'<a{on} href="/browse?kind={kind}">{title} {counts.get(kind, 0)}</a>')
    links.append('<a href="/" style="margin-left:auto">Status</a>')
    search = (
        f'<form method="get" action="/browse"><input type="hidden" name="kind" value="{_e(active)}">'
        f'<input name="q" placeholder="Search" value="{_e(query)}"></form>'
    )
    return (
        '<!doctype html><meta charset="utf-8"><title>Myna Server</title>'
        f"{_STYLE}<nav>{''.join(links)}</nav>{search}{body}"
    )


def list_page(store: Store, kind: str, query: str, before: float | None) -> str:
    rows = store.browse(kind, query, before=before)
    names = {person["id"]: person.get("name", "") for person in store.browse("person", limit=1000)}
    parts: list[str] = []
    day = None
    for row in rows:
        stamp = _when(row["at"], "%A %d %B %Y")
        if stamp != day and kind in ("utterance", "note"):
            day = stamp
            parts.append(f'<div class="day">{_e(stamp)}</div>')
        clock = _when(row["at"], "%H:%M")
        if kind == "utterance":
            who = row.get("speakerName") or names.get(row.get("speaker", ""), "")
            label = f'<span class="who">{_e(who)}:</span>' if who else ""
            parts.append(f'<div class="row"><span class="t">{clock}</span>{label}{_e(row.get("text"))}</div>')
        elif kind == "note":
            link = f'/browse/note?id={quote(row["id"])}'
            parts.append(
                f'<div class="row"><span class="t">{clock}</span><a href="{link}">{_e(row.get("title") or "Untitled")}</a>'
                f'<div class="dim">{_e(row.get("overview"))}</div></div>'
            )
        elif kind == "memory":
            if row.get("archived"):
                continue
            parts.append(
                f'<div class="row">{_e(row.get("content"))}'
                f'<div class="dim">{_e(_when(row["at"], "%d %b %Y"))}</div></div>'
            )
        elif kind == "item":
            mark = "☑" if row.get("isDone") else "☐"
            parts.append(
                f'<div class="row">{mark} {_e(row.get("text"))} <span class="dim">{_e(row.get("kind"))}</span>'
                f'<div class="dim">{_e(row.get("detail"))}</div></div>'
            )
        elif kind == "person":
            parts.append(
                f'<div class="row">{_e(row.get("name") or "Unnamed voice")}'
                f' <span class="dim">heard {_e(row.get("sampleCount", 0))} times</span></div>'
            )
    if not parts:
        parts.append('<p class="dim">Nothing here yet. It fills in as the phone syncs.</p>')
    elif len(rows) >= 300:
        older = f'/browse?kind={kind}&q={quote(query)}&before={rows[-1]["at"]}'
        parts.append(f'<p><a href="{older}">Older</a></p>')
    return _frame(kind, query, "".join(parts), store.counts())


def note_page(store: Store, note_id: str) -> str:
    note = store.get("note", note_id)
    if note is None:
        return _frame("note", "", '<p class="dim">That note is gone.</p>', store.counts())
    parts = [
        f'<h1>{_e(note.get("title") or "Untitled")}</h1>',
        f'<div class="dim">{_e(_when(note.get("startedAt"), "%A %d %B %Y, %H:%M"))}'
        f'{" · " + _e(note.get("placeName")) if note.get("placeName") else ""}</div>',
    ]

    def section(title: str, text) -> None:
        if text:
            parts.append(f"<h2>{title}</h2><pre>{_e(text)}</pre>")

    def bullets(title: str, items) -> None:
        if items:
            parts.append(f"<h2>{title}</h2>" + "".join(f'<div class="row">{_e(item)}</div>' for item in items))

    section("Overview", note.get("overview"))
    section("Notes", note.get("detailedNotes"))
    bullets("Key points", note.get("keyPoints"))
    bullets("Decisions", note.get("decisions"))
    bullets("Action items", [item.get("task") for item in note.get("actionItems") or [] if isinstance(item, dict)])
    bullets("Follow-ups", note.get("followUps"))
    section("Transcript", note.get("transcript"))
    return _frame("note", "", "".join(parts), store.counts())
