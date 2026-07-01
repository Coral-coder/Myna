# Myna 🪶

**An all-day, on-device AI conversation scribe for iPhone.**

Myna listens to your meetings and conversations, transcribes them locally with
**OpenAI Whisper** running on the Apple Neural Engine, and uses a local large
language model running on the iPhone's GPU to compose detailed, flexible
notes — then quietly puts the meetings you agreed to onto your calendar.
Nothing you say ever leaves the device.

Named for the myna bird: a brilliant listener.

---

## What it does

Myna runs a two-stage local pipeline: **ears** (Whisper speech recognition) →
**mind** (a language model that writes the notes).

| Capability | How |
|---|---|
| Always-on, non-exclusive mic | `AVAudioEngine` with an audio session in `.mixWithOthers` mode — Myna listens *alongside* music, podcasts and other recorders instead of seizing the mic. Background audio mode keeps it running with the screen off |
| On-device Whisper transcription | Captured audio is resampled to 16 kHz and sliced into utterances by an energy-based voice-activity detector, then transcribed by **OpenAI Whisper via [WhisperKit](https://github.com/argmaxinc/WhisperKit)** on the Neural Engine. Audio is never written to disk and never leaves the device |
| AI meeting notes | A local LLM (MLX, 4-bit quantized) turns each conversation into a structured note: overview, detailed narrative, key points, decisions, action items, follow-ups |
| Conversation detection | A silence watchdog ends a "conversation" after a configurable quiet period (default 90 s); marathon meetings are scribed in chapters |
| Auto-scheduling | The model extracts events being planned ("let's meet next Tuesday at 2"), resolves them to concrete dates, and EventKit puts them on your calendar with a 15-minute alert |
| Apple Notes hand-off | Every note exports as rich text via the share sheet — choose **Notes** to file it in Apple Notes (Apple provides no direct write API; the share sheet is the sanctioned path) |
| In-app model downloads | The **Neural Core** tab downloads both the Whisper model and the note-writing model straight from Hugging Face with live progress, stores them in Application Support (excluded from iCloud backup), and lets you delete or swap models any time |

## The interface ✨

A dark "imagineered" stage: a slow-breathing aurora mesh with drifting pixie
dust, a living **listening orb** that pulses with the room's sound and spins a
waveform constellation, frosted-glass show-control panels with glowing
gradient borders, and a floating glass dock. Tabs: **Listen · Notes · Neural
Core · Backstage**.

## Model recommendations

For **iPhone 15 Pro Max and newer** (A17 Pro / A18+, 8 GB RAM).

### Ears — Whisper speech recognition (Neural Engine)

| Model | Size | Verdict |
|---|---|---|
| **Whisper Base (English)** | ~145 MB | ⭐ **Recommended.** Transcribes English faster than real time while sipping battery — the all-day sweet spot for meeting notes |
| Whisper Small (English) | ~470 MB | Sharper on names, jargon and crosstalk; a modest step up in memory and battery |
| Whisper Large v3 Turbo | ~626 MB | State-of-the-art accuracy across 99 languages, distilled for the Neural Engine; heaviest on battery |
| Whisper Tiny (English) | ~75 MB | Fastest and lightest; best when battery matters most and speech is clear |

Downloaded in-app from the [`argmaxinc/whisperkit-coreml`](https://huggingface.co/argmaxinc/whisperkit-coreml)
repo and run via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (pinned
to the stable 1.x line). WhisperKit 1.x has no `swift-transformers` dependency,
so it coexists cleanly with the MLX stack.

### Mind — note-writing language model (GPU)

| Model | Size | RAM | Verdict |
|---|---|---|---|
| **Llama 3.2 3B Instruct (4-bit)** | 1.8 GB | ~2.6 GB | ⭐ **Recommended.** Best quality-per-watt for structured note taking; ~20 tok/s on A17 Pro with system headroom to spare |
| Qwen 2.5 3B Instruct (4-bit) | 1.7 GB | ~2.5 GB | Excellent at dates/numbers and multilingual rooms |
| Qwen 3 4B (4-bit) | 2.3 GB | ~3.4 GB | Max quality that still fits comfortably in 8 GB |
| Llama 3.2 1B Instruct (4-bit) | 0.7 GB | ~1.2 GB | Fastest, lightest on battery; notes are less nuanced |

Downloadable inside the app from the `mlx-community` organization on Hugging
Face. Inference runs through [MLX Swift](https://github.com/ml-explore/mlx-swift)
([`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm), pinned to the
stable 2.x line), which is Apple-maintained and tuned for Apple Silicon GPUs.

Because Whisper runs on the Neural Engine and the LLM on the GPU, transcription
and note-writing can proceed on different compute units without contending.

## Building & running

**Requirements:** Xcode 16.2+, a physical iPhone 15 Pro / Pro Max or newer on
iOS 18+ (MLX needs the device GPU — the simulator won't run the model), and an
Apple developer team for code signing.

1. Open `Myna.xcodeproj` in Xcode. Swift Package Manager resolves
   `mlx-swift-lm`, `mlx-swift` and `WhisperKit` automatically on first open.
2. Select the **Myna** target → *Signing & Capabilities* → choose your team.
   (The bundle id is `com.myna.studio`; change it to anything under your team.)
3. Build & run on your iPhone.
4. First launch asks for microphone (and, optionally, calendar) permission,
   then visit **Neural Core** and download one **Ears** model (Whisper) and one
   **Mind** model (the note writer) — one-time downloads, Wi-Fi suggested.
5. Tap the orb. Have a conversation. Watch the note appear.

### Project layout

```
Myna.xcodeproj/          Xcode 16 project (filesystem-synchronized groups)
Config/                  Info.plist + entitlements
Myna/
  MynaApp.swift          App entry; wires SwiftData + engines
  Theme/                 Aurora background, glass cards, palette
  Audio/
    AudioCaptureEngine   Always-on non-exclusive mic, 16 kHz resample, VAD chunking
  Engine/
    WhisperCatalog       The curated Whisper (ears) models
    WhisperTranscriber   Whisper download / load / run via WhisperKit (Neural Engine)
    ConversationPilot    Per-utterance transcription + conversation orchestration
    ModelCatalog         The curated note-writing (mind) models
    ModelManager         LLM download / load / run (MLX + Hugging Face Hub)
    NotesEngine          Chunked condensation → structured JSON note
    EventScheduler       EventKit writer
  Models/                SwiftData schema (ConversationNote)
  Views/                 Dashboard, orb, notes, Neural Core, settings, onboarding
```

### Implementation notes

- **Non-exclusive mic:** the audio session uses `.playAndRecord` with
  `.mixWithOthers`, so Myna coexists with other audio apps rather than
  interrupting them. iOS may still limit mic access during a phone/FaceTime
  call or when another app holds exclusive capture — Myna yields in those cases
  rather than fighting for the input.
- **Utterance chunking:** an energy-based VAD slices the 16 kHz stream into
  utterances (speech followed by a ~0.7 s pause, capped at 28 s), each
  transcribed by Whisper as it completes. This is what makes all-day listening
  tractable — Whisper processes short clips faster than real time instead of
  one unbounded stream.
- **Memory:** the app carries the `com.apple.developer.kernel.increased-memory-limit`
  entitlement and caps MLX's GPU buffer cache at 20 MB. Whisper (Neural Engine,
  ~0.1–0.6 GB) and the LLM (GPU, ~1.2–3.4 GB) fit together on an 8 GB device.
- **Long meetings:** transcripts beyond ~6,000 characters are condensed in
  chunks before the final structured-note pass, so the model's context window
  is never overflowed regardless of meeting length.
- **Resilience:** if the model's JSON ever fails to parse, the raw transcript
  is still filed as a note — nothing heard is ever lost.
- **Battery & thermals:** continuous capture, Whisper on every utterance, and
  periodic LLM runs is a heavy duty cycle; expect meaningful battery use on an
  all-day session. Whisper Tiny + Llama 1B is the battery-saver pairing.
- **App Review caveat:** an app that records all day in the background is fine
  for personal/side-loaded use, but App Store distribution of always-on
  recording requires careful review positioning (visible recording indicator,
  clear consent). Also mind your local laws on recording conversations —
  consent requirements vary by jurisdiction.

## CI/CD (GitHub Actions → TestFlight)

`.github/workflows/ci.yml` runs two jobs on macOS 15 runners:

- **build** — every PR and push: compiles the whole app for a real iOS device
  (unsigned, `CODE_SIGNING_ALLOWED=NO`). This is the merge gate. There is no
  simulator job on purpose: MLX targets physical Apple-Silicon GPUs.
- **testflight** — pushes to `main` and manual runs (*Actions → CI → Run
  workflow*): builds a signed Release archive, exports an App Store IPA and
  uploads it to TestFlight. The build number is the workflow run number, so
  every upload is unique. The IPA is also kept as a workflow artifact for
  14 days.

### One-time setup

1. In [App Store Connect](https://appstoreconnect.apple.com), create the app
   record with bundle id `com.myna.studio` (or change `BUNDLE_ID` in the
   workflow and the project to match yours).
2. In the developer portal, create an **Apple Distribution** certificate and
   an **App Store** provisioning profile for that bundle id.
3. In App Store Connect → *Users and Access* → *Integrations*, create an
   **API key** with the App Manager role.
4. Add these repository secrets (Settings → Secrets and variables → Actions);
   the upload job also uses a `testflight` environment, so you can require
   manual approval there if you like:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | Your 10-character team id |
| `BUILD_CERTIFICATE_BASE64` | `base64 -i Certificates.p12` (the distribution cert + private key) |
| `P12_PASSWORD` | Password of that `.p12` |
| `PROVISIONING_PROFILE_BASE64` | `base64 -i Myna_AppStore.mobileprovision` |
| `PROVISIONING_PROFILE_NAME` | The profile's name exactly as in the portal |
| `KEYCHAIN_PASSWORD` | Any random string |
| `APP_STORE_CONNECT_KEY_ID` | API key id (e.g. `2X9R4HXF34`) |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer id (UUID) |
| `APP_STORE_CONNECT_API_KEY_BASE64` | `base64 -i AuthKey_XXXX.p8` |

Builds land in App Store Connect → TestFlight a few minutes after upload
(processing time included); add testers there.

## Privacy charter

- Audio is processed in memory and never written to disk or uploaded.
- Speech-to-text uses OpenAI Whisper running on the Apple Neural Engine —
  fully on-device, no network.
- The LLM runs locally; the only network traffic the app ever generates is the
  one-time model downloads from Hugging Face.
- Notes live in the app's private SwiftData store. Sharing to Apple Notes or
  the calendar is always explicit user-visible behavior.
