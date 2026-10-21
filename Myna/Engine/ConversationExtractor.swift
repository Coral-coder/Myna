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
    /// Minimum confidence (0–100) to act without asking.
    static let autoAddConfidence = 60

    struct Result {
        var isMedia: Bool
        var items: [ParsedSuggestion]
    }

    static func extract(
        transcript: String,
        beeSummary: String,
        wearerName: String?,
        conversationDate: Date
    ) async -> Result? {
        #if canImport(FoundationModels) && os(iOS)
        if #available(iOS 26.0, *), AppleIntelligenceEngine.isAvailable {
            return await run(transcript: transcript, beeSummary: beeSummary,
                             wearerName: wearerName, conversationDate: conversationDate)
        }
        #endif
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
