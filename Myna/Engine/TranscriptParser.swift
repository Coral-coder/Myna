import Foundation

/// One actionable thing pulled out of a transcript, before it becomes a stored
/// `Suggestion`. Kept as a plain value so the heuristics are easy to unit-test.
struct ParsedSuggestion: Equatable {
    var kind: SuggestionKind
    var text: String
    var detail: String
    var date: Date?
    /// Confident enough to act on without asking (calendar / lists), with a
    /// Cancel-able notification. Everything else waits in the Inbox.
    var autoAdd = false

    var dedupKey: String { kind.dedupKey(for: text) }
}

/// Reads a Bee conversation transcript and finds things worth acting on:
/// appointments, reminders, shopping items and to-dos, plus phone numbers,
/// addresses and links. Deterministic heuristics plus Apple's `NSDataDetector`
/// — no on-device language model, which was unreliable.
enum TranscriptParser {
    /// Everything actionable in `transcript`, de-duplicated.
    static func parse(_ transcript: String, now: Date = .now) -> [ParsedSuggestion] {
        var items = keywordItems(transcript)

        // A to-do that comes with a date ("call the dentist tomorrow at 3") is
        // really a reminder for that time.
        for i in items.indices where items[i].kind == .todo {
            if let date = firstFutureDate(in: items[i].detail, now: now) {
                items[i].kind = .reminder
                items[i].date = date
            }
        }

        let detected = dataDetections(transcript, now: now)
        // When a sentence produced a calendar event, don't also file it as a
        // reminder / to-do.
        let eventSentences = Set(detected.filter { $0.kind == .appointment && $0.autoAdd }.map(\.detail))
        items.removeAll { ($0.kind == .todo || $0.kind == .reminder) && eventSentences.contains($0.detail) }

        return dedup(items + detected)
    }

    static func dedup(_ items: [ParsedSuggestion]) -> [ParsedSuggestion] {
        var seen = Set<String>()
        var out: [ParsedSuggestion] = []
        for item in items where seen.insert(item.dedupKey).inserted {
            out.append(item)
        }
        return out
    }

    // MARK: - Keyword heuristics (pure, unit-tested)

    /// Phrases that introduce a shopping item; the object follows the phrase.
    private static let shoppingCues = [
        "add to the shopping list", "add to the grocery list", "put on the shopping list",
        "put on the list", "we're out of", "we are out of", "we ran out of",
        "need to buy", "need to pick up", "need to grab", "need to get",
        "pick up some", "pick up a", "pick up the", "grab some", "grab a",
        "buy some", "buy a", "buy the", "get some", "we need some", "we need more",
    ]

    /// Lead-ins clear enough that the task is acted on automatically.
    static let strongLeadIns = [
        "remind me to", "don't let me forget to", "don't forget to", "do not forget to",
        "make sure to", "make sure you", "remember to", "i need to", "we need to",
        "i have to", "we have to", "i've got to",
    ]

    /// Softer lead-ins — still a to-do, but offered in the Inbox instead.
    private static let weakLeadIns = [
        "you need to", "i should", "we should", "you should", "i'll", "i will",
        "we'll", "let's", "got to", "gotta",
    ]

    private static var todoLeadIns: [String] { strongLeadIns + weakLeadIns }

    /// Imperative verbs that, on their own, signal a task.
    private static let todoVerbs = [
        "call", "email", "text", "message", "send", "book", "schedule",
        "cancel", "reschedule", "pay", "order", "renew", "return", "confirm",
        "sign up for", "follow up with", "follow up on", "make an appointment",
    ]

    /// Words that make a dated sentence an actual calendar event.
    static let eventCues = [
        "appointment", "appt", "meeting", "meet ", "dinner", "lunch", "breakfast",
        "brunch", "doctor", "dentist", "interview", "flight", "party", "reservation",
        "class", "practice", "game", "birthday", "haircut", "vet", "concert",
        "wedding", "conference", "session", "visit", "checkup", "check-up",
        "pickup", "pick up the kids", "drop off", "recital", "rehearsal", "show",
        "movie", "date night", "call with", "zoom", "webinar", "exam", "test",
    ]

    static func keywordItems(_ transcript: String) -> [ParsedSuggestion] {
        var out: [ParsedSuggestion] = []
        for sentence in sentences(transcript) {
            let clean = stripSpeaker(sentence)
            let lower = clean.lowercased()

            // 1. Explicit shopping phrasing wins.
            if let object = clause(afterAnyOf: shoppingCues, in: lower), object.count >= 2 {
                out.append(ParsedSuggestion(kind: .shopping, text: object, detail: clean, autoAdd: true))
                continue
            }
            // 2. A to-do lead-in; the remainder is the task (which may itself be
            //    a "buy X" → shopping).
            if let rest = clause(afterAnyOf: todoLeadIns, in: lower), rest.count >= 2 {
                let strong = strongLeadIns.contains { lower.contains($0) }
                if let object = clause(afterAnyOf: ["buy", "pick up", "grab", "get"], in: rest), object.count >= 2 {
                    out.append(ParsedSuggestion(kind: .shopping, text: object, detail: clean, autoAdd: strong))
                } else {
                    out.append(ParsedSuggestion(kind: .todo, text: rest, detail: clean, autoAdd: strong))
                }
                continue
            }
            // 3. A bare imperative near the start of the sentence.
            if let task = clause(fromAnyOf: todoVerbs, in: lower), task.count >= 4 {
                out.append(ParsedSuggestion(kind: .todo, text: task, detail: clean))
            }
        }
        return out
    }

    /// A short calendar title from the sentence an event was heard in:
    /// "I have a dentist appointment on Tuesday at 3pm" → "Dentist appointment".
    static func eventTitle(from sentence: String, removing dateText: String) -> String {
        var s = stripSpeaker(sentence)
        if !dateText.isEmpty, let r = s.range(of: dateText, options: .caseInsensitive) {
            s.replaceSubrange(r, with: " ")
        }
        s = s.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?-"))

        let fillers = [
            "don't forget we have ", "don't forget i have ", "don't forget the ", "don't forget ",
            "remember we have ", "remember the ", "remember ",
            "i've got a ", "i've got an ", "we've got a ", "we've got an ",
            "i have a ", "i have an ", "we have a ", "we have an ", "i have ", "we have ",
            "there's a ", "there's an ", "there is a ", "there is an ",
            "we're having ", "we are having ", "i'm having ", "let's have ", "let's do ", "let's ",
            "so ", "and ", "oh ", "also ", "okay ", "ok ", "yeah ", "the ", "a ", "an ",
        ]
        var stripped = true
        while stripped {
            stripped = false
            for f in fillers where s.lowercased().hasPrefix(f) {
                s = String(s.dropFirst(f.count))
                stripped = true
                break
            }
        }

        let trailing: Set<String> = ["at", "on", "for", "this", "next", "by", "around", "from", "to", "is", "with", "until", "in"]
        var words = s.split(separator: " ").map(String.init)
        while let last = words.last, trailing.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeLast()
        }
        if words.count > 8 { words = Array(words.prefix(8)) }
        let title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,!?-"))
        return title.count >= 3 ? CommandParser.capitalizeFirst(title) : "Event"
    }

    static func hasEventCue(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        return eventCues.contains { lower.contains($0) }
    }

    // MARK: - NSDataDetector (dates, phones, addresses, links)

    static func dataDetections(_ transcript: String, now: Date = .now) -> [ParsedSuggestion] {
        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .date, .address, .link]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let ns = transcript as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [ParsedSuggestion] = []

        detector.enumerateMatches(in: transcript, range: range) { match, _, _ in
            guard let match else { return }
            let context = stripSpeaker(sentence(around: match.range, in: ns))
            switch match.resultType {
            case .phoneNumber:
                if let number = match.phoneNumber {
                    out.append(ParsedSuggestion(kind: .phone, text: number, detail: context))
                }
            case .date:
                guard let date = match.date, date > now else { return }
                let dateText = ns.substring(with: match.range)
                let title = eventTitle(from: context, removing: dateText)
                // A dated sentence that names an event goes on the calendar;
                // a bare date is just offered.
                out.append(ParsedSuggestion(kind: .appointment, text: title, detail: context, date: date,
                                            autoAdd: hasEventCue(context)))
            case .address:
                let text = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(ParsedSuggestion(kind: .note, text: text, detail: context)) }
            case .link:
                if let url = match.url {
                    out.append(ParsedSuggestion(kind: .note, text: url.absoluteString, detail: context))
                }
            default:
                break
            }
        }
        return out
    }

    static func firstFutureDate(in text: String, now: Date = .now) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, range: range).compactMap(\.date).first { $0 > now }
    }

    // MARK: - Text helpers

    static func sentences(_ text: String) -> [String] {
        text
            .split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Bee transcripts are speaker-labelled ("Speaker 1: …", "Alex: …"). Drop the
    /// leading label so cues at the start of what someone said still match.
    static func stripSpeaker(_ sentence: String) -> String {
        guard let colon = sentence.firstIndex(of: ":") else { return sentence }
        let label = sentence[..<colon]
        // Only strip a short label (a name or "Speaker 2"), not a mid-sentence colon.
        guard label.count <= 24, !label.contains(" where "), label.split(separator: " ").count <= 3 else { return sentence }
        return sentence[sentence.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    /// The lowercased object/remainder that follows the earliest of `cues`.
    static func clause(afterAnyOf cues: [String], in lower: String) -> String? {
        var best: (start: Int, len: Int)?
        for cue in cues {
            guard let r = lower.range(of: cue) else { continue }
            // Require the cue to sit on a word boundary at its start.
            if r.lowerBound != lower.startIndex {
                let before = lower[lower.index(before: r.lowerBound)]
                if before.isLetter || before.isNumber { continue }
            }
            let start = lower.distance(from: lower.startIndex, to: r.lowerBound)
            if best == nil || start < best!.start {
                best = (start, lower.distance(from: r.lowerBound, to: r.upperBound))
            }
        }
        guard let best else { return nil }
        let afterStart = lower.index(lower.startIndex, offsetBy: best.start + best.len)
        return tidy(String(lower[afterStart...]))
    }

    /// The lowercased clause starting at the earliest of `verbs` (verb kept).
    static func clause(fromAnyOf verbs: [String], in lower: String) -> String? {
        var best: Int?
        for verb in verbs {
            guard let r = lower.range(of: verb) else { continue }
            if r.lowerBound != lower.startIndex {
                let before = lower[lower.index(before: r.lowerBound)]
                if before.isLetter || before.isNumber { continue }
            }
            // The verb must end on a word boundary too ("called" isn't "call").
            if r.upperBound != lower.endIndex, lower[r.upperBound].isLetter { continue }
            let start = lower.distance(from: lower.startIndex, to: r.lowerBound)
            // Only a verb near the start reads as an instruction, not narration.
            if start <= 12, best == nil || start < best! { best = start }
        }
        guard let best else { return nil }
        return tidy(String(lower[lower.index(lower.startIndex, offsetBy: best)...]))
    }

    /// Trim a clause to a tidy item: cut at the first conjunction/clause break
    /// and cap the length so we don't capture half a sentence.
    static func tidy(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let breaks = [",", ";", " and ", " but ", " so ", " because ", " then ", " which ", " that "]
        for b in breaks {
            if let r = s.range(of: b) { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = s.split(separator: " ")
        if words.count > 10 { s = words.prefix(10).joined(separator: " ") }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
    }

    private static func sentence(around range: NSRange, in ns: NSString) -> String {
        let full = NSRange(location: 0, length: ns.length)
        var start = range.location
        var end = range.location + range.length
        let stops = CharacterSet(charactersIn: ".!?\n")
        while start > full.location {
            let c = ns.substring(with: NSRange(location: start - 1, length: 1))
            if c.rangeOfCharacter(from: stops) != nil { break }
            start -= 1
        }
        while end < full.length {
            let c = ns.substring(with: NSRange(location: end, length: 1))
            if c.rangeOfCharacter(from: stops) != nil { break }
            end += 1
        }
        return ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
