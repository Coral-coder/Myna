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
    // Only what's waiting, fetched by the store — not every suggestion ever made,
    // filtered on each redraw. This screen also no longer watches the bracelet or
    // the microphone, whose many-times-a-second updates were rebuilding the whole
    // list and made it crawl.
    @Query private var pending: [Suggestion]
    @State private var confirmingClear = false

    init() {
        let waiting = SuggestionStatus.pending.rawValue
        _pending = Query(filter: #Predicate<Suggestion> { $0.statusRaw == waiting },
                         sort: \Suggestion.createdAt, order: .reverse)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if pending.isEmpty {
                    Text(beeCloud.hasToken
                         ? "Nothing waiting. New things to buy, do and remember land here as Myna hears them."
                         : "Nothing waiting.")
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(MynaTheme.muted)
                        .padding(.vertical, 16)
                }
                ForEach(pending) { suggestion in
                    SuggestionRow(
                        suggestion: suggestion,
                        accept: { accept(suggestion) },
                        dismiss: { dismiss(suggestion) }
                    )
                    Rectangle().fill(MynaTheme.hairSoft).frame(height: 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .refreshable { await beeCloud.importRecent() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(pending.count == 1 ? "1 waiting" : "\(pending.count) waiting")
                .font(MynaTheme.mono(11))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(MynaTheme.faint)
            Spacer()
            if !pending.isEmpty {
                if confirmingClear {
                    Button { confirmingClear = false } label: {
                        Text("Keep")
                            .font(MynaTheme.mono(11)).tracking(1).textCase(.uppercase)
                            .foregroundStyle(MynaTheme.muted)
                    }
                    .buttonStyle(.plain)
                    Button { clearAll() } label: {
                        Text("Clear all \(pending.count)")
                            .font(MynaTheme.mono(11)).tracking(1).textCase(.uppercase)
                            .foregroundStyle(MynaTheme.paper)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(MynaTheme.ink))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { confirmingClear = true } label: {
                        Text("Clear all")
                            .font(MynaTheme.mono(11)).tracking(1).textCase(.uppercase)
                            .foregroundStyle(MynaTheme.ink)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .overlay(Capsule().strokeBorder(MynaTheme.hair, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
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

    /// Dismiss everything that's waiting, in one save.
    private func clearAll() {
        let dismissed = SuggestionStatus.dismissed.rawValue
        let waiting = pending
        for suggestion in waiting { suggestion.statusRaw = dismissed }
        try? modelContext.save()
        confirmingClear = false
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
                    .foregroundStyle(MynaTheme.ink.opacity(0.45))
                Spacer()
                if let date = suggestion.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(MynaTheme.gold)
                }
            }

            Text(CommandParser.capitalizeFirst(suggestion.text))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MynaTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !suggestion.detail.isEmpty, suggestion.detail != suggestion.text {
                Text("“\(suggestion.detail)”")
                    .font(.system(size: 12))
                    .foregroundStyle(MynaTheme.ink.opacity(0.45))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !suggestion.sourceTitle.isEmpty {
                Label(suggestion.sourceTitle, systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MynaTheme.ink.opacity(0.35))
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
                                .fill(MynaTheme.ink.opacity(0.06))
                        )
                        .foregroundStyle(MynaTheme.ink.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 14)
    }
}
