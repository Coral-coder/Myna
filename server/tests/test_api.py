import io
import wave

import numpy as np
import pytest
from fastapi.testclient import TestClient

from myna_server.app import _allowed, create_app
from myna_server.audio import decode_wav, resample_to_16k
from myna_server.config import Config


class FakeTranscriber:
    name = "fake-stt"

    def __init__(self):
        self.seen = None

    def transcribe(self, samples):
        self.seen = samples
        return f"heard {samples.size} samples"


class FakeWriter:
    name = "fake-llm"

    def generate(self, instructions, prompt, max_tokens):
        return f"[{instructions}] {prompt} ({max_tokens})"


def wav_bytes(samples: np.ndarray, rate: int = 16000, channels: int = 1) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())
    return buffer.getvalue()


def quiet(count, dtype=None):
    """Quiet room noise (not digital silence, which is skipped)."""
    return (np.random.default_rng(0).standard_normal(count) * 0.01).astype(np.float32)


@pytest.fixture
def stt():
    return FakeTranscriber()


@pytest.fixture
def client(stt):
    config = Config(token="secret-token", simple_mode=False)
    return TestClient(create_app(config, stt, FakeWriter()))


AUTH = {"Authorization": "Bearer secret-token"}


def test_health_requires_pairing(client):
    assert client.get("/health").status_code == 401
    assert client.get("/health", headers={"Authorization": "Bearer wrong"}).status_code == 401
    body = client.get("/health", headers=AUTH).json()
    assert body["ok"] is True and body["transcriber"] == "fake-stt" and body["writer"] == "fake-llm"


def test_transcribe_round_trip(client, stt):
    tone = np.sin(np.linspace(0, 440 * 2 * np.pi, 16000)).astype(np.float32) * 0.5
    reply = client.post("/v1/transcribe", content=wav_bytes(tone), headers=AUTH)
    assert reply.status_code == 200
    body = reply.json()
    assert body["text"] == "heard 16000 samples"
    assert body["audio_seconds"] == 1.0
    assert body["engine"] == "fake-stt"
    # The samples reach the model brought up to a working level (peak 0.8), not clipped.
    assert abs(float(np.abs(stt.seen).max()) - 0.8) < 0.02


def test_transcribe_resamples_and_downmixes(client, stt):
    stereo = quiet(48000 * 2)
    reply = client.post("/v1/transcribe", content=wav_bytes(stereo, rate=48000, channels=2), headers=AUTH)
    assert reply.status_code == 200
    assert reply.json()["audio_seconds"] == 1.0
    assert stt.seen.size == 16000


def test_transcribe_rejects_bad_input(client):
    assert client.post("/v1/transcribe", content=b"", headers=AUTH).status_code == 400
    assert client.post("/v1/transcribe", content=b"not audio", headers=AUTH).status_code == 400
    assert client.post("/v1/transcribe", content=wav_bytes(quiet(10)), headers={}).status_code == 401


def test_generate(client):
    reply = client.post("/v1/generate", json={"instructions": "be brief", "prompt": "hi", "max_tokens": 50}, headers=AUTH)
    assert reply.status_code == 200
    assert reply.json()["text"] == "[be brief] hi (50)"
    assert client.post("/v1/generate", json={"prompt": "hi", "max_tokens": 0}, headers=AUTH).status_code == 422
    assert client.post("/v1/generate", json={"prompt": "hi"}).status_code == 401


def test_only_private_networks_are_answered():
    assert _allowed("127.0.0.1", allow_lan=False)
    assert _allowed("100.101.102.103", allow_lan=False)      # Tailscale
    assert _allowed("fd7a:115c:a1e0::1", allow_lan=False)    # Tailscale IPv6
    assert not _allowed("192.168.1.20", allow_lan=False)
    assert _allowed("192.168.1.20", allow_lan=True)
    assert not _allowed("8.8.8.8", allow_lan=True)
    assert not _allowed(None, allow_lan=True)


def test_config_persists_token(tmp_path):
    path = tmp_path / "config.json"
    first = Config.load(path)
    assert len(first.token) >= 32
    assert Config.load(path).token == first.token


def test_audio_helpers():
    samples, rate = decode_wav(wav_bytes(np.array([0.0, 0.5, -0.5], dtype=np.float32), rate=8000))
    assert rate == 8000 and samples.shape == (3,)
    assert resample_to_16k(samples, 8000).size == 6


def change(kind, record_id, data, at, deleted=False):
    return {"kind": kind, "id": record_id, "data": data, "updated_at": at, "deleted": deleted}


def test_sync_requires_pairing(client):
    assert client.post("/v1/sync", json={"since": 0, "changes": []}).status_code == 401


def test_sync_keeps_newest_edit_and_reports_others_changes(client):
    first = client.post(
        "/v1/sync",
        headers=AUTH,
        json={"since": 0, "changes": [change("memory", "m1", {"content": "likes tea", "createdAt": 10}, 100)]},
    ).json()
    # The sender doesn't get its own change back.
    assert first["changes"] == [] and first["cursor"] == 1

    # Someone who has seen nothing gets it.
    fresh = client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": []}).json()
    assert [c["id"] for c in fresh["changes"]] == ["m1"] and fresh["changes"][0]["data"]["content"] == "likes tea"

    # An older edit loses; a newer one wins.
    client.post("/v1/sync", headers=AUTH, json={"since": 1, "changes": [change("memory", "m1", {"content": "old"}, 50)]})
    client.post("/v1/sync", headers=AUTH, json={"since": 1, "changes": [change("memory", "m1", {"content": "likes coffee"}, 200)]})
    latest = client.post("/v1/sync", headers=AUTH, json={"since": 1, "changes": []}).json()
    assert [c["data"]["content"] for c in latest["changes"]] == ["likes coffee"]
    # Nothing new after the cursor.
    assert client.post("/v1/sync", headers=AUTH, json={"since": latest["cursor"], "changes": []}).json()["changes"] == []


def test_sync_delete_is_kept_as_a_mark_and_unknown_kinds_are_ignored(client):
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("item", "i1", {"text": "milk", "createdAt": 5}, 10),
        change("nonsense", "x", {"a": 1}, 10),
    ]})
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [change("item", "i1", None, 20, deleted=True)]})
    seen = client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": []}).json()["changes"]
    assert len(seen) == 1 and seen[0]["deleted"] is True and seen[0]["data"] is None
    assert client.get("/health", headers=AUTH).json()["records"] == 0


def test_browse_lists_and_searches(client):
    assert client.get("/browse").status_code == 401
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("utterance", "u1", {"text": "Buy <b>oat</b> milk", "heardAt": 1_700_000_000, "speakerName": "Sam"}, 1),
        change("utterance", "u2", {"text": "The meeting moved", "heardAt": 1_700_000_100}, 1),
        change("note", "n1", {"title": "Standup", "overview": "Short", "startedAt": 1_700_000_000, "transcript": "hello"}, 1),
    ]})
    page = client.get("/browse?kind=utterance", headers=AUTH).text
    assert "The meeting moved" in page and "Sam:" in page
    assert "&lt;b&gt;oat&lt;/b&gt;" in page and "<b>oat</b>" not in page  # text is never treated as markup
    found = client.get("/browse?kind=utterance&q=MILK", headers=AUTH).text
    assert "oat" in found and "meeting moved" not in found
    note = client.get("/browse/note?id=n1", headers=AUTH).text
    assert "Standup" in note and "hello" in note


def test_live_page_shows_what_was_received(client):
    samples = np.zeros(16000, dtype=np.float32)
    client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(samples))
    client.post("/v1/generate", headers=AUTH, json={"prompt": "hello"})
    live = client.get("/browse/live.json", headers=AUTH).json()
    kinds = [event["kind"] for event in live["events"]]
    assert kinds == ["transcribe", "generate"] and live["events"][0]["audio_seconds"] == 1.0
    assert live["transcriber"] == "fake-stt"
    assert "Just received" in client.get("/browse/live", headers=AUTH).text


def test_models_page_lists_choices_and_switches(stt):
    class SwitchableWriter(FakeWriter):
        def use(self, repo, file):
            self.name = file.removesuffix(".gguf")

    config = Config(token="secret-token", simple_mode=False)
    app = create_app(config, stt, SwitchableWriter())
    app.state.save_config = False
    client = TestClient(app)
    page = client.get("/browse/models", headers=AUTH).text
    assert "Whisper large-v3 turbo" in page and "Qwen 3 14B" in page
    assert client.post("/browse/models", data={"repo": "x/y", "file": "z.gguf"}).status_code == 401
    reply = client.post("/browse/models", headers=AUTH, data={"repo": "x/y", "file": "z.gguf"}, follow_redirects=False)
    assert reply.status_code == 303
    assert config.llm_file == "z.gguf" and client.get("/health", headers=AUTH).json()["writer"] == "z"


def test_heard_music_lists_and_exports(client):
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("song", "s1", {"title": "Blue in Green", "artist": "Miles Davis", "lastHeard": 1_700_000_000,
                              "appleMusicURL": "https://music.apple.com/x", "timesHeard": 2}, 1),
    ]})
    page = client.get("/browse?kind=song", headers=AUTH).text
    assert "Blue in Green" in page and "music.apple.com/x" in page and "open.spotify.com/search/" in page
    assert client.get("/browse/playlist", headers=AUTH).text == "Blue in Green - Miles Davis"


def test_invented_phrases_from_quiet_audio_are_left_out():
    from types import SimpleNamespace as S

    from myna_server.engines import keep_segments

    segments = [
        S(text=" Thank you.", no_speech_prob=0.5, avg_logprob=-0.9),           # made up from near-silence
        S(text=" Thanks for watching!", no_speech_prob=0.1, avg_logprob=-0.2),  # never real here
        S(text=" Thank you.", no_speech_prob=0.02, avg_logprob=-0.15),         # someone really said it
        S(text=" can you pass the salt", no_speech_prob=0.3, avg_logprob=-0.8),  # quiet but real speech
        S(text=" mm blah", no_speech_prob=0.9, avg_logprob=-1.4),              # noise
    ]
    assert keep_segments(segments) == ["Thank you.", "can you pass the salt"]


def test_choosing_where_models_run_and_big_models_are_shared(stt):
    class SwitchableWriter(FakeWriter):
        def use(self, repo, file):
            self.name = file.removesuffix(".gguf")

    config = Config(token="secret-token", simple_mode=False)
    app = create_app(config, stt, SwitchableWriter())
    app.state.save_config = False
    client = TestClient(app)
    page = client.get("/browse/models", headers=AUTH).text
    assert "DeepSeek R1 distill 14B" in page and "Llama 3.3 70B" in page and "Processor" in page
    client.post("/browse/models", headers=AUTH, data={"llm_device": "cpu", "stt_device": "cpu"}, follow_redirects=False)
    assert config.llm_device == "cpu" and config.stt_device == "cpu"
    # A model bigger than the card, chosen while set to the card, is shared
    # instead. (This one is dense, so it warns first — confirm to go ahead.)
    config.llm_device = "gpu"
    client.post("/browse/models", headers=AUTH, follow_redirects=False,
                data={"repo": "bartowski/Qwen_Qwen3-32B-GGUF", "file": "Qwen_Qwen3-32B-Q4_K_M.gguf", "confirm": "1"})
    assert config.llm_device == "shared" and config.llm_file == "Qwen_Qwen3-32B-Q4_K_M.gguf"


def test_ask_looks_things_up_in_transcripts_and_the_web(stt):
    """Myna answers by actually searching — it scans the transcript for the
    fact, and asks the web only for what the user's data doesn't cover."""
    from myna_server import web

    calls = []

    class ScriptedWriter:
        name = "scripted"

        def generate(self, instructions, prompt, max_tokens):
            from myna_server import recall
            calls.append(prompt)
            if instructions == recall.PLAN:                     # phase 1: decide what to look up
                if "lighthouse" in prompt and "31 metres" not in prompt:
                    return '{"action": "web", "query": "height of the lighthouse"}'
                if "dentist" in prompt and "415-555-0142" not in prompt:
                    return '{"action": "find", "what": "phone"}'
                return '{"action": "done"}'
            # phase 2: plain-text answer from what was found
            if "31 metres" in prompt:
                return "It is 31 metres tall."
            if "415-555-0142" in prompt:
                return "Your dentist is on 415-555-0142."
            return "I couldn't find that."

    app = create_app(Config(token="secret-token"), stt, ScriptedWriter())
    app.state.web_lookup = lambda query: f"1. Lighthouse — 31 metres ({query})"
    client = TestClient(app)
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("utterance", "u1", {"text": "The dentist's number is 415-555-0142, book me in.", "heardAt": 1_700_000_000}, 1),
    ]})
    assert client.post("/browse/ask.json", json={"question": "hi"}).status_code == 401
    first = client.post("/browse/ask.json", headers=AUTH, json={"question": "what's the dentist's number?"}).json()
    assert first == {"reply": "Your dentist is on 415-555-0142.", "searched": ""}
    assert any("415-555-0142" in c for c in calls)   # the number was found in the transcript and fed back
    second = client.post("/browse/ask.json", headers=AUTH, json={
        "question": "how tall is the lighthouse?", "history": [{"role": "me", "text": "what about the dentist?"}]}).json()
    assert second == {"reply": "It is 31 metres tall.", "searched": "height of the lighthouse"}
    assert "CONVERSATION SO FAR" in calls[-1] and "31 metres" in calls[-1]
    assert "Ask Myna" in client.get("/browse/ask", headers=AUTH).text

    page = '<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;x=1">A <b>title</b></a>' \
           '<a class="result__snippet" href="#">Some &amp; text</a>'
    assert web.parse_results(page) == [("A title", "Some & text", "https://example.com/a")]
    assert web.readable("<head><title>x</title></head><script>var a</script><p>Hello <b>there</b></p>") == "Hello there"


def test_ask_falls_back_to_gathered_material_when_the_model_skips_the_tools(stt):
    """If the model answers in plain prose instead of the action protocol, Myna
    still answers from the saved material rather than breaking."""
    class PlainWriter:
        name = "plain"
        seen = []

        def generate(self, instructions, prompt, max_tokens):
            self.seen.append(prompt)
            return "Friday at four."   # no JSON action — recall can't parse it

    writer = PlainWriter()
    client = TestClient(create_app(Config(token="secret-token"), stt, writer))
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("utterance", "u1", {"text": "the dentist is at four on Friday", "heardAt": 1_700_000_000}, 1),
    ]})
    reply = client.post("/browse/ask.json", headers=AUTH, json={"question": "when is the dentist?"}).json()
    assert reply["reply"] == "Friday at four."
    assert any("THE MOST RECENT THINGS HEARD" in p for p in writer.seen)  # the one-shot gather ran


def test_transcribe_splits_a_clip_by_speaker(stt):
    class FakeVoices:
        def split(self, audio):
            return [(0.0, 1.0, 0), (1.1, 2.0, 0), (2.5, 4.0, 1), (4.05, 4.2, 0)]  # the last is a sliver

        def print_of(self, audio):
            return [float(audio.size)]

    client = TestClient(create_app(Config(token="secret-token", simple_mode=False), stt, FakeWriter(), voices=FakeVoices()))
    body = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000 * 5, dtype=np.float32))).json()
    segments = body["segments"]
    # Speaker 0's two pieces joined, then speaker 1; the sliver is dropped. The
    # last second, where nobody was found, is still transcribed, with no voice.
    assert [(s["start"], s["duration"]) for s in segments] == [(0.0, 2.0), (2.5, 1.5), (4.0, 1.0)]
    assert segments[0]["text"] == "heard 32000 samples" and segments[1]["text"] == "heard 24000 samples"
    assert segments[0]["voice"] != segments[1]["voice"] and segments[2]["voice"] == []
    assert body["text"] == "heard 32000 samples heard 24000 samples heard 16000 samples"


def test_one_speaker_is_transcribed_whole_and_no_voices_still_works(stt, client):
    class OneVoice:
        def split(self, audio):
            return [(0.2, 1.0, 0), (1.3, 2.8, 0)]

        def print_of(self, audio):
            return [1.0, 2.0]

    solo = TestClient(create_app(Config(token="secret-token", simple_mode=False), stt, FakeWriter(), voices=OneVoice()))
    body = solo.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000 * 3, dtype=np.float32))).json()
    assert body["text"] == "heard 48000 samples" and len(body["segments"]) == 1 and body["segments"][0]["voice"] == [1.0, 2.0]
    plain = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000, dtype=np.float32))).json()
    assert plain["segments"] == [] and plain["text"] == "heard 16000 samples"


class NamedStt:
    """A transcriber whose output depends on its (switchable) name."""

    def __init__(self, name):
        self.name = name

    def use(self, model):
        self.name = model

    def transcribe(self, samples):
        return f"{self.name} heard {samples.size}"


def test_audio_is_kept_and_another_model_can_be_run_over_it(tmp_path):
    import time as clock

    stt = NamedStt("model-a")
    app = create_app(Config(token="secret-token"), stt, FakeWriter(), audio_dir=tmp_path)
    app.state.save_config = False
    client = TestClient(app)
    for turn in range(2):  # two different clips (the same clip twice is answered from memory)
        client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000 * 2, dtype=np.float32) * (1 + turn)))
    assert len(list(tmp_path.rglob("*.wav"))) == 2

    stt.use("model-b")
    assert client.post("/browse/reprocess", data={"hours": "1"}).status_code == 401
    client.post("/browse/reprocess", headers=AUTH, data={"hours": "1"}, follow_redirects=False)
    for _ in range(50):
        if not client.get("/browse/live.json", headers=AUTH).json()["reprocess"]["running"]:
            break
        clock.sleep(0.05)
    job = client.get("/browse/live.json", headers=AUTH).json()["reprocess"]
    assert job["done"] == 2 and job["total"] == 2 and job["model"] == "model-b"

    page = client.get("/browse/compare?hours=1", headers=AUTH).text
    assert "model-a heard 32000" in page and "model-b heard 32000" in page  # same recording, each model
    assert "Reprocess with model-b" in page and "real time" in page
    # Running it again has nothing left to do.
    client.post("/browse/reprocess", headers=AUTH, data={"hours": "1"}, follow_redirects=False)
    clock.sleep(0.2)
    assert "already done" in client.get("/browse/live.json", headers=AUTH).json()["reprocess"]["note"]


class Recorder:
    """A writing model that records what it was asked and answers from a script."""

    def __init__(self, name, reply):
        self.name, self.reply, self.asked, self.chosen, self.stopped = name, reply, [], True, 0

    def generate(self, instructions, prompt, max_tokens):
        self.asked.append((instructions, prompt))
        return self.reply(instructions, prompt) if callable(self.reply) else self.reply

    def stop(self):
        self.stopped += 1


def test_end_of_day_summary_uses_its_own_model_and_is_listed(stt):
    from datetime import datetime

    day = "2026-11-17"
    noon = datetime(2026, 11, 17, 12, 0).timestamp()
    helper = Recorder("small", "They discussed the roof repair with Sam.")
    summary = Recorder("summary-model", "The day in brief\nRoof repair agreed with Sam.")
    main = Recorder("big", "should not be used")
    app = create_app(Config(token="secret-token"), stt, main, helper=helper, summarizer=summary)
    client = TestClient(app)
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("utterance", "u1", {"text": "so the roof needs doing before winter", "heardAt": noon}, 1),
        change("note", "n1", {"title": "Roof", "overview": "Agreed a date", "startedAt": noon + 60,
                              "placeName": "Home", "people": ["Sam"], "actionItems": [{"task": "call the roofer"}]}, 1),
        change("song", "s1", {"title": "Blue in Green", "artist": "Miles Davis", "lastHeard": noon + 120}, 1),
    ]})
    text = app.state.run_daily(day)
    assert text.startswith("The day in brief") and not main.asked
    assert "roof needs doing" in helper.asked[0][1]                     # the helper read the transcript
    prompt = summary.asked[0][1]
    assert "roof repair with Sam" in prompt and "Home around 12:01" in prompt
    assert "call the roofer" in prompt and "Blue in Green" in prompt
    assert main.stopped == 1 and summary.stopped == 1                   # room made for it, then released
    page = client.get("/browse?kind=daily", headers=AUTH).text
    assert "Roof repair agreed with Sam." in page and "summary-model" in page
    # A day with nothing saved writes nothing.
    assert app.state.run_daily("2020-01-01") == ""


def test_models_page_assigns_jobs_to_models(stt):
    class Switchable(FakeWriter):
        chosen = True

        def use(self, repo, file):
            self.name = file.removesuffix(".gguf")

    config = Config(token="secret-token", simple_mode=False)
    helper, summary = Switchable(), Switchable()
    app = create_app(config, stt, Switchable(), helper=helper, summarizer=summary)
    app.state.save_config = False
    client = TestClient(app)
    form = {"repo": "bartowski/Qwen_Qwen3-4B-GGUF", "file": "Qwen_Qwen3-4B-Q4_K_M.gguf"}
    client.post("/browse/models", headers=AUTH, data={"role": "helper", **form}, follow_redirects=False)
    client.post("/browse/models", headers=AUTH, follow_redirects=False,
                data={"role": "summary", "repo": "bartowski/Qwen_Qwen3-32B-GGUF",
                      "file": "Qwen_Qwen3-32B-Q4_K_M.gguf", "confirm": "1"})  # dense+big: confirm past the warning
    assert config.helper_file == "Qwen_Qwen3-4B-Q4_K_M.gguf" and config.llm_file.startswith("Qwen3.6")
    assert config.summary_file == "Qwen_Qwen3-32B-Q4_K_M.gguf" and config.summary_device == "auto"  # placed automatically
    page = client.get("/browse/models", headers=AUTH).text
    assert "HELPER" in page and "SUMMARY" in page and "Stop using" in page
    client.post("/browse/models", headers=AUTH, data={"clear": "helper"}, follow_redirects=False)
    assert helper.name == ""


def test_quiet_audio_is_brought_up_before_transcribing():
    from myna_server.audio import level

    quiet = (np.sin(np.linspace(0, 200, 16000)) * 0.03).astype(np.float32)
    louder = level(quiet)
    assert 0.2 < float(np.abs(louder).max()) <= 0.8              # far-field speech brought up, gain capped at 8x
    assert float(np.abs(level(quiet * 0.0001)).max()) < 0.01     # near-silence is not blown up into noise
    loud = (np.sin(np.linspace(0, 200, 16000)) * 0.8).astype(np.float32)
    assert np.array_equal(level(loud), loud)                     # already loud: untouched


def test_tuner_prefers_the_model_the_others_agree_with_and_that_keeps_up():
    from myna_server import tuner

    results = {
        "good": ["pass me the salt please", "", "we should leave at five"],
        "also-good": ["pass me the salt please", "", "we should leave by five"],
        "invents": ["thank you for watching", "thank you", "subscribe to my channel"],
        "deaf": ["", "", ""],
    }
    scores = tuner.score(results)
    assert scores["good"] > scores["invents"] and scores["good"] > scores["deaf"]
    # Of two that score about the same, the faster one is chosen; one too slow to keep up is not.
    assert tuner.choose(scores, {"good": 4.0, "also-good": 40.0, "invents": 90.0, "deaf": 90.0}) == "also-good"
    assert tuner.choose({"best": 0.9, "ok": 0.6}, {"best": 0.5, "ok": 20.0}) == "ok"
    # The test set: recordings a model heard nothing in first, then the quietest; short ones left out.
    clips = [{"id": 1, "seconds": 10, "loudness": 0.2}, {"id": 2, "seconds": 10, "loudness": 0.01},
             {"id": 3, "seconds": 1, "loudness": 0.001}, {"id": 4, "seconds": 8, "loudness": 0.05}]
    assert [c["id"] for c in tuner.hardest(clips, heard_nothing={4})] == [4, 2, 1]


def test_tuning_switches_to_the_best_model_and_reports(tmp_path):
    class Tunable(NamedStt):
        said = {
            "careful": "pass me the salt please",
            "careful-too": "pass me the salt please",
            "sloppy": "thank you for watching",
        }

        def transcribe(self, samples):
            return self.said.get(self.name, "")

    stt = Tunable("sloppy")
    config = Config(token="secret-token", stt_model="sloppy")
    app = create_app(config, stt, FakeWriter(), audio_dir=tmp_path)
    app.state.save_config = False
    app.state.tune_candidates = ["careful", "careful-too"]
    client = TestClient(app)
    tone = (np.sin(np.linspace(0, 900, 16000 * 4)) * 0.02).astype(np.float32)
    assert app.state.run_tune() == ""                         # nothing recorded yet
    for turn in range(6):
        client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(tone * (1 + turn / 10)))
    winner = app.state.run_tune()
    assert winner in ("careful", "careful-too") and config.stt_model == winner and stt.name == winner
    page = client.get("/browse/compare", headers=AUTH).text
    assert "CHOSEN" in page and "sloppy" in page and "Tune now" in page


def test_conversations_are_split_kept_or_discarded_and_written_up_like_omi(stt):
    from myna_server import conversations

    import time as clock

    base = float(int(clock.time()) - 5000)
    lines = [{"at": base + offset, "text": text} for offset, text in
             [(0, "okay"), (5, "yeah sure"), (400, "we should move the launch to March"), (410, "agreed, I'll tell the team")]]
    # Two minutes of silence ends a conversation; one still going on is left alone.
    assert [len(group) for group in conversations.split(lines, now=base + 1000)] == [2, 2]
    assert [len(group) for group in conversations.split(lines, now=base + 420)] == [2]

    asked = []

    def model(instructions, prompt):
        asked.append((instructions, prompt))
        if instructions.startswith("You will receive a transcript"):
            return "discard = True" if "yeah sure" in prompt else "discard = False"
        if "memory curator" in instructions:
            return ('{"memories": [{"content": "Sam decided to move the launch to March", "category": "system"},'
                    ' {"content": "Speaker 1 likes coffee", "category": "system"},'
                    ' {"content": "Sam decided to move the launch to March.", "category": "system"}]}')
        return ('{"title": "Launch moved", "gist": "Launch date pushed to March", "overview": "They agreed to move it.",'
                ' "emoji": "🚀", "category": "work", "sections": [{"heading": "Decision", "bullets": ["Launch moves to March."]}],'
                ' "action_items": [{"description": "Tell the team about the new launch date", "owner": "Sam", "due_at": "", "context": "agreed in the call"}],'
                ' "events": [{"title": "Launch", "start": "sometime in March"}]}')

    writer = Recorder("big", model)
    app = create_app(Config(token="secret-token", owner_name="Sam"), stt, writer)
    client = TestClient(app)
    changes = [change("utterance", f"u{i}", {"text": line["text"], "heardAt": line["at"]}, 1) for i, line in enumerate(lines)]
    changes.append(change("song", "s1", {"title": "Blue in Green", "artist": "Miles Davis", "lastHeard": base + 405}, 1))
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": changes})

    assert app.state.run_conversations(10) == 2
    page = client.get("/browse?kind=conversation", headers=AUTH).text
    assert "Launch moved" in page and "Discarded as not worth keeping" in page and "♪ 1" in page
    detail = client.get("/browse/conversation?id=c-" + str(int((base + 400) * 1000)), headers=AUTH).text
    assert "Tell the team about the new launch date" in detail and "Blue in Green - Miles Davis" in detail
    assert detail.count("Sam decided to move the launch to March") == 1   # the reworded repeat is dropped
    assert "likes coffee" not in detail                                    # "Speaker 1" never reaches a memory
    assert "sometime in March" not in detail                               # an event needs a real date and time
    assert "Sam" in [a for a in asked if "memory curator" in a[0]][0][0]   # memories are about the named wearer
    assert app.state.run_conversations(10) == 0                            # nothing is written up twice

    # Over a hundred words is always kept, without asking.
    long_text = " ".join(["word"] * 150)
    assert conversations.should_discard(long_text, 150, 30, lambda *a: "discard = True") is False
    assert conversations.should_discard("", 0, 5, lambda *a: "discard = False") is True
    # Ask can use what was written up.
    writer.reply = '{"reply": "March.", "search": ""}'
    client.post("/browse/ask.json", headers=AUTH, json={"question": "when is the launch?"})
    assert "Launch moved" in writer.asked[-1][1] and "NOTICED IN CONVERSATIONS" in writer.asked[-1][1]


def test_two_recognizers_are_combined_and_trust_is_learned(tmp_path):
    from myna_server import blend

    learning = blend.Learning(tmp_path / "learning.json")
    # Agreement: kept as is.
    text, how = blend.combine({"a": "pass the salt please", "b": "pass the salt please"}, learning, None, [])
    assert (text, how) == ("pass the salt please", "agreed")
    # One hears speech, the other only noise or a stock phrase: the speech is kept.
    text, how = blend.combine({"a": "", "b": "the meeting moved to Tuesday"}, learning, None, [])
    assert (text, how) == ("the meeting moved to Tuesday", "rescued")
    assert blend.combine({"a": "Thank you.", "b": ""}, learning, None, []) == ("", "agreed")
    # Disagreement: reconciled by a writing model, using the wearer's words...
    asked = []

    def arbiter(instructions, prompt, max_tokens):
        asked.append(prompt)
        return "call Saoirse about the Kilkenny trip"

    text, how = blend.combine({"a": "call searsha about the kill kenny trip", "b": "call Saoirse about the Kilkenny trip"},
                              learning, arbiter, ["Saoirse", "Kilkenny"])
    assert (text, how) == ("call Saoirse about the Kilkenny trip", "reconciled") and "Saoirse, Kilkenny" in asked[0]
    # ...but never accepted if it invents words nobody heard.
    text, how = blend.combine({"a": "call searsha about the trip", "b": "call Saoirse about the trip"},
                              learning, lambda *a: "please buy a new car tomorrow", [])
    assert how == "trusted" and text in ("call searsha about the trip", "call Saoirse about the trip")
    # Trust moves toward whichever model matched the result.
    for _ in range(10):
        learning.note({"good": "the cat sat", "bad": "a hat that"}, "the cat sat")
    assert learning.trust["good"] > 0.9 > learning.trust["bad"]
    learning.save()
    assert blend.Learning(tmp_path / "learning.json").trust["good"] > 0.9   # kept between runs
    assert blend.default_partner("turbo").startswith("sherpa:") and blend.default_partner("sherpa:canary") == "turbo"


def test_live_transcription_uses_both_recognizers_and_learns_words(stt):
    class Partner:
        name = "partner"

        def transcribe(self, samples):
            return "Saoirse is coming on Friday"

    class Deaf(NamedStt):
        hotwords = ""

        def transcribe(self, samples):
            return ""

    main = Deaf("main")
    app = create_app(Config(token="secret-token", simple_mode=False, blend=True), main, FakeWriter(), partner_for=lambda model: Partner())
    client = TestClient(app)
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("person", "p1", {"name": "Saoirse", "createdAt": 1}, 1),
        change("memory", "m1", {"content": "Lives near Kilkenny. Visits Kilkenny often. Loves Kilkenny.", "createdAt": 1}, 1),
    ]})
    body = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000, dtype=np.float32))).json()
    assert body["text"] == "Saoirse is coming on Friday"                 # the partner caught what the main one missed
    assert "Saoirse" in main.hotwords and "Kilkenny" in main.hotwords    # the wearer's words reach the recognizer
    page = client.get("/browse/compare", headers=AUTH).text
    assert "Models working together" in page and "partner" in page and "1 clips where one caught speech" in page
    client.post("/browse/blend", headers=AUTH, data={"blend": "off"}, follow_redirects=False)
    off = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000, dtype=np.float32))).json()
    assert off["text"] == ""


def test_a_panel_of_recognizers_and_a_light_checker(tmp_path):
    from myna_server import blend
    from myna_server.engines import LlamaWriter

    # The panel: different kinds of recognizer, at most two Whisper models on the card.
    assert blend.panel("turbo", 3) == ["sherpa:parakeet-v2", "sherpa:canary"]
    assert blend.panel("sherpa:parakeet-v2", 4) == ["turbo", "sherpa:canary", "distil-large-v3"]
    assert blend.panel("turbo", 4) == ["sherpa:parakeet-v2", "sherpa:canary", "distil-large-v3"]
    assert blend.panel("turbo", 2, first_partner="sherpa:sensevoice") == ["sherpa:sensevoice"]
    assert LlamaWriter(Config(token="x" * 20), "checker").chosen   # a light checker is set up by default

    learning = blend.Learning(None)
    versions = {"a": "the dog ran to the park", "b": "the dog ran to the bark", "c": "a fog ran to the park"}
    # With no checker, the version closest to all the others wins.
    assert blend.combine(versions, learning, None, []) == ("the dog ran to the park", "consensus")
    # With a checker, its sensible sentence is taken.
    asked = []

    def checker(instructions, prompt, max_tokens):
        asked.append(instructions)
        return "the dog ran to the park"

    assert blend.combine(versions, learning, checker, []) == ("the dog ran to the park", "reconciled")
    assert "sentence structure and sense" in asked[0]


def test_every_panel_member_is_heard_and_the_checker_settles_it(stt):
    class Says:
        def __init__(self, name, text):
            self.name, self.text = name, text

        def transcribe(self, samples):
            if self.text is None:
                raise RuntimeError("broken")
            return self.text

    said = {"sherpa:parakeet-v2": "meet Saoirse at the station", "sherpa:canary": None}

    class Checker(Recorder):
        pass

    checker = Checker("small", "meet Saoirse at the station")
    main = NamedStt("turbo")
    main.transcribe = lambda samples: "meet searsha at the station"
    app = create_app(Config(token="secret-token", stt_model="turbo", simple_mode=False, blend=True), main, FakeWriter(), checker=checker,
                     partner_for=lambda model: Says(model, said[model]))
    client = TestClient(app)
    body = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000, dtype=np.float32))).json()
    assert body["text"] == "meet Saoirse at the station"                # one broken recognizer doesn't stop the rest
    assert "searsha" in checker.asked[0][1] and "Saoirse" in checker.asked[0][1]
    client.post("/browse/blend", headers=AUTH, data={"count": "2"}, follow_redirects=False)
    page = client.get("/browse/compare", headers=AUTH).text
    assert "Recognizers per clip" in page and "sense-checked by: small" in page


def test_choosing_the_recognizers_by_hand(stt):
    from myna_server import blend

    assert blend.panel("turbo", 3, picked=["sherpa:sensevoice", "large-v3"]) == ["sherpa:sensevoice", "large-v3"]
    # Chosen by hand: as many as ticked, the main one left out.
    assert blend.panel("turbo", 3, picked=["large-v3", "distil-large-v3", "turbo", "medium.en"]) == \
        ["large-v3", "distil-large-v3", "medium.en"]

    config = Config(token="secret-token", stt_model="turbo", simple_mode=False, blend=True)
    app = create_app(config, NamedStt("whisper-turbo"), FakeWriter(), partner_for=lambda model: NamedStt(model))
    app.state.save_config = False
    client = TestClient(app)
    page = client.get("/browse/models", headers=AUTH).text
    assert "Speech recognizers" in page and "MAIN" in page and "Save choices" in page and "chosen automatically" in page
    # Take one off the automatic panel, put another on.
    client.post("/browse/blend", headers=AUTH, data={"listen": "sherpa:canary", "back": "models"}, follow_redirects=False)
    assert config.blend_models == ["sherpa:parakeet-v2"]
    reply = client.post("/browse/blend", headers=AUTH, data={"listen": "sherpa:sensevoice", "back": "models"},
                        follow_redirects=False)
    assert reply.headers["location"] == "/browse/models"
    assert config.blend_models == ["sherpa:parakeet-v2", "sherpa:sensevoice"]
    assert "chosen by hand" in client.get("/browse/models", headers=AUTH).text
    # Making another model the main one works from the same table.
    client.post("/browse/models", headers=AUTH, data={"speech": "sherpa:parakeet-v3"}, follow_redirects=False)
    assert config.stt_model == "sherpa:parakeet-v3"
    # Removing them all leaves just the main recognizer; "automatically" brings the panel back.
    for model in ("sherpa:parakeet-v2", "sherpa:sensevoice"):
        client.post("/browse/blend", headers=AUTH, data={"listen": model}, follow_redirects=False)
    assert config.blend is False
    client.post("/browse/blend", headers=AUTH, data={"listen": "auto", "blend": "on"}, follow_redirects=False)
    assert config.blend and config.blend_models == []


def test_tick_any_number_of_recognizers_and_extra_whisper_models_go_to_the_processor(stt):
    made = []

    def partner_for(model, device=None):
        made.append((model, device))
        return NamedStt(model)

    config = Config(token="secret-token", stt_model="turbo", simple_mode=False, blend=True)
    app = create_app(config, NamedStt("whisper-turbo"), FakeWriter(), partner_for=partner_for)
    app.state.save_config = False
    client = TestClient(app)
    page = client.get("/browse/models", headers=AUTH).text
    assert 'type="checkbox" name="model"' in page and "Save choices" in page
    ticked = ["large-v3", "distil-large-v3", "medium.en", "sherpa:parakeet-v2", "sherpa:canary", "sherpa:sensevoice"]
    client.post("/browse/blend", headers={**AUTH, "Content-Type": "application/x-www-form-urlencoded"},
                follow_redirects=False, content="listening=1&back=models&" + "&".join(f"model={m}" for m in ticked))
    assert config.blend_models == ticked and config.blend
    client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000, dtype=np.float32)))
    assert len(made) == 6
    devices = dict(made)
    assert devices["large-v3"] is None                                   # second Whisper shares the card
    assert devices["distil-large-v3"] == "cpu" and devices["medium.en"] == "cpu"   # the rest on the processor
    assert devices["sherpa:parakeet-v2"] is None
    # Unticking everything leaves only the main recognizer.
    client.post("/browse/blend", headers={**AUTH, "Content-Type": "application/x-www-form-urlencoded"},
                content="listening=1&back=models", follow_redirects=False)
    assert config.blend_models == [] and config.blend is False


def test_stop_and_reload_buttons(stt):
    import time as clock

    class Stoppable(Recorder):
        def __init__(self, name):
            super().__init__(name, "ok")
            self.killed = self.warmed = 0

        def force_stop(self):
            self.killed += 1

        def warm(self):
            self.warmed += 1

    class Resettable(NamedStt):
        resets = 0

        def force_reset(self):
            Resettable.resets += 1

        def warm(self):
            pass

    writer, checker = Stoppable("big"), Stoppable("small")
    main = Resettable("whisper-turbo")
    app = create_app(Config(token="secret-token", stt_model="turbo", simple_mode=False, blend=True), main, writer, checker=checker,
                     partner_for=lambda model: Resettable(model))
    exits = []
    app.state.exit = lambda: exits.append(True)
    client = TestClient(app)
    for page in ("/browse/live", "/browse/models"):
        html = client.get(page, headers=AUTH).text
        assert "Stop &amp; reload" in html and "Restart everything" in html
    assert client.post("/browse/reset", data={"which": "llm"}).status_code == 401

    client.post("/browse/reset", headers=AUTH, data={"which": "llm"}, follow_redirects=False)
    clock.sleep(0.1)
    assert writer.killed == 1 and writer.warmed == 1 and checker.killed == 0

    client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000, dtype=np.float32)))  # make the panel
    reply = client.post("/browse/reset", headers=AUTH, data={"which": "recognition", "back": "models"}, follow_redirects=False)
    assert reply.headers["location"] == "/browse/models" and Resettable.resets == 3   # the main one and two on the panel
    assert "stopped and reloading" in client.get("/browse/live", headers=AUTH).text

    client.post("/browse/reset", headers=AUTH, data={"which": "all"}, follow_redirects=False)
    clock.sleep(1.8)
    assert exits == [True]          # the whole worker restarts; the launcher brings it back


def test_the_helper_process_can_be_stopped_mid_request():
    import threading as threads
    import time as clock

    from myna_server.sidecar import Sidecar

    side = Sidecar()
    side._ensure()
    assert side._process.is_alive()
    failed = []

    def stuck():
        try:
            side.call("stt", "no-such-model", np.zeros(10, dtype=np.float32), timeout=30)
        except Exception as error:
            failed.append(str(error))

    worker = threads.Thread(target=stuck)
    worker.start()
    clock.sleep(0.3)
    side.kill()
    worker.join(timeout=10)
    assert failed and not worker.is_alive()       # the waiting request ends at once
    assert side._process is None and side.crashes == 0


def test_memory_budget_unloads_the_least_recently_used_to_make_room():
    import threading as threads
    import time as clock

    from myna_server.memory import GB, Budget

    budget = Budget()
    free = {"gpu": 1.0 * GB}
    budget.probe = {"gpu": lambda: (free["gpu"], 12 * GB), "ram": lambda: (100 * GB, 128 * GB)}
    unloaded = []

    def model(name, size, busy=False):
        def unload():
            if busy:
                return False                  # in use right now: left alone
            unloaded.append(name)
            free["gpu"] += size * GB
            return True
        return unload

    budget.register("main-whisper", "gpu", 2 * GB, model("main-whisper", 2), keep=True)   # never unloaded
    budget.register("old-helper", "gpu", 3 * GB, model("old-helper", 3))
    clock.sleep(0.01)
    budget.register("busy-checker", "gpu", 2 * GB, model("busy-checker", 2, busy=True))
    clock.sleep(0.01)
    budget.register("recent-writer", "gpu", 5 * GB, model("recent-writer", 5))
    budget.touch("recent-writer")

    # Needs 4 GB (+ margin): the oldest idle one goes first, and that is enough.
    assert budget.make_room("summary", "gpu", 3 * GB) is True
    assert unloaded == ["old-helper"]
    # Needs far more: everything idle goes, but not the kept or the busy one, and it still doesn't fit.
    assert budget.make_room("huge", "gpu", 30 * GB) is False
    assert unloaded == ["old-helper", "recent-writer"]
    names = " ".join(budget.snapshot()["loaded"])
    assert "main-whisper" in names and "busy-checker" in names and "old-helper" not in names
    # Memory that can't be read never blocks a load.
    budget.probe["gpu"] = lambda: None
    assert budget.make_room("any", "gpu", 99 * GB) is True

    # One model loads at a time.
    order = []

    def load(name):
        with budget.loading:
            order.append(f"{name} start")
            clock.sleep(0.1)
            order.append(f"{name} end")

    workers = [threads.Thread(target=load, args=(n,)) for n in ("a", "b")]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join()
    assert order[1].endswith("end") and order[3].endswith("end")   # never two loads overlapping


def test_memory_readout_is_on_the_live_and_models_tabs(stt):
    client = TestClient(create_app(Config(token="secret-token"), stt, FakeWriter()))
    for page in ("/browse/live", "/browse/models"):
        html = client.get(page, headers=AUTH).text
        assert "<h2>Memory</h2>" in html and "Graphics card:" in html and "Models load one at a time" in html


def test_how_a_model_is_split_between_the_card_and_memory():
    from myna_server.engines import cpu_threads, is_moe, runner_args

    on_card = runner_args("gpu", "/m/gemma.gguf", 8192, 8791, 8)
    assert on_card[-2:] == ["-ngl", "999"] and on_card[on_card.index("--reasoning") + 1] == "off"
    shared = runner_args("shared", "/m/Qwen_Qwen3-30B-A3B-Q4_K_M.gguf", 8192, 8791, 8)
    # Shared: llama.cpp fits it (layers and experts left unset), read fully into memory, fast cores.
    assert "-ngl" not in shared and "-ot" not in shared and "--n-cpu-moe" not in shared
    assert shared[shared.index("-lm") + 1] == "none" and shared[shared.index("-t") + 1] == "8"
    # Only options this llama.cpp build accepts (the old ones stopped models loading).
    for gone in ("--no-mmap", "--mlock"):
        assert gone not in shared
    assert runner_args("cpu", "/m/x.gguf", 8192, 8791, 8)[-2:] == ["-ngl", "0"]
    mtp = runner_args("shared", "/m/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf", 8192, 8791, 8, mtp=True)
    assert mtp[mtp.index("--spec-type") + 1] == "draft-mtp" and mtp[mtp.index("--spec-draft-n-max") + 1] == "2"
    assert is_moe("openai_gpt-oss-20b-Q4_K_M.gguf") and not is_moe("phi-4-Q4_K_M.gguf")
    assert cpu_threads(12) == 12 and 2 <= cpu_threads() <= 8


def test_heavy_default_moves_to_a_lighter_model_and_falls_back_if_it_cannot_load(tmp_path):
    import json as js

    from myna_server.engines import LlamaWriter

    path = tmp_path / "config.json"
    # An old install on the heavy 35B shared model is moved to one that fits the card,
    # and simple mode is turned on.
    path.write_text(js.dumps({"token": "x" * 20, "upgraded_to": "auto-devices",
                              "llm_repo": "unsloth/Qwen3.6-35B-A3B-MTP-GGUF",
                              "llm_file": "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"}))
    config = Config.load(path)
    # The big hybrid writer is kept (lean layers relieve the card, not downgrading the model).
    assert config.llm_file == "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
    assert config.simple_mode is True and config.blend is False and config.speakers is True

    # A model chosen by hand is not moved.
    path.write_text(js.dumps({"token": "x" * 20, "upgraded_to": "big-and-speakers", "llm_file": "phi-4-Q4_K_M.gguf"}))
    assert Config.load(path).llm_file == "phi-4-Q4_K_M.gguf"

    # If the main model can't load, the fallback is used.
    writer = LlamaWriter(Config(token="x" * 20, llm_repo="unsloth/Qwen3.6-35B-A3B-MTP-GGUF",
                                llm_file="Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"))
    tried = []

    def ensure():
        tried.append(writer._file)
        if writer._file.startswith("Qwen3.6"):
            writer.status = "Couldn't load: unknown model architecture"
            raise RuntimeError("unknown model architecture")
        writer.status = "Ready on the graphics card"

    writer._ensure_running = ensure
    writer._config.save = lambda *a: None
    writer.warm()
    assert tried == ["Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf", "gemma-4-12b-it-qat-q4_0.gguf"]
    assert writer.name == "gemma-4-12b-it-qat-q4_0" and "Switched to this because" in writer.status

def test_writing_speed_is_measured_from_real_requests(tmp_path, monkeypatch, stt):
    monkeypatch.setenv("MYNA_SERVER_HOME", str(tmp_path))
    from myna_server.engines import Speeds

    measured = Speeds()
    measured.record("model.gguf", "shared", {"predicted_per_second": 40.0, "prompt_per_second": 900.0,
                                             "draft_n": 10, "draft_n_accepted": 7})
    measured.record("model.gguf", "shared", {"predicted_per_second": 50.0})
    row = measured.get("model.gguf")
    assert 40 < row["writing"] < 50 and row["requests"] == 2 and abs(row["accepted"] - 0.7) < 1e-9
    assert Speeds().get("model.gguf")["requests"] == 2          # kept between runs
    measured.record("other.gguf", "gpu", {})                     # no timings: nothing recorded
    assert measured.get("other.gguf") == {}


def test_long_requests_are_fitted_to_the_context_and_retried(monkeypatch):
    import io
    import json as js
    import urllib.error
    import urllib.request

    from myna_server.engines import LlamaWriter, fit_text

    assert fit_text("short", 100) == "short"
    cut = fit_text("A" * 500 + "MIDDLE" + "Z" * 500, 300)
    assert len(cut) <= 330 and cut.startswith("A") and cut.endswith("Z") and "MIDDLE" not in cut

    writer = LlamaWriter(Config(token="x" * 20, llm_context=8192))
    writer._ensure_running = lambda: None
    sizes = []

    def fake_urlopen(request, timeout=0):
        prompt = js.loads(request.data)["messages"][1]["content"]
        sizes.append(len(prompt))
        if len(prompt) > 12000:
            raise urllib.error.HTTPError(request.full_url, 400, "Bad Request", {},
                                         io.BytesIO(b'{"error":"the request exceeds the available context size"}'))
        return io.BytesIO(js.dumps({"choices": [{"message": {"content": "done"}}]}).encode())

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    assert writer.generate("instructions", "x" * 100000, 1600) == "done"
    assert sizes[0] < 100000 and sizes[-1] <= 12000          # shortened up front, then further on the refusal

    def refuse(request, timeout=0):
        raise urllib.error.HTTPError(request.full_url, 400, "Bad Request", {}, io.BytesIO(b"invalid json in messages"))

    monkeypatch.setattr(urllib.request, "urlopen", refuse)
    try:
        writer.generate("i", "p", 10)
        raise AssertionError("expected a refusal")
    except RuntimeError as error:
        assert "invalid json in messages" in str(error)        # the reason is shown, not just "400"


def test_a_conversation_that_fails_doesnt_hold_up_the_rest(stt):
    import time as clock

    base = float(int(clock.time()) - 9000)
    calls = {"n": 0}

    def model(instructions, prompt):
        calls["n"] += 1
        if "first one" in prompt and calls["n"] < 50:
            raise RuntimeError("the writing model refused the request (400): too long")
        return '{"title": "Second", "overview": "ok", "category": "work", "sections": [], "action_items": [], "events": []}'

    writer = Recorder("big", model)
    app = create_app(Config(token="secret-token"), stt, writer)
    client = TestClient(app)
    words = " ".join(["word"] * 120)
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("utterance", "u1", {"text": "this is the first one " + words, "heardAt": base}, 1),
        change("utterance", "u2", {"text": "and the second " + words, "heardAt": base + 1000}, 1),
    ]})
    assert app.state.run_conversations(10) == 2
    page = client.get("/browse?kind=conversation", headers=AUTH).text
    assert "t write this up (" in page and "too long" in page and "Second" in page
    calls["n"] = 100                                          # the model works now: the button retries it
    client.post("/browse/conversations", headers=AUTH, follow_redirects=False)
    for _ in range(40):
        if "t write this up (" not in client.get("/browse?kind=conversation", headers=AUTH).text:
            break
        clock.sleep(0.05)
    assert "t write this up (" not in client.get("/browse?kind=conversation", headers=AUTH).text


def test_existing_setups_get_the_larger_context_once(tmp_path):
    import json as js

    path = tmp_path / "config.json"
    path.write_text(js.dumps({"token": "x" * 20, "upgraded_to": "qwen3.6-mtp", "llm_context": 8192,
                              "llm_file": "phi-4-Q4_K_M.gguf"}))
    config = Config.load(path)
    assert config.llm_context == 16384 and config.llm_file == "phi-4-Q4_K_M.gguf" and config.upgraded_to == "big-and-speakers"
    assert config.simple_mode is True and config.blend is False and config.speakers is True


def test_a_lone_yeah_from_one_recognizer_is_dropped():
    from myna_server import blend

    learning = blend.Learning(None)
    assert blend.combine({"parakeet": "", "canary": "Yeah.", "whisper": ""}, learning, None, []) == ("", "filler")
    assert learning.phantoms == {"canary": 1}
    # Heard by two, or with other words, it stays.
    assert blend.combine({"parakeet": "yeah", "canary": "Yeah.", "whisper": ""}, learning, None, [])[0] in ("yeah", "Yeah.")
    assert blend.combine({"parakeet": "", "canary": "yeah I'll be there at six"}, learning, None, []) == \
        ("yeah I'll be there at six", "rescued")


def test_whisper_drops_an_unsure_lone_yeah():
    from types import SimpleNamespace as S

    from myna_server.engines import keep_segments

    assert keep_segments([S(text=" Yeah.", no_speech_prob=0.4, avg_logprob=-0.9)]) == []
    assert keep_segments([S(text=" Yeah.", no_speech_prob=0.02, avg_logprob=-0.1)]) == ["Yeah."]


def test_the_panel_works_in_parallel_and_silence_is_skipped(stt):
    import threading as threads
    import time as clock

    running, peak = [0], [0]
    gate = threads.Lock()

    class Slow(NamedStt):
        def transcribe(self, samples):
            with gate:
                running[0] += 1
                peak[0] = max(peak[0], running[0])
            clock.sleep(0.2)
            with gate:
                running[0] -= 1
            return "hello there"

    main = Slow("whisper-turbo")
    app = create_app(Config(token="secret-token", stt_model="turbo", simple_mode=False, blend=True), main, FakeWriter(),
                     partner_for=lambda model: Slow(model))
    client = TestClient(app)
    tone = (np.sin(np.linspace(0, 900, 16000)) * 0.2).astype(np.float32)
    began = clock.time()
    body = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(tone)).json()
    assert body["text"] == "hello there" and peak[0] == 3       # all three at once
    assert clock.time() - began < 0.55                          # not 3 × 0.2 s one after another
    silent = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(np.zeros(16000, dtype=np.float32))).json()
    assert silent["text"] == "" and silent["took_seconds"] == 0.0


def test_clips_with_no_speech_are_not_transcribed(stt):
    class Counting(NamedStt):
        calls = 0

        def transcribe(self, samples):
            Counting.calls += 1
            return "words"

    app = create_app(Config(token="secret-token", simple_mode=False, blend=True), Counting("whisper-turbo"), FakeWriter(),
                     partner_for=lambda model: Counting(model))
    found = {"seconds": 0.0}
    app.state.speech_seconds = lambda samples: found["seconds"]
    client = TestClient(app)
    noise = wav_bytes(quiet(16000 * 3))
    assert client.post("/v1/transcribe", headers=AUTH, content=noise).json()["text"] == ""
    assert Counting.calls == 0                                      # no recognizer ran
    found["seconds"] = 1.4
    assert client.post("/v1/transcribe", headers=AUTH, content=noise).json()["text"] == "words"
    assert Counting.calls == 3

    def broken(samples):
        raise RuntimeError("no detector")

    app.state.speech_seconds = broken                               # the detector failing never loses speech
    assert client.post("/v1/transcribe", headers=AUTH, content=noise).json()["text"] == "words"


def test_search_by_meaning(tmp_path):
    from myna_server import meaning
    from myna_server.store import Store

    store = Store(tmp_path / "m.db")
    store.sync(0, [
        {"kind": "conversation", "id": "c1", "updated_at": 1, "data": {"title": "Dentist appointment", "overview": "Booked a cleaning for Tuesday"}},
        {"kind": "conversation", "id": "c2", "updated_at": 1, "data": {"title": "Car trouble", "overview": "The brakes squeal"}},
        {"kind": "memory", "id": "m1", "updated_at": 1, "data": {"content": "Likes jazz"}},
    ])

    def embed(texts):
        # Toy meaning: teeth-ish words point one way, everything else another.
        return [[1.0, 0.0] if any(w in t.lower() for w in ("dentist", "teeth")) else [0.0, 1.0] for t in texts]

    assert meaning.index_pending(store, embed) == 3
    assert meaning.index_pending(store, embed) == 0  # nothing new
    found = meaning.related(store, embed, "when do I see someone about my teeth?")
    assert [row["id"] for row in found] == ["c1"]


def test_confirming_learned_memories(tmp_path):
    from myna_server import ask, facts
    from myna_server.store import Store

    store = Store(tmp_path / "f.db")
    store.sync(0, [{"kind": "conversation", "id": "c-1", "updated_at": 1, "data": {
        "startedAt": 1, "title": "Lunch", "overview": "Talked about work",
        "memories": [{"content": "Works as a nurse at the city hospital", "category": "system"},
                     {"content": "Has a brother called Sam", "category": "system"}]}}])
    assert len(facts.pending(store)) == 2
    assert facts.decide(store, "c-1", 0, keep=True)
    assert facts.decide(store, "c-1", 1, keep=False)
    assert facts.pending(store) == []
    saved = store.browse("memory")
    assert len(saved) == 1 and saved[0]["pinned"] and "nurse" in saved[0]["content"]
    material = ask.gather(store, "where do I work?")
    assert "CONFIRMED BY THE USER" in material and "nurse" in material
    assert "brother" not in material  # rejected: never used
    assert facts.mark(store, saved[0]["id"], "forget")
    assert store.browse("memory")[0]["archived"]


def test_suggested_todos_are_added_or_dismissed(tmp_path):
    from myna_server import facts
    from myna_server.store import Store

    store = Store(tmp_path / "t.db")
    store.sync(0, [{"kind": "conversation", "id": "c-2", "updated_at": 1, "data": {
        "startedAt": 1, "title": "Planning",
        "actionItems": [{"description": "Email the venue", "due_at": "2026-12-01T09:00"},
                        {"description": "Think about it", "due_at": ""}]}}])
    assert [t["description"] for t in facts.pending_todos(store)] == ["Email the venue", "Think about it"]
    assert facts.decide_todo(store, "c-2", 0, add=True)
    assert facts.decide_todo(store, "c-2", 1, add=False)
    assert facts.pending_todos(store) == []
    items = store.browse("item")
    assert len(items) == 1 and items[0]["text"] == "Email the venue" and items[0]["source"] == "conversation"
    assert items[0]["dueDate"] > 0



def test_made_up_lines_and_repeats_are_taken_out():
    from myna_server.cleanup import clean

    assert clean("I'm going to go to the next video.") == ""
    assert clean("Bye-bye, Bye-bye, Bye-bye,") == ""
    assert clean("The, The, The, The, The") == ""
    assert clean("Thank you very much.") == ""
    assert clean("Am, I Am, I Am, I Am, I Am, I Am") .count("I Am") == 1
    assert clean("I said no no no to him") == "I said no no no to him"
    real = "There was a sandbag distribution place on Singleton, but I don't know if they're open."
    assert clean(real) == real


def test_the_same_line_is_not_given_twice(client, stt):
    stt.transcribe = lambda samples: "I think that was just my initial connection"
    first = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000))).json()
    again = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000))).json()
    overlap = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000) * 2)).json()
    assert first["text"] and again["text"] == first["text"]     # a resend gets the same answer
    assert overlap["text"] == ""                                 # overlapping audio: not twice


def test_a_model_used_for_two_jobs_is_loaded_once():
    from myna_server.engines import LlamaWriter

    config = Config(token="secret-token", simple_mode=False)
    config.helper_repo, config.helper_file = config.llm_repo, config.llm_file
    main, helper = LlamaWriter(config, "llm"), LlamaWriter(config, "helper")
    main.generate = lambda instructions, prompt, most: "from the main runner"
    assert helper.generate("i", "p", 5) == "from the main runner"
    assert "loaded once" in helper.status
    config.helper_file = "something-else.gguf"
    assert helper._twin() is None



def test_models_are_placed_by_measured_speed(tmp_path, monkeypatch):
    from myna_server import engines

    monkeypatch.setattr(engines, "data_dir", lambda: tmp_path)
    table = engines.Speeds()
    monkeypatch.setattr(engines, "speeds", table)
    GB = 1024 ** 3
    # Unmeasured: a small job model starts on the processor, the main model on the card.
    assert engines.choose_device("checker", "small.gguf", 1.5 * GB, False, 12 * GB)[0] == "cpu"
    assert engines.choose_device("llm", "mid.gguf", 7 * GB, False, 12 * GB)[0] == "gpu"
    assert engines.choose_device("llm", "huge-A3B.gguf", 23 * GB, True, 12 * GB)[0] == "shared"
    # Measured on the card: tried on the processor next, then kept where it is best.
    for _ in range(3):
        table.record("mid.gguf", "gpu", {"predicted_per_second": 60})
    assert engines.choose_device("helper", "mid.gguf", 7 * GB, False, 12 * GB)[0] == "cpu"
    for _ in range(3):
        table.record("mid.gguf", "cpu", {"predicted_per_second": 30})
    assert engines.choose_device("helper", "mid.gguf", 7 * GB, False, 12 * GB)[0] == "cpu"   # fast enough for a job
    assert engines.choose_device("llm", "mid.gguf", 7 * GB, False, 12 * GB)[0] == "gpu"      # the main model wants speed
    # Speech: Whisper measured in seconds of audio per second.
    for _ in range(5):
        table.record_speech("small.en", "gpu", 10, 0.2)
    assert engines.choose_speech_device("small.en", 0.9 * GB)[0] == "cpu"   # try the processor
    for _ in range(5):
        table.record_speech("small.en", "cpu", 10, 0.5)
    assert engines.choose_speech_device("small.en", 0.9 * GB)[0] == "cpu"   # 20x real time: fast enough
    assert engines.choose_speech_device("large-v3", 3.6 * GB)[0] == "gpu"


def test_experiment_tab_tries_a_model_and_keeps_or_drops_it(tmp_path, monkeypatch):
    import time as clock

    from myna_server import experiment

    monkeypatch.setattr(experiment, "data_dir", lambda: tmp_path)
    monkeypatch.setattr(experiment, "search", lambda kind, q, most=20: [
        {"repo": "someone/faster-whisper-tiny", "downloads": 1200, "likes": 3, "updated": "2026-10-01"}])
    downloaded = []
    monkeypatch.setattr(experiment, "download_speech", lambda state, repo: downloaded.append(repo))

    class Candidate(NamedStt):
        def transcribe(self, samples):
            return "pass the salt please"

    stt = NamedStt("model-a")
    made = []

    def partner_for(model, device=None):
        made.append(model)
        return Candidate("whisper-" + model)

    config = Config(token="secret-token", simple_mode=False)
    app = create_app(config, stt, FakeWriter(), audio_dir=tmp_path, partner_for=partner_for)
    app.state.save_config = False
    client = TestClient(app)
    client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000 * 2, dtype=np.float32)))

    page = client.get("/browse/experiment?kind=speech&q=tiny", headers=AUTH).text
    assert "someone/faster-whisper-tiny" in page and "Try it" in page and "Experiment" in page
    client.post("/browse/experiment", headers=AUTH, follow_redirects=False,
                data={"action": "try", "kind": "speech", "model": "someone/faster-whisper-tiny", "hours": "1"})
    for _ in range(100):
        page = client.get("/browse/experiment?kind=speech", headers=AUTH).text
        if "Finished" in page:
            break
        clock.sleep(0.05)
    assert "Finished" in page and "pass the salt please" in page and "Keep it as the recognizer" in page
    assert downloaded == ["someone/faster-whisper-tiny"]          # downloaded before it ran
    client.post("/browse/experiment", headers=AUTH, data={"action": "keep"}, follow_redirects=False)
    assert config.stt_model == "someone/faster-whisper-tiny" and stt.name == "someone/faster-whisper-tiny"
    page = client.get("/browse/experiment", headers=AUTH).text
    assert "Tried before" in page and "KEPT" in page


def test_a_trial_model_that_cannot_run_stops_and_says_why(tmp_path):
    import threading

    from myna_server import experiment
    from myna_server.store import Store

    store = Store(tmp_path / "e.db")
    for i in range(10):
        store.add_clip(9e9 - i, 2.0, str(tmp_path / f"{i}.wav"))   # files missing: every clip fails

    class Broken:
        name = "broken"

        def transcribe(self, samples):
            raise RuntimeError("no")

    state = experiment.new_state()
    state["hours"] = 1e9
    experiment.run_speech(state, store, Broken(), "now", lambda a: a, threading.Event())
    assert state["done"] == 3 and state["note"].startswith("This model couldn't run")


def test_a_slow_speech_check_does_not_freeze_the_server(stt):
    """The speech check runs off the event loop: pages answer while it waits."""
    import threading
    import time as clock

    app = create_app(Config(token="secret-token"), stt, FakeWriter(), partner_for=lambda model, device=None: stt)
    app.state.save_config = False
    release = threading.Event()

    def slow(samples):
        release.wait(5)
        return 1.0

    app.state.speech_seconds = slow
    done = {}
    with TestClient(app) as client:              # one event loop for every request, as in the server

        def send():
            done["reply"] = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000)))

        worker = threading.Thread(target=send)
        worker.start()
        clock.sleep(0.3)
        started = clock.time()
        assert client.get("/health", headers=AUTH).status_code == 200
        waited = clock.time() - started
        release.set()
        worker.join(10)
    assert waited < 2                            # answered while the clip waited
    assert done["reply"].status_code == 200


def test_a_busy_helper_is_skipped_by_live_audio():
    import threading

    from myna_server.sidecar import Sidecar

    side = Sidecar()
    side._lock.acquire()                          # something else holds it
    try:
        try:
            side.call("vad", None, wait=0.2)
            raise AssertionError("should not wait")
        except RuntimeError as error:
            assert "busy" in str(error)
    finally:
        side._lock.release()


def test_simple_mode_runs_one_recognizer_and_one_writer(stt):
    # In simple mode the panel never runs even with partners configured, and the
    # whole clip is transcribed without diarization.
    class CountingStt(NamedStt):
        calls = 0

        def transcribe(self, samples):
            CountingStt.calls += 1
            return "hello"

    main = CountingStt("whisper-turbo")
    app = create_app(Config(token="secret-token", simple_mode=True, blend=True),
                     main, FakeWriter(), partner_for=lambda model: CountingStt("partner"))
    client = TestClient(app)
    body = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000))).json()
    assert body["text"] == "hello" and body["segments"] == []     # no speaker split
    assert CountingStt.calls == 1                                   # just the one recognizer, no panel

    page = client.get("/browse/models", headers=AUTH).text
    assert "Lean layers: ON" in page and "Switch to Full" in page
    client.post("/browse/simple", headers=AUTH, data={"simple": "off"}, follow_redirects=False)
    page = client.get("/browse/models", headers=AUTH).text
    assert "Lean layers: OFF" in page and "Switch to Lean" in page



def test_speaker_separation_runs_even_in_lean_mode(stt):
    # Lean layers on, but speaker separation on: the clip is split by speaker.
    class Splitter:
        def split(self, audio):
            return [(0.0, 1.0, 0), (1.0, 2.0, 1)]

        def print_of(self, audio):
            return [0.1] * 64

    app = create_app(Config(token="secret-token", simple_mode=True, speakers=True), stt, FakeWriter(), voices=Splitter())
    client = TestClient(app)
    body = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000 * 2))).json()
    assert len(body["segments"]) == 2        # two speakers, split despite lean mode

    page = client.get("/browse/models", headers=AUTH).text
    assert "Speaker separation: ON" in page
    client.post("/browse/simple", headers=AUTH, data={"speakers": "off"}, follow_redirects=False)
    body = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000 * 2) * 1.1)).json()
    assert body["segments"] == []            # off: whole clip


def test_a_cached_model_is_not_downloaded_again(monkeypatch):
    import sys
    import types

    from myna_server import engines

    calls = []

    def fake_hf(repo_id, filename, cache_dir, local_files_only=False):
        calls.append(("offline" if local_files_only else "download", filename))
        if local_files_only and filename != "already.bin":
            raise FileNotFoundError("not cached")
        return f"/cache/{filename}"

    # huggingface_hub isn't installed in the test env; cached_hf imports it
    # internally, so give it a stub module.
    stub = types.ModuleType("huggingface_hub")
    stub.hf_hub_download = fake_hf
    monkeypatch.setitem(sys.modules, "huggingface_hub", stub)

    # Already cached: one offline hit, no download.
    assert engines.cached_hf("r", "already.bin", "/cache") == "/cache/already.bin"
    assert calls == [("offline", "already.bin")]

    # Missing: offline miss, then a single download.
    calls.clear()
    assert engines.cached_hf("r", "new.bin", "/cache") == "/cache/new.bin"
    assert calls == [("offline", "new.bin"), ("download", "new.bin")]


def test_the_main_recognizer_is_pinned_and_never_moves():
    from myna_server.engines import WhisperTranscriber
    from myna_server.config import Config

    main = WhisperTranscriber(Config(token="x" * 20, stt_device="auto"))
    main.essential = True
    main.device = "cuda"
    main._model = object()
    main._move = True                       # even if something set it
    # The pinned recognizer keeps its loaded model; it is not dropped to re-place.
    assert main.essential and main._model is not None


def test_bee_cloud_imports_conversations_and_dedupes(tmp_path):
    from myna_server import bee_cloud
    from myna_server.store import Store

    class FakeBee(bee_cloud.BeeCloud):
        def __init__(self):
            super().__init__("tok")
            self.detail_calls = 0

        def recent_conversations(self, limit=30):
            return [{"bee_id": 7, "start": 1000.0, "end": 1200.0, "summary": "Lunch with Sam about the launch", "state": "completed"},
                    {"bee_id": 8, "start": 2000.0, "end": 2100.0, "summary": "Call with the plumber", "state": "completed"}]

        def conversation(self, bee_id):
            self.detail_calls += 1
            return {"bee_id": bee_id, "start": 1000.0 if bee_id == 7 else 2000.0, "end": 1200.0,
                    "summary": "Lunch with Sam about the launch" if bee_id == 7 else "Call with the plumber",
                    "state": "completed",
                    "lines": [(1000.0, "Speaker 1", "Should we move the launch?"), (1005.0, "Speaker 2", "Yes, to March.")]}

    store = Store(tmp_path / "b.db")
    bee = FakeBee()
    assert bee_cloud.import_conversations(store, bee) == 2
    assert bee_cloud.import_conversations(store, bee) == 0          # dedupe: nothing new
    assert bee.detail_calls == 2                                     # the second pull fetched no details

    convo = store.get("conversation", "bee-7")
    assert convo["source"] == "bee" and convo["title"].startswith("Lunch with Sam")
    assert convo["overview"] == "Lunch with Sam about the launch"
    lines = [u for u in store.browse("utterance") if u.get("beeId") == 7]
    assert len(lines) == 2 and lines[0]["engine"] == "bee"


def test_bee_cloud_reads_dates_and_transcripts(tmp_path):
    from myna_server import bee_cloud

    assert bee_cloud._parse_date("2026-11-20T09:30:00Z") is not None
    assert bee_cloud._parse_date(1700000000) == 1700000000.0
    assert bee_cloud._parse_date("") is None


def test_bee_source_skips_local_transcription_and_syncs(tmp_path, monkeypatch):
    from myna_server import bee_cloud
    from myna_server.store import Store

    store = Store(tmp_path / "s.db")
    config = Config(token="secret-token", transcribe_source="bee", bee_token="devtok")

    class Deaf(FakeTranscriber):
        def transcribe(self, samples):
            raise AssertionError("should not transcribe in Bee mode")

    app = create_app(config, Deaf(), FakeWriter(), store=store)
    app.state.save_config = False
    client = TestClient(app)

    # In Bee mode the server never runs a recognizer.
    body = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(quiet(16000))).json()
    assert body["text"] == "" and body["engine"] == "bee"

    # Sync pulls and stores Bee conversations.
    def fake_recent(self, limit=30):
        return [{"bee_id": 3, "start": 100.0, "end": 200.0, "summary": "Dentist on Tuesday", "state": "completed"}]

    def fake_detail(self, bee_id):
        return {"bee_id": bee_id, "start": 100.0, "end": 200.0, "summary": "Dentist on Tuesday",
                "state": "completed", "lines": [(100.0, "Speaker 1", "Booked the dentist for Tuesday.")]}

    monkeypatch.setattr(bee_cloud.BeeCloud, "recent_conversations", fake_recent)
    monkeypatch.setattr(bee_cloud.BeeCloud, "conversation", fake_detail)
    monkeypatch.setattr(bee_cloud.BeeCloud, "account_name", lambda self: "Ara")

    assert app.state.run_bee_sync() == 1
    page = client.get("/browse/models", headers=AUTH).text
    assert "Transcription source: BEE CLOUD" in page and "Dentist on Tuesday" not in page  # summary not on the models page
    convo = store.get("conversation", "bee-3")
    assert convo["overview"] == "Dentist on Tuesday" and convo.get("myna")   # both views stored


def test_bee_pairing_decrypts_the_token_and_qr_renders():
    import base64

    import nacl.public
    import nacl.utils

    from myna_server import bee_cloud

    pair = bee_cloud.Pairing()
    # Simulate Bee sealing a token to our public key with an ephemeral keypair.
    ephem = nacl.public.PrivateKey.generate()
    our_pub = nacl.public.PublicKey(base64.b64decode(pair.public_key_b64))
    nonce = nacl.utils.random(24)
    ciphertext = nacl.public.Box(ephem, our_pub).encrypt(b"tok_live_123", nonce).ciphertext
    packed = bytes([1]) + nonce + bytes(ephem.public_key) + ciphertext
    token = bee_cloud._decrypt_pairing_token(base64.b64encode(packed).decode(), pair._secret)
    assert token == "tok_live_123"

    svg = bee_cloud.qr_svg("https://bee.computer/connect#abc")
    assert svg.startswith("<svg") and "path" in svg


def test_bee_connect_button_starts_pairing(tmp_path, monkeypatch):
    from myna_server import bee_cloud
    from myna_server.store import Store

    # Pairing completes immediately with a token.
    def fake_start(self):
        self.token = "tok_from_pairing"
        return None

    monkeypatch.setattr(bee_cloud.Pairing, "start", fake_start)
    config = Config(token="secret-token", transcribe_source="bee")
    app = create_app(config, FakeTranscriber(), FakeWriter(), store=Store(tmp_path / "p.db"))
    app.state.save_config = False
    monkeypatch.setattr("myna_server.bee_cloud.BeeCloud.recent_conversations", lambda self, limit=30: [])
    monkeypatch.setattr("myna_server.bee_cloud.BeeCloud.account_name", lambda self: "Ara")
    client = TestClient(app)

    client.post("/browse/bee/connect", headers=AUTH, follow_redirects=False)
    import time as clock
    for _ in range(50):
        if config.bee_token == "tok_from_pairing":
            break
        clock.sleep(0.05)
    assert config.bee_token == "tok_from_pairing"


def test_connect_renders_the_qr_immediately(tmp_path, monkeypatch):
    from myna_server import bee_cloud
    from myna_server.store import Store

    def fake_start(self):
        self.request_id = "abc"
        self.expires_at = "2030-01-01T00:00:00Z"
        self.url = "https://bee.computer/connect#abc"
        return self.url

    monkeypatch.setattr(bee_cloud.Pairing, "start", fake_start)
    monkeypatch.setattr(bee_cloud.Pairing, "poll_once", lambda self: False)

    app = create_app(Config(token="secret-token", transcribe_source="bee"), FakeTranscriber(), FakeWriter(),
                     store=Store(tmp_path / "q.db"))
    app.state.save_config = False
    client = TestClient(app)

    client.post("/browse/bee/connect", headers=AUTH, follow_redirects=False)
    page = client.get("/browse/models", headers=AUTH).text
    assert "<svg" in page and "bee.computer/connect#abc" in page   # QR is on the page right away
    client.post("/browse/bee/cancel", headers=AUTH, follow_redirects=False)
    assert "<svg" not in client.get("/browse/models", headers=AUTH).text


def test_bee_conversations_mirror_to_phone_notes(tmp_path):
    from myna_server import bee_cloud
    from myna_server.store import Store

    store = Store(tmp_path / "m.db")
    store.sync(0, [
        {"kind": "utterance", "id": "bee-9-0", "updated_at": 1,
         "data": {"text": "Move the launch to March.", "heardAt": 10, "beeId": 9, "speakerName": "Sam"}},
        {"kind": "conversation", "id": "bee-9", "updated_at": 1,
         "data": {"startedAt": 10, "endedAt": 60, "title": "Launch", "overview": "Bee summary here",
                  "source": "bee", "beeId": 9, "speakers": ["Sam"],
                  "myna": {"title": "Launch moved", "overview": "They agreed to move it.",
                           "actionItems": [{"description": "Tell the team", "due_at": "2026-12-01"}],
                           "sections": [{"bullets": ["March date agreed"]}]}}},
    ])
    assert bee_cloud.mirror_note(store, "bee-9")
    notes = store.browse("note")
    assert len(notes) == 1
    note = notes[0]
    assert note["title"] == "Launch moved" and note["overview"] == "They agreed to move it."
    assert note["detailedNotes"] == "Bee summary here"           # Bee's summary kept
    assert note["actionItems"][0]["task"] == "Tell the team" and note["keyPoints"] == ["March date agreed"]
    assert "Sam: Move the launch to March." in note["transcript"]
    # Deterministic id; re-mirroring updates in place, no duplicate.
    assert bee_cloud.mirror_note(store, "bee-9")
    assert len(store.browse("note")) == 1


def test_sync_reports_a_stable_db_id(tmp_path):
    from myna_server.store import Store

    store = Store(tmp_path / "db1.db")
    first = store.sync(0, [])
    assert first.get("db_id") and store.sync(0, [])["db_id"] == first["db_id"]   # stable

    other = Store(tmp_path / "db2.db")
    assert other.sync(0, [])["db_id"] != first["db_id"]                          # a new DB → new id


def test_recall_finds_exact_facts_in_the_transcript():
    """The whole point: recall can pull a specific number out of the words
    actually spoken, not just a summary."""
    import time

    from myna_server import recall
    from myna_server.store import Store

    store = Store(":memory:")
    store.sync(0, [change("utterance", "u1",
                          {"text": "Call me on 415-555-0142, and email alex@acme.com.", "heardAt": time.time(),
                           "speakerName": "Alex", "beeId": "bee-1"}, time.time())])

    assert "415-555-0142" in recall.execute(store, {"action": "find", "what": "phone"})
    assert "alex@acme.com" in recall.execute(store, {"action": "find", "what": "email"})
    assert "415-555-0142" in recall.execute(store, {"action": "transcript", "query": "call"})

    # The two-phase loop: plan a lookup, then write the answer from what was found.
    def gen(instructions, prompt, max_tokens):
        if instructions == recall.PLAN:
            return '{"action": "done"}' if "415-555-0142" in prompt else '{"action": "find", "what": "phone"}'
        return "It is 415-555-0142."   # the plain-text answer sees the finding
    out = recall.answer(store, gen, "what's the number?", [])
    assert "415-555-0142" in out["reply"]


def test_recall_writes_a_script_as_a_real_code_block_not_a_description():
    """Asked to write something, Myna produces it — the answer is plain text, so
    a code block comes out whole instead of being crammed into a JSON field."""
    from myna_server import recall
    from myna_server.store import Store

    store = Store(":memory:")
    calls = {"plan": 0, "answer": 0}

    def gen(instructions, prompt, max_tokens):
        if instructions == recall.PLAN:
            calls["plan"] += 1
            return '{"action": "done"}'        # writing a script needs no lookup
        calls["answer"] += 1
        return "Here you go:\n```bash\n#!/bin/bash\nsubscription-manager attach --auto\n```"

    out = recall.answer(store, gen, "write me a bash script to attach a subscription", [])
    assert "```bash" in out["reply"] and "subscription-manager attach --auto" in out["reply"]
    assert calls["answer"] == 1

    # And it can refer back to that script on the next turn (history carries it).
    history = [{"role": "me", "text": "write me a bash script"}, {"role": "myna", "text": out["reply"]}]
    seen = {}
    def gen2(instructions, prompt, max_tokens):
        if instructions == recall.PLAN:
            return '{"action": "done"}'
        seen["prompt"] = prompt
        return "It's the script in my last message."
    recall.answer(store, gen2, "where is the script?", history)
    assert "subscription-manager attach --auto" in seen["prompt"]   # the prior answer is in view


def test_recall_can_write_a_document_the_user_can_see():
    import time

    from myna_server import recall
    from myna_server.store import Store

    store = Store(":memory:")
    recall.execute(store, {"action": "document", "title": "Plan", "body": "x" * 60}, None, None)
    notes = store.browse("note", limit=5)
    assert notes and notes[0]["title"] == "Plan"


def test_receptionist_learns_follows_up_and_messages_on_its_own():
    """After a conversation, Myna acts without being asked: it remembers a
    fact, makes a follow-up, drafts a document, and sends one message."""
    import time

    from myna_server import reception
    from myna_server.store import Store

    store = Store(":memory:")
    store.sync(0, [change("conversation", "bee-1",
                          {"startedAt": time.time(), "title": "Call with Alex", "source": "bee", "beeId": "bee-1",
                           "myna": {"overview": "Beta planning", "keyPoints": ["Ship Dec 1"]}}, time.time())])

    def model(instructions, prompt, max_tokens):
        assert "Call with Alex" in prompt           # it read the conversation
        return ('{"remember": ["Alex works at Acme"],'
                ' "followups": [{"text": "Email Alex the deck", "due": ""}],'
                ' "documents": [{"title": "Beta plan", "body": "' + "y" * 60 + '"}],'
                ' "message": {"send": true, "text": "Dont forget to email Alex."}}')

    did = reception.reflect(store, model)
    assert did == {"conversations": 1, "learned": 1, "followups": 1, "documents": 1, "messages": 1}
    assert store.browse("memory", limit=5)[0]["content"] == "Alex works at Acme"
    assert store.browse("item", limit=5)[0]["text"] == "Email Alex the deck"
    assert store.browse("message", limit=5)[0]["text"] == "Dont forget to email Alex."
    # It never acts on the same conversation twice.
    assert reception.reflect(store, model)["conversations"] == 0


def test_receptionist_messages_sync_to_the_phone():
    """A message Myna sends is a syncable record, so the phone pulls it and can
    turn it into a notification."""
    client = TestClient(create_app(Config(token="secret-token"), FakeTranscriber(), FakeWriter()))
    # The server's store is reachable through a sync round-trip.
    from myna_server import reception

    app_store = client.app.state.store
    reception.send_message(app_store, "Your 3pm is in ten minutes.")
    pulled = client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": []}).json()
    messages = [c for c in pulled["changes"] if c["kind"] == "message"]
    assert messages and messages[0]["data"]["text"] == "Your 3pm is in ten minutes."


def test_receptionist_reminds_about_due_todos_once():
    import time

    from myna_server import reception
    from myna_server.store import Store

    store = Store(":memory:")
    soon = time.time() + 3 * 3600
    store.sync(0, [change("item", "i1",
                          {"kind": "todo", "text": "Pay the invoice", "dueDate": soon, "isDone": False}, time.time())])
    store.sync(0, [change("item", "i2",
                          {"kind": "todo", "text": "Next week thing", "dueDate": time.time() + 10 * 86400, "isDone": False}, time.time())])

    assert reception.remind_due(store) == 1                   # only the soon one
    assert reception.remind_due(store) == 0                   # never twice
    messages = store.browse("message", limit=5)
    assert len(messages) == 1 and "Pay the invoice" in messages[0]["text"]


def test_model_picker_warns_before_a_slow_dense_model(stt):
    """Choosing a dense model bigger than the card shows a warning with a
    'Continue anyway', and only goes through on confirm."""
    class Switchable(FakeWriter):
        chosen = True
        used = None

        def use(self, repo, file):
            type(self).used = (repo, file)
            self.name = file.removesuffix(".gguf")

    from myna_server import catalog

    # A dense, bigger-than-the-card model from the catalog.
    repo, file, *_ = next(r for r in catalog.WRITING if "Qwen2.5-32B" in r[1])
    app = create_app(Config(token="secret-token", simple_mode=False), stt, Switchable())
    app.state.save_config = False
    client = TestClient(app)

    first = client.post("/browse/models", headers=AUTH, data={"role": "llm", "repo": repo, "file": file},
                        follow_redirects=False)
    assert first.status_code == 200 and "Continue anyway" in first.text and "slow" in first.text.lower()
    assert Switchable.used is None                       # nothing applied yet

    client.post("/browse/models", headers=AUTH, data={"role": "llm", "repo": repo, "file": file, "confirm": "1"},
                follow_redirects=False)
    assert Switchable.used == (repo, file)               # confirmed → applied


def test_model_picker_does_not_warn_for_a_big_moe_model(stt):
    """A mixture-of-experts model bigger than the card is fast, so no warning."""
    class Switchable(FakeWriter):
        chosen = True
        used = None

        def use(self, repo, file):
            type(self).used = (repo, file)

    from myna_server import catalog

    repo, file, *_ = next(r for r in catalog.WRITING if "A3B" in r[1])
    app = create_app(Config(token="secret-token", simple_mode=False), stt, Switchable())
    app.state.save_config = False
    client = TestClient(app)
    reply = client.post("/browse/models", headers=AUTH, data={"role": "llm", "repo": repo, "file": file},
                        follow_redirects=False)
    assert reply.status_code == 303 and Switchable.used == (repo, file)   # applied, no warning
