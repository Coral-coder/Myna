"""The pages the server's own window shows for looking through the database."""

from __future__ import annotations

import html
from datetime import datetime
from urllib.parse import quote

from . import catalog
from .store import Store

TABS = (("utterance", "Transcript"), ("note", "Notes"), ("memory", "Memories"), ("item", "Lists"), ("person", "People"), ("song", "Music"))

_STYLE = """<style>
body{font:15px/1.5 system-ui,sans-serif;max-width:760px;margin:28px auto;padding:0 20px;color:#e9e9e6;background:#141517;color-scheme:dark}
a{color:inherit}
nav{display:flex;gap:16px;flex-wrap:wrap;border-bottom:1px solid #ffffff22;padding-bottom:10px;margin-bottom:14px}
nav a{text-decoration:none;font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;color:#9b9d9e}
nav a.on{color:#e9e9e6;border-bottom:1px solid #e9e9e6}
input{font:inherit;width:100%;box-sizing:border-box;padding:8px 10px;border:1px solid #ffffff33;border-radius:8px;background:#ffffff0d;color:#e9e9e6}
.day{font:11px ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;color:#6a6c6e;margin:22px 0 6px}
.row{padding:7px 0;border-bottom:1px solid #ffffff12}
.t{font:11px ui-monospace,monospace;color:#6a6c6e;margin-right:8px}
.who{color:#9b9d9e;margin-right:6px}
.dim{color:#9b9d9e;font-size:13px}
h1{font-weight:300;font-size:24px;margin:6px 0}
h2{font:11px ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;color:#6a6c6e;margin:20px 0 4px}
pre{white-space:pre-wrap;font:13px/1.5 system-ui,sans-serif}
</style>"""


# Keeps a page current as the phone syncs, without reloading it: the content is
# fetched again every two seconds and swapped in only if it changed, leaving the
# scroll position, the search box and any selected text alone.
_REFRESH = """<script>
let last = document.getElementById('page').innerHTML;
setInterval(async () => {
  try {
    if (String(window.getSelection())) return;
    const reply = await fetch(location.href, {cache: 'no-store'});
    if (reply.status === 401) { location.reload(); return; }
    const text = await reply.text();
    const next = new DOMParser().parseFromString(text, 'text/html').getElementById('page');
    if (!next || next.innerHTML === last) return;
    const y = window.scrollY;
    last = next.innerHTML;
    document.getElementById('page').innerHTML = last;
    window.scrollTo(0, y);
  } catch (e) {}
}, 2000);
</script>"""


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
    for key, title in (("live", "Live"), ("models", "Models")):
        on = ' class="on"' if key == active else ""
        links.append(f'<a{on} href="/browse/{key}"{" style=margin-left:auto" if key == "live" else ""}>{title}</a>')
    links.append('<a href="/">Status</a>')
    links.append(
        '<form method="post" action="/lock" style="margin:0"><button style="font:11px ui-monospace,monospace;'
        "letter-spacing:.1em;text-transform:uppercase;padding:2px 10px;border:1px solid #e9e9e6;color:#e9e9e6;"
        'background:none;border-radius:99px;cursor:pointer">Lock</button></form>'
    )
    search = ""
    if active not in ("live", "models"):
        search = (
            f'<form method="get" action="/browse"><input type="hidden" name="kind" value="{_e(active)}">'
            f'<input name="q" placeholder="Search" value="{_e(query)}"></form>'
        )
    return (
        '<!doctype html><meta charset="utf-8"><title>Myna Server</title>'
        f"{_STYLE}<nav>{''.join(links)}</nav>{search}"
        f'<div id="page">{body}</div>{"" if active == "live" else _REFRESH}'
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
            heard = row.get("context") or ""
            if heard and heard != "conversation":
                piece = f"{heard} · {row.get('segment')}" if row.get("segment") else heard
                label = f'<span class="t">{_e(piece.upper())}</span>' + label
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
        elif kind == "song":
            found = quote(f"{row.get('title', '')} {row.get('artist', '')}")
            links = f'<a href="https://open.spotify.com/search/{found}">Spotify</a>'
            if str(row.get("appleMusicURL") or "").startswith("https://"):
                links = f'<a href="{_e(row.get("appleMusicURL"))}">Apple Music</a> · ' + links
            times = row.get("timesHeard") or 1
            parts.append(
                f'<div class="row">{_e(row.get("title"))} <span class="dim">— {_e(row.get("artist"))}</span>'
                f'<div class="dim">{_e(_when(row["at"], "%d %b %Y %H:%M"))}'
                f'{f" · heard {_e(times)} times" if times > 1 else ""} · {links}</div></div>'
            )
        elif kind == "person":
            parts.append(
                f'<div class="row">{_e(row.get("name") or "Unnamed voice")}'
                f' <span class="dim">heard {_e(row.get("sampleCount", 0))} times</span></div>'
            )
    if kind == "song" and parts:
        parts.insert(0, '<p><a href="/browse/playlist">Export playlist</a></p>')
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


def live_page(store: Store) -> str:
    """What the server is receiving and doing right now, updating by itself."""
    body = """
<h2>Now</h2><div id="now" class="dim">…</div>
<h2>Just received</h2><div id="events"><p class="dim">Nothing yet. Lines appear here as the phone sends audio.</p></div>
<script>
const esc = s => String(s ?? '').replace(/[&<>]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;'}[c]));
async function tick() {
  try {
    const reply = await fetch('/browse/live.json', {cache: 'no-store'});
    if (reply.status === 401) { location.reload(); return; }
    const d = await reply.json();
    document.getElementById('now').innerHTML =
      'Transcription: ' + esc(d.transcriber) + ' — ' + esc(d.transcriber_status) + '<br>' +
      'Writing: ' + esc(d.writer) + ' — ' + esc(d.writer_status) + '<br>' +
      esc(d.transcribed) + ' clips transcribed, ' + esc(d.generated) + ' pieces written since the server started';
    if (d.events.length) {
      document.getElementById('events').innerHTML = d.events.slice().reverse().map(e => {
        const t = new Date(e.at * 1000).toLocaleTimeString();
        const what = e.kind === 'transcribe'
          ? 'heard ' + e.audio_seconds + ' s, transcribed in ' + e.took + ' s'
          : 'wrote in ' + e.took + ' s';
        const text = e.failed ? 'Failed: ' + esc(e.text) : (esc(e.text) || '<span class="dim">(no speech in this clip)</span>');
        return '<div class="row"><span class="t">' + t + '</span>' + text +
               '<div class="dim">' + what + ' · ' + esc(e.engine) + '</div></div>';
      }).join('');
    }
  } catch (e) {}
}
tick(); setInterval(tick, 1500);
</script>"""
    return _frame("live", "", body, store.counts())


def models_page(store: Store, config, state: dict) -> str:
    """Choose which models transcribe and write."""
    parts = [
        '<style>button{font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;'
        "padding:6px 12px;border:1px solid #e9e9e6;color:#e9e9e6;background:none;border-radius:99px;cursor:pointer}"
        ".pick{display:flex;gap:12px;align-items:center;justify-content:space-between}</style>",
        "<h2>Transcription</h2>",
        f'<div class="dim">{_e(state.get("transcriber_status"))}</div>',
    ]
    for model, name, note in catalog.SPEECH:
        current = model == config.stt_model
        action = (
            '<span class="t">IN USE</span>'
            if current
            else f'<form method="post" action="/browse/models"><input type="hidden" name="speech" value="{_e(model)}">'
            "<button>Use</button></form>"
        )
        parts.append(f'<div class="row pick"><div>{_e(name)}<div class="dim">{_e(note)}</div></div>{action}</div>')

    parts += ["<h2>Writing notes and answers</h2>", f'<div class="dim">{_e(state.get("writer_status"))}</div>']
    listed = False
    for repo, file, name, note in catalog.WRITING:
        current = repo == config.llm_repo and file == config.llm_file
        listed = listed or current
        action = (
            '<span class="t">IN USE</span>'
            if current
            else f'<form method="post" action="/browse/models"><input type="hidden" name="repo" value="{_e(repo)}">'
            f'<input type="hidden" name="file" value="{_e(file)}"><button>Use</button></form>'
        )
        parts.append(f'<div class="row pick"><div>{_e(name)}<div class="dim">{_e(note)}</div></div>{action}</div>')
    if not listed:
        parts.append(f'<div class="row pick"><div>{_e(config.llm_file)}<div class="dim">{_e(config.llm_repo)}</div></div><span class="t">IN USE</span></div>')
    parts.append(
        "<h2>Another model</h2>"
        '<div class="dim">Any GGUF model on Hugging Face: its repository and file name.</div>'
        '<form method="post" action="/browse/models" style="display:grid;gap:8px;margin-top:8px">'
        '<input name="repo" placeholder="owner/repository"><input name="file" placeholder="model-file.gguf">'
        "<div><button>Use</button></div></form>"
        '<p class="dim">A model is downloaded the first time it is used, then loaded onto the graphics card. '
        "The Live tab shows when it is ready.</p>"
    )
    return _frame("models", "", "".join(parts), store.counts())


def playlist_text(store: Store) -> str:
    """The heard music as a plain list, one song per line, newest first."""
    return "\n".join(
        f"{song.get('title', '')} - {song.get('artist', '')}" for song in store.browse("song", limit=5000)
    )
