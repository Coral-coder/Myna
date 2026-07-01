import SwiftData
import SwiftUI

/// Mission control: the orb, live captions, and today's tally.
struct DashboardView: View {
    @EnvironmentObject private var pilot: ConversationPilot
    @EnvironmentObject private var capture: AudioCaptureEngine
    @EnvironmentObject private var transcriber: WhisperTranscriber
    @EnvironmentObject private var modelManager: ModelManager

    @Query private var allNotes: [ConversationNote]

    private var notesToday: [ConversationNote] {
        allNotes.filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                Button(action: toggleListening) {
                    ListeningOrb(
                        isListening: pilot.phase == .listening,
                        isComposing: pilot.phase == .composing || transcriber.isTranscribing,
                        level: capture.audioLevel
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                statusLine

                if pilot.phase == .listening || pilot.phase == .composing {
                    liveTranscriptCard
                }

                if pilot.phase == .listening && pilot.hasMeaningfulContent {
                    Button(action: pilot.composeNow) {
                        Label("Conclude & Compose Note", systemImage: "wand.and.stars")
                            .font(MynaTheme.display(15, weight: .semibold))
                            .foregroundStyle(MynaTheme.void)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 13)
                            .background(Capsule().fill(MynaTheme.auroraGradient))
                            .shadow(color: MynaTheme.magenta.opacity(0.5), radius: 14, y: 6)
                    }
                    .buttonStyle(.plain)
                }

                if !transcriber.hasAnyModelInstalled || !modelManager.hasAnyModelInstalled {
                    modelCTA
                }

                todayCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 4) {
            Text("MYNA")
                .font(MynaTheme.display(34, weight: .heavy))
                .tracking(12)
                .auroraText()
                .shadow(color: MynaTheme.cyan.opacity(0.6), radius: 14)
            Text(Date.now.formatted(date: .complete, time: .omitted))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(1.5)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusLine: some View {
        VStack(spacing: 6) {
            Text(statusTitle)
                .font(MynaTheme.display(19, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.opacity)
                .animation(.easeInOut, value: statusTitle)
            Text(statusSubtitle)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
    }

    private var statusTitle: String {
        switch pilot.phase {
        case .idle: return "Standing by"
        case .listening: return capture.isReacquiring ? "Reconnecting…" : "Listening…"
        case .composing: return "Imagining your notes…"
        }
    }

    private var statusSubtitle: String {
        switch pilot.phase {
        case .idle:
            return "Tap the orb to begin. Everything is heard,\nunderstood and stored only on this iPhone."
        case .listening:
            if capture.isReacquiring {
                return "The mic is busy elsewhere (a call, or another app).\nMyna stays on and grabs it back the moment it's free."
            }
            return "Myna takes notes when a conversation ends.\nTap the orb again to stop."
        case .composing:
            return "The on-device model is composing detailed\nnotes from what it just heard."
        }
    }

    private var liveTranscriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeading(icon: "text.quote", title: "Live Caption", tint: MynaTheme.mint)
                if transcriber.isTranscribing {
                    GlowChip(text: "Transcribing", icon: "waveform.badge.magnifyingglass", tint: MynaTheme.gold)
                } else if capture.isSpeaking {
                    GlowChip(text: "Hearing", icon: "ear.fill", tint: MynaTheme.cyan)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pilot.liveTranscriptTail) { line in
                    Text(line.text)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(3)
                        .contentTransition(.interpolate)
                }
                if pilot.liveTranscriptTail.isEmpty {
                    Text(capture.isSpeaking ? "Listening to the room…" : "Waiting for voices…")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .italic()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.mint)
        .animation(.easeOut(duration: 0.25), value: pilot.liveTranscriptTail)
    }

    private var modelCTA: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 30))
                .foregroundStyle(MynaTheme.gold)
                .symbolEffect(.pulse)
            Text("Install your AI scribe")
                .font(MynaTheme.display(16, weight: .semibold))
                .foregroundStyle(.white)
            Text(ctaMessage)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassCard(glow: MynaTheme.gold)
    }

    private var ctaMessage: String {
        let needsEars = !transcriber.hasAnyModelInstalled
        let needsMind = !modelManager.hasAnyModelInstalled
        switch (needsEars, needsMind) {
        case (true, true):
            return "Head to the Neural Core tab to download Myna's ears (Whisper) and its mind (the note-writing model). Both run entirely on this iPhone."
        case (true, false):
            return "Myna still needs its ears. Download a Whisper speech model in the Neural Core tab to start transcribing — it's a one-time download."
        default:
            return "Myna still needs its mind. Download a note-writing model in the Neural Core tab so it can compose notes from what it hears."
        }
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(icon: "sun.max.fill", title: "Today", tint: MynaTheme.gold)
            HStack(spacing: 12) {
                statBlock(value: "\(notesToday.count)", label: "Notes", icon: "sparkles.rectangle.stack", tint: MynaTheme.cyan)
                statBlock(value: "\(notesToday.flatMap(\.detectedEvents).filter(\.isScheduled).count)", label: "Scheduled", icon: "calendar.badge.checkmark", tint: MynaTheme.magenta)
                statBlock(value: "\(notesToday.reduce(0) { $0 + $1.durationMinutes })m", label: "Captured", icon: "waveform", tint: MynaTheme.mint)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .padding(.bottom, 12)
    }

    private func statBlock(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
            Text(value)
                .font(MynaTheme.display(21, weight: .bold))
                .foregroundStyle(.white)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
    }

    // MARK: - Actions

    private func toggleListening() {
        switch pilot.phase {
        case .idle, .composing:
            pilot.startListening()
        case .listening:
            pilot.stopListening()
        }
    }
}
