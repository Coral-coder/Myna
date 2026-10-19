import SwiftData
import SwiftUI

/// To-dos, shopping, reminders and memos — everything Myna is keeping track
/// of for you, whether you said it, typed it, or it came up in conversation.
struct ListsView: View {
    @EnvironmentObject private var brain: MynaBrain
    @Query(sort: \MynaItem.createdAt) private var items: [MynaItem]

    @AppStorage("myna.lists.kind") private var kindRaw = ItemKind.todo.rawValue
    @State private var draft = ""
    @State private var showDone = false
    @FocusState private var draftFocused: Bool

    private var kind: ItemKind { ItemKind(rawValue: kindRaw) ?? .todo }

    private var open: [MynaItem] {
        let list = items.filter { $0.kind == kind && !$0.isDone }
        guard kind == .reminder else { return list }
        // Reminders read best soonest-first, undated at the end.
        return list.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var done: [MynaItem] {
        items.filter { $0.kind == kind && $0.isDone }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeading(icon: "checklist", title: "Lists", tint: MynaTheme.gold)
                    .padding(.top, 12)

                kindPicker
                composer

                if open.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(open) { item in
                            ItemRow(item: item)
                        }
                    }
                }

                if !done.isEmpty {
                    doneSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Pieces

    private var kindPicker: some View {
        HStack(spacing: 8) {
            ForEach(ItemKind.allCases) { option in
                let count = items.filter { $0.kind == option && !$0.isDone }.count
                Button {
                    withAnimation(.bouncy(duration: 0.3)) { kindRaw = option.rawValue }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.icon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(count > 0 ? "\(option.title) \(count)" : option.title)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(option == kind ? AnyShapeStyle(MynaTheme.auroraGradient) : AnyShapeStyle(.white.opacity(0.5)))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(option == kind ? 0.09 : 0.03))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(MynaTheme.auroraGradient)
            TextField(placeholder, text: $draft)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.white)
                .focused($draftFocused)
                .submitLabel(.done)
                .onSubmit(addDraft)
            if !draft.isEmpty {
                Button(action: addDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(MynaTheme.cyan)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 18, glow: MynaTheme.gold)
    }

    private var placeholder: String {
        switch kind {
        case .todo: return "Add a to-do…"
        case .shopping: return "Milk, eggs, coffee…"
        case .reminder: return "Call Mom tomorrow at 6…"
        case .memo: return "Jot something down…"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: kind.icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(MynaTheme.auroraGradient)
            Text(emptyTitle)
                .font(MynaTheme.display(16, weight: .semibold))
                .foregroundStyle(.white)
            Text(emptyHint)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
    }

    private var emptyTitle: String {
        switch kind {
        case .todo: return "Nothing to do"
        case .shopping: return "Shopping list is empty"
        case .reminder: return "No reminders"
        case .memo: return "No memos yet"
        }
    }

    private var emptyHint: String {
        switch kind {
        case .todo: return "Say “Myna, I need to renew my passport” —\nor just mention it in a meeting."
        case .shopping: return "Say “Myna, we're out of coffee”\nand it lands here."
        case .reminder: return "Say “Myna, remind me to call Mom at 6.”"
        case .memo: return "Say “Myna, take a note: the garage code is 4512.”"
        }
    }

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.easeInOut) { showDone.toggle() }
                } label: {
                    HStack {
                        Text("Completed · \(done.count)")
                            .font(MynaTheme.display(13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        Image(systemName: showDone ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if showDone {
                    Button("Clear") {
                        for item in done { brain.delete(item) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(MynaTheme.magenta)
                }
            }

            if showDone {
                ForEach(done.prefix(40)) { item in
                    ItemRow(item: item)
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Actions

    private func addDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch kind {
        case .shopping:
            brain.add(.shopping, texts: CommandParser.splitItems(text), source: .typed)
        case .reminder, .todo:
            if let match = TimePhrase.find(in: text), match.hasTime || kind == .reminder {
                brain.add(.reminder, texts: [match.remainder.isEmpty ? text : match.remainder], due: match.date, source: .typed)
            } else {
                brain.add(kind, texts: [text], source: .typed)
            }
        case .memo:
            brain.add(.memo, texts: [text], source: .typed)
        }
        draft = ""
        draftFocused = true
    }
}

private struct ItemRow: View {
    @Bindable var item: MynaItem
    @EnvironmentObject private var brain: MynaBrain

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if item.kind != .memo {
                Button {
                    withAnimation(.snappy) { brain.setDone(item, !item.isDone) }
                } label: {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(item.isDone ? MynaTheme.mint : .white.opacity(0.45))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(item.isDone ? .white.opacity(0.4) : .white)
                    .strikethrough(item.isDone, color: .white.opacity(0.4))
                HStack(spacing: 8) {
                    if let due = item.dueDate {
                        Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.fill")
                            .foregroundStyle(due < .now && !item.isDone ? MynaTheme.magenta : MynaTheme.gold)
                    }
                    Label(sourceLabel, systemImage: item.source.icon)
                        .foregroundStyle(.white.opacity(0.4))
                    if item.beeTodoID != nil {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(MynaTheme.cyan.opacity(0.7))
                    }
                }
                .font(.system(size: 11, design: .rounded))
                .labelStyle(.titleAndIcon)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18, glow: item.kind == .shopping ? MynaTheme.mint : MynaTheme.cyan)
        .contextMenu {
            Button(role: .destructive) {
                brain.delete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var sourceLabel: String {
        switch item.source {
        case .voice: return "Said"
        case .typed: return "Typed"
        case .conversation: return "Heard"
        case .bee: return "Bee"
        case .siri: return "Siri"
        }
    }
}
