# Myna 🪶

**An always-on, on-device AI second brain for iPhone.**

Myna listens all day — to your meetings, your conversations and to you. It
composes detailed notes with a local language model, keeps your to-do and
shopping lists, sets reminders, puts plans on your calendar, and answers when
you say "Myna, …". It's the half of your brain that was paying attention.
Speech recognition and the AI run on the iPhone; nothing you say is uploaded
(unless you connect a Bee, whose data already lives in Bee's cloud).

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
| "Myna, …" voice commands | Say "Myna, add oat milk to the shopping list", "remind me to call Mom at 6", "schedule lunch with Alex Friday at noon", "what's on my calendar tomorrow?", "check off eggs" — understood instantly by an on-CPU parser (works with the phone locked) and answered out loud |
| Ask anything | Anything the parser doesn't recognize goes to the language model with your lists, calendar, recent conversations (and Bee facts) as context; it answers and acts — adds items, sets reminders, schedules |
| Lists | **Lists** tab: To-Do, Shopping, Reminders and Memos. Filled by voice, typing, Siri, your Bee, or automatically from conversations ("I'll send the deck tonight" → a to-do) |
| Reminders that remind | Time-sensitive notifications at the due time (they break through Focus), mirrored to Apple Reminders so they reach your Watch and Mac |
| Bee wearable | Connect a Bee in Backstage: Myna hears your Bee's live transcript (so "Myna, …" works when you talk to your Bee), turns finished Bee conversations into Myna notes, and syncs to-dos both ways |
| Siri & Shortcuts | "Add to my Myna shopping list", "Remind me with Myna", "Ask Myna", "Start Myna" — also usable from the Action button |
| Never drops a conversation | iOS forbids GPU work in the background on iPhone, so with an MLX model a conversation that ends while the phone is locked is queued and composed the moment Myna is opened; Apple Intelligence keeps composing while locked |
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
| **Apple Intelligence** (iOS 26+) | built in | — | Nothing to download, light on battery, and the only option that keeps composing while the phone is locked. Myna also uses it as a background helper whenever it's available |
| **Qwen 3 8B (4-bit)** | 4.6 GB | ~5.6 GB | ⚡ **Most powerful.** The strongest reasoning that runs on a phone — for 12 GB iPhones (17 Pro / Pro Max and newer) |
| **Llama 3.2 3B Instruct (4-bit)** | 1.8 GB | ~2.6 GB | ⭐ **Recommended.** Best quality-per-watt for structured note taking; ~20 tok/s on A17 Pro with system headroom to spare |
| Qwen 2.5 3B Instruct (4-bit) | 1.7 GB | ~2.5 GB | Excellent at dates/numbers and multilingual rooms |
| Qwen 3 4B (4-bit) | 2.3 GB | ~3.4 GB | Max quality that still fits comfortably in 8 GB |
| Llama 3.2 1B Instruct (4-bit) | 0.7 GB | ~1.2 GB | Fastest, lightest on battery; notes are less nuanced |

The MLX models are downloadable inside the app from the `mlx-community` organization
on Hugging Face. Inference runs through [MLX Swift](https://github.com/ml-explore/mlx-swift)
([`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm), pinned to the
stable 2.x line), which is Apple-maintained and tuned for Apple Silicon GPUs.

## Building & running

**Requirements:** Xcode 16.2+, a physical iPhone 15 Pro / Pro Max or newer on
iOS 18+ (MLX needs the device GPU — the simulator won't run the model), and an
Apple developer team for code signing.

1. Open `Myna.xcodeproj` in Xcode. Swift Package Manager resolves
   `mlx-swift-lm` and `mlx-swift` automatically on first open.
2. Signing is set up for bundle ID `com.lightwave.myna` on team `9BQDEVHKJZ`
   (automatic signing). The app uses the Increased Memory Limit, Extended
   Virtual Addressing and Time Sensitive Notifications capabilities, all
   enabled on that App ID.
3. Build & run on your iPhone.
4. First launch walks you through microphone, speech, calendar, reminders and
   notification permissions. Myna starts listening right away (turn off
   *Always on* in Backstage if you'd rather tap the orb). Visit **Neural
   Core** to pick Apple Intelligence or download a model (one-time, Wi-Fi
   suggested).
5. Say "Myna, add coffee to the shopping list." Have a conversation. Watch
   the note — and the to-dos you promised — appear.
6. Optional: in the Bee app, enable Developer Mode (Settings → tap Version
   five times), then **Backstage → Bee Wearable → Connect Bee** and approve
   Myna on the page that opens.

Every pull request is compiled by `.github/workflows/ios-build.yml` on a
macOS 26 runner (no signing).

### Project layout

```
Myna.xcodeproj/          Xcode 16 project (filesystem-synchronized groups)
Config/                  Info.plist + entitlements
Myna/
  MynaApp.swift          App entry; wires SwiftData + engines
  Theme/                 Aurora background, glass cards, palette
  AppServices.swift      Creates and wires everything (shared with App Intents)
  Audio/                 SpeechListener (engine tap + on-device recognition), VoiceReply
  Brain/
    CommandParser        "Myna, …" → command, rule-based, no GPU needed
    CommandSpotter       Finds wake word + finished command in live partial text
    TimePhrase           "tomorrow at 9", "in 20 minutes" → Date
    MynaBrain            Performs commands, talks back, LLM agent for open questions
  Engine/
    ConversationPilot    Conversation segmentation, composing, background queue
    ModelCatalog         Curated models (Apple Intelligence + MLX)
    ModelManager         Download / load / run; background fallback
    AppleIntelligenceEngine  FoundationModels wrapper (iOS 26+)
    NotesEngine          Chunked condensation → structured JSON note + personal follow-through
    EventScheduler       EventKit calendar writer / reader
    ReminderCenter       Notifications + Apple Reminders mirror
  Integrations/
    Bee/                 Bee developer API client, pairing (NaCl box), live sync
    Keychain             Token storage
  Intents/               Siri & Shortcuts
  Models/                SwiftData schema (ConversationNote, MynaItem, PendingConversation)
  Views/                 Dashboard, orb, notes, lists, Neural Core, settings, onboarding
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
- **Background reality:** the app stays alive while locked through the
  background audio mode, and voice commands, lists, reminders and calendar
  writes all work there. MLX inference can't (iOS blocks background GPU work
  on iPhone; the "Background GPU Access" capability currently only applies to
  M-series iPads), so those conversations queue until Myna is opened — or are
  composed by Apple Intelligence if it's on. If you swipe Myna away, iOS
  stops it; leave it running.
- **Talking back:** recognition pauses while Myna speaks so it never
  transcribes itself, and a command heard by both the phone and a Bee is only
  carried out once.
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
- The LLM runs locally (MLX or Apple Intelligence). Network traffic is limited
  to model downloads from Hugging Face and — only if you connect one — Bee's
  developer API.
- Notes and lists live in the app's private SwiftData store. Calendar events
  and Apple Reminders entries are created only for things you asked for or
  agreed to, and both can be switched off in Backstage.
