import Foundation

/// Turns a raw conversation transcript into a rich, structured note using the
/// local language model. Long transcripts are condensed in chunks first so we
/// never overflow a small model's context window.
final class NotesEngine {

    /// The structured note as the model emits it (JSON).
    struct ComposedNote: Codable {
        var title: String
        var overview: String
        var detailed_notes: String
        var key_points: [String]?
        var decisions: [String]?
        var action_items: [RawActionItem]?
        var events: [RawEvent]?
        var follow_ups: [String]?
        var my_tasks: [String]?
        var shopping_items: [String]?
        var reminders: [RawReminder]?

        struct RawReminder: Codable {
            var text: String
            var at: String?
            var as_heard: String?
        }

        struct RawActionItem: Codable {
            var task: String
            var owner: String?
            var due: String?
        }

        struct RawEvent: Codable {
            var title: String
            var start: String?          // ISO 8601, resolved by the model
            var as_heard: String?       // the phrase from the conversation
            var duration_minutes: Int?
            var location: String?
            var attendees: [String]?
            var confidence: Double?
        }
    }

    /// A finished note plus the personal follow-through Myna picked up for
    /// your lists.
    struct Result {
        var note: ConversationNote
        var myTasks: [String]
        var shoppingItems: [String]
        var reminders: [(text: String, at: Date?)]
    }

    private let modelManager: ModelManager

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    /// The user's name, so the model can tell their commitments from everyone else's.
    private var userName: String {
        UserDefaults.standard.string(forKey: "myna.userName")?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    // MARK: - Public API

    func composeNote(transcript: String, startedAt: Date, endedAt: Date, sourceRef: String = "", context: NoteContext = .empty) async throws -> Result {
        let condensed = try await condenseIfNeeded(transcript)
        let composed = try await composeStructuredNote(from: condensed, startedAt: startedAt, context: context)

        let events = (composed.events ?? []).map { raw -> DetectedEvent in
            DetectedEvent(
                title: raw.title,
                startDate: Self.resolveDate(iso: raw.start, phrase: raw.as_heard, reference: endedAt),
                rawWhen: raw.as_heard ?? raw.start ?? "time not specified",
                durationMinutes: raw.duration_minutes,
                location: raw.location,
                attendees: (raw.attendees ?? []).map(context.resolveAttendee),
                confidence: raw.confidence
            )
        }

        let actionItems = (composed.action_items ?? []).map {
            ActionItem(task: $0.task, owner: $0.owner, due: $0.due)
        }

        let modelName = await MainActor.run { modelManager.activeModel?.displayName ?? "Local model" }

        let note = ConversationNote(
            startedAt: startedAt,
            endedAt: endedAt,
            title: composed.title.isEmpty ? "Conversation" : composed.title,
            overview: composed.overview,
            detailedNotes: composed.detailed_notes,
            keyPoints: composed.key_points ?? [],
            decisions: composed.decisions ?? [],
            actionItems: actionItems,
            detectedEvents: events,
            followUps: composed.follow_ups ?? [],
            transcript: transcript,
            modelName: modelName,
            sourceRef: sourceRef
        )
        note.placeName = context.place
        note.people = context.people.map(\.summary)
        note.photoIdentifiers = context.photoIdentifiers
        let reminders = (composed.reminders ?? []).map { raw in
            (text: raw.text, at: Self.resolveDate(iso: raw.at, phrase: raw.as_heard, reference: endedAt))
        }
        return Result(
            note: note,
            myTasks: (composed.my_tasks ?? []).filter { !$0.isEmpty },
            shoppingItems: (composed.shopping_items ?? []).filter { !$0.isEmpty },
            reminders: reminders.filter { !$0.text.isEmpty }
        )
    }

    // MARK: - Stage 1: condense long transcripts

    private func condenseIfNeeded(_ transcript: String) async throws -> String {
        let chunkCharacterLimit = await MainActor.run { modelManager.promptCharacterBudget }
        guard transcript.count > chunkCharacterLimit else { return transcript }

        let chunks = Self.split(transcript, limit: chunkCharacterLimit)
        var condensed: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let instructions = """
            You are a meticulous meeting scribe. Condense raw conversation transcripts into \
            detailed minutes. Preserve every name, number, date, time, commitment, decision \
            and task exactly as stated. Write tight prose, no preamble.
            """
            let prompt = """
            Transcript part \(index + 1) of \(chunks.count):

            \(chunk)

            Condensed minutes of this part:
            """
            let minutes = try await modelManager.respond(instructions: instructions, prompt: prompt, maxTokens: 900)
            condensed.append(minutes.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return condensed.joined(separator: "\n\n")
    }

    // MARK: - Stage 2: structured note

    private func composeStructuredNote(from material: String, startedAt: Date, context: NoteContext) async throws -> ComposedNote {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, yyyy-MM-dd 'at' HH:mm"
        let now = formatter.string(from: startedAt)
        let owner = userName.isEmpty ? "the phone's owner (the person wearing Myna)" : "\(userName), the phone's owner"
        let budget = await MainActor.run { modelManager.promptCharacterBudget }
        // Keep the final pass inside the model's window even after condensing.
        let fitted = material.count > budget * 2 ? String(material.suffix(budget * 2)) : material
        let contextBlock = context.promptBlock(budget: max(400, budget / 3))

        let instructions = """
        You are Myna, an expert personal meeting scribe living on the user's iPhone. \
        You transform conversation material into detailed, flexible notes. \
        You respond with a single valid JSON object and absolutely nothing else — \
        no markdown fences, no commentary.
        """

        let prompt = """
        The conversation below took place on \(now) (the user's local time).

        CONVERSATION MATERIAL:
        \(fitted)
        \(contextBlock.isEmpty ? "" : "\n" + contextBlock + "\n")
        Produce a JSON object with exactly these keys:
        {
          "title": "short, vivid title for this conversation",
          "overview": "2-3 sentence summary",
          "detailed_notes": "thorough narrative notes covering everything substantive that was discussed, organized into short paragraphs; preserve names, numbers, dates and context",
          "key_points": ["the most important takeaways"],
          "decisions": ["decisions that were made, empty array if none"],
          "action_items": [{"task": "...", "owner": "person responsible or null", "due": "deadline as spoken or null"}],
          "events": [{"title": "...", "start": "ISO 8601 local datetime like 2026-06-12T14:00, resolved from phrases like 'next Tuesday at 2' using the conversation date above; null if you cannot resolve it", "as_heard": "the scheduling phrase as spoken", "duration_minutes": 60, "location": "or null", "attendees": ["names"], "confidence": 0.9}],
          "follow_ups": ["open questions or things to revisit"],
          "my_tasks": ["things \(owner) personally said they will do or must do, phrased as short to-dos"],
          "shopping_items": ["anything \(owner) needs to buy or pick up, one item per entry"],
          "reminders": [{"text": "what \(owner) should be reminded of", "at": "ISO 8601 local datetime or null", "as_heard": "the time phrase as spoken or null"}]
        }

        Only include events that are genuinely being planned or agreed (meetings, calls, \
        appointments) — not past events or hypotheticals. If the transcript is small talk \
        with nothing substantive, still write an accurate title, overview and notes. \
        my_tasks, shopping_items and reminders are only for \(owner) — leave them empty \
        rather than guessing.

        JSON:
        """

        let reply = try await modelManager.respond(instructions: instructions, prompt: prompt, maxTokens: 2400)
        guard let json = Self.extractJSON(from: reply),
              let data = json.data(using: .utf8)
        else {
            throw NotesEngineError.malformedModelOutput
        }
        do {
            return try JSONDecoder().decode(ComposedNote.self, from: data)
        } catch {
            throw NotesEngineError.malformedModelOutput
        }
    }

    // MARK: - Helpers

    /// Splits on sentence-ish boundaries, keeping each piece under `limit` characters.
    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var chunks: [String] = []
        var current = ""
        for sentence in text.split(separator: " ", omittingEmptySubsequences: false) {
            if current.count + sentence.count + 1 > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + sentence
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Pulls the first balanced JSON object out of model output, tolerating
    /// reasoning preambles, code fences and trailing chatter.
    static func extractJSON(from reply: String) -> String? {
        var text = reply
        // Strip <think>...</think> blocks some models emit.
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>") {
            guard open.lowerBound < close.upperBound else { break }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Resolves an event time: model-emitted ISO string first, then a natural
    /// language pass over the spoken phrase with NSDataDetector.
    static func resolveDate(iso: String?, phrase: String?, reference: Date) -> Date? {
        if let iso {
            let trimmed = iso.trimmingCharacters(in: .whitespaces)
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]
            if let date = isoFormatter.date(from: trimmed) { return date }

            let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
            for format in formats {
                let formatter = DateFormatter()
                formatter.dateFormat = format
                formatter.timeZone = .current
                if let date = formatter.date(from: trimmed) { return date }
            }
        }
        if let phrase,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(phrase.startIndex..., in: phrase)
            let matches = detector.matches(in: phrase, options: [], range: range)
            if let date = matches.first?.date, date > reference {
                return date
            }
        }
        return nil
    }
}

enum NotesEngineError: LocalizedError {
    case malformedModelOutput

    var errorDescription: String? {
        switch self {
        case .malformedModelOutput:
            return "The model's response could not be read as a structured note. The raw transcript was kept."
        }
    }
}
