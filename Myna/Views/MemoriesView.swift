import SwiftData
import SwiftUI

/// Your memory — the durable facts Myna has distilled about you, plus outside
/// wisdom worth keeping. Omi's "second brain", on-device. Browse, add your own,
/// pin the ones that matter, and set aside the ones that don't.
struct MemoriesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Memory> { !$0.archived },
        sort: [SortDescriptor(\Memory.createdAt, order: .reverse)]
    )
    private var memories: [Memory]

    @State private var draft = ""
    @FocusState private var adding: Bool

    private var grouped: [(MemoryCategory, [Memory])] {
        MemoryCategory.allCases.compactMap { category in
            let items = memories
                .filter { $0.category == category }
                .sorted { a, b in a.pinned != b.pinned ? a.pinned : a.createdAt > b.createdAt }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                addRow
                if memories.isEmpty {
                    emptyState
                } else {
                    ForEach(grouped, id: \.0) { category, items in
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeading(icon: category.icon, title: category.title, tint: MynaTheme.cyan)
                            ForEach(items) { memory in row(memory) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        Text("Memory")
            .font(MynaTheme.style == .grid ? MynaTheme.display(24, weight: .bold) : .system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(MynaTheme.style == .minimal ? AnyShapeStyle(.white) : AnyShapeStyle(MynaTheme.auroraGradient))
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            TextField("Add something to remember…", text: $draft, axis: .vertical)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1...3)
                .focused($adding)
                .onSubmit(addManual)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
            Button(action: addManual) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(MynaTheme.void)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(draft.trimmingCharacters(in: .whitespaces).isEmpty ? .white.opacity(0.2) : MynaTheme.cyan))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func row(_ memory: Memory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if memory.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(MynaTheme.gold)
                    .padding(.top, 3)
            }
            Text(memory.content)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Menu {
                Button { memory.pinned.toggle(); try? modelContext.save() } label: {
                    Label(memory.pinned ? "Unpin" : "Pin", systemImage: memory.pinned ? "pin.slash" : "pin")
                }
                Button { memory.archived = true; try? modelContext.save() } label: {
                    Label("Set aside", systemImage: "archivebox")
                }
                Button(role: .destructive) { modelContext.delete(memory); try? modelContext.save() } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 28, height: 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassCard(cornerRadius: 14)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing remembered yet.")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Text("As Myna hears your conversations, it keeps the durable facts about you here — your preferences, people, projects — plus any outside wisdom worth holding onto. You can add your own above.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.top, 20)
    }

    private func addManual() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        modelContext.insert(Memory(content: text, category: .system, manuallyAdded: true))
        try? modelContext.save()
        draft = ""
        adding = false
    }
}
