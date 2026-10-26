import SwiftData
import SwiftUI

/// Myna's inbox. Everything it noticed in your Bee conversations — things to
/// buy, to do, to put on the calendar, people and numbers worth keeping — shown
/// as suggestions. Nothing is acted on until you tap Accept. This is the heart
/// of Myna-as-Bee-companion: no microphone, no listening, just your Bee
/// transcripts turned into things you can actually use.
struct SuggestionsView: View {
    @EnvironmentObject private var brain: MynaBrain
    @EnvironmentObject private var beeCloud: BeeCloudImporter
    @EnvironmentObject private var bee: BeeManager
    @EnvironmentObject private var listener: SpeechListener
    @EnvironmentObject private var pilot: ConversationPilot
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Suggestion.createdAt, order: .reverse) private var all: [Suggestion]
    @Query(sort: \ConversationNote.createdAt, order: .reverse) private var notes: [ConversationNote]

    private var pending: [Suggestion] { all.filter { $0.status == .pending } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeading(icon: "tray.full", title: "Inbox", tint: MynaTheme.cyan)
                    .padding(.top, 12)

                liveStatusStrip

                if pending.isEmpty {
                    emptyState
                    activityCards
                } else {
                    Text(pending.count == 1 ? "1 suggestion from your Bee" : "\(pending.count) suggestions from your Bee")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(pending) { suggestion in
                        SuggestionRow(
                            suggestion: suggestion,
                            accept: { accept(suggestion) },
                            dismiss: { dismiss(suggestion) }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .animation(.bouncy(duration: 0.35), value: pending.count)
        }
        .scrollIndicators(.hidden)
        .refreshable { await beeCloud.importRecent() }
    }

    // MARK: - Accept / dismiss

    private func accept(_ s: Suggestion) {
        switch s.kind {
        case .shopping:
            brain.add(.shopping, texts: [s.text], source: .conversation, noteID: s.noteID, announce: false)
        case .todo:
            brain.add(.todo, texts: [s.text], source: .conversation, noteID: s.noteID, announce: false)
        case .reminder:
            brain.add(.reminder, texts: [s.text], due: s.date, detail: s.detail, source: .conversation, noteID: s.noteID, announce: false)
        case .appointment:
            let (title, date, detail, noteID) = (s.text, s.date, s.detail, s.noteID)
            Task {
                if await !brain.addEvent(title: title, at: date, detail: detail, noteID: noteID) {
                    brain.add(.reminder, texts: [title], due: date, detail: detail, source: .conversation, noteID: noteID, announce: false)
                }
            }
        case .contact, .phone, .note:
            let text = s.kind == .phone ? "Call \(s.text)" : s.text
            brain.add(.memo, texts: [text], detail: s.detail, source: .conversation, noteID: s.noteID, announce: false)
        }
        s.status = .accepted
        try? modelContext.save()
    }

    private func dismiss(_ s: Suggestion) {
        s.status = .dismissed
        try? modelContext.save()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: beeCloud.hasToken ? "checkmark.seal.fill" : "link")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(MynaTheme.auroraGradient)
            Text(beeCloud.hasToken ? "Inbox zero" : "Connect your Bee")
                .font(MynaTheme.display(17, weight: .semibold))
                .foregroundStyle(.white)
            Text(beeCloud.hasToken
                 ? "Nothing waiting. New things to buy, do and remember land here as Myna hears them."
                 : "Myna reads your Bee conversations and turns them into suggestions. Connect your Bee account in Backstage to begin.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .glassCard(cornerRadius: 22)
    }

    // MARK: - Live + activity

    private var isLive: Bool { bee.pairing == .streaming || pilot.phase == .listening || listener.usingExternalSource }

    private var liveStatusStrip: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill((isLive ? MynaTheme.mint : .white.opacity(0.25)))
                    .frame(width: 8, height: 8)
                if isLive {
                    Circle().stroke(MynaTheme.mint.opacity(0.5), lineWidth: 1)
                        .frame(width: 16, height: 16)
                }
            }
            Text(statusText)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            if bee.pairing == .streaming {
                Text("\(bee.packetsDecoded) pkts")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassCard(cornerRadius: 14)
    }

    private var statusText: String {
        if bee.pairing == .streaming { return bee.audioActive ? "Listening through your bracelet" : "Bracelet connected" }
        if pilot.phase == .listening || listener.usingExternalSource { return "Listening on this iPhone" }
        if pilot.phase == .composing { return "Composing a note…" }
        return "Standing by"
    }

    private var acceptedToday: [Suggestion] {
        all.filter { $0.status == .accepted && Calendar.current.isDateInToday($0.createdAt) }
    }

    private var notesToday: [ConversationNote] {
        notes.filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    @ViewBuilder
    private var activityCards: some View {
        // Today's tally.
        HStack(spacing: 12) {
            miniStat("\(notesToday.count)", "Notes today", "sparkles.rectangle.stack", MynaTheme.cyan)
            miniStat("\(acceptedToday.count)", "Added today", "checkmark.circle", MynaTheme.mint)
            miniStat("\(notesToday.reduce(0) { $0 + $1.durationMinutes })m", "Captured", "waveform", MynaTheme.magenta)
        }

        // What Myna recently added for you.
        let recentHandled = all.filter { $0.status == .accepted }.prefix(6)
        if !recentHandled.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(icon: "clock.arrow.circlepath", title: "Recently added", tint: MynaTheme.mint)
                ForEach(Array(recentHandled)) { s in
                    HStack(spacing: 10) {
                        Image(systemName: s.kind.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MynaTheme.mint)
                            .frame(width: 20)
                        Text(CommandParser.capitalizeFirst(s.text))
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer()
                        Text(s.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 18)
        } else if let lastNote = notes.first {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(icon: "note.text", title: "Latest note", tint: MynaTheme.cyan)
                Text(lastNote.title.isEmpty ? "Untitled note" : lastNote.title)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !lastNote.overview.isEmpty {
                    Text(lastNote.overview)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(3)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 18)
        }
    }

    private func miniStat(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint)
            Text(value).font(MynaTheme.display(19, weight: .bold)).foregroundStyle(.white)
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
    }
}

/// One suggestion card with Accept / Dismiss.
private struct SuggestionRow: View {
    let suggestion: Suggestion
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: suggestion.kind.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MynaTheme.cyan)
                    .frame(width: 22)
                Text(suggestion.kind.title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                if let date = suggestion.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(MynaTheme.gold)
                }
            }

            Text(CommandParser.capitalizeFirst(suggestion.text))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if !suggestion.detail.isEmpty, suggestion.detail != suggestion.text {
                Text("“\(suggestion.detail)”")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !suggestion.sourceTitle.isEmpty {
                Label(suggestion.sourceTitle, systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Button(action: accept) {
                    Label("Accept", systemImage: "checkmark")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(MynaTheme.auroraGradient)
                        )
                        .foregroundStyle(MynaTheme.void)
                }
                .buttonStyle(.plain)

                Button(action: dismiss) {
                    Label("Dismiss", systemImage: "xmark")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }
}
