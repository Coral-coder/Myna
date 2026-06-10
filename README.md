# Myna 🪶

**An all-day, on-device AI conversation scribe for iPhone.**

Myna listens to your meetings and conversations, transcribes them with Apple's
on-device speech engine, and uses a local large language model running on the
iPhone's GPU to compose detailed, flexible notes — then quietly puts the
meetings you agreed to onto your calendar. Nothing you say ever leaves the
device.

Named for the myna bird: a brilliant listener.

---

## What it does

| Capability | How |
|---|---|
| All-day listening | `AVAudioEngine` + background audio mode; tap the orb once and Myna keeps listening, even with the screen off |
| Private transcription | `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` — speech never touches the network |
| AI meeting notes | A local LLM (MLX, 4-bit quantized) turns each conversation into a structured note: overview, detailed narrative, key points, decisions, action items, follow-ups |
| Conversation detection | A silence watchdog ends a "conversation" after a configurable quiet period (default 90 s); marathon meetings are scribed in chapters |
| Auto-scheduling | The model extracts events being planned ("let's meet next Tuesday at 2"), resolves them to concrete dates, and EventKit puts them on your calendar with a 15-minute alert |
| Apple Notes hand-off | Every note exports as rich text via the share sheet — choose **Notes** to file it in Apple Notes (Apple provides no direct write API; the share sheet is the sanctioned path) |
| In-app model downloads | The **Neural Core** tab downloads pre-quantized weights straight from Hugging Face with live progress, stores them in Application Support (excluded from iCloud backup), and lets you delete or swap models any time |

## The interface ✨

A dark "imagineered" stage: a slow-breathing aurora mesh with drifting pixie
dust, a living **listening orb** that pulses with the room's sound and spins a
waveform constellation, frosted-glass show-control panels with glowing
gradient borders, and a floating glass dock. Tabs: **Listen · Notes · Neural
Core · Backstage**.

## Model recommendation

For **iPhone 15 Pro Max and newer** (A17 Pro / A18+, 8 GB RAM):

| Model | Size | RAM | Verdict |
|---|---|---|---|
| **Llama 3.2 3B Instruct (4-bit)** | 1.8 GB | ~2.6 GB | ⭐ **Recommended.** Best quality-per-watt for structured note taking; ~20 tok/s on A17 Pro with system headroom to spare |
| Qwen 2.5 3B Instruct (4-bit) | 1.7 GB | ~2.5 GB | Excellent at dates/numbers and multilingual rooms |
| Qwen 3 4B (4-bit) | 2.3 GB | ~3.4 GB | Max quality that still fits comfortably in 8 GB |
| Llama 3.2 1B Instruct (4-bit) | 0.7 GB | ~1.2 GB | Fastest, lightest on battery; notes are less nuanced |

All four are downloadable inside the app from the `mlx-community` organization
on Hugging Face. Inference runs through [MLX Swift](https://github.com/ml-explore/mlx-swift)
([`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm), pinned to the
stable 2.x line), which is Apple-maintained and tuned for Apple Silicon GPUs.

## Building & running

**Requirements:** Xcode 16.2+, a physical iPhone 15 Pro / Pro Max or newer on
iOS 18+ (MLX needs the device GPU — the simulator won't run the model), and an
Apple developer team for code signing.

1. Open `Myna.xcodeproj` in Xcode. Swift Package Manager resolves
   `mlx-swift-lm` and `mlx-swift` automatically on first open.
2. Select the **Myna** target → *Signing & Capabilities* → choose your team.
   (The bundle id is `com.myna.studio`; change it to anything under your team.)
3. Build & run on your iPhone.
4. First launch walks you through microphone, speech and calendar permissions,
   then visit **Neural Core** and tap **Download to iPhone** on the
   recommended model (one-time, ~1.8 GB — Wi-Fi suggested).
5. Tap the orb. Have a conversation. Watch the note appear.

### Project layout

```
Myna.xcodeproj/          Xcode 16 project (filesystem-synchronized groups)
Config/                  Info.plist + entitlements
Myna/
  MynaApp.swift          App entry; wires SwiftData + engines
  Theme/                 Aurora background, glass cards, palette
  Audio/                 SpeechListener — engine tap + on-device recognition
  Engine/
    ConversationPilot    Conversation segmentation & orchestration
    ModelCatalog         The four curated models
    ModelManager         Download / load / run (MLX + Hugging Face Hub)
    NotesEngine          Chunked condensation → structured JSON note
    EventScheduler       EventKit writer
  Models/                SwiftData schema (ConversationNote)
  Views/                 Dashboard, orb, notes, Neural Core, settings, onboarding
```

### Implementation notes

- **Memory:** the app carries the `com.apple.developer.kernel.increased-memory-limit`
  entitlement and caps MLX's GPU buffer cache at 20 MB so a 3–4B model fits
  alongside the rest of the system.
- **Long meetings:** transcripts beyond ~6,000 characters are condensed in
  chunks before the final structured-note pass, so the model's context window
  is never overflowed regardless of meeting length.
- **Resilience:** if the model's JSON ever fails to parse, the raw transcript
  is still filed as a note — nothing heard is ever lost.
- **Battery & thermals:** continuous on-device recognition plus periodic LLM
  runs is a heavy duty cycle; expect meaningful battery use on an all-day
  session. The 1B model is offered specifically as a battery-saver scribe.
- **App Review caveat:** an app that records all day in the background is fine
  for personal/side-loaded use, but App Store distribution of always-on
  recording requires careful review positioning (visible recording indicator,
  clear consent). Also mind your local laws on recording conversations —
  consent requirements vary by jurisdiction.

## Privacy charter

- Audio is processed in memory and never written to disk or uploaded.
- Speech-to-text uses Apple's on-device engine exclusively.
- The LLM runs locally; the only network traffic the app ever generates is the
  one-time model download from Hugging Face.
- Notes live in the app's private SwiftData store. Sharing to Apple Notes or
  the calendar is always explicit user-visible behavior.
