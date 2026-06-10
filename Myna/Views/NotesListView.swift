import SwiftData
import SwiftUI

/// The archive: every conversation Myna has scribed, newest first.
struct NotesListView: View {
    @Query(sort: \ConversationNote.createdAt, order: .reverse) private var notes: [ConversationNote]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    SectionHeading(icon: "sparkles.rectangle.stack", title: "Field Notes", tint: MynaTheme.cyan)
                        .padding(.top, 12)

                    if notes.isEmpty {
                        emptyState
                    } else {
                        ForEach(groupedDays, id: \.self) { day in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(dayLabel(day))
                                    .font(MynaTheme.display(13, weight: .semibold))
                                    .foregroundStyle(MynaTheme.gold)
                                    .tracking(2)
                                    .textCase(.uppercase)
                                ForEach(notesByDay[day] ?? []) { note in
                                    NavigationLink(value: note.id) {
                                        NoteCard(note: note)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            modelContext.delete(note)
                                            try? modelContext.save()
                                        } label: {
                                            Label("Delete Note", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .navigationDestination(for: UUID.self) { id in
                if let note = notes.first(where: { $0.id == id }) {
                    NoteDetailView(note: note)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .background(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private var notesByDay: [Date: [ConversationNote]] {
        Dictionary(grouping: notes) { Calendar.current.startOfDay(for: $0.createdAt) }
    }

    private var groupedDays: [Date] {
        notesByDay.keys.sorted(by: >)
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.stars")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(MynaTheme.auroraGradient)
            Text("No notes yet")
                .font(MynaTheme.display(17, weight: .semibold))
                .foregroundStyle(.white)
            Text("Start listening from the Listen tab.\nWhen a conversation winds down, its note will appear here like magic.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 70)
    }
}

private struct NoteCard: View {
    let note: ConversationNote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(note.title)
                    .font(MynaTheme.display(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Text(note.overview.isEmpty ? String(note.transcript.prefix(120)) : note.overview)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(3)
            HStack(spacing: 8) {
                GlowChip(text: note.startedAt.formatted(date: .omitted, time: .shortened), icon: "clock", tint: MynaTheme.mint)
                if !note.actionItems.isEmpty {
                    GlowChip(text: "\(note.actionItems.count) tasks", icon: "checklist", tint: MynaTheme.cyan)
                }
                if !note.detectedEvents.isEmpty {
                    GlowChip(text: "\(note.detectedEvents.count) events", icon: "calendar", tint: MynaTheme.magenta)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }
}
