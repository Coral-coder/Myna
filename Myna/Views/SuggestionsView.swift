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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Suggestion.createdAt, order: .reverse) private var all: [Suggestion]

    private var pending: [Suggestion] { all.filter { $0.status == .pending } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeading(icon: "tray.full", title: "Inbox", tint: MynaTheme.cyan)
                    .padding(.top, 12)

                if pending.isEmpty {
                    emptyState
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
        VStack(spacing: 14) {
            Image(systemName: beeCloud.hasToken ? "sparkles" : "link")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(MynaTheme.auroraGradient)
            Text(beeCloud.hasToken ? "All caught up" : "Connect your Bee")
                .font(MynaTheme.display(17, weight: .semibold))
                .foregroundStyle(.white)
            Text(beeCloud.hasToken
                 ? "New conversations from your Bee will show up here as things to buy, do, and remember."
                 : "Myna reads your Bee conversations and turns them into suggestions. Connect your Bee account in Backstage to begin.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .glassCard(cornerRadius: 22)
        .padding(.top, 20)
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
