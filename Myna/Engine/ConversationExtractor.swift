import Foundation
#if canImport(FoundationModels) && os(iOS)
import FoundationModels
#endif

/// Reads a whole Bee conversation with Apple's on-device model and pulls out
/// only the things the wearer actually committed to or asked for — with the
/// surrounding context, not keyword matches. It also recognises when the
/// "conversation" is really a TV, film, podcast or video playing nearby, and
/// returns nothing for it.
///
/// Returns nil when Apple Intelligence isn't available, so the caller can fall
/// back to Inbox-only suggestions (never auto-adding without understanding).
enum ConversationExtractor {
    /// Minimum confidence (0–100) to act without asking. Only a model that
    /// genuinely understood the exchange clears this; junk sits lower.
    static let autoAddConfidence = 70

    /// Generates text from `prompt` under `instructions`. The app injects one
    /// backed by the user's downloaded model (a bigger MLX model when installed
    /// and on screen, Apple Intelligence otherwise). Kept as a closure so this
    /// file — and its unit tests — don't depend on the model layer.
    typealias Generate = (_ instructions: String, _ prompt: String) async throws -> String

    struct Result {
        var isMedia: Bool
        var items: [ParsedSuggestion]
    }

    static func extract(
        transcript: String,
        beeSummary: String,
        wearerName: String?,
        conversationDate: Date,
        generate: Generate? = nil
    ) async -> Result? {
        // Preferred path: the user's chosen model reads it and returns JSON.
        if let generate {
            return await runJSON(transcript: transcript, beeSummary: beeSummary,
                                 wearerName: wearerName, conversationDate: conversationDate, generate: generate)
        }
        #if canImport(FoundationModels) && os(iOS)
        if #available(iOS 26.0, *), AppleIntelligenceEngine.isAvailable {
            return await run(transcript: transcript, beeSummary: beeSummary,
                             wearerName: wearerName, conversationDate: conversationDate)
        }
        #endif
        return nil
    }

    // MARK: - Model path (any backend, via JSON)

    /// The instructions every backend gets. Demands evidence and wearer intent,
    /// which is what stops the junk.
    static func instructions(for wearerName: String?) -> String {
        let who = (wearerName?.isEmpty == false) ? wearerName! : "the wearer"
        return """
        You help \(who), who wears a Bee recording bracelet that captures audio of \
        their day. You read a transcript and extract ONLY concrete action items \
        that \(who) is responsible for.

        Return STRICT JSON, nothing else, in exactly this shape:
        {"isMedia": false, "items": [{"kind": "...", "title": "...", "dateTime": "...", "confidence": 0, "evidence": "..."}]}

        - isMedia: true if the audio is a TV show, movie, podcast, video, radio or \
        other media/background playing nearby rather than \(who) in a real \
        conversation. If true, items MUST be empty.
        - Include an item ONLY if \(who) personally committed to it, agreed to it, \
        asked to be reminded of it, or was directly asked to do it. A plan everyone \
        settled on (a dinner, meeting, appointment with a time) counts.
        - EXCLUDE: things that already happened; hypotheticals ("we could", "maybe \
        someday", "we should probably"); jokes, stories, quotes; opinions and \
        complaints; other people's tasks; anything vague with no real commitment. \
        When in doubt, leave it out.
        - kind is one of: "calendarEvent" (has a day and time), "reminder" (dated \
        nudge), "todo" (task, no fixed time), "shopping" (something to buy).
        - title: short and plain, e.g. "Dentist appointment", "Call Mom about Sunday", \
        "Milk". No filler words.
        - dateTime: "yyyy-MM-dd HH:mm" in local time resolved against the \
        conversation date; use 09:00 if only a day was named; "" if no time at all.
        - confidence: 0-100, how sure you are \(who) truly committed to this.
        - evidence: the exact words from the transcript that justify the item. \
        Never invent an item you cannot quote.
        """
    }

    static func header(beeSummary: String, conversationDate: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        return """
        Conversation date: \(f.string(from: conversationDate))
        Bee's summary: \(beeSummary.isEmpty ? "(none)" : beeSummary)

        Transcript:
        """
    }

    private static func runJSON(transcript: String, beeSummary: String, wearerName: String?, conversationDate: Date, generate: Generate) async -> Result? {
        let instr = instructions(for: wearerName)
        let head = header(beeSummary: beeSummary, conversationDate: conversationDate)
        var merged: [ParsedSuggestion] = []
        var media = false
        var anySucceeded = false
        for chunk in chunks(of: transcript, size: 4_500).prefix(4) {
            guard let text = try? await generate(instr, "\(head)\n\(chunk)") else { continue }
            guard let parsed = parseJSON(text, reference: conversationDate) else { continue }
            anySucceeded = true
            if parsed.isMedia { media = true; continue }
            merged += parsed.items
        }
        guard anySucceeded else { return nil }
        if media && merged.isEmpty { return Result(isMedia: true, items: []) }
        return Result(isMedia: false, items: TranscriptParser.dedup(merged))
    }

    /// Tolerant parse of the model's JSON (it may wrap it in prose or fences).
    static func parseJSON(_ raw: String, reference: Date) -> (isMedia: Bool, items: [ParsedSuggestion])? {
        guard let data = firstJSONObject(in: raw)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let isMedia = (obj["isMedia"] as? Bool) ?? false
        let rawItems = (obj["items"] as? [[String: Any]]) ?? []
        var out: [ParsedSuggestion] = []
        for it in rawItems {
            guard let title = (it["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), title.count >= 2 else { continue }
            let date = parseDate((it["dateTime"] as? String) ?? "")
            let kindRaw = (it["kind"] as? String ?? "todo").lowercased()
            var kind: SuggestionKind
            switch kindRaw {
            case "calendarevent", "event", "appointment": kind = date == nil ? .todo : .appointment
            case "reminder": kind = .reminder
            case "shopping": kind = .shopping
            default: kind = date == nil ? .todo : .reminder
            }
            if let date, date < Date.now, kind == .appointment || kind == .reminder { continue }
            let confidence = (it["confidence"] as? Int) ?? Int((it["confidence"] as? Double) ?? 0)
            let evidence = (it["evidence"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var parsed = ParsedSuggestion(kind: kind, text: title, detail: evidence, date: date)
            // Auto-add only when the model is confident AND can quote its evidence.
            parsed.autoAdd = confidence >= autoAddConfidence && !evidence.isEmpty
            out.append(parsed)
        }
        return (isMedia, out)
    }

    /// The first balanced {...} block in `s`, or nil.
    static func firstJSONObject(in s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var idx = start
        while idx < s.endIndex {
            let c = s[idx]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return String(s[start...idx]) }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    #if canImport(FoundationModels) && os(iOS)
    @available(iOS 26.0, *)
    @Generable
    enum Kind {
        case calendarEvent
        case reminder
        case todo
        case shopping
    }

    @available(iOS 26.0, *)
    @Generable
    struct Item {
        @Guide(description: "What kind of action this is.")
        var kind: Kind
        @Guide(description: "A short, clear title in plain words, e.g. 'Dentist appointment', 'Call Mom about Sunday', 'Milk'. No filler.")
        var title: String
        @Guide(description: "When it happens or is due, as 'yyyy-MM-dd HH:mm' in local time, resolved against the conversation date. Use 09:00 if only a day was said. Empty string if no time was given.")
        var dateTime: String
        @Guide(description: "0 to 100: how sure you are that the wearer genuinely committed to this, asked for it, or agreed to it in this conversation.")
        var confidence: Int
        @Guide(description: "The exact words from the transcript that justify this item.")
        var evidence: String
    }

    @available(iOS 26.0, *)
    @Generable
    struct Extraction {
        @Guide(description: "True if this audio is mostly a TV show, movie, news broadcast, podcast, video, radio, or other media playing in the background rather than people actually talking to the wearer.")
        var isMediaOrBackground: Bool
        @Guide(description: "Real action items for the wearer. Empty if there are none.")
        var items: [Item]
    }

    @available(iOS 26.0, *)
    private static func run(transcript: String, beeSummary: String, wearerName: String?, conversationDate: Date) async -> Result? {
        let who = (wearerName?.isEmpty == false) ? wearerName! : "the wearer"
        let instructions = """
        You help \(who), who wears a Bee recording bracelet. You read a transcript \
        of audio it captured and find ONLY real action items for \(who).

        Rules:
        - First decide if the audio is TV, a movie, a podcast, a video, the radio or \
        any other media playing nearby. Dialogue from media is NEVER an action item. \
        If it is media, set isMediaOrBackground to true and return no items.
        - Only include things \(who) committed to, agreed to, asked to be reminded of, \
        or was directly asked to do by someone in the conversation. Plans everyone \
        agreed on (a dinner, a meeting, an appointment) count.
        - Ignore: things that already happened, hypotheticals ("we could…", "maybe \
        someday"), jokes, stories, quotes, complaints, general opinions, other \
        people's tasks that don't involve \(who), and vague talk with no real intent.
        - calendarEvent: a specific event with a day/time (appointment, meeting, \
        dinner, flight…). reminder: something to be reminded of at a time. todo: a \
        task with no fixed time. shopping: something to buy.
        - Plans, appointments, reminders and errands \(who) mentioned doing are what matter most — don't miss them. Never invent details.
        """
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        let header = """
        Conversation date: \(dateFormatter.string(from: conversationDate))
        Bee's summary: \(beeSummary.isEmpty ? "(none)" : beeSummary)

        Transcript:
        """

        var merged: [ParsedSuggestion] = []
        var media = false
        var anySucceeded = false
        for chunk in chunks(of: transcript, size: 3_800).prefix(3) {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.1)
            do {
                let response = try await session.respond(
                    to: "\(header)\n\(chunk)",
                    generating: Extraction.self,
                    options: options
                )
                anySucceeded = true
                let extraction = response.content
                if extraction.isMediaOrBackground { media = true; continue }
                merged += extraction.items.compactMap { convert($0, reference: conversationDate) }
            } catch {
                // One chunk failing (guardrails, context) shouldn't sink the rest.
                continue
            }
        }
        // Every chunk errored (guardrails etc.) — let the caller fall back.
        guard anySucceeded else { return nil }
        if media && merged.isEmpty { return Result(isMedia: true, items: []) }
        return Result(isMedia: false, items: TranscriptParser.dedup(merged))
    }

    @available(iOS 26.0, *)
    private static func convert(_ item: Item, reference: Date) -> ParsedSuggestion? {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2 else { return nil }
        let date = parseDate(item.dateTime)
        let kind: SuggestionKind
        switch item.kind {
        case .calendarEvent: kind = date == nil ? .todo : .appointment
        case .reminder: kind = .reminder
        case .todo: kind = date == nil ? .todo : .reminder
        case .shopping: kind = .shopping
        }
        // Don't act on events already in the past.
        if let date, date < Date.now, kind == .appointment || kind == .reminder { return nil }
        var parsed = ParsedSuggestion(kind: kind, text: title, detail: item.evidence, date: date)
        parsed.autoAdd = item.confidence >= autoAddConfidence
        return parsed
    }
    #endif

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: trimmed) {
                return format == "yyyy-MM-dd" ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) : d
            }
        }
        return nil
    }

    /// Splits on line boundaries into pieces that fit the model's context.
    static func chunks(of text: String, size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if current.count + line.count + 1 > size, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
