import SwiftUI

/// Backstage: tune how Myna listens, composes and schedules.
struct SettingsView: View {
    @AppStorage("myna.silenceThreshold") private var silenceThreshold: Double = 90
    @AppStorage("myna.maxSegmentMinutes") private var maxSegmentMinutes: Int = 20
    @AppStorage("myna.autoSchedule") private var autoSchedule = true
    @AppStorage("myna.alwaysOn") private var alwaysOn = true
    @AppStorage("myna.wakeWord") private var wakeWord = true
    @AppStorage("myna.speakReplies") private var speakReplies = true
    @AppStorage("myna.autoCapture") private var autoCapture = true
    @AppStorage("myna.mirrorReminders") private var mirrorReminders = true
    @AppStorage("myna.userName") private var userName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Backstage")
                    .font(MynaTheme.display(24, weight: .bold))
                    .auroraText()
                    .padding(.top, 16)

                assistantCard
                listeningCard
                automationCard
                ContextCard()
                BraceletCard()
                privacyCard
                aboutCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
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

            Toggle(isOn: $alwaysOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Always on").settingsLabel()
                    Text("Start listening whenever Myna opens and resume after calls. iOS stops Myna if you swipe it away, so leave it running.").settingsCaption()
                }
            }
            .tint(MynaTheme.cyan)

            Toggle(isOn: $wakeWord) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Answer to “Myna”").settingsLabel()
                    Text("Say “Myna, …” to add to lists, set reminders, schedule things or ask a question.").settingsCaption()
                }
            }
            .tint(MynaTheme.cyan)

            Toggle(isOn: $speakReplies) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Talk back").settingsLabel()
                    Text("Myna answers out loud. Download a Premium voice in Settings → Accessibility → Spoken Content for the most natural sound.").settingsCaption()
                }
            }
            .tint(MynaTheme.cyan)

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
