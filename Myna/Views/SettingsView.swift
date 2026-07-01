import SwiftUI

/// Backstage: tune how Myna listens, composes and schedules.
struct SettingsView: View {
    @AppStorage("myna.silenceThreshold") private var silenceThreshold: Double = 90
    @AppStorage("myna.maxSegmentMinutes") private var maxSegmentMinutes: Int = 20
    @AppStorage("myna.autoSchedule") private var autoSchedule = true
    @AppStorage("myna.whisperLanguage") private var whisperLanguage = "en"

    private let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("hi", "Hindi"),
        ("", "Auto-detect"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Backstage")
                    .font(MynaTheme.display(24, weight: .bold))
                    .auroraText()
                    .padding(.top, 16)

                listeningCard
                transcriptionCard
                automationCard
                privacyCard
                aboutCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var transcriptionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(icon: "waveform", title: "Transcription", tint: MynaTheme.mint)
            HStack {
                Text("Spoken language")
                    .settingsLabel()
                Spacer()
                Picker("", selection: $whisperLanguage) {
                    ForEach(languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
                .tint(MynaTheme.mint)
            }
            Text("Whisper transcribes on the Neural Engine. Pick a language for best accuracy, or Auto-detect for mixed or unknown speech. English-only models always transcribe English regardless of this setting.")
                .settingsCaption()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.mint)
    }

    private var listeningCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(icon: "ear.badge.waveform", title: "Listening", tint: MynaTheme.cyan)

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
            "Speech is transcribed by OpenAI Whisper running on the Neural Engine.",
            "The note-writing model runs locally on the GPU — no cloud, no account.",
            "The only network use is the one-time model downloads.",
            "Notes are stored in the app's private database; sharing is always your explicit choice.",
        ]
    }

    private var aboutCard: some View {
        VStack(spacing: 6) {
            Text("MYNA")
                .font(MynaTheme.display(16, weight: .heavy))
                .tracking(8)
                .auroraText()
            Text("Your on-device conversation scribe.\nNamed for the myna bird — a brilliant listener.")
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
