import Foundation

/// One actionable thing pulled out of a transcript, before it becomes a stored
/// `Suggestion`. Kept as a plain value so the heuristics are easy to unit-test.
struct ParsedSuggestion: Equatable {
    var kind: SuggestionKind
    var text: String
    var detail: String
    var date: Date?

    var dedupKey: String { kind.dedupKey(for: text) }
}

/// Reads a Bee conversation transcript and finds things worth acting on:
/// shopping items and to-dos (keyword heuristics), plus appointments, phone
/// numbers, addresses and links (Apple's `NSDataDetector`). Deliberately does
/// NOT use the on-device language model — that was unreliable (ask for the
/// weather, get your calendar). Plain pattern-matching is predictable, and the
/// user is the one who accepts or dismisses each suggestion anyway.
enum TranscriptParser {
    /// Everything actionable in `transcript`, de-duplicated.
    static func parse(_ transcript: String, now: Date = .now) -> [ParsedSuggestion] {
        var out: [ParsedSuggestion] = []
        out += keywordItems(transcript)
        out += dataDetections(transcript, now: now)
        return dedup(out)
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

    /// Lead-ins that introduce a to-do; whatever follows is the task itself.
    private static let todoLeadIns = [
        "don't forget to", "do not forget to", "make sure to", "make sure you",
        "remember to", "i need to", "we need to", "you need to", "i have to",
        "we have to", "i should", "we should", "you should", "i'll", "i will",
        "we'll", "let's", "got to", "gotta", "i've got to",
    ]

    /// Imperative verbs that, on their own, signal a task.
    private static let todoVerbs = [
        "call", "email", "text", "message", "send", "book", "schedule",
        "cancel", "reschedule", "pay", "order", "renew", "return", "confirm",
        "sign up for", "follow up with", "follow up on", "make an appointment",
    ]

    static func keywordItems(_ transcript: String) -> [ParsedSuggestion] {
        var out: [ParsedSuggestion] = []
        for sentence in sentences(transcript) {
            let clean = stripSpeaker(sentence)
            let lower = clean.lowercased()

            // 1. Explicit shopping phrasing wins.
            if let object = clause(afterAnyOf: shoppingCues, in: lower), object.count >= 2 {
                out.append(ParsedSuggestion(kind: .shopping, text: object, detail: clean))
                continue
            }
            // 2. A to-do lead-in; the remainder is the task (which may itself be
            //    a "buy X" → shopping).
            if let rest = clause(afterAnyOf: todoLeadIns, in: lower), rest.count >= 2 {
                if let object = clause(afterAnyOf: ["buy", "pick up", "grab", "get"], in: rest), object.count >= 2 {
                    out.append(ParsedSuggestion(kind: .shopping, text: object, detail: clean))
                } else {
                    out.append(ParsedSuggestion(kind: .todo, text: rest, detail: clean))
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

    // MARK: - NSDataDetector (dates, phones, addresses, links)

    static func dataDetections(_ transcript: String, now: Date = .now) -> [ParsedSuggestion] {
        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .date, .address, .link]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let ns = transcript as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [ParsedSuggestion] = []

        detector.enumerateMatches(in: transcript, range: range) { match, _, _ in
            guard let match else { return }
            let context = sentence(around: match.range, in: ns)
            switch match.resultType {
            case .phoneNumber:
                if let number = match.phoneNumber {
                    out.append(ParsedSuggestion(kind: .phone, text: number, detail: context))
                }
            case .date:
                if let date = match.date, date > now {
                    // A future date in conversation is almost always a plan.
                    out.append(ParsedSuggestion(kind: .appointment, text: context, detail: context, date: date))
                }
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
