"""The pages the server's own window shows for looking through the database."""

from __future__ import annotations

import html
from datetime import datetime, timedelta
from urllib.parse import quote

from . import catalog
from .engines import speeds
from .store import Store

TABS = (("utterance", "Transcript"), ("conversation", "Conversations"), ("note", "Notes"), ("memory", "Memories"), ("item", "Lists"), ("person", "People"), ("song", "Music"), ("daily", "Days"))

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
// Don't swap the page out from under a click (see the Settings page).
let holdUntil = 0;
document.addEventListener('pointerdown', () => { holdUntil = Date.now() + 2500; }, true);
setInterval(async () => {
  try {
    if (Date.now() < holdUntil || String(window.getSelection())) return;
    const reply = await fetch(location.href, {cache: 'no-store'});
    if (reply.status === 401) { location.reload(); return; }
    if (!reply.ok) return;
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
    for key, title in (("ask", "Ask"), ("live", "Live"), ("compare", "Compare"), ("models", "Models"), ("experiment", "Experiment")):
        on = ' class="on"' if key == active else ""
        links.append(f'<a{on} href="/browse/{key}"{" style=margin-left:auto" if key == "ask" else ""}>{title}</a>')
    links.append('<a href="/">Settings</a>')
    links.append(
        '<form method="post" action="/lock" style="margin:0"><button style="font:11px ui-monospace,monospace;'
        "letter-spacing:.1em;text-transform:uppercase;padding:2px 10px;border:1px solid #e9e9e6;color:#e9e9e6;"
        'background:none;border-radius:99px;cursor:pointer">Lock</button></form>'
    )
    search = ""
    if active not in ("live", "models", "ask", "compare", "daily", "conversation-detail", "experiment"):
        search = (
            f'<form method="get" action="/browse"><input type="hidden" name="kind" value="{_e(active)}">'
            f'<input name="q" placeholder="Search" value="{_e(query)}"></form>'
        )
    return (
        '<!doctype html><meta charset="utf-8"><title>Myna Server</title>'
        f"{_STYLE}<nav>{''.join(links)}</nav>{search}"
        f'<div id="page">{body}</div>{"" if active in ("live", "ask") else _REFRESH}'
    )


def _fact_button(hidden: str, action: str, label: str) -> str:
    return (f'<form method="post" action="/browse/facts" style="margin:0">{hidden}'
            f'<button name="action" value="{action}">{label}</button></form>')


def list_page(store: Store, kind: str, query: str, before: float | None, daily_status: str = "") -> str:
    rows = store.browse(kind, query, before=before)
    names = {person["id"]: person.get("name", "") for person in store.browse("person", limit=1000)}
    parts: list[str] = []
    hidden = 0
    if kind == "utterance":
        from .cleanup import clean
    day = None
    for row in rows:
        stamp = _when(row["at"], "%A %d %B %Y")
        if stamp != day and kind in ("utterance", "note", "conversation"):
            day = stamp
            parts.append(f'<div class="day">{_e(stamp)}</div>')
        clock = _when(row["at"], "%H:%M")
        if kind == "utterance":
            shown = clean(str(row.get("text") or ""))
            if not shown:
                hidden += 1  # kept, but not shown: made up by a recognizer
                continue
            row = {**row, "text": shown}
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
            ok = ('<span class="t">CONFIRMED</span>' if row.get("pinned") else
                  _fact_button(f'<input type="hidden" name="memory" value="{_e(row["id"])}">', "confirm", "Confirm"))
            parts.append(
                f'<div class="row pick"><div>{_e(row.get("content"))}'
                f'<div class="dim">{_e(_when(row["at"], "%d %b %Y"))}</div></div><div style="display:flex;gap:6px">{ok}'
                + _fact_button(f'<input type="hidden" name="memory" value="{_e(row["id"])}">', "forget", "Forget")
                + "</div></div>"
            )
        elif kind == "item":
            mark = "☑" if row.get("isDone") else "☐"
            parts.append(
                f'<div class="row">{mark} {_e(row.get("text"))} <span class="dim">{_e(row.get("kind"))}</span>'
                f'<div class="dim">{_e(row.get("detail"))}</div></div>'
            )
        elif kind == "conversation":
            if row.get("failed"):
                parts.append(
                    f'<div class="row"><span class="t">{clock}</span>Couldn\'t write this up ({row.get("words", 0)} words)'
                    f'<div class="dim">{_e(row.get("failed"))} · <a href="/browse/conversation?id={quote(row["id"])}">see the transcript</a></div></div>'
                )
            elif row.get("discarded"):
                parts.append(
                    f'<div class="row dim"><span class="t">{clock}</span>Discarded as not worth keeping '
                    f'({row.get("words", 0)} words) · <a href="/browse/conversation?id={quote(row["id"])}">see it</a></div>'
                )
            else:
                link = f'/browse/conversation?id={quote(row["id"])}'
                tasks = len(row.get("actionItems") or [])
                extra = f' · {tasks} to do' if tasks else ""
                music = f' · ♪ {len(row["songs"])}' if row.get("songs") else ""
                parts.append(
                    f'<div class="row"><span class="t">{clock}</span>{_e(row.get("emoji"))} <a href="{link}">{_e(row.get("title"))}</a>'
                    f' <span class="dim">{_e(row.get("category"))}{extra}{music}</span>'
                    f'<div class="dim">{_e(row.get("gist") or row.get("overview"))}</div></div>'
                )
        elif kind == "daily":
            parts.append(
                f'<h1>{_e(_when(row["at"], "%A %d %B %Y"))}</h1>'
                f'<div class="dim">written {_e(_when(row.get("writtenAt"), "%d %b %H:%M"))} by {_e(row.get("model"))}</div>'
                f'<pre>{_e(row.get("text"))}</pre>'
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
    if kind == "memory" and not query:
        from .facts import pending

        waiting = pending(store)
        if waiting:
            rows_html = []
            for item in waiting:
                hidden = (f'<input type="hidden" name="conversation" value="{_e(item["conversation"])}">'
                          f'<input type="hidden" name="index" value="{item["index"]}">')
                rows_html.append(
                    f'<div class="row pick"><div>{_e(item["content"])}<div class="dim">from '
                    f'<a href="/browse/conversation?id={quote(item["conversation"])}">{_e(item["title"])}</a>, '
                    f'{_e(_when(item["at"], "%d %b %H:%M"))}</div></div><div style="display:flex;gap:6px">'
                    + _fact_button(hidden, "keep", "Keep") + _fact_button(hidden, "reject", "Wrong") + "</div></div>"
                )
            parts.insert(0, "<h2>Is this right?</h2><div class=\"dim\">Things Myna noticed about you in conversations. "
                            "Keep the true ones; they become memories it trusts. Wrong ones are never used again.</div>"
                            + "".join(rows_html) + "<h2>Memories</h2>")
    if kind == "item" and not query:
        from .facts import pending_todos

        waiting = pending_todos(store)
        if waiting:
            rows_html = []
            for item in waiting:
                hidden = (f'<input type="hidden" name="todo" value="{_e(item["conversation"])}">'
                          f'<input type="hidden" name="index" value="{item["index"]}">')
                due = f' · due {_e(item["due"])}' if item["due"] else ""
                rows_html.append(
                    f'<div class="row pick"><div>{_e(item["description"])}<div class="dim">from '
                    f'<a href="/browse/conversation?id={quote(item["conversation"])}">{_e(item["title"])}</a>{due}</div></div>'
                    '<div style="display:flex;gap:6px">'
                    + _fact_button(hidden, "add", "Add") + _fact_button(hidden, "dismiss", "Dismiss") + "</div></div>"
                )
            parts.insert(0, "<h2>Add to your list?</h2><div class=\"dim\">To-dos picked out of your conversations. "
                            "Added ones go on your list on the phone too.</div>" + "".join(rows_html) + "<h2>Your lists</h2>")
    if hidden:
        parts.insert(0, f'<div class="dim">{hidden} lines a recognizer made up from noise (like "Thanks for watching") '
                        "are kept but not shown.</div>")
    if kind == "song" and parts:
        parts.insert(0, '<p><a href="/browse/playlist">Export playlist</a></p>')
    if kind == "conversation":
        parts.insert(
            0,
            '<form method="post" action="/browse/conversations" style="margin:6px 0 4px">'
            '<button style="font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;padding:7px 14px;'
            'border:1px solid #e9e9e6;color:#e9e9e6;background:none;border-radius:99px;cursor:pointer">Write up what is waiting, and retry failed ones</button></form>'
            f'<div class="dim">{_e(daily_status) or "A conversation is written up by itself two minutes after it ends."}</div>',
        )
    if kind == "daily":
        parts.insert(
            0,
            '<form method="post" action="/browse/daily" style="display:flex;gap:8px;align-items:center;margin:6px 0 4px">'
            f'<input type="date" name="day" value="{datetime.now().strftime("%Y-%m-%d")}" style="width:auto">'
            '<button style="font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;padding:7px 14px;'
            'border:1px solid #e9e9e6;color:#e9e9e6;background:none;border-radius:99px;cursor:pointer">Write this day\'s summary now</button></form>'
            f'<div class="dim">{_e(daily_status) or "A summary is written by itself once nothing has been heard for a while."}</div>',
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


def live_page(store: Store, state: dict | None = None) -> str:
    """What the server is receiving and doing right now, updating by itself."""
    body = _reset_buttons(state or {}, "live") + """
<h2>Working on</h2><div id="busy" class="dim">…</div>
<h2>Now</h2><div id="now" class="dim">…</div>
<h2>Just received</h2><div id="events"><p class="dim">Nothing yet. Lines appear here as the phone sends audio.</p></div>
<script>
const esc = s => String(s ?? '').replace(/[&<>]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;'}[c]));
async function tick() {
  try {
    const reply = await fetch('/browse/live.json', {cache: 'no-store'});
    if (reply.status === 401) { location.reload(); return; }
    const d = await reply.json();
    document.getElementById('busy').innerHTML = (d.busy && d.busy.length)
      ? d.busy.map(b => '<div class="row">' + esc(b.what) + ' <span class="dim">· ' + b.seconds + ' s</span>' +
          (b.seconds > 120 ? ' <span class="t">SLOW</span>' : '') + '</div>').join('')
      : 'Nothing: waiting for audio.';
    document.getElementById('now').innerHTML =
      'Transcription: ' + esc(d.transcriber) + ' — ' + esc(d.transcriber_status) + '<br>' +
      'Writing: ' + esc(d.writer) + ' — ' + esc(d.writer_status) + '<br>' +
      'Telling speakers apart: ' + esc(d.voices_status || 'off') + '<br>' +
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


def _choices(field: str, options, current: str) -> str:
    out = []
    for key, name, note in options:
        action = (
            '<span class="t">IN USE</span>'
            if key == current
            else f'<form method="post" action="/browse/models"><input type="hidden" name="{field}" value="{_e(key)}">'
            "<button>Use</button></form>"
        )
        out.append(f'<div class="row pick"><div>{_e(name)}<div class="dim">{_e(note)}</div></div>{action}</div>')
    return "".join(out)


def _recognizers(config, listening: list[str], trust: dict, readout: dict) -> str:
    """Every speech model, with what it has shown on this person's audio: a
    button to make one the main recognizer, and a tick box to have any number
    of others listen alongside it and be merged into one transcript."""
    names = {key: name for key, name, _ in catalog.SPEECH}

    def short(key: str) -> str:
        return key.removeprefix("sherpa:") if key.startswith("sherpa:") else f"whisper-{key}"

    out = [
        '<div class="dim">The <b>main</b> recognizer always listens. Tick as many others as you like to listen '
        "alongside it; what they all hear is merged into one transcript and checked for sense. Two Whisper models "
        "run on the graphics card; any more run on the processor. Each one ticked adds work for every clip. The "
        "figures are from your own audio this past week.</div>",
        '<form method="post" action="/browse/blend"><input type="hidden" name="listening" value="1">'
        '<input type="hidden" name="back" value="models">',
        "<table><tr><th>Listen</th><th>Model</th><th>Speed</th><th>Trust</th><th>Recordings</th><th></th></tr>",
    ]
    for key, name, note in catalog.SPEECH:
        row = readout.get(short(key)) or {}
        audio, took = row.get("audio") or 0, row.get("took") or 0
        speed = f"{audio / took:.0f}×" if took else ""
        learned = f"{trust[short(key)]:.0%}" if short(key) in trust else ""
        if key == config.stt_model:
            box = '<input type="checkbox" checked disabled title="The main recognizer always listens">'
            action = '<span class="t">MAIN</span>'
        else:
            ticked = " checked" if key in listening else ""
            box = f'<input type="checkbox" name="model" value="{_e(key)}"{ticked}>'
            action = f'<button name="speech" value="{_e(key)}" formaction="/browse/models">Make main</button>'
        out.append(
            f'<tr><td>{box}</td><td>{_e(name)}<div class="dim">{_e(note)}</div></td><td>{speed}</td>'
            f'<td>{learned}</td><td>{row.get("clips") or ""}</td><td>{action}</td></tr>'
        )
    out.append("</table>")
    automatic = "chosen by hand" if config.blend_models else "chosen automatically"
    out.append(
        '<div style="display:flex;gap:8px;align-items:center;margin-top:10px"><button>Save choices</button>'
        f'<span class="dim">Listening alongside now: {_e(", ".join(names.get(m, m) for m in listening) or "none")} '
        f"({automatic}).</span></div></form>"
        + ('<form method="post" action="/browse/blend" style="margin-top:6px"><input type="hidden" name="listen" value="auto">'
           '<input type="hidden" name="blend" value="on"><input type="hidden" name="back" value="models">'
           "<button>Choose automatically again</button></form>"
           if config.blend_models else "")
    )
    return "".join(out)


def _reset_buttons(state: dict, back: str) -> str:
    """Stop-and-reload buttons for when a model hangs or memory runs out."""
    rows = [
        ("recognition", "Speech recognition", f'{state.get("transcriber", "")} — {state.get("transcriber_status", "")}'),
        ("llm", "Writing (main)", f'{state.get("writer", "")} — {state.get("writer_status", "")}'),
        ("checker", "Checker", state.get("checker_status", "")),
        ("embedder", "Search", state.get("embedder_status", "")),
        ("helper", "Helper", state.get("helper_status", "")),
        ("summary", "Summary", state.get("summary_status", "")),
    ]
    out = [
        '<style>.rb{font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;padding:6px 12px;'
        'border:1px solid #e9e9e6;color:#e9e9e6;background:none;border-radius:99px;cursor:pointer}</style>'
        "<h2>Stuck or out of memory?</h2>",
        '<div class="dim">Stop &amp; reload ends a model at once, even in the middle of a job, frees its memory and '
        "loads it again. Restart everything restarts the whole server, which frees all of it; it is back in a minute "
        "or two.</div>",
    ]
    for key, label, status in rows:
        out.append(
            f'<div class="row" style="display:flex;gap:12px;align-items:center;justify-content:space-between">'
            f'<div>{_e(label)}<div class="dim">{_e(status)}</div></div>'
            f'<form method="post" action="/browse/reset" style="margin:0"><input type="hidden" name="which" value="{key}">'
            f'<input type="hidden" name="back" value="{back}"><button class="rb">Stop &amp; reload</button></form></div>'
        )
    out.append(
        f'<form method="post" action="/browse/reset" style="margin-top:10px"><input type="hidden" name="which" value="all">'
        f'<input type="hidden" name="back" value="{back}"><button class="rb">Restart everything</button></form>'
    )
    if state.get("reset_status"):
        out.append(f'<p class="dim">{_e(state["reset_status"])}</p>')
    use = state.get("memory") or {}
    if use:
        out.append(
            "<h2>Memory</h2>"
            f'<div class="dim">Graphics card: {_e(use.get("gpu"))} · Memory: {_e(use.get("ram"))}. Models load one at '
            "a time; when there isn't room, the one used longest ago is unloaded and loads again when next needed. "
            "The main recognizer is always kept.</div>"
            + "".join(f'<div class="row">{_e(line)}</div>' for line in use.get("loaded") or [])
            + (f'<p class="dim">{_e(use.get("note"))}</p>' if use.get("note") else "")
        )
    return "".join(out)


def _source_banner(config, state: dict) -> str:
    """Choose where transcripts come from: local transcription, or Bee's cloud."""
    source = getattr(config, "transcribe_source", "local")
    bee = (state or {}).get("bee") or {}
    token = getattr(config, "bee_token", "")
    hint = (token[:4] + "…" + token[-4:]) if len(token) > 10 else ("set" if token else "not set")
    last = bee.get("last_sync") or 0
    when = _when(last, "%d %b %H:%M") if last else "never"
    rows = [
        '<div style="border:1px solid #e9e9e6;border-radius:10px;padding:12px;margin-bottom:14px">',
        f'<b>Transcription source: {"BEE CLOUD" if source == "bee" else "LOCAL"}</b>',
        '<div class="dim" style="margin:4px 0 8px">Local: Myna transcribes bracelet/phone audio here. '
        'Bee cloud: pull finished transcripts and summaries from Bee\'s developer API — Bee does the '
        'transcription, Myna keeps a copy and writes its own notes and search. In Bee mode the recognizer, '
        'speaker models and speech gate don\'t load at all.</div>',
        '<form method="post" action="/browse/source" style="display:flex;gap:6px;margin:0 0 8px">',
        f'<input type="hidden" name="source" value="{"local" if source == "bee" else "bee"}">',
        f'<button>Switch to {"Local" if source == "bee" else "Bee cloud"}</button></form>',
    ]
    if source == "bee":
        pair = (state or {}).get("bee_pair") or {}
        if pair.get("active"):
            rows.append(f'<div class="dim" style="margin:4px 0 6px">{_e(pair.get("status") or "Connecting…")}</div>')
            if pair.get("svg"):
                rows.append('<div style="background:#fff;display:inline-block;padding:10px;border-radius:10px">'
                            + pair["svg"] + "</div>")
                rows.append(f'<div class="dim" style="margin:6px 0">Or open on this phone: '
                            f'<a href="{_e(pair.get("url"))}">{_e(pair.get("url"))}</a></div>')
            rows.append('<form method="post" action="/browse/bee/cancel" style="margin:4px 0"><button>Cancel</button></form>')
        elif not token:
            rows.append('<div class="dim" style="margin:4px 0 6px">Not connected. Connect scans a QR with the Bee app '
                        '(turn on Developer Mode: in the Bee app, tap the version 5 times), then approves — no token to copy.</div>')
            rows.append('<form method="post" action="/browse/bee/connect" style="margin:0 0 6px"><button>Connect Bee (QR)</button></form>')
        else:
            rows.append(f'<div class="dim" style="margin:4px 0">Connected · token {_e(hint)} · account '
                        f'{_e(bee.get("account") or "—")} · last sync {_e(when)} · {_e(bee.get("status") or "")}</div>')
            rows.append('<form method="post" action="/browse/source" style="display:flex;gap:6px;margin:0 0 6px">'
                        '<button name="sync" value="now">Sync now</button></form>'
                        '<form method="post" action="/browse/bee/connect" style="margin:0 0 6px"><button>Reconnect (QR)</button></form>')
        rows += [
            '<details style="margin-top:4px"><summary class="dim">Paste a token instead</summary>',
            '<form method="post" action="/browse/source" style="display:grid;gap:6px;margin:6px 0">',
            '<input name="bee_token" placeholder="Bee developer token" autocomplete="off">',
            '<div style="display:flex;gap:6px"><button name="sync" value="save">Save token</button>'
            '<button name="sync" value="now">Save &amp; sync now</button></div></form></details>',
        ]
    rows.append("</div>")
    return "".join(rows)


def _simple_banner(config) -> str:
    """The Simple-mode switch at the top of the Models page."""
    on = getattr(config, "simple_mode", True)
    speakers = getattr(config, "speakers", True)
    other = "off" if on else "on"
    label = "Full" if on else "Lean"
    sp_other = "off" if speakers else "on"
    return (
        '<div style="border:1px solid #e9e9e6;border-radius:10px;padding:12px;margin-bottom:14px">'
        f'<b>Lean layers: {"ON" if on else "OFF"}</b>'
        '<div class="dim" style="margin:4px 0 8px">One recognizer and one writing model — no recognizer panel and '
        'no extra checker / helper / summary / search models, no auto-tuning. Your chosen writing model (including '
        'the big hybrid one) and speaker separation still run; this only drops the redundant layers that were '
        'overwhelming the card. Turn it off to add the cross-checking panel and the extra models.</div>'
        f'<form method="post" action="/browse/simple" style="margin:0 0 8px">'
        f'<input type="hidden" name="simple" value="{other}"><button>Switch to {label}</button></form>'
        f'<b>Speaker separation: {"ON" if speakers else "OFF"}</b>'
        '<div class="dim" style="margin:4px 0 8px">Tell who is speaking apart on each clip (on the processor).</div>'
        f'<form method="post" action="/browse/simple" style="margin:0">'
        f'<input type="hidden" name="speakers" value="{sp_other}"><button>Turn speaker separation {sp_other}</button></form>'
        "</div>"
    )


def models_page(store: Store, config, state: dict, listening: list[str] | None = None,
                trust: dict | None = None, readout: dict | None = None) -> str:
    """Choose which models transcribe and write, and where each runs."""
    parts = [
        '<style>button{font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;'
        "padding:6px 12px;border:1px solid #e9e9e6;color:#e9e9e6;background:none;border-radius:99px;cursor:pointer}"
        ".pick{display:flex;gap:12px;align-items:center;justify-content:space-between}"
        "table{border-collapse:collapse;width:100%;margin-top:8px}td,th{text-align:left;padding:6px 10px 6px 0;"
        "border-bottom:1px solid #ffffff12;font-size:13px;vertical-align:top}th{font:11px ui-monospace,monospace;"
        "letter-spacing:.1em;text-transform:uppercase;color:#6a6c6e}</style>",
        _source_banner(config, state),
        _simple_banner(config),
        "<h2>Transcription</h2>",
        f'<div class="dim">{_e(state.get("transcriber"))} — {_e(state.get("transcriber_status"))}</div>',
        "<h2>Transcription runs on</h2>",
        _choices("stt_device", catalog.STT_DEVICES, config.stt_device),
        "<h2>Speech recognizers</h2>",
        _recognizers(config, listening or [], trust or {}, readout or {}),
        "<h2>Writing notes and answers</h2>",
        f'<div class="dim">{_e(state.get("writer"))} — {_e(state.get("writer_status"))}</div>',
        "<h2>Writing runs on</h2>",
        _choices("llm_device", catalog.LLM_DEVICES, config.llm_device),
        "<h2>Writing model</h2>",
    ]
    in_use = {
        "llm": (config.llm_repo, config.llm_file),
        "checker": (config.checker_repo, config.checker_file),
        "helper": (config.helper_repo, config.helper_file),
        "summary": (config.summary_repo, config.summary_file),
        "embedder": (config.embedder_repo, config.embedder_file),
    }
    labels = (("llm", "Main"), ("helper", "Helper"), ("summary", "Summary"), ("checker", "Checker"))
    parts.append(
        '<div class="dim">Each model can be given a job. <b>Main</b> writes notes and answers. <b>Helper</b> is a '
        "small, quick model that reads a lot of saved material and picks out what matters before the main model "
        "sees it. <b>Summary</b> writes the end-of-day summary (left unset, the main model does it). <b>Checker</b> is a "
        "light model that reads what the speech recognizers heard and makes sure it forms sensible sentences.</div>"
    )
    listed = False
    for repo, file, name, size, note in catalog.WRITING:
        buttons = []
        for role, label in labels:
            if in_use[role] == (repo, file):
                listed = listed or role == "llm"
                buttons.append(f'<span class="t">{label.upper()}</span>')
            else:
                buttons.append(
                    f'<form method="post" action="/browse/models" style="margin:0"><input type="hidden" name="role" value="{role}">'
                    f'<input type="hidden" name="repo" value="{_e(repo)}"><input type="hidden" name="file" value="{_e(file)}">'
                    f"<button>{label}</button></form>"
                )
        measured = speeds.get(file)
        speed = ""
        if measured.get("writing"):
            speed = f' · <b>{measured["writing"]:.0f} words/s</b> here'
            if measured.get("accepted"):
                speed += f' ({measured["accepted"]:.0%} of drafts kept)'
        parts.append(
            f'<div class="row pick"><div>{_e(name)} <span class="dim">{size:g} GB{speed}</span>'
            f'<div class="dim">{_e(note)}</div></div><div style="display:flex;gap:6px;align-items:center">{"".join(buttons)}</div></div>'
        )
    if not listed:
        parts.append(f'<div class="row pick"><div>{_e(config.llm_file)}<div class="dim">{_e(config.llm_repo)}</div></div><span class="t">MAIN</span></div>')
    parts.append(
        "<h2>Another model</h2>"
        '<div class="dim">Any GGUF model on Hugging Face: its repository and file name.</div>'
        '<form method="post" action="/browse/models" style="display:grid;gap:8px;margin-top:8px">'
        '<input name="repo" placeholder="owner/repository"><input name="file" placeholder="model-file.gguf">'
        '<div style="display:flex;gap:6px"><button name="role" value="llm">Main</button>'
        '<button name="role" value="helper">Helper</button><button name="role" value="summary">Summary</button></div></form>'
        '<p class="dim">A chosen model starts downloading straight away; progress shows above.</p>'
    )
    for role, title, status_key in (("checker", "Checker model", "checker_status"), ("helper", "Helper model", "helper_status"),
                                    ("summary", "Summary model", "summary_status"),
                                    ("embedder", "Search-by-meaning model", "embedder_status")):
        repo, file = in_use[role]
        shown = file.removesuffix(".gguf") if file else ("the main model" if role == "summary" else "not used")
        clear = (
            f'<form method="post" action="/browse/models" style="margin:0"><input type="hidden" name="clear" value="{role}">'
            "<button>Stop using</button></form>" if file else ""
        )
        parts.append(
            f"<h2>{title}</h2>"
            f'<div class="row pick"><div>{_e(shown)}<div class="dim">{_e(state.get(status_key))}</div></div>{clear}</div>'
            f"<h2>{title} runs on</h2>" + _choices(f"{role}_device", catalog.LLM_DEVICES, getattr(config, f"{role}_device"))
        )
    parts.insert(1, _reset_buttons(state, "models"))
    return _frame("models", "", "".join(parts), store.counts())


def playlist_text(store: Store) -> str:
    """The heard music as a plain list, one song per line, newest first."""
    return "\n".join(
        f"{song.get('title', '')} - {song.get('artist', '')}" for song in store.browse("song", limit=5000)
    )


def ask_page(store: Store) -> str:
    """Ask Myna on the computer: answers from what is saved here and the web."""
    body = """
<style>
#chat{min-height:120px}
.me{margin:10px 0 4px auto;max-width:80%;padding:8px 12px;border:1px solid #ffffff22;border-radius:12px;width:fit-content}
.her{margin:4px auto 10px 0;max-width:88%;padding:8px 12px;background:#ffffff0d;border-radius:12px;width:fit-content;white-space:pre-wrap}
#bar{display:flex;gap:8px;margin-top:14px}
#bar button,#new{font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;padding:8px 14px;
border:1px solid #e9e9e6;color:#e9e9e6;background:none;border-radius:99px;cursor:pointer}
</style>
<div id="chat"><p class="dim">Ask about anything Myna has heard or saved, or anything it can look up on the web.</p></div>
<form id="bar"><input id="q" placeholder="Ask Myna" autocomplete="off" autofocus><button>Ask</button></form>
<p><button id="new" type="button">New chat</button></p>
<script>
const esc = s => String(s ?? '').replace(/[&<>]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;'}[c]));
let history = [];
try { history = JSON.parse(localStorage.getItem('myna-ask') || '[]'); } catch (e) {}
const chat = document.getElementById('chat');
function draw(waiting) {
  if (!history.length && !waiting) return;
  chat.innerHTML = history.map(t => '<div class="' + (t.role === 'me' ? 'me' : 'her') + '">' + esc(t.text) +
    (t.searched ? '<div class="dim">looked up: ' + esc(t.searched) + '</div>' : '') + '</div>').join('') +
    (waiting ? '<div class="her dim">Thinking…</div>' : '');
  window.scrollTo(0, document.body.scrollHeight);
}
draw(false);
document.getElementById('new').onclick = () => { history = []; localStorage.removeItem('myna-ask'); location.reload(); };
document.getElementById('bar').onsubmit = async (event) => {
  event.preventDefault();
  const box = document.getElementById('q');
  const question = box.value.trim();
  if (!question) return;
  box.value = '';
  const before = history.slice(-10);
  history.push({role: 'me', text: question});
  draw(true);
  let turn;
  try {
    const reply = await fetch('/browse/ask.json', {method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({question, history: before})});
    if (reply.status === 401) { location.reload(); return; }
    const data = await reply.json();
    turn = {role: 'myna', text: data.reply || data.detail || 'Something went wrong.', searched: data.searched || ''};
  } catch (e) {
    turn = {role: 'myna', text: 'The server did not answer.'};
  }
  history.push(turn);
  history = history.slice(-200);
  localStorage.setItem('myna-ask', JSON.stringify(history));
  draw(false);
};
</script>"""
    return _frame("ask", "", body, store.counts())


def compare_page(store: Store, model: str, job: dict, hours: float, keep_days: int,
                 tune: dict | None = None, auto_tune: bool = True, together: dict | None = None) -> str:
    """Run the chosen transcription model over the kept recordings, and read
    off how each model did on the same audio."""
    since = (datetime.now() - timedelta(hours=hours)).timestamp()
    parts = [
        '<style>button{font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;'
        "padding:7px 14px;border:1px solid #e9e9e6;color:#e9e9e6;background:none;border-radius:99px;cursor:pointer}"
        "table{border-collapse:collapse;width:100%;margin-top:8px}td,th{text-align:left;padding:6px 10px 6px 0;"
        "border-bottom:1px solid #ffffff12;font-size:13px;vertical-align:top}th{font:11px ui-monospace,monospace;"
        "letter-spacing:.1em;text-transform:uppercase;color:#6a6c6e}select{font:inherit;padding:6px;background:#141517;"
        "color:#e9e9e6;border:1px solid #ffffff33;border-radius:8px}</style>",
        "<h2>Try the current model on what was recorded</h2>",
        f'<div class="dim">Transcription model in use: <b>{_e(model)}</b>. Change it on the Models tab, then run it over '
        f"the same recordings here to compare. Audio is kept {keep_days} days.</div>",
        '<form method="post" action="/browse/reprocess" style="display:flex;gap:8px;align-items:center;margin-top:10px">'
        '<select name="hours"><option value="1">the last hour</option><option value="6">the last 6 hours</option>'
        '<option value="24" selected>the last 24 hours</option><option value="72">the last 3 days</option>'
        '<option value="168">the last 7 days</option></select>'
        f'<button>Reprocess with {_e(model)}</button></form>',
    ]
    if job.get("running"):
        parts.append(f'<p>Running {_e(job.get("model"))}: {job.get("done", 0)} of {job.get("total", 0)} recordings…</p>')
    elif job.get("note"):
        parts.append(f'<p class="dim">{_e(job.get("note"))}</p>')

    if together is not None:
        parts.append("<h2>Models working together</h2>")
        state = "On" if together.get("on") else "Off"
        flip = "off" if together.get("on") else "on"
        parts.append(
            f'<div class="dim">{state}. Several different recognizers hear every clip. Where they agree, that is the '
            "transcript; where only one catches speech, it is kept; where they disagree, the light Checker model picks "
            "or pieces together the version that makes sense as a sentence, using your own words, and if that fails "
            "the version closest to all the others wins. Each recognizer is trusted more the closer it runs to the "
            "result, and that is learned as it goes.</div>"
            f'<form method="post" action="/browse/blend" style="margin-top:10px;display:flex;gap:8px;align-items:center">'
            f'<input type="hidden" name="blend" value="{flip}"><button>Turn {flip}</button>'
            f'<span class="dim">Also listening: {_e(together.get("partner"))} · '
            f'sense-checked by: {_e(together.get("arbiter")) or "nothing (set a Checker on the Models tab)"}</span></form>'
            '<form method="post" action="/browse/blend" style="margin-top:8px;display:flex;gap:6px;align-items:center">'
            '<span class="dim">Recognizers per clip:</span>'
            + "".join(
                f'<button name="count" value="{n}"{" disabled" if together.get("count") == n else ""}>{n}</button>'
                for n in (2, 3, 4)
            )
            + "</form>"
        )
        if together.get("trust"):
            parts.append("<table><tr><th>Recognizer</th><th>Trust, learned</th><th>Clips judged</th>"
                         "<th>Fillers heard in noise</th></tr>")
            for name, value in sorted(together["trust"].items(), key=lambda pair: -pair[1]):
                parts.append(f'<tr><td>{_e(name)}</td><td>{value:.0%}</td><td>{together["heard"].get(name, 0)}</td>'
                             f'<td>{together.get("phantoms", {}).get(name, 0)}</td></tr>')
            parts.append("</table>")
            parts.append(
                f'<div class="dim">{together.get("rescued", 0)} clips where one caught speech the other missed · '
                f'{together.get("reconciled", 0)} disagreements reconciled.</div>'
            )
        if together.get("words"):
            parts.append(f'<div class="dim" style="margin-top:8px">Your words, learned so far: {_e(", ".join(together["words"]))}</div>')

    tune = tune or {}
    parts.append("<h2>Automatic tuning</h2>")
    parts.append(
        '<div class="dim">'
        + ("On: while nothing is being recorded, " if auto_tune else "Off. When run, ")
        + "the server takes the hardest recent recordings (the quietest, and ones a model heard nothing in), runs every "
        "candidate model over them, and switches to the one that agrees best with the others while keeping up with "
        "real time. There is no correct transcript to mark against, so agreement between models is the measure.</div>"
        '<form method="post" action="/browse/tune" style="margin-top:10px"><button>Tune now</button></form>'
    )
    if tune.get("status"):
        parts.append(f'<p>{_e(tune.get("status"))}</p>')
    if tune.get("report"):
        parts.append("<table><tr><th>Model</th><th>Agreement</th><th>Speed</th><th>Words</th><th></th></tr>")
        for row in tune["report"]:
            if "note" in row:
                parts.append(f'<tr><td>{_e(row["model"])}</td><td colspan="4" class="dim">{_e(row["note"])}</td></tr>')
            else:
                parts.append(
                    f'<tr><td>{_e(row["model"])}</td><td>{row["agreement"]:.0%}</td><td>{row["speed"]:g}× real time</td>'
                    f'<td>{row["words"]}</td><td>{"CHOSEN" if row["chosen"] else ""}</td></tr>'
                )
        parts.append("</table>")

    readout = store.model_readout(since)
    parts.append(f"<h2>Readout, last {hours:g} hours</h2>")
    if not readout:
        parts.append('<p class="dim">No recordings kept yet. They appear as the phone sends audio.</p>')
    else:
        parts.append(
            "<table><tr><th>Model</th><th>Recordings</th><th>Audio</th><th>Time taken</th><th>Speed</th>"
            "<th>Words</th><th>Heard nothing in</th></tr>"
        )
        for row in readout:
            audio, took = row["audio"] or 0, row["took"] or 0
            speed = f"{audio / took:.0f}× real time" if took > 0 else ""
            parts.append(
                f'<tr><td>{_e(row["model"])}</td><td>{row["clips"]}</td><td>{audio / 60:.1f} min</td>'
                f'<td>{took:.1f} s</td><td>{speed}</td><td>{row["words"] or 0}</td><td>{row["empty"] or 0}</td></tr>'
            )
        parts.append("</table>")

    parts.append("<h2>Same recording, each model</h2>")
    for clip in store.side_by_side(since):
        lines = "".join(
            f'<div><span class="t">{_e(text["model"])}</span>{_e(text["text"]) or "<span class=dim>(nothing)</span>"}</div>'
            for text in clip["texts"]
        )
        parts.append(
            f'<div class="row"><div class="dim">{_e(_when(clip["at"], "%d %b %H:%M:%S"))} · {clip["seconds"]:.0f} s</div>{lines}</div>'
        )
    return _frame("compare", "", "".join(parts), store.counts())


def conversation_page(store: Store, record_id: str) -> str:
    """One conversation as written up: the note, what to do, memories, music."""
    talk = store.get("conversation", record_id)
    if talk is None:
        return _frame("conversation", "", '<p class="dim">That conversation is gone.</p>', store.counts())
    when = f'{_when(talk.get("startedAt"), "%A %d %B %Y, %H:%M")} to {_when(talk.get("endedAt"), "%H:%M")}'
    parts = [
        f'<h1>{_e(talk.get("emoji"))} {_e(talk.get("title"))}</h1>',
        f'<div class="dim">{_e(when)} · {_e(talk.get("category"))} · {talk.get("words", 0)} words</div>',
    ]
    if talk.get("gist"):
        parts.append(f'<p>{_e(talk.get("gist"))}</p>')
    if talk.get("overview"):
        parts.append(f'<h2>Overview</h2><p>{_e(talk.get("overview"))}</p>')
    for section in talk.get("sections") or []:
        parts.append(f'<h2>{_e(section.get("heading"))}</h2>' + "".join(
            f'<div class="row">{_e(bullet)}</div>' for bullet in section.get("bullets") or []))
    if talk.get("actionItems"):
        parts.append("<h2>To do</h2>")
        for item in talk["actionItems"]:
            detail = " · ".join(part for part in (item.get("owner"), item.get("due_at"), item.get("context")) if part)
            parts.append(f'<div class="row">☐ {_e(item.get("description"))}<div class="dim">{_e(detail)}</div></div>')
    if talk.get("events"):
        parts.append("<h2>Events</h2>" + "".join(
            f'<div class="row">{_e(event.get("title"))} <span class="dim">{_e(event.get("start"))}, '
            f'{_e(event.get("duration_minutes"))} min</span></div>' for event in talk["events"]))
    if talk.get("memories"):
        parts.append("<h2>Memories</h2>" + "".join(
            f'<div class="row">{_e(memory.get("content"))} <span class="dim">'
            f'{"worth remembering" if memory.get("category") == "interesting" else "about you"}</span></div>'
            for memory in talk["memories"]))
    if talk.get("songs"):
        parts.append("<h2>Music heard</h2>" + "".join(f'<div class="row">{_e(song)}</div>' for song in talk["songs"]))
    parts.append(f'<h2>Transcript</h2><pre>{_e(talk.get("transcript"))}</pre>')
    return _frame("conversation", "", "".join(parts), store.counts())


def experiment_page(store: Store, trying: dict, kind: str, query: str, repo: str, found: list[dict],
                    files: list[dict], problem: str, tried: list[dict], current: dict, trial_status: str) -> str:
    """Find a model on Hugging Face, run it over the last few hours, then keep it or throw it out."""
    from .catalog import SHERPA

    kind = "speech" if kind == "speech" else "writing"
    button = ('<style>button{font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;'
              "padding:6px 12px;border:1px solid #e9e9e6;color:#e9e9e6;background:none;border-radius:99px;cursor:pointer}"
              ".pick{display:flex;gap:12px;align-items:center;justify-content:space-between}"
              ".pair{display:grid;grid-template-columns:1fr 1fr;gap:10px}.pair>div{border:1px solid #2a2c30;border-radius:8px;padding:8px}"
              "select{background:#141517;color:#e9e9e6;border:1px solid #444;border-radius:6px;padding:4px}</style>")
    hours = ('<select name="hours">' + "".join(
        f'<option value="{h}"{" selected" if h == 3 else ""}>last {h} hour{"s" if h != 1 else ""}</option>'
        for h in (1, 3, 6, 12, 24, 48)) + "</select>")

    def try_form(fields: str, label: str = "Try it") -> str:
        return (f'<form method="post" action="/browse/experiment" style="display:flex;gap:6px;margin:0">'
                f'<input type="hidden" name="action" value="try"><input type="hidden" name="kind" value="{kind}">'
                f"{fields}{hours}<button>{label}</button></form>")

    parts = [button, "<h1>Experiment</h1>",
             '<div class="dim">Find a model on Hugging Face, run it over the last few hours of your own audio or '
             "conversations, and read what it did beside what the current model did. Keep it, or throw it out and "
             "try another. Nothing you have is changed until you keep one.</div>"]

    # -- the model being tried -------------------------------------------------------------
    if trying.get("model") or trying.get("file"):
        name = trying.get("model") or f'{trying.get("repo")} · {trying.get("file")}'
        progress = f'{trying.get("done", 0)} of {trying.get("total", 0)}' if trying.get("total") else ""
        status = trial_status if trying.get("kind") == "writing" and trying.get("running") else ""
        parts.append(f'<h2>Trying: {_e(name)}</h2><div class="dim">Over the last {trying.get("hours")} hours. '
                     f'{_e(progress)} {_e(trying.get("note"))} {_e(status)}</div>')
        controls = []
        finished_any = bool(trying.get("results"))
        if trying.get("running"):
            controls.append('<form method="post" action="/browse/experiment" style="margin:0">'
                            '<button name="action" value="stop">Stop</button></form>')
        elif finished_any:
            if trying.get("kind") == "speech":
                controls.append('<form method="post" action="/browse/experiment" style="margin:0">'
                                '<input type="hidden" name="action" value="keep"><button>✓ Keep it as the recognizer</button></form>')
            else:
                controls.append('<form method="post" action="/browse/experiment" style="display:flex;gap:6px;margin:0">'
                                '<input type="hidden" name="action" value="keep"><select name="role">'
                                '<option value="llm">as Main</option><option value="helper">as Helper</option>'
                                '<option value="summary">as Summary</option><option value="checker">as Checker</option>'
                                "</select><button>✓ Keep it</button></form>")
        controls.append('<form method="post" action="/browse/experiment" style="margin:0">'
                        '<button name="action" value="drop">✕ Throw it out</button></form>')
        parts.append(f'<div style="display:flex;gap:8px;margin:8px 0">{"".join(controls)}</div>')
        summary = trying.get("summary") or {}
        if trying.get("kind") == "speech" and summary.get("clips"):
            parts.append(
                f'<div class="row">{summary.get("clips", 0)} recordings · {summary.get("pace", 0)}x real time · '
                f'agrees with the current transcript {summary.get("agreement", 0):.0%} · heard speech the current one '
                f'missed in {summary.get("heard_more", 0)} · heard nothing where it heard something in '
                f'{summary.get("heard_less", 0)}</div>'
                f'<div class="pair" style="margin-top:6px"><div class="t">NOW ({_e(current.get("speech"))})</div>'
                '<div class="t">THIS MODEL</div></div>')
            for row in trying.get("results") or []:
                if row["before"] == row["after"]:
                    continue
                parts.append(f'<div class="dim">{_e(_when(row["at"], "%a %H:%M"))}</div><div class="pair">'
                             f'<div>{_e(row["before"]) or "<span class=dim>(nothing)</span>"}</div>'
                             f'<div>{_e(row["after"]) or "<span class=dim>(nothing)</span>"}</div></div>')
        if trying.get("kind") == "writing" and trying.get("results"):
            parts.append(f'<div class="row">{summary.get("conversations", 0)} conversations written up again in '
                         f'{summary.get("seconds", 0)} s. Left: as written now ({_e(current.get("llm"))}); right: this model.</div>')
            for row in trying["results"]:
                def card(rec: dict) -> str:
                    todo = "".join(f"<li>{_e(i.get('description'))}</li>" for i in rec.get("actionItems") or [])
                    mems = "".join(f"<li>{_e(m.get('content'))}</li>" for m in rec.get("memories") or [])
                    if rec.get("discarded"):
                        return '<span class="dim">Discarded as not worth keeping</span>'
                    return (f'<b>{_e(rec.get("emoji"))} {_e(rec.get("title"))}</b><div>{_e(rec.get("overview"))}</div>'
                            + (f'<div class="dim">To do</div><ul>{todo}</ul>' if todo else "")
                            + (f'<div class="dim">Remembered</div><ul>{mems}</ul>' if mems else ""))
                parts.append(f'<div class="dim">{_e(_when(row["at"], "%a %H:%M"))} · {row["took"]} s</div>'
                             f'<div class="pair"><div>{card(row["before"])}</div><div>{card(row["after"])}</div></div>')

    # -- suggested: no searching needed ------------------------------------------------------
    from .experiment import SUGGESTED_SPEECH, SUGGESTED_WRITING

    outcome = {}
    for row in tried:
        outcome.setdefault(str(row.get("model")), str(row.get("outcome") or ""))
    in_use = {current.get("speech")} | {v for k, v in current.items() if k != "speech"}

    def mark(model_key: str, file: str = "") -> str:
        if (file or model_key) in in_use:
            return '<span class="t">IN USE</span>'
        done = outcome.get(model_key)
        return f'<span class="dim">tried: {_e(done)}</span>' if done else ""

    tabs = "".join(
        f'<a href="/browse/experiment?kind={k}" style="margin-right:14px{";font-weight:600" if k == kind else ""}">{t}</a>'
        for k, t in (("writing", "Writing models"), ("speech", "Speech models")))
    parts.append(f"<h2>Worth trying</h2><div>{tabs}</div>"
                 '<div class="dim">Picked for this computer (12 GB graphics card, 128 GB memory). Press Try it; '
                 "nothing changes until you keep one.</div>")
    if kind == "speech":
        for model, name, why in SUGGESTED_SPEECH:
            busy = mark(model)
            action = busy if "IN USE" in busy else try_form(f'<input type="hidden" name="model" value="{_e(model)}">')
            parts.append(f'<div class="row pick"><div>{_e(name)} {busy if "tried" in busy else ""}'
                         f'<div class="dim">{_e(why)}</div></div>{action}</div>')
    else:
        for job, models in SUGGESTED_WRITING:
            parts.append(f'<div class="dim" style="margin-top:12px">{_e(job.upper())}</div>')
            for repo_id, file, name, gb, why in models:
                busy = mark(f"{repo_id}/{file}", file)
                fields = (f'<input type="hidden" name="repo" value="{_e(repo_id)}">'
                          f'<input type="hidden" name="file" value="{_e(file)}">')
                action = busy if "IN USE" in busy else try_form(fields)
                parts.append(f'<div class="row pick"><div>{_e(name)} <span class="dim">{gb:g} GB</span> '
                             f'{busy if "tried" in busy else ""}<div class="dim">{_e(why)}</div></div>{action}</div>')

    # -- or search ------------------------------------------------------------------------------
    parts.append("<h2>Or search Hugging Face</h2>")
    hint = ("Writing models are GGUF files: try “qwen3”, “gemma”, “phi”, “deepseek”, “mistral”."
            if kind == "writing" else
            "Speech models here are Whisper models made for faster-whisper (CTranslate2): try “whisper”, "
            "“distil”, “turbo”, “faster-whisper”.")
    parts.append(f'<form method="get" action="/browse/experiment" style="display:flex;gap:6px;margin:8px 0">'
                 f'<input type="hidden" name="kind" value="{kind}"><input name="q" value="{_e(query)}" '
                 f'placeholder="Search Hugging Face"><button>Search</button></form><div class="dim">{hint}</div>')
    if problem:
        parts.append(f'<p class="dim">{_e(problem)}</p>')
    if repo and kind == "writing":
        parts.append(f'<h2>{_e(repo)}</h2><div class="dim">Pick a file. Smaller files are faster and lighter, '
                     "a little less careful; about 4–5 bits per weight (Q4_K_M) is the usual balance. "
                     "Up to about 11 GB fits wholly on the graphics card.</div>")
        for row in files:
            fields = (f'<input type="hidden" name="repo" value="{_e(repo)}">'
                      f'<input type="hidden" name="file" value="{_e(row["file"])}">')
            parts.append(f'<div class="row pick"><div>{_e(row["file"])} <span class="dim">{row["gb"]:g} GB</span></div>'
                         f"{try_form(fields)}</div>")
        if not files and not problem:
            parts.append('<p class="dim">No GGUF files in this repository.</p>')
    for row in found:
        meta = f'{row["downloads"]:,} downloads · {row["likes"]} likes · updated {_e(row["updated"])}'
        link = f'<a href="https://huggingface.co/{_e(row["repo"])}">page</a>'
        if kind == "writing":
            action = f'<a href="/browse/experiment?kind=writing&q={quote(query)}&repo={quote(row["repo"])}">Files →</a>'
        else:
            action = try_form(f'<input type="hidden" name="model" value="{_e(row["repo"])}">')
        parts.append(f'<div class="row pick"><div>{_e(row["repo"])}<div class="dim">{meta} · {link}</div></div>{action}</div>')
    if query and not found and not problem:
        parts.append('<p class="dim">Nothing found. Try a shorter search.</p>')
    # -- tried before ---------------------------------------------------------------------------
    if tried:
        parts.append("<h2>Tried before</h2>")
        for row in tried[:20]:
            s = row.get("summary") or {}
            detail = (f'{s.get("agreement", 0):.0%} agreement, {s.get("pace", 0)}x real time' if row.get("kind") == "speech"
                      else f'{s.get("conversations", 0)} conversations in {s.get("seconds", 0)} s')
            parts.append(f'<div class="row">{_e(row.get("model"))} <span class="t">{_e(str(row.get("outcome")).upper())}</span>'
                         f'<div class="dim">{_e(_when(row.get("at"), "%d %b %H:%M"))} · {detail}</div></div>')
    return _frame("experiment", "", "".join(parts), store.counts())
