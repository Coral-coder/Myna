import Foundation

/// The kinds of things Myna keeps track of for you.
enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case todo
    case shopping
    case reminder
    case memo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo: return "To-Do"
        case .shopping: return "Shopping"
        case .reminder: return "Reminders"
        case .memo: return "Memos"
        }
    }

    var icon: String {
        switch self {
        case .todo: return "checklist"
        case .shopping: return "cart.fill"
        case .reminder: return "bell.badge.fill"
        case .memo: return "note.text"
        }
    }
}

/// Something you asked Myna to do, out loud or typed.
enum MynaCommand: Equatable {
    case addItems(ItemKind, [String])
    case remind(String, at: Date?, phrase: String?)
    case schedule(title: String, at: Date?, durationMinutes: Int?, attendees: [String], phrase: String)
    case readList(ItemKind)
    case agenda(Date)
    case complete(String)
    case stopListening
    /// Anything else — handed to the language model.
    case ask(String)
}

/// Fast, rule-based understanding of the things people say to an assistant
/// most. It runs in microseconds on the CPU, so commands work instantly even
/// with the phone locked in a pocket; everything it doesn't recognize becomes
/// `.ask` for the language model.
enum CommandParser {

    /// Words that wake Myna up. Speech recognition hears "Myna" a few ways.
    static let wakeWords = ["myna", "mynah", "mina", "minah", "maina", "myena"]

    private static var wakePattern: String {
        let names = wakeWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return #"(?:\b(?:hey|hi|ok|okay|yo|alright)[,]? )?\b(?:"# + names + #")\b[,.!:]?\s*"#
    }

    /// Returns the text spoken after each wake word in `text`, in order — one
    /// entry per wake word, empty when nothing has followed it yet.
    static func commandsFollowingWakeWord(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: wakePattern, options: [.caseInsensitive]) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var commands: [String] = []
        for (index, match) in matches.enumerated() {
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : nsText.length
            let command = end > start
                ? nsText.substring(with: NSRange(location: start, length: end - start))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.!?")))
                : ""
            commands.append(command)
        }
        return commands
    }

    // MARK: - Parsing

    static func parse(_ raw: String, now: Date = .now, calendar: Calendar = .current) -> MynaCommand {
        let text = clean(raw)
        let lowered = text.lowercased()

        if matches(lowered, #"^(?:stop|stop listening|go to sleep|pause listening|that's all|thats all|goodnight|good night)$"#) {
            return .stopListening
        }

        // Reading lists back.
        if let kind = listQuery(lowered) {
            return .readList(kind)
        }

        // Agenda.
        if matches(lowered, #"^(?:what(?:'s| is| do i have)|whats|what does) .*(?:calendar|schedule|agenda|day look like|today|tomorrow|next|have on|planned)"#)
            || matches(lowered, #"^(?:read|tell me) (?:me )?my (?:agenda|schedule|calendar)"#) {
            let day = lowered.contains("tomorrow")
                ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
                : calendar.startOfDay(for: now)
            return .agenda(day)
        }

        // Shopping list.
        if let items = capture(lowered, in: text, #"^(?:please )?(?:add|put|throw|stick) (.+?) (?:to|on|onto|in) (?:my |the |our )?(?:shopping|grocery|groceries|store)(?: list)?(?: please)?$"#) {
            return .addItems(.shopping, splitItems(items))
        }
        if let items = capture(lowered, in: text, #"^(?:we need|we need to get|i need to buy|we're out of|we are out of|were out of|buy|pick up|get some|grab some) (.+?)(?: from the store| at the store)?$"#) {
            return .addItems(.shopping, splitItems(items))
        }
        if let items = capture(lowered, in: text, #"^(?:shopping list|grocery list)[,: ]+(.+)$"#) {
            return .addItems(.shopping, splitItems(items))
        }

        // Reminders — checked before to-dos so "remind me to…" with a time becomes an alert.
        if let body = capture(lowered, in: text, #"^(?:please )?(?:remind me|set a reminder|make a reminder|create a reminder)(?: for me)?(?: to| that| about|:)? (.+)$"#) {
            let found = TimePhrase.find(in: body, now: now, calendar: calendar)
            let task = TimePhrase.tidy(found?.remainder ?? body)
            return .remind(task.isEmpty ? body : task, at: found?.date, phrase: found?.phrase)
        }

        // To-dos.
        if let task = capture(lowered, in: text, #"^(?:please )?(?:add|put) (.+?) (?:to|on) (?:my |the )?(?:to ?do|to-do|todo|task|tasks)(?: list)?$"#)
            ?? capture(lowered, in: text, #"^(?:add a task|new task|add task|to ?do|to-do|todo|task)[,: ]+(?:to )?(.+)$"#)
            ?? capture(lowered, in: text, #"^(?:i need to|i have to|i've got to|i gotta|don't let me forget to|dont let me forget to|remember to|make sure i) (.+)$"#) {
            if let found = TimePhrase.find(in: task, now: now, calendar: calendar), found.hasTime {
                return .remind(found.remainder, at: found.date, phrase: found.phrase)
            }
            return .addItems(.todo, [capitalizeFirst(task)])
        }

        // Memos.
        if let memo = capture(lowered, in: text, #"^(?:take a note|make a note|note|note that|remember that|jot down|write down)[,: ]+(?:that )?(.+)$"#) {
            return .addItems(.memo, [capitalizeFirst(memo)])
        }

        // Completing things.
        if let item = capture(lowered, in: text, #"^(?:check off|cross off|tick off|mark off|i bought|i got|i picked up|i finished|i did|done with|mark) (.+?)(?: as done| as complete| off| done)?(?: from (?:my |the )?(?:\w+ )?list)?$"#) {
            return .complete(item)
        }

        // Calendar events.
        if let event = scheduleCommand(text, lowered: lowered, now: now, calendar: calendar) {
            return event
        }

        return .ask(text)
    }

    // MARK: - Pieces

    private static func listQuery(_ lowered: String) -> ItemKind? {
        guard matches(lowered, #"^(?:what(?:'s| is| do i| do we)|whats|read|tell me|show|show me|list)\b"#) else { return nil }
        if matches(lowered, #"\b(?:shopping|grocery|groceries|need from the store|need to buy|buy)\b"#) { return .shopping }
        if matches(lowered, #"\b(?:to ?do|to-do|todo|tasks?)\b"#) { return .todo }
        if matches(lowered, #"\breminders?\b"#) { return .reminder }
        if matches(lowered, #"\b(?:notes|memos)\b"#) { return .memo }
        return nil
    }

    private static func scheduleCommand(_ text: String, lowered: String, now: Date, calendar: Calendar) -> MynaCommand? {
        let verb = #"^(?:please )?(?:schedule|book|set up|setup|plan|put|add|create|make)(?: me)?(?: an?| the)? "#
        let eventWords = #"\b(?:meeting|call|appointment|lunch|dinner|breakfast|coffee|interview|session|sync|standup|catch ?up|date|visit|party|event|game|practice|class|check ?up|flight)\b"#
        let mentionsCalendar = matches(lowered, #"\b(?:calendar|schedule)\b"#)
        guard matches(lowered, verb), matches(lowered, eventWords) || mentionsCalendar else { return nil }

        var body = text.replacingOccurrences(of: verb, with: "", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"\b(?:to|on|in) (?:my|the) (?:calendar|schedule)\b"#, with: "", options: [.regularExpression, .caseInsensitive])

        let found = TimePhrase.find(in: body, now: now, calendar: calendar)
        var title = found?.remainder ?? TimePhrase.tidy(body)

        var duration: Int?
        if let minutes = captureNumber(title.lowercased(), #"\bfor (\d+|an?|one|two|three|half an?) (minute|hour)s?\b"#) {
            duration = minutes
            title = title.replacingOccurrences(of: #"\bfor (?:\d+|an?|one|two|three|half an?) (?:minute|hour)s?\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        }

        var attendees: [String] = []
        if let range = title.range(of: #"\bwith ([A-Z][\w'’-]*(?:(?:,| and| &) [A-Z][\w'’-]*)*)"#, options: .regularExpression) {
            let names = String(title[range]).dropFirst(5)
            attendees = names
                .replacingOccurrences(of: " and ", with: ",")
                .replacingOccurrences(of: " & ", with: ",")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        title = capitalizeFirst(TimePhrase.tidy(title))
        if title.isEmpty { title = "Meeting" }
        return .schedule(title: title, at: found?.date, durationMinutes: duration, attendees: attendees, phrase: found?.phrase ?? "")
    }

    /// "milk, eggs and a loaf of bread" → ["Milk", "Eggs", "A loaf of bread"]
    static func splitItems(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: #",? and (?:also |some )?|, also |, | & |, plus | plus "#, with: "|", options: .regularExpression)
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.replacingOccurrences(of: #"^(?:some|a few|more|another|an?) (?=\w)"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
            .map(capitalizeFirst)
    }

    static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.!?;:")))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// First capture group of `pattern` matched against `lowered`, returned
    /// from the original-case `text` so names keep their capitals.
    private static func capture(_ lowered: String, in text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        let source = lowered.count == text.count ? text : lowered
        guard let range = Range(match.range(at: 1), in: source) else { return nil }
        let value = String(source[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func captureNumber(_ text: String, _ pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let quantityRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let quantityText = String(text[quantityRange])
        let quantity = quantityText.hasPrefix("half") ? 0.5 : Double(TimePhrase.numberValue(quantityText) ?? 1)
        return Int(quantity * (text[unitRange] == "hour" ? 60 : 1))
    }
}
