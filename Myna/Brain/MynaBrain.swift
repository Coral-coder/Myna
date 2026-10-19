import EventKit
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Myna's personality and hands: hears "Myna, …", does the thing, and answers
/// like a person would. Simple requests are understood by `CommandParser` on
/// the CPU (instant, works while locked); everything else goes to the language
/// model with your lists, calendar and recent conversations as context.
@MainActor
final class MynaBrain: ObservableObject {

    enum Origin {
        case voice, typed, siri

        var itemSource: ItemSource {
            switch self {
            case .voice: return .voice
            case .typed: return .typed
            case .siri: return .siri
            }
        }
    }

    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        let heard: String
        let reply: String
        let at: Date
    }

    @Published private(set) var lastExchange: Exchange?
    @Published private(set) var isThinking = false

    let voice = VoiceReply()
    let reminders = ReminderCenter()

    var isWakeWordEnabled: Bool {
        UserDefaults.standard.object(forKey: "myna.wakeWord") as? Bool ?? true
    }

    var autoCapture: Bool {
        UserDefaults.standard.object(forKey: "myna.autoCapture") as? Bool ?? true
    }

    private let listener: SpeechListener
    private let modelManager: ModelManager
    private let scheduler: EventScheduler
    private weak var pilot: ConversationPilot?
    private var modelContext: ModelContext?
    private var spotter = CommandSpotter()
    private var spotterTimer: Timer?
    /// Recently performed spoken commands, so a repeated recognition never acts twice.
    private var recentCommands: [(key: String, at: Date)] = []

    init(listener: SpeechListener, modelManager: ModelManager, pilot: ConversationPilot) {
        self.listener = listener
        self.modelManager = modelManager
        self.scheduler = pilot.scheduler
        self.pilot = pilot

        listener.onPartialText = { [weak self] text in
            guard let self, self.isWakeWordEnabled, !self.voice.isSpeaking else { return }
            for command in self.spotter.observe(partial: text, at: .now) {
                self.run(command, origin: .voice)
            }
        }
        listener.onTaskFinished = { [weak self] text in
            guard let self else { return }
            let missed = self.spotter.finish(final: text)
            guard self.isWakeWordEnabled, !self.voice.isSpeaking else { return }
            for command in missed {
                self.run(command, origin: .voice)
            }
        }
        voice.onStart = { [weak listener] in listener?.pauseRecognition() }
        voice.onFinish = { [weak listener] in listener?.resumeRecognition() }

        spotterTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.listener.isListening, let command = self.spotter.tick(at: .now) else { return }
                self.run(command, origin: .voice)
            }
        }
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Entry points

    /// Typed into the "Ask Myna" field. Returns the reply.
    @discardableResult
    func handleTyped(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Typing "Myna, …" is fine too.
        let command = CommandParser.commandsFollowingWakeWord(in: trimmed).first(where: { !$0.isEmpty }) ?? trimmed
        return await perform(CommandParser.parse(command), heard: trimmed, origin: .typed)
    }

    private func run(_ text: String, origin: Origin) {
        let key = text.lowercased().filter { $0.isLetter || $0.isNumber }
        recentCommands.removeAll { Date.now.timeIntervalSince($0.at) > 20 }
        guard !recentCommands.contains(where: { $0.key == key }) else { return }
        recentCommands.append((key, .now))
        let command = CommandParser.parse(text)
        Task { await perform(command, heard: text, origin: origin) }
    }

    /// Carries out a command and answers. Used by voice, typing and Siri.
    @discardableResult
    func perform(_ command: MynaCommand, heard: String, origin: Origin) async -> String {
        let reply: String
        switch command {
        case .addItems(let kind, let texts):
            let added = add(kind, texts: texts, source: origin.itemSource)
            reply = confirmation(for: kind, added: added.map(\.text))

        case .remind(let text, let at, _):
            let item = add(.reminder, texts: [text], due: at, source: origin.itemSource).first
            if let at, item != nil {
                reply = "Okay, I'll remind you to \(lowercasedFirst(text)) \(Self.spoken(at))."
            } else {
                reply = "I've put “\(text)” on your reminders. Tell me a time if you'd like an alert."
            }

        case .schedule(let title, let at, let duration, let attendees, let phrase):
            reply = await schedule(title: title, at: at, durationMinutes: duration, attendees: attendees, phrase: phrase, origin: origin)

        case .readList(let kind):
            reply = describeList(kind)

        case .agenda(let day):
            reply = describeAgenda(on: day)

        case .complete(let text):
            if let item = complete(matching: text) {
                reply = item.kind == .shopping ? "Got it — \(lowercasedFirst(item.text)) is crossed off." : "Nice. “\(item.text)” is done."
            } else {
                reply = "I couldn't find “\(text)” on your lists."
            }

        case .stopListening:
            reply = "Okay, I'll stop listening. Tap the orb when you need me."
            Task {
                try? await Task.sleep(for: .seconds(3))
                self.pilot?.stopListening()
            }

        case .ask(let question):
            reply = await ask(question, origin: origin)
        }

        respond(heard: heard, reply: reply, origin: origin)
        return reply
    }

    private func respond(heard: String, reply: String, origin: Origin) {
        withAnimation(.easeOut(duration: 0.25)) {
            lastExchange = Exchange(heard: heard, reply: reply, at: .now)
        }
        switch origin {
        case .voice:
            voice.say(reply)
        case .typed, .siri:
            break
        }
        if origin != .typed, UIApplication.shared.applicationState != .active {
            reminders.announce("Myna", body: reply)
        }
    }

    // MARK: - Lists

    @discardableResult
    func add(_ kind: ItemKind, texts: [String], due: Date? = nil, detail: String = "", source: ItemSource, noteID: UUID? = nil) -> [MynaItem] {
        guard let modelContext else { return [] }
        let existing = openItems(kind)
        var added: [MynaItem] = []
        for raw in texts {
            let text = CommandParser.capitalizeFirst(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty else { continue }
            // Don't double-add "milk" when it's already on the list.
            if kind == .shopping || kind == .todo,
               existing.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
                continue
            }
            let item = MynaItem(kind: kind, text: text, detail: detail, dueDate: due, source: source, noteID: noteID)
            modelContext.insert(item)
            reminders.scheduleAlert(for: item)
            reminders.mirror(item)
            added.append(item)
        }
        try? modelContext.save()
        return added
    }

    func setDone(_ item: MynaItem, _ done: Bool) {
        item.isDone = done
        item.completedAt = done ? .now : nil
        if done {
            reminders.cancelAlert(for: item)
        } else {
            reminders.scheduleAlert(for: item)
        }
        reminders.mirror(item)
        try? modelContext?.save()
    }

    func delete(_ item: MynaItem) {
        reminders.cancelAlert(for: item)
        reminders.removeMirror(of: item)
        modelContext?.delete(item)
        try? modelContext?.save()
    }

    func openItems(_ kind: ItemKind? = nil) -> [MynaItem] {
        guard let modelContext else { return [] }
        let descriptor = FetchDescriptor<MynaItem>(
            predicate: #Predicate { $0.isDone == false },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let items = (try? modelContext.fetch(descriptor)) ?? []
        guard let kind else { return items }
        return items.filter { $0.kind == kind }
    }

    private func complete(matching text: String) -> MynaItem? {
        let needle = text.lowercased()
            .replacingOccurrences(of: #"^(?:the|my|some|a|an) "#, with: "", options: .regularExpression)
        let candidates = openItems().filter { $0.kind != .memo }
        let match = candidates.first { $0.text.lowercased() == needle }
            ?? candidates.first { $0.text.lowercased().contains(needle) }
            ?? candidates.first { needle.contains($0.text.lowercased()) }
        if let match { setDone(match, true) }
        return match
    }

    /// Files the personal follow-through from a freshly composed note.
    func absorb(_ result: NotesEngine.Result) {
        guard autoCapture else { return }
        let noteID = result.note.id
        add(.todo, texts: result.myTasks, detail: "From “\(result.note.title)”", source: .conversation, noteID: noteID)
        add(.shopping, texts: result.shoppingItems, detail: "From “\(result.note.title)”", source: .conversation, noteID: noteID)
        for reminder in result.reminders {
            add(.reminder, texts: [reminder.text], due: reminder.at, detail: "From “\(result.note.title)”", source: .conversation, noteID: noteID)
        }
    }

    // MARK: - Calendar

    private func schedule(title: String, at: Date?, durationMinutes: Int?, attendees: [String], phrase: String, origin: Origin) async -> String {
        guard let at else {
            add(.todo, texts: ["Schedule: \(title)"], source: origin.itemSource)
            return "I didn't catch when, so “Schedule \(lowercasedFirst(title))” is on your to-do list."
        }
        if !scheduler.hasAccess {
            _ = await scheduler.requestAccess()
        }
        let event = DetectedEvent(
            title: title,
            startDate: at,
            rawWhen: phrase,
            durationMinutes: durationMinutes,
            attendees: attendees,
            confidence: 1
        )
        do {
            _ = try scheduler.schedule(event)
            return "Done — \(title) is on your calendar \(Self.spoken(at))."
        } catch {
            add(.todo, texts: ["Schedule: \(title) \(Self.spoken(at))"], source: origin.itemSource)
            return "I couldn't reach your calendar, so I added it to your to-dos instead."
        }
    }

    private func describeAgenda(on day: Date) -> String {
        let isToday = Calendar.current.isDateInToday(day)
        let label = isToday ? "today" : (Calendar.current.isDateInTomorrow(day) ? "tomorrow" : day.formatted(.dateTime.weekday(.wide)))
        guard scheduler.hasAccess else {
            return "I don't have access to your calendar yet. You can turn it on in Settings."
        }
        let start = isToday ? Date.now : day
        let events = scheduler.events(from: start, days: 1)
            .filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
        let due = openItems(.reminder).filter { $0.dueDate.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
        if events.isEmpty && due.isEmpty {
            return isToday ? "Nothing else on your calendar today. Enjoy the breathing room." : "Your calendar is clear \(label)."
        }
        var parts = events.prefix(6).map { event -> String in
            event.isAllDay ? "\(event.title ?? "an event") all day" : "\(event.title ?? "an event") at \(event.startDate.formatted(date: .omitted, time: .shortened))"
        }
        parts += due.prefix(4).map { "a reminder to \(lowercasedFirst($0.text)) at \(($0.dueDate ?? .now).formatted(date: .omitted, time: .shortened))" }
        let count = events.count + due.count
        let lead = isToday ? "Coming up today" : "For \(label)"
        return "\(lead), you have \(count == 1 ? "one thing" : "\(count) things"): \(Self.joined(parts))."
    }

    // MARK: - Speaking

    private func confirmation(for kind: ItemKind, added: [String]) -> String {
        guard !added.isEmpty else {
            return kind == .shopping ? "That's already on your shopping list." : "That's already on your list."
        }
        let list = Self.joined(added.map(lowercasedFirst))
        switch kind {
        case .shopping: return "Added \(list) to your shopping list."
        case .todo: return added.count == 1 ? "Got it — “\(added[0])” is on your to-do list." : "Added \(added.count) things to your to-do list."
        case .reminder: return "Added \(list) to your reminders."
        case .memo: return "Noted."
        }
    }

    private func describeList(_ kind: ItemKind) -> String {
        let items = openItems(kind)
        guard !items.isEmpty else {
            switch kind {
            case .shopping: return "Your shopping list is empty."
            case .todo: return "Your to-do list is clear. Nice work."
            case .reminder: return "You don't have any reminders coming up."
            case .memo: return "You haven't asked me to note anything yet."
            }
        }
        let names = items.prefix(12).map { lowercasedFirst($0.text) }
        let more = items.count > 12 ? ", and \(items.count - 12) more" : ""
        switch kind {
        case .shopping: return "You need \(Self.joined(names))\(more)."
        case .todo: return "You have \(items.count == 1 ? "one thing" : "\(items.count) things") to do: \(Self.joined(names))\(more)."
        case .reminder: return "Your reminders: \(Self.joined(names))\(more)."
        case .memo: return "Here's what you asked me to note: \(Self.joined(names))\(more)."
        }
    }

    static func spoken(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let minutesAway = date.timeIntervalSinceNow / 60
        if minutesAway > 0, minutesAway < 90 {
            let minutes = Int(minutesAway.rounded())
            return minutes < 2 ? "in a minute" : "in \(minutes) minutes"
        }
        if calendar.isDateInToday(date) { return "at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: date).day, days < 7 {
            return "on \(date.formatted(.dateTime.weekday(.wide))) at \(time)"
        }
        return "on \(date.formatted(.dateTime.month(.wide).day())) at \(time)"
    }

    static func joined(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        }
    }

    private func lowercasedFirst(_ text: String) -> String {
        // Keep "I", acronyms and names that start a phrase ("Mom", "Dave") as they are.
        guard let first = text.first, first.isUppercase else { return text }
        let firstWord = text.split(separator: " ").first.map(String.init) ?? text
        let keepWords: Set<String> = ["I", "Mom", "Dad"]
        if keepWords.contains(firstWord) || firstWord.count > 1 && firstWord == firstWord.uppercased() {
            return text
        }
        return first.lowercased() + text.dropFirst()
    }

    // MARK: - Open questions (language model)

    private struct AgentReply: Decodable {
        var reply: String
        var actions: [Action]?

        struct Action: Decodable {
            var type: String
            var text: String?
            var items: [String]?
            var at: String?
            var title: String?
            var start: String?
            var duration_minutes: Int?
            var attendees: [String]?
        }
    }

    private func ask(_ question: String, origin: Origin) async -> String {
        isThinking = true
        defer { isThinking = false }

        let instructions = """
        You are Myna, a warm, quick, capable personal assistant living on the user's iPhone. \
        You are their memory and their second pair of ears: you remember their conversations, \
        keep their lists and calendar, and take care of things for them like a trusted human \
        assistant would. Answer in one to three natural spoken sentences — no lists, no markdown. \
        If the request needs something done, do it with actions. \
        Respond with one JSON object and nothing else.
        """
        let prompt = """
        \(context())

        THE USER SAYS: "\(question)"

        Respond with JSON:
        {"reply": "what you say back, spoken aloud",
         "actions": [
           {"type": "add_todo", "text": "...", "at": "ISO 8601 local datetime or null"},
           {"type": "add_shopping", "items": ["..."]},
           {"type": "remind", "text": "...", "at": "ISO 8601 local datetime"},
           {"type": "schedule", "title": "...", "start": "ISO 8601 local datetime", "duration_minutes": 30, "attendees": ["..."]},
           {"type": "note", "text": "..."},
           {"type": "complete", "text": "the item to check off"}
         ]}
        Use an empty actions array when nothing needs doing. Never invent facts about the \
        user's life — if the context doesn't say, say you don't know.

        JSON:
        """

        do {
            let raw = try await modelManager.respond(instructions: instructions, prompt: prompt, maxTokens: 700)
            guard let json = NotesEngine.extractJSON(from: raw),
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(AgentReply.self, from: data) else {
                // A model that ignored the format still usually said something useful.
                let plain = raw.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return plain.isEmpty ? "Sorry, I lost my train of thought. Could you ask that again?" : String(plain.prefix(400))
            }
            await apply(decoded.actions ?? [], origin: origin)
            return decoded.reply
        } catch MynaModelError.needsForeground {
            add(.memo, texts: ["Asked: \(question)"], detail: "Open Myna and ask again for an answer.", source: origin.itemSource)
            return "I need you to open Myna before I can think that one through. I've saved the question."
        } catch MynaModelError.noModelInstalled {
            return "I need a brain for that one. Download a model in the Neural Core tab and ask me again."
        } catch {
            return "I couldn't work that out: \(error.localizedDescription)"
        }
    }

    private func apply(_ actions: [AgentReply.Action], origin: Origin) async {
        let source = origin.itemSource
        for action in actions {
            let at = NotesEngine.resolveDate(iso: action.at ?? action.start, phrase: nil, reference: .now)
            switch action.type {
            case "add_todo":
                if let text = action.text { add(at == nil ? .todo : .reminder, texts: [text], due: at, source: source) }
            case "add_shopping":
                add(.shopping, texts: action.items ?? action.text.map { [$0] } ?? [], source: source)
            case "remind":
                if let text = action.text { add(.reminder, texts: [text], due: at, source: source) }
            case "schedule":
                if let title = action.title ?? action.text {
                    _ = await schedule(title: title, at: at, durationMinutes: action.duration_minutes, attendees: action.attendees ?? [], phrase: action.start ?? "", origin: origin)
                }
            case "note":
                if let text = action.text { add(.memo, texts: [text], source: source) }
            case "complete":
                if let text = action.text { _ = complete(matching: text) }
            default:
                break
            }
        }
    }

    /// What Myna knows right now, trimmed to fit the active model.
    private func context() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        var lines: [String] = ["NOW: \(formatter.string(from: .now)) (user's local time)"]
        let name = UserDefaults.standard.string(forKey: "myna.userName") ?? ""
        if !name.isEmpty { lines.append("USER'S NAME: \(name)") }

        let todos = openItems(.todo).prefix(20).map(\.text)
        if !todos.isEmpty { lines.append("TO-DO LIST: " + todos.joined(separator: "; ")) }
        let shopping = openItems(.shopping).prefix(25).map(\.text)
        if !shopping.isEmpty { lines.append("SHOPPING LIST: " + shopping.joined(separator: "; ")) }
        let upcoming = openItems(.reminder).compactMap { item in
            item.dueDate.map { "\(item.text) (\($0.formatted(date: .abbreviated, time: .shortened)))" }
        }
        if !upcoming.isEmpty { lines.append("REMINDERS: " + upcoming.prefix(10).joined(separator: "; ")) }

        let events = scheduler.events(from: .now, days: 7).prefix(15).map { event in
            "\(event.title ?? "Event") — \(event.startDate.formatted(date: .abbreviated, time: .shortened))"
        }
        if !events.isEmpty { lines.append("CALENDAR (next 7 days): " + events.joined(separator: "; ")) }

        if let modelContext {
            var descriptor = FetchDescriptor<ConversationNote>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            descriptor.fetchLimit = 8
            let notes = (try? modelContext.fetch(descriptor)) ?? []
            if !notes.isEmpty {
                lines.append("RECENT CONVERSATIONS:")
                for note in notes {
                    var entry = "- \(note.startedAt.formatted(date: .abbreviated, time: .shortened)): \(note.title). \(note.overview)"
                    let tasks = note.actionItems.prefix(4).map(\.task)
                    if !tasks.isEmpty { entry += " Action items: \(tasks.joined(separator: "; "))." }
                    lines.append(entry)
                }
            }
        }

        let text = lines.joined(separator: "\n")
        let budget = modelManager.promptCharacterBudget
        return text.count > budget ? String(text.prefix(budget)) : text
    }
}
