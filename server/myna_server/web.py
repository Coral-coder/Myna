"""Looking things up on the web for the server's Ask tab: the top search
results for a query, and the text of the first result's page. Only the search
query leaves the computer."""

from __future__ import annotations

import html as html_lib
import re
import urllib.parse
import urllib.request

_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"


def _get(url: str, timeout: float = 12, limit: int = 3_000_000) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": _AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as reply:
        raw = reply.read(limit)
    return raw.decode("utf-8", errors="replace")


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", html_lib.unescape(re.sub(r"<[^>]+>", "", text))).strip()


def parse_results(page: str, limit: int = 5) -> list[tuple[str, str, str]]:
    """(title, snippet, link) for each result on a DuckDuckGo HTML results page."""
    links = re.findall(r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', page, re.S)
    snippets = re.findall(r'class="result__snippet"[^>]*>(.*?)</a>', page, re.S)
    out = []
    for (link, title), snippet in list(zip(links, snippets))[:limit]:
        link = html_lib.unescape(link)
        if link.startswith("//"):
            link = "https:" + link
        wrapped = urllib.parse.parse_qs(urllib.parse.urlparse(link).query).get("uddg")
        out.append((_clean(title), _clean(snippet), wrapped[0] if wrapped else link))
    return out


def readable(page: str) -> str:
    """A page's text with scripts, styles and markup removed."""
    for pattern in (r"<script[\s\S]*?</script>", r"<style[\s\S]*?</style>", r"<head[\s\S]*?</head>",
                    r"<nav[\s\S]*?</nav>", r"<footer[\s\S]*?</footer>"):
        page = re.sub(pattern, " ", page, flags=re.I)
    return _clean(page)


def lookup(query: str) -> str:
    """What the web says about `query`, as plain text; empty if nothing was found."""
    try:
        page = _get("https://html.duckduckgo.com/html/?q=" + urllib.parse.quote(query))
    except Exception:
        return ""
    results = parse_results(page)
    if not results:
        return ""
    lines = [f"{index + 1}. {title} — {snippet}" for index, (title, snippet, _) in enumerate(results)]
    first = results[0][2]
    if first.startswith(("https://", "http://")):
        try:
            text = readable(_get(first, timeout=10))
            if len(text) > 80:
                lines.append("From the first result's page: " + text[:1800])
        except Exception:
            pass
    return "\n".join(lines)[:4000]
