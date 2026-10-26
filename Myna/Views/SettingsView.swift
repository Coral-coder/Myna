import SwiftUI
import UIKit

/// Backstage: tune how Myna listens, composes and schedules.
struct SettingsView: View {
    @AppStorage("myna.silenceThreshold") private var silenceThreshold: Double = 90
    @AppStorage("myna.maxSegmentMinutes") private var maxSegmentMinutes: Int = 20
    @AppStorage("myna.autoSchedule") private var autoSchedule = true
    @AppStorage(BeeCloudImporter.autoAddKey) private var beeAutoAdd = true
    @AppStorage(BackgroundWaker.enabledKey) private var backgroundWake = true
    @AppStorage("myna.alwaysOn") private var alwaysOn = true
    @AppStorage("myna.micEnabled") private var micEnabled = true
    @AppStorage("myna.wakeWord") private var wakeWord = true
    @AppStorage("myna.speakReplies") private var speakReplies = true
    @AppStorage("myna.autoCapture") private var autoCapture = true
    @AppStorage("myna.mirrorReminders") private var mirrorReminders = true
    @AppStorage("myna.userName") private var userName = ""
    @AppStorage("myna.customWakeWord") private var customWakeWord = ""
    @AppStorage("myna.micSensitivity") private var micSensitivity: Double = 3.0
    @AppStorage("myna.useWhisper") private var useWhisper = true
    @AppStorage(ConversationPilot.composeNotesKey) private var composeNotes = false
    @AppStorage("myna.voiceIdentifier") private var voiceIdentifier = ""
    @AppStorage("myna.speakImportant") private var speakImportant = true
    @AppStorage("myna.agentPrompt") private var agentPrompt = ""
    @AppStorage("myna.webLookup") private var webLookup = true
    @EnvironmentObject private var pilot: ConversationPilot
    @EnvironmentObject private var listener: SpeechListener
    @EnvironmentObject private var whisper: WhisperTranscriber
    @EnvironmentObject private var neuralVoice: NeuralVoice
    @EnvironmentObject private var brain: MynaBrain

    /// The installed system voices, enumerated once. `AVSpeechSynthesisVoice
    /// .speechVoices()` is slow and was being called on every render of this
    /// screen (once for the label, once per row in the picker), which is what
    /// made Backstage lag. Cache it.
    @State private var cachedVoices: [VoiceOption] = []

    private var whisperStatus: String {
        switch whisper.state {
        case .notLoaded: return "Downloads a small model the first time."
        case .loading: return "Downloading the Whisper model…"
        case .ready: return "Ready — transcribing with Whisper."
        case .failed(let message): return "Couldn't load Whisper: \(message)"
        }
    }

    private var assistantName: String {
        let first = customWakeWord.split(whereSeparator: { $0 == "," || $0 == "\n" }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !first.isEmpty else { return "Myna" }
        return first.prefix(1).uppercased() + String(first.dropFirst())
    }

    private var sensitivityLabel: String {
        switch micSensitivity {
        case ..<1.5: return "Normal"
        case ..<4: return "High"
        case ..<6.5: return "Far"
        default: return "Max"
        }
    }

    private var selectedVoiceName: String {
        guard !voiceIdentifier.isEmpty,
              let match = cachedVoices.first(where: { $0.id == voiceIdentifier }) else {
            return "Best available"
        }
        return match.name
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Backstage")
                    .font(MynaTheme.display(24, weight: .bold))
                    .auroraText()
                    .padding(.top, 16)

                assistantCard
                naturalVoicesCard
                listeningCard
                automationCard
                DiagnosticsCard()
                ContextCard()
                BraceletCard()
                BeeCloudCard()
                privacyCard
                aboutCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .task {
            if cachedVoices.isEmpty { cachedVoices = brain.voice.availableVoices() }
        }
    }

    private var naturalVoicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(icon: "waveform.circle.fill", title: "Natural voices", tint: MynaTheme.cyan)
            Text("On-device neural voices (MIT-licensed) — fully offline once downloaded. Choose one and \(assistantName) speaks with it; the system voice is the fallback.")
                .settingsCaption()

            ForEach(neuralVoice.models) { model in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name).settingsLabel()
                            Text("\(model.mb) MB").settingsCaption()
                        }
                        Spacer()
                        neuralControl(for: model)
                    }
                    if case .downloading(let p) = neuralVoice.status(of: model.id) {
                        ProgressView(value: p).tint(MynaTheme.cyan)
                    } else if case .failed(let msg) = neuralVoice.status(of: model.id) {
                        Text(msg).font(.system(size: 12, design: .rounded)).foregroundStyle(MynaTheme.gold)
                    }
                }
            }

            if neuralVoice.isActive {
                Button("Use the system voice instead") { neuralVoice.setSelected("") }
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder
    private func neuralControl(for model: NeuralVoiceModel) -> some View {
        if neuralVoice.isInstalled(model.id) {
            if neuralVoice.selectedID == model.id {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(MynaTheme.mint)
            } else {
                Button("Use") { neuralVoice.setSelected(model.id) }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(MynaTheme.cyan)
            }
        } else if case .downloading = neuralVoice.status(of: model.id) {
            ProgressView().controlSize(.small).tint(MynaTheme.cyan)
        } else {
            Button("Download") { neuralVoice.download(model) }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(MynaTheme.cyan)
        }
    }

    private var assistantCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(icon: "person.wave.2.fill", title: "Assistant", tint: MynaTheme.cyan)

            VStack(alignment: .leading, spacing: 6) {
                Text("Your name").settingsLabel()
                TextField("So Myna knows which tasks are yours", text: $userName)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white)
                    .textContentType(.givenName)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
            }

            Toggle(isOn: $micEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use the iPhone mic").settingsLabel()
                    Text("Myna records and transcribes through this iPhone, on the device — and keeps going in the background and with the screen locked.").settingsCaption()
                }
            }
            .tint(MynaTheme.cyan)
            .onChange(of: micEnabled) { _, on in
                if !on { pilot.stopListening() }
            }

            if micEnabled {
                Toggle(isOn: $alwaysOn) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Always on").settingsLabel()
                        Text("Start listening whenever Myna opens and resume after calls. If iOS ever stops the mic in the background you'll get a notification to reopen Myna.").settingsCaption()
                    }
                }
                .tint(MynaTheme.cyan)
            }

            Toggle(isOn: $wakeWord) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Answer to a wake word").settingsLabel()
                    Text("Say the wake word, then your request — add to lists, set reminders, schedule things or ask a question.").settingsCaption()
                }
            }
            .tint(MynaTheme.cyan)

            if wakeWord {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom wake word").settingsLabel()
                    TextField("Myna", text: $customWakeWord)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
                        .onChange(of: customWakeWord) { _, _ in AppServices.applyCustomWakeWords() }
                    Text("Leave blank to use “Myna”. Set your own word or short phrase (e.g. your name, or “hey scribe”). Pick something distinct and two or more syllables so it’s easy to hear; separate several with commas. Your word is used alongside “Myna”. This is also the name it answers to.").settingsCaption()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("How \(assistantName) should act").settingsLabel()
                TextField("Describe its personality and how it should treat you…", text: $agentPrompt, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
                Text("Optional. Shapes its personality and tone — it keeps its name, its skills and the way it takes actions, this just changes how it feels to talk to. Leave blank for the default.").settingsCaption()
            }

            Toggle(isOn: $speakReplies) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Talk back").settingsLabel()
                    Text("\(assistantName) answers out loud in the voice you pick below.").settingsCaption()
                }
            }
            .tint(MynaTheme.cyan)

            if speakReplies {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Voice").settingsLabel()
                        Spacer()
                        Menu {
                            Button("Best available") {
                                voiceIdentifier = ""
                                brain.voice.preview(identifier: "")
                            }
                            ForEach(cachedVoices) { voice in
                                Button {
                                    voiceIdentifier = voice.id
                                    brain.voice.preview(identifier: voice.id)
                                } label: {
                                    Text(voice.quality == .standard ? voice.name : "\(voice.name) · \(voice.quality.label)")
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedVoiceName)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                            }
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(MynaTheme.cyan)
                        }
                    }
                    HStack(spacing: 16) {
                        Button("Preview") { brain.voice.preview(identifier: voiceIdentifier) }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(MynaTheme.cyan)
                        Button("Get more voices") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                    }
                    Text("For the most natural, Siri-quality sound, download a Premium or Enhanced voice in Settings → Accessibility → Spoken Content → Voices, then pick it here.").settingsCaption()
                }

                Toggle(isOn: $speakImportant) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Speak up about important things").settingsLabel()
                        Text("\(assistantName) says a quick line out loud when it captures a note or something needs you — only while the app is open.").settingsCaption()
                    }
                }
                .tint(MynaTheme.cyan)
            }

            Toggle(isOn: $autoCapture) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Catch things in conversation").settingsLabel()
                    Text("Tasks you commit to, things to buy and times to be reminded go straight to your lists.").settingsCaption()
                }
            }
            .tint(MynaTheme.cyan)

            Toggle(isOn: $mirrorReminders) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mirror to Apple Reminders").settingsLabel()
                    Text("To-dos, reminders and shopping also appear in Reminders, on your Watch and Mac.").settingsCaption()
                }
            }
            .tint(MynaTheme.cyan)

            Toggle(isOn: $webLookup) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Look things up online").settingsLabel()
                    Text("When \(assistantName) doesn't know something, it searches the web and answers from what it finds. Only your search query leaves the device, and only when it needs to look something up.").settingsCaption()
                }
            }
            .tint(MynaTheme.cyan)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var listeningCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(icon: "ear.badge.waveform", title: "Listening", tint: MynaTheme.cyan)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Microphone sensitivity")
                        .settingsLabel()
                    Spacer()
                    Text(sensitivityLabel)
                        .font(MynaTheme.display(14, weight: .bold))
                        .foregroundStyle(MynaTheme.cyan)
                }
                Slider(value: $micSensitivity, in: 1...8, step: 0.5)
                    .tint(MynaTheme.cyan)
                    .onChange(of: micSensitivity) { _, value in
                        listener.setSensitivity(Float(value))
                    }
                Text("Higher lets Myna hear voices farther across a room. If it starts catching background noise, ease it back down.")
                    .settingsCaption()
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $useWhisper) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Transcribe with Whisper").settingsLabel()
                        Text("Use OpenAI's Whisper for conversation notes — more accurate on distant or noisy speech. The quick “Myna…” wake word still uses Apple's recognizer.").settingsCaption()
                    }
                }
                .tint(MynaTheme.cyan)
                .onChange(of: useWhisper) { _, on in whisper.setEnabled(on) }

                if useWhisper {
                    Text(whisperStatus).settingsCaption()
                }
            }

            Toggle(isOn: $composeNotes) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Write AI notes").settingsLabel()
                    Text("Off: each conversation is saved as its transcript — fast, reliable, works in the background. On: the AI model also writes a summary note (slower, foreground model).").settingsCaption()
                }
            }
            .tint(MynaTheme.cyan)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("End a conversation after silence of")
                        .settingsLabel()
                    Spacer()
                    Text("\(Int(silenceThreshold))s")
                        .font(MynaTheme.display(14, weight: .bold))
                        .foregroundStyle(MynaTheme.cyan)
                }
                Slider(value: $silenceThreshold, in: 30...300, step: 15)
                    .tint(MynaTheme.cyan)
                Text("When the room goes quiet this long, Myna treats the conversation as finished and composes its note.")
                    .settingsCaption()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Compose long meetings every")
                        .settingsLabel()
                    Spacer()
                    Picker("", selection: $maxSegmentMinutes) {
                        ForEach([10, 15, 20, 30, 45], id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(MynaTheme.cyan)
                }
                Text("Marathon meetings are scribed in chapters so notes stay timely.")
                    .settingsCaption()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var automationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(icon: "wand.and.stars", title: "Automation", tint: MynaTheme.magenta)
            Toggle(isOn: $beeAutoAdd) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Act on Bee conversations")
                        .settingsLabel()
                    Text("Appointments go straight onto your calendar, and reminders, to-dos and shopping items onto your lists. Each one sends a notification to your iPhone and Apple Watch with a Cancel button. Anything less certain waits in the Inbox.")
                        .settingsCaption()
                }
            }
            .tint(MynaTheme.magenta)
            Toggle(isOn: $backgroundWake) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Check Bee in the background")
                        .settingsLabel()
                    Text(AppServices.shared.waker.statusText)
                        .settingsCaption()
                }
            }
            .tint(MynaTheme.magenta)
            .onChange(of: backgroundWake) { _, _ in AppServices.shared.waker.apply() }
            Toggle(isOn: $autoSchedule) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto-schedule detected meetings")
                        .settingsLabel()
                    Text("When Myna is confident about a date and time it heard, the event goes straight onto your calendar with a 15-minute alert. Less confident detections wait for your tap inside the note.")
                        .settingsCaption()
                }
            }
            .tint(MynaTheme.magenta)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.magenta)
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(icon: "lock.shield.fill", title: "Privacy Charter", tint: MynaTheme.mint)
            ForEach(privacyPoints, id: \.self) { point in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(MynaTheme.mint)
                    Text(point).settingsLabel()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.mint)
    }

    private var privacyPoints: [String] {
        [
            "Audio is never recorded to disk and never leaves this iPhone.",
            "Speech recognition runs with Apple's on-device engine.",
            "The AI runs locally — MLX on the GPU or Apple Intelligence — no cloud, no account.",
            "The only network use is the one-time model download — plus Apple Maps place names, only if you turn that on.",
            "Contacts, Health, Photos and Places are each off until you switch them on, and are read only on this iPhone.",
            "Saved places are kept in the Keychain, on this device only.",
            "Notes and lists are stored in the app's private database; sharing is always your explicit choice.",
        ]
    }

    private var aboutCard: some View {
        VStack(spacing: 6) {
            Text("MYNA")
                .font(MynaTheme.display(16, weight: .heavy))
                .tracking(8)
                .auroraText()
            Text("Your on-device second brain.\nNamed for the myna bird — a brilliant listener.")
                .settingsCaption()
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glassCard(glow: MynaTheme.gold)
    }
}

private extension Text {
    func settingsLabel() -> Text {
        font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.9))
    }

    func settingsCaption() -> Text {
        font(.system(size: 12, design: .rounded))
            .foregroundColor(.white.opacity(0.5))
    }
}
