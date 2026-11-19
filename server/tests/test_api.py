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


@pytest.fixture
def stt():
    return FakeTranscriber()


@pytest.fixture
def client(stt):
    config = Config(token="secret-token")
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
    # The samples reach the model at the right scale.
    assert abs(float(np.abs(stt.seen).max()) - 0.5) < 0.01


def test_transcribe_resamples_and_downmixes(client, stt):
    stereo = np.zeros(48000 * 2, dtype=np.float32)
    reply = client.post("/v1/transcribe", content=wav_bytes(stereo, rate=48000, channels=2), headers=AUTH)
    assert reply.status_code == 200
    assert reply.json()["audio_seconds"] == 1.0
    assert stt.seen.size == 16000


def test_transcribe_rejects_bad_input(client):
    assert client.post("/v1/transcribe", content=b"", headers=AUTH).status_code == 400
    assert client.post("/v1/transcribe", content=b"not audio", headers=AUTH).status_code == 400
    assert client.post("/v1/transcribe", content=wav_bytes(np.zeros(10)), headers={}).status_code == 401


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

    config = Config(token="secret-token")
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

    config = Config(token="secret-token")
    app = create_app(config, stt, SwitchableWriter())
    app.state.save_config = False
    client = TestClient(app)
    page = client.get("/browse/models", headers=AUTH).text
    assert "DeepSeek R1 distill 14B" in page and "Llama 3.3 70B" in page and "Processor" in page
    client.post("/browse/models", headers=AUTH, data={"llm_device": "cpu", "stt_device": "cpu"}, follow_redirects=False)
    assert config.llm_device == "cpu" and config.stt_device == "cpu"
    # A model bigger than the card, chosen while set to the card, is shared instead.
    config.llm_device = "gpu"
    client.post("/browse/models", headers=AUTH, follow_redirects=False,
                data={"repo": "bartowski/Qwen_Qwen3-32B-GGUF", "file": "Qwen_Qwen3-32B-Q4_K_M.gguf"})
    assert config.llm_device == "shared" and config.llm_file == "Qwen_Qwen3-32B-Q4_K_M.gguf"


def test_ask_uses_saved_material_and_the_web(stt):
    from myna_server import web

    calls = []

    class ScriptedWriter:
        name = "scripted"

        def generate(self, instructions, prompt, max_tokens):
            calls.append(prompt)
            if "WEB RESULTS" in prompt:
                return '{"reply": "It is 31 metres tall.", "search": ""}'
            if "lighthouse" in prompt.split("THE USER ASKS")[-1]:
                return '{"reply": "", "search": "height of the lighthouse"}'
            return '{"reply": "You said you would call the dentist.", "search": ""}'

    app = create_app(Config(token="secret-token"), stt, ScriptedWriter())
    app.state.web_lookup = lambda query: f"1. Lighthouse — 31 metres ({query})"
    client = TestClient(app)
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("utterance", "u1", {"text": "I need to call the dentist tomorrow", "heardAt": 1_700_000_000}, 1),
    ]})
    assert client.post("/browse/ask.json", json={"question": "hi"}).status_code == 401
    first = client.post("/browse/ask.json", headers=AUTH, json={"question": "what about the dentist?"}).json()
    assert first == {"reply": "You said you would call the dentist.", "searched": ""}
    assert "call the dentist tomorrow" in calls[0]  # the saved line reached the model
    second = client.post("/browse/ask.json", headers=AUTH, json={
        "question": "how tall is the lighthouse?", "history": [{"role": "me", "text": "what about the dentist?"}]}).json()
    assert second == {"reply": "It is 31 metres tall.", "searched": "height of the lighthouse"}
    assert "EARLIER IN THIS CHAT" in calls[-1] and "31 metres" in calls[-1]
    assert "Ask Myna" in client.get("/browse/ask", headers=AUTH).text

    page = '<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;x=1">A <b>title</b></a>' \
           '<a class="result__snippet" href="#">Some &amp; text</a>'
    assert web.parse_results(page) == [("A title", "Some & text", "https://example.com/a")]
    assert web.readable("<head><title>x</title></head><script>var a</script><p>Hello <b>there</b></p>") == "Hello there"


def test_transcribe_splits_a_clip_by_speaker(stt):
    class FakeVoices:
        def split(self, audio):
            return [(0.0, 1.0, 0), (1.1, 2.0, 0), (2.5, 4.0, 1), (4.05, 4.2, 0)]  # the last is a sliver

        def print_of(self, audio):
            return [float(audio.size)]

    client = TestClient(create_app(Config(token="secret-token"), stt, FakeWriter(), voices=FakeVoices()))
    body = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(np.zeros(16000 * 5, dtype=np.float32))).json()
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

    solo = TestClient(create_app(Config(token="secret-token"), stt, FakeWriter(), voices=OneVoice()))
    body = solo.post("/v1/transcribe", headers=AUTH, content=wav_bytes(np.zeros(16000 * 3, dtype=np.float32))).json()
    assert body["text"] == "heard 48000 samples" and len(body["segments"]) == 1 and body["segments"][0]["voice"] == [1.0, 2.0]
    plain = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(np.zeros(16000, dtype=np.float32))).json()
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
    for _ in range(2):
        client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(np.zeros(16000 * 2, dtype=np.float32)))
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


def test_helper_model_picks_out_context_for_the_main_model(stt):
    helper = Recorder("small", "[Tue 10:00] the dentist is at four on Friday")
    main = Recorder("big", '{"reply": "Friday at four.", "search": ""}')
    client = TestClient(create_app(Config(token="secret-token"), stt, main, helper=helper))
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("utterance", "u1", {"text": "the dentist is at four on Friday", "heardAt": 1_700_000_000}, 1),
        change("utterance", "u2", {"text": "we talked about the dentist bill", "heardAt": 1_700_000_100}, 1),
    ]})
    reply = client.post("/browse/ask.json", headers=AUTH, json={"question": "when is the dentist?"}).json()
    assert reply["reply"] == "Friday at four."
    assert "dentist bill" in helper.asked[0][1]            # the helper saw the wide material
    assert "PICKED OUT" in main.asked[0][1] and "at four on Friday" in main.asked[0][1]
    assert "dentist bill" not in main.asked[0][1]          # the main model only got what was picked


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

    config = Config(token="secret-token")
    helper, summary = Switchable(), Switchable()
    app = create_app(config, stt, Switchable(), helper=helper, summarizer=summary)
    app.state.save_config = False
    client = TestClient(app)
    form = {"repo": "bartowski/Qwen_Qwen3-4B-GGUF", "file": "Qwen_Qwen3-4B-Q4_K_M.gguf"}
    client.post("/browse/models", headers=AUTH, data={"role": "helper", **form}, follow_redirects=False)
    client.post("/browse/models", headers=AUTH, follow_redirects=False,
                data={"role": "summary", "repo": "bartowski/Qwen_Qwen3-32B-GGUF", "file": "Qwen_Qwen3-32B-Q4_K_M.gguf"})
    assert config.helper_file == "Qwen_Qwen3-4B-Q4_K_M.gguf" and config.llm_file.startswith("gemma")
    assert config.summary_file == "Qwen_Qwen3-32B-Q4_K_M.gguf" and config.summary_device == "shared"  # too big for the card
    page = client.get("/browse/models", headers=AUTH).text
    assert "HELPER" in page and "SUMMARY" in page and "Stop using" in page
    client.post("/browse/models", headers=AUTH, data={"clear": "helper"}, follow_redirects=False)
    assert helper.name == ""


def test_quiet_audio_is_brought_up_before_transcribing():
    from myna_server.audio import level

    quiet = (np.sin(np.linspace(0, 200, 16000)) * 0.03).astype(np.float32)
    louder = level(quiet)
    assert 0.45 < float(np.abs(louder).max()) <= 0.55            # far-field speech reaches a working level
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
    for _ in range(6):
        client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(tone))
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
    assert "Launch moved" in writer.asked[-1][1] and "REMEMBERED FROM CONVERSATIONS" in writer.asked[-1][1]


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
    app = create_app(Config(token="secret-token"), main, FakeWriter(), partner_for=lambda model: Partner())
    client = TestClient(app)
    client.post("/v1/sync", headers=AUTH, json={"since": 0, "changes": [
        change("person", "p1", {"name": "Saoirse", "createdAt": 1}, 1),
        change("memory", "m1", {"content": "Lives near Kilkenny. Visits Kilkenny often.", "createdAt": 1}, 1),
    ]})
    body = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(np.zeros(16000, dtype=np.float32))).json()
    assert body["text"] == "Saoirse is coming on Friday"                 # the partner caught what the main one missed
    assert "Saoirse" in main.hotwords and "Kilkenny" in main.hotwords    # the wearer's words reach the recognizer
    page = client.get("/browse/compare", headers=AUTH).text
    assert "Models working together" in page and "partner" in page and "1 clips where one caught speech" in page
    client.post("/browse/blend", headers=AUTH, data={"blend": "off"}, follow_redirects=False)
    off = client.post("/v1/transcribe", headers=AUTH, content=wav_bytes(np.zeros(16000, dtype=np.float32))).json()
    assert off["text"] == ""
