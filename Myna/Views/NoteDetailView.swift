import EventKit
import SwiftData
import SwiftUI

/// A single note, fully unfurled — with one-tap export to Apple Notes and
/// calendar scheduling for any meetings Myna overheard being planned.
struct NoteDetailView: View {
    @Bindable var note: ConversationNote
    @EnvironmentObject private var pilot: ConversationPilot
    @Environment(\.modelContext) private var modelContext
    @State private var scheduleError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero

                if !note.people.isEmpty {
                    section(icon: "person.2.fill", title: "People", tint: MynaTheme.gold) {
                        bulletList(note.people, bullet: "•", tint: MynaTheme.gold)
                    }
                }

                if !note.photoIdentifiers.isEmpty {
                    section(icon: "photo.on.rectangle", title: "Photos", tint: MynaTheme.gold) {
                        NotePhotoStrip(identifiers: note.photoIdentifiers)
                    }
                }

                if !note.overview.isEmpty {
                    section(icon: "scope", title: "Overview", tint: MynaTheme.cyan) {
                        Text(note.overview).noteBody()
                    }
                }

                if !note.detailedNotes.isEmpty {
                    section(icon: "text.alignleft", title: "Detailed Notes", tint: MynaTheme.cyan) {
                        Text(note.detailedNotes).noteBody()
                    }
                }

                if !note.keyPoints.isEmpty {
                    section(icon: "star.fill", title: "Key Points", tint: MynaTheme.gold) {
                        bulletList(note.keyPoints, bullet: "✦", tint: MynaTheme.gold)
                    }
                }

                if !note.decisions.isEmpty {
                    section(icon: "checkmark.seal.fill", title: "Decisions", tint: MynaTheme.mint) {
                        bulletList(note.decisions, bullet: "✔", tint: MynaTheme.mint)
                    }
                }

                if !note.actionItems.isEmpty {
                    section(icon: "checklist", title: "Action Items", tint: MynaTheme.cyan) {
                        actionItemsList
                    }
                }

                if !note.detectedEvents.isEmpty {
                    section(icon: "calendar.badge.plus", title: "Events Detected", tint: MynaTheme.magenta) {
                        eventsList
                    }
                }

                if !note.followUps.isEmpty {
                    section(icon: "arrow.uturn.forward", title: "Follow-ups", tint: MynaTheme.magenta) {
                        bulletList(note.followUps, bullet: "→", tint: MynaTheme.magenta)
                    }
                }

                transcriptSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color.clear)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // "Save to Notes" lives in the share sheet — choose Notes there.
                ShareLink(item: note.exportText, subject: Text(note.title)) {
                    Label("Send to Apple Notes", systemImage: "square.and.arrow.up")
                        .foregroundStyle(MynaTheme.cyan)
                }
            }
        }
        .alert("Couldn't schedule", isPresented: .init(
            get: { scheduleError != nil },
            set: { if !$0 { scheduleError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scheduleError ?? "")
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - Pieces

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.title)
                .font(MynaTheme.display(26, weight: .bold))
                .auroraText()
            HStack(spacing: 8) {
                GlowChip(
                    text: "\(note.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(note.durationMinutes) min",
                    icon: "clock",
                    tint: MynaTheme.mint
                )
                if !note.modelName.isEmpty {
                    GlowChip(text: note.modelName, icon: "cpu", tint: MynaTheme.gold)
                }
            }
            if !note.placeName.isEmpty {
                GlowChip(text: note.placeName, icon: "mappin.and.ellipse", tint: MynaTheme.cyan)
            }
            Text("Composed entirely on this iPhone")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 8)
    }

    private func section(icon: String, title: String, tint: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(icon: icon, title: title, tint: tint)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 22, glow: tint)
    }

    private func bulletList(_ items: [String], bullet: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 9) {
                    Text(bullet).foregroundStyle(tint)
                    Text(item).noteBody()
                }
            }
        }
    }

    private var actionItemsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(note.actionItems) { item in
                Button {
                    toggle(item)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isDone ? MynaTheme.mint : .white.opacity(0.4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.task)
                                .strikethrough(item.isDone, color: .white.opacity(0.5))
                                .noteBody()
                            if item.owner != nil || item.due != nil {
                                Text([item.owner, item.due.map { "due \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var eventsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(note.detectedEvents) { event in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(event.startDate?.formatted(date: .abbreviated, time: .shortened) ?? "“\(event.rawWhen)”")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(MynaTheme.magenta)
                        if let location = event.location, !location.isEmpty {
                            Text(location)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Spacer()
                    if event.isScheduled {
                        GlowChip(text: "On Calendar", icon: "checkmark", tint: MynaTheme.mint)
                    } else {
                        Button {
                            schedule(event)
                        } label: {
                            GlowChip(text: "Schedule", icon: "calendar.badge.plus", tint: MynaTheme.cyan)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var transcriptSection: some View {
        DisclosureGroup {
            Text(note.transcript)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            SectionHeading(icon: "waveform", title: "Full Transcript", tint: MynaTheme.mint)
        }
        .tint(.white.opacity(0.6))
        .padding(18)
        .glassCard(cornerRadius: 22, glow: MynaTheme.mint)
    }

    // MARK: - Actions

    private func toggle(_ item: ActionItem) {
        guard let index = note.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
        var items = note.actionItems
        items[index].isDone.toggle()
        note.actionItems = items
        try? modelContext.save()
    }

    private func schedule(_ event: DetectedEvent) {
        Task { @MainActor in
            if !pilot.scheduler.hasAccess {
                _ = await pilot.scheduler.requestAccess()
            }
            do {
                let identifier = try pilot.scheduler.schedule(event)
                if let index = note.detectedEvents.firstIndex(where: { $0.id == event.id }) {
                    var events = note.detectedEvents
                    events[index].calendarEventID = identifier
                    note.detectedEvents = events
                    try? modelContext.save()
                }
            } catch {
                scheduleError = error.localizedDescription
            }
        }
    }
}

/// Thumbnails of the photos taken during a conversation. Photos you've since
/// deleted, or that iOS no longer lets Myna see, simply don't appear.
private struct NotePhotoStrip: View {
    let identifiers: [String]
    @State private var images: [Thumbnail] = []

    private struct Thumbnail: Identifiable {
        let id: String
        let image: UIImage
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(images) { entry in
                    Image(uiImage: entry.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: images.isEmpty ? 0 : 96)
        .task(id: identifiers) {
            var loaded: [Thumbnail] = []
            for id in identifiers {
                if let image = await PhotosContext.thumbnail(for: id, side: 240) {
                    loaded.append(Thumbnail(id: id, image: image))
                }
            }
            images = loaded
        }
    }
}

private extension Text {
    func noteBody() -> some View {
        font(.system(size: 14, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .lineSpacing(3)
    }
}
