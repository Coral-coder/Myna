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

    /// One memory the curator proposed from a note.
    struct MemoryDraft { let content: String; let category: MemoryCategory }

    private struct MemoriesReply: Decodable {
        struct Item: Decodable { var content: String; var category: String }
        var memories: [Item]
    }

    // MARK: - Public API

    /// Distil durable memories from a composed note, following Omi's memory
    /// curator rules: a few timeless facts about the user ("system") or outside
    /// wisdom ("interesting"), deduped against what Myna already knows. Returns
    /// an empty list when nothing is worth keeping.
    func extractMemories(from note: ConversationNote, existing: [String]) async -> [MemoryDraft] {
        let owner = userName.isEmpty ? "the user" : userName
        let material = [note.overview, note.detailedNotes].filter { !$0.isEmpty }.joined(separator: "\n")
        guard material.count > 60 else { return [] }
        let budget = await MainActor.run { modelManager.promptCharacterBudget }
        let known = existing.prefix(60).joined(separator: "\n")
        let fittedKnown = known.count > budget / 3 ? String(known.prefix(budget / 3)) : known
        let fittedMaterial = material.count > budget ? String(material.prefix(budget)) : material

        let instructions = """
        You are an expert memory curator for \(owner). From a conversation you keep only \
        a few genuinely durable memories and ignore everything trivial. You reply with \
        one JSON object and nothing else.
        """
        let prompt = """
        CONVERSATION:
        \(fittedMaterial)

        MEMORIES ALREADY KNOWN (never repeat these or anything that means the same):
        \(fittedKnown.isEmpty ? "(none yet)" : fittedKnown)

        Extract durable memories. Two kinds:
        - "system": a fact ABOUT \(owner) — a preference, opinion, realization, relationship, project, decision or dislike. Write it starting with "\(owner)".
        - "interesting": actionable wisdom or advice FROM someone else that \(owner) could learn from. Say who it is from, formatted "Source: insight".

        Rules:
        - At most 2 system and 2 interesting. Fewer is better; prefer an empty list over weak memories.
        - Each memory is ONE short, specific, TIMELESS statement — at most 15 words. No "Thursday"/"next week"; scheduled events are not memories.
        - \(owner)'s own opinions and realizations are "system", never "interesting".
        - Never repeat a known memory. But if something changed or contradicts one, include the new version.
        - No hedging ("maybe", "seems"), no filler, no transient "is working on". If it is uncertain or temporary, skip it.
        - Never include news, general knowledge, product facts, or other people's facts with no stated relation to \(owner).

        Reply with JSON and nothing else:
        {"memories": [{"content": "...", "category": "system"}]}

        JSON:
        """
        guard let raw = try? await modelManager.respond(instructions: instructions, prompt: prompt, maxTokens: 500),
              let json = Self.extractJSON(from: raw),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MemoriesReply.self, from: data) else {
            return []
        }
        return decoded.memories.compactMap { item in
            let text = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 3, text.split(separator: " ").count <= 22 else { return nil }
            let category = MemoryCategory(rawValue: item.category.lowercased()) ?? .system
            return MemoryDraft(content: text, category: category)
        }
    }

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

        Rules for accuracy:
        - Stay true to what was actually said. A suggestion is not a decision; agreement \
        is not completion; "I'll do it" is an intention, not a finished thing. Keep that \
        distinction in the notes and decisions, and don't turn a plan that was merely \
        floated into a firm commitment.
        - Never write a speaker label like "Speaker 1" anywhere. If you don't know who \
        said something, write it without a name or as "someone" — never guess or invent a \
        name. Keep exact spellings, numbers and dates from the transcript; don't \
        "correct" an unfamiliar name from general knowledge.
        - title: a specific headline of at most 10 words about the main topic or outcome. \
        You may name the one or two most central people (spelled exactly as in the \
        transcript), but never \(owner) — the note is theirs.
        - action_items: each is timeless, verb-led and about 15 words at most, stating \
        the action and its object; keep timing out of the task text. Set "due" ONLY when a \
        specific date was explicitly committed — never invent an hour; if only a day was \
        named, leave due null and mention the day in the task.
        - events: only genuinely planned or agreed meetings, calls or appointments with a \
        concrete date AND time — not past events, hypotheticals, or things merely floated. \
        Don't emit the same plan as both an event and a reminder.
        - my_tasks, shopping_items and reminders are ONLY for \(owner): things \(owner) \
        personally committed to or asked to be reminded of, plus an explicit offer someone \
        made to \(owner) ("I'll send you the file"). Leave them empty rather than guessing. \
        A "remind me to…" from \(owner) always belongs in reminders, even a small errand.
        - If the transcript is small talk with nothing substantive, still write an \
        accurate title and short overview, and keep the lists empty.

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
