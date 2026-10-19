import SwiftData
import SwiftUI

/// Mission control: the orb, live captions, and today's tally.
struct DashboardView: View {
    @EnvironmentObject private var pilot: ConversationPilot
    @EnvironmentObject private var listener: SpeechListener
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var brain: MynaBrain
    @EnvironmentObject private var bee: BeeBridge

    @Query private var allNotes: [ConversationNote]
    @State private var question = ""
    @FocusState private var askFocused: Bool

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
                        isComposing: pilot.phase == .composing,
                        level: listener.audioLevel
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                statusLine

                statusChips

                assistantCard

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

                if !modelManager.hasAnyModelInstalled {
                    modelCTA
                }

                todayCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
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
        case .listening: return "Listening…"
        case .composing: return "Imagining your notes…"
        }
    }

    private var statusSubtitle: String {
        switch pilot.phase {
        case .idle:
            return "Tap the orb to begin. Everything is heard,\nunderstood and stored only on this iPhone."
        case .listening:
            return "Say “Myna, …” any time. Notes appear when\na conversation ends. Tap the orb to stop."
        case .composing:
            return "The on-device model is composing detailed\nnotes from what it just heard."
        }
    }

    @ViewBuilder
    private var statusChips: some View {
        if pilot.queuedCount > 0 || bee.isConnected {
            HStack(spacing: 8) {
                if pilot.queuedCount > 0 {
                    GlowChip(
                        text: "\(pilot.queuedCount) waiting to compose",
                        icon: "hourglass",
                        tint: MynaTheme.gold
                    )
                }
                if bee.isConnected {
                    GlowChip(
                        text: bee.isLive ? "Bee live" : "Bee connected",
                        icon: "circle.hexagongrid.fill",
                        tint: bee.isLive ? MynaTheme.mint : MynaTheme.cyan
                    )
                }
            }
        }
    }

    private var assistantCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(icon: "bubble.left.and.text.bubble.right.fill", title: "Ask Myna", tint: MynaTheme.magenta)

            if let exchange = brain.lastExchange {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(exchange.heard)”")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                    Text(exchange.reply)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("Try “Myna, add eggs to the shopping list”, “remind me to call Mom at 6”, “what's on my calendar tomorrow?” or ask about any conversation.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(spacing: 10) {
                TextField("Type to Myna…", text: $question)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.white)
                    .focused($askFocused)
                    .submitLabel(.send)
                    .onSubmit(sendQuestion)
                if brain.isThinking {
                    ProgressView().tint(MynaTheme.magenta)
                } else if !question.isEmpty {
                    Button(action: sendQuestion) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(MynaTheme.magenta)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.magenta)
        .animation(.easeOut(duration: 0.25), value: brain.lastExchange)
    }

    private func sendQuestion() {
        let text = question
        question = ""
        askFocused = false
        Task { await brain.handleTyped(text) }
    }

    private var liveTranscriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(icon: "text.quote", title: "Live Caption", tint: MynaTheme.mint)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pilot.liveTranscriptTail) { line in
                    Text(line.text)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
                if !listener.liveTranscript.isEmpty {
                    Text(listener.liveTranscript)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(MynaTheme.mint)
                        .lineLimit(3)
                        .contentTransition(.interpolate)
                }
                if pilot.liveTranscriptTail.isEmpty && listener.liveTranscript.isEmpty {
                    Text("Waiting for voices…")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .italic()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.mint)
        .animation(.easeOut(duration: 0.25), value: listener.liveTranscript)
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
            Text("Myna needs a local model before it can compose notes and answer questions. Head to the Neural Core tab and download \(ModelCatalog.model(withID: ModelCatalog.recommendedID)?.displayName ?? "a model") — it's a one-time download. Voice commands and lists already work.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassCard(glow: MynaTheme.gold)
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
