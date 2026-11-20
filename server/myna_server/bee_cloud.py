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


# -- QR login (app pairing), reverse-engineered from the official Bee CLI ----------------
#
# The CLI generates a NaCl box keypair, POSTs {app_id, publicKey} to
# auth.beeai-services.com/apps/pairing/request, shows a QR of
# bee.computer/connect#<requestId> for the phone to approve, then polls the same
# endpoint until it returns an encryptedToken sealed to our public key.

PAIRING_HOST = "https://auth.beeai-services.com"
PAIRING_PATH = "/apps/pairing/request"
PAIRING_APP_ID = "ph9fssu1kv1b0hns69fxf7rx"   # the Bee CLI's registered app id (prod)
CONNECT_URL = "https://bee.computer/connect#"


def _pairing_request(app_id: str, public_key_b64: str) -> dict:
    body = json.dumps({"app_id": app_id, "publicKey": public_key_b64}).encode()
    request = urllib.request.Request(PAIRING_HOST + PAIRING_PATH, data=body,
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as reply:
            data = json.loads(reply.read())
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise BeeError("Bee's pairing endpoint wasn't found.") from error
        raise BeeError(f"Bee pairing returned HTTP {error.code}.") from error
    except (urllib.error.URLError, ValueError, TimeoutError) as error:
        raise BeeError(f"Couldn't reach Bee to pair: {error}") from error
    if data.get("ok") is not True:
        raise BeeError("Bee sent an unexpected pairing response.")
    return data


def _decrypt_pairing_token(encrypted_b64: str, secret_key) -> str:
    import base64

    import nacl.public

    packed = base64.b64decode(encrypted_b64)
    if len(packed) < 1 + 24 + 32 + 16 or packed[0] != 1:
        raise BeeError("Bee sent a pairing token Myna couldn't read.")
    nonce, ephemeral, ciphertext = packed[1:25], packed[25:57], packed[57:]
    box = nacl.public.Box(secret_key, nacl.public.PublicKey(ephemeral))
    return box.decrypt(ciphertext, nonce).decode("utf-8").strip()


class Pairing:
    """One QR-login attempt: start it, show the URL/QR, poll until approved."""

    def __init__(self, app_id: str = PAIRING_APP_ID) -> None:
        import nacl.public

        self._secret = nacl.public.PrivateKey.generate()
        self.app_id = app_id
        self.public_key_b64 = __import__("base64").b64encode(bytes(self._secret.public_key)).decode()
        self.request_id = ""
        self.expires_at = ""
        self.url = ""
        self.token = ""

    def start(self) -> str | None:
        """Begin pairing. Returns the connect URL to show as a QR, or the token
        if Bee completed immediately."""
        data = _pairing_request(self.app_id, self.public_key_b64)
        status = data.get("status")
        if status == "completed":
            self.token = _decrypt_pairing_token((data.get("result") or {}).get("encryptedToken", ""), self._secret)
            return None
        if status == "expired":
            raise BeeError("The pairing request expired. Start again.")
        self.request_id = str(data.get("requestId") or "")
        self.expires_at = str(data.get("expiresAt") or "")
        self.url = CONNECT_URL + self.request_id
        return self.url

    def poll_once(self) -> bool:
        """Check once whether the phone has approved. True once a token is in hand."""
        if self.token:
            return True
        data = _pairing_request(self.app_id, self.public_key_b64)
        status = data.get("status")
        if status == "completed":
            self.token = _decrypt_pairing_token((data.get("result") or {}).get("encryptedToken", ""), self._secret)
            return True
        if status == "expired":
            raise BeeError("The pairing request expired. Start again.")
        return False


def qr_svg(url: str) -> str:
    """An inline SVG QR code for `url`."""
    import io

    import qrcode
    import qrcode.image.svg

    img = qrcode.make(url, image_factory=qrcode.image.svg.SvgPathImage, box_size=10, border=2)
    buf = io.BytesIO()
    img.save(buf)
    svg = buf.getvalue().decode("utf-8")
    return svg[svg.index("<svg"):]
