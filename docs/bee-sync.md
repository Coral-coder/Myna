# Bee integration — the two ways Myna can get your conversations

Myna can get bracelet conversations from Bee by **two independent paths**.
Both are the user's own data, read with the user's own credentials.

## 1. Cloud pull (the current direction) — `server/myna_server/bee_cloud.py`

Bee's bracelet, even on the free tier, records, transcribes and summarizes on
Bee's own servers. The Myna **server** reads those finished conversations from
Bee's **developer API** and keeps a local copy, then runs Myna's own write-ups
and search on top. Bee does the far-field capture and transcription it's good
at; Myna owns the notes.

- **API:** `https://api.developer.bee.amazon.dev`, `Authorization: Bearer <token>`.
  Token from the Bee account at developer.bee.computer.
- **Endpoints used:** `GET /v1/conversations?limit=N` (list: id, start, end,
  summary, state), `GET /v1/conversations/{id}` (full speaker-labelled
  transcript in `transcriptions[].utterances[]`), plus `/v1/facts`, `/v1/todos`,
  `/v1/me`.
- **Stored as:** one Myna `conversation` record per Bee conversation
  (`id = bee-<id>`, carrying Bee's summary as the overview), plus the transcript
  as `utterance` records (`engine = "bee"`), deduped by Bee id.
- **Read-only.** Only GETs the account's own data; sends nothing out but the token.
- Mirrors the iOS app's `BeeCloudAPI` exactly (same base URL, auth and shapes),
  which is already in use and verified.

In this mode the server's own transcription, speaker separation and speech gate
do not run (nothing to transcribe), so the GPU/CPU are free for the writing
model and search.

## 2. Direct bracelet (BLE) — `Myna/Integrations/Bee/*` (set aside)

Myna connects to the bracelet over Bluetooth and decrypts its audio itself,
then transcribes locally. This is fully working but is **not** the current
direction; it's kept for the record and for a possible Omi contribution.

### Audio protocol
- AES-128-CTR, 16-byte key, 12-byte session nonce, per-packet sequence; the
  decrypted stream is ADTS AAC. Service/characteristic UUIDs and the control
  command ids are in `BeeProtocol.swift`.

### The encryption key (the wall)
Provisioning the key is `SetEncryptionKey` (0xC018). The key token is **108
bytes** and is **cryptographically signed by Bee** — you cannot forge or
generate your own. Confirmed two ways:

- **On-device test (build 105–108):** writing a token with our own key in a
  real envelope, or a synthetic one, is rejected with `invalidParam`.
- **Entropy analysis of four real tokens for one bracelet:** the layout is
  `"SKV1"(4) · device id(8) · AES key(16, in the clear, constant) · aux(16) ·
  ECDSA-P256 signature(64)`. The key is the same every fetch; only the aux +
  signature change (randomized signature).
- **Firmware teardown (`docs/bee-firmware-notes.md`):** the 0xC018 handler
  (nRF52840, Zephyr/NCS + MCUboot) verifies an ECDSA-P256 signature over the
  header+id+key against a **baked-in Bee public key**, and binds the token to
  the chip's fused device id. Not forgeable without Bee's private key.

### What this means
- To decrypt audio you need the real, Bee-signed token for *that* bracelet.
  Capture it once (recovery passphrase → Bee, in Backstage); Myna stores it and
  reuses it with no further cloud calls, across reconnects and factory resets.
- A Bee-independent key generator is **not possible** on stock firmware. The
  only route to your own key is custom firmware over SWD (replace MCUboot's key
  / the handler) on your own hardware.

## Choosing between them
`config.transcribe_source` selects `"local"` (path 2 / phone audio) or `"bee"`
(path 1). A future phone option could route the bracelet's audio to the Bee app
vs. to Myna per the user's choice.
