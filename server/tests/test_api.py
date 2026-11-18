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
