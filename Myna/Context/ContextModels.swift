import Foundation

// The platform-free half of Myna's on-device context: plain values and the
// logic that matches them up. No framework imports, so it is unit-tested on
// its own.

// MARK: - Places

/// A spot the user has named ("Home", "Work", "Climbing gym"). Kept in the
/// Keychain, because a list of where someone lives and works is sensitive.
struct SavedPlace: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    /// How close counts as "at" this place, in meters.
    var radius: Double = 150

    /// Great-circle distance in meters (haversine).
    func distance(toLatitude latitude: Double, longitude: Double) -> Double {
        let earthRadius = 6_371_000.0
        let φ1 = self.latitude * .pi / 180
        let φ2 = latitude * .pi / 180
        let Δφ = (latitude - self.latitude) * .pi / 180
        let Δλ = (longitude - self.longitude) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// The closest saved place whose radius covers the point, if any.
    static func nearest(toLatitude latitude: Double, longitude: Double, in places: [SavedPlace]) -> SavedPlace? {
        places
            .map { ($0, $0.distance(toLatitude: latitude, longitude: longitude)) }
            .filter { $0.1 <= $0.0.radius }
            .min { $0.1 < $1.1 }?
            .0
    }
}

// MARK: - People

/// The handful of contact fields Myna reads: enough to spell a name right and
/// know who someone is, nothing more (no numbers, emails or addresses).
struct KnownPerson: Hashable, Codable {
    var givenName: String
    var familyName: String
    var nickname: String = ""
    var organization: String = ""
    var jobTitle: String = ""

    var fullName: String {
        [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Alex Chen (Product Lead, Acme)".
    var summary: String {
        let role = [jobTitle, organization].filter { !$0.isEmpty }.joined(separator: ", ")
        return role.isEmpty ? fullName : "\(fullName) (\(role))"
    }
}

/// Finds the people in your contacts that a piece of text talks about.
///
/// A full name ("Alex Chen") always matches. A first name or nickname alone
/// matches only when exactly one contact has it, it is capitalized the way the
/// speech recognizer writes names, and it isn't an everyday word ("Will",
/// "May", "Grace") — so "I will call" never turns into a contact.
struct PeopleIndex {
    private(set) var people: [KnownPerson]
    private var uniqueShortNames: [String: KnownPerson] = [:]

    static let ambiguousWords: Set<String> = [
        "will", "may", "june", "april", "august", "mark", "bill", "grace", "hope", "faith",
        "joy", "rose", "summer", "autumn", "dawn", "art", "pat", "sue", "rob", "jack",
        "frank", "chase", "hunter", "max", "sky", "ray", "gene", "victor", "major", "page",
        "drew", "dean", "earl", "guy", "lane", "rich", "chuck", "penny", "ruby", "amber",
        "iris", "lily", "holly", "violet", "jade", "sunny", "honey", "angel", "king", "carter",
        "mason", "cash", "brown", "white", "black", "green", "young", "long", "can", "don",
        "ben", "al", "ed", "eve", "sam", "kim", "lee", "jo", "di", "ty",
    ]

    init(people: [KnownPerson]) {
        self.people = people.filter { !$0.givenName.isEmpty || !$0.familyName.isEmpty }
        var counts: [String: Int] = [:]
        var owners: [String: KnownPerson] = [:]
        for person in self.people {
            for name in Set([person.givenName, person.nickname].map { $0.lowercased() }) where Self.isUsableShortName(name) {
                counts[name, default: 0] += 1
                owners[name] = person
            }
        }
        uniqueShortNames = owners.filter { counts[$0.key] == 1 }
    }

    private static func isUsableShortName(_ name: String) -> Bool {
        name.count >= 3 && !ambiguousWords.contains(name)
    }

    /// People mentioned in `text`, in order of first mention.
    func mentions(in text: String, limit: Int = 12) -> [KnownPerson] {
        let words = Self.words(in: text)
        guard !words.isEmpty else { return [] }
        let lowered = words.map { $0.lowercased() }
        var found: [(person: KnownPerson, at: Int)] = []
        var seen = Set<String>()

        func record(_ person: KnownPerson, at index: Int) {
            guard seen.insert(person.fullName.lowercased()).inserted else { return }
            found.append((person, index))
        }

        // Full names first, so "Alex Chen" wins over another Alex.
        for person in people where !person.givenName.isEmpty && !person.familyName.isEmpty {
            let parts = Self.words(in: person.fullName).map { $0.lowercased() }
            if let index = Self.firstIndex(of: parts, in: lowered) {
                record(person, at: index)
            }
        }
        for (index, word) in words.enumerated() {
            guard let person = uniqueShortNames[lowered[index]], Self.looksLikeName(word) else { continue }
            record(person, at: index)
        }
        return found.sorted { $0.at < $1.at }.prefix(limit).map(\.person)
    }

    /// Resolves a name as heard ("Alex", "alex chen") to one contact, if unambiguous.
    func resolve(_ name: String) -> KnownPerson? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let exact = people.filter { $0.fullName.lowercased() == key }
        if exact.count == 1 { return exact[0] }
        return uniqueShortNames[key]
    }

    static func words(in text: String) -> [String] {
        text.split { !($0.isLetter || $0 == "'" || $0 == "’" || $0 == "-") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'’-")) }
            .map { $0.hasSuffix("'s") || $0.hasSuffix("’s") ? String($0.dropLast(2)) : $0 }
            .filter { !$0.isEmpty }
    }

    private static func looksLikeName(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return first.isUppercase
    }

    private static func firstIndex(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }
}

// MARK: - Health

enum HealthMath {
    /// Total time covered by possibly overlapping intervals — an Apple Watch
    /// and an iPhone both logging the same night must not count it twice.
    static func coveredDuration(of intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in sorted {
            if let open = current, interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                if let open = current { total += open.duration }
                current = interval
            }
        }
        if let open = current { total += open.duration }
        return total
    }

    /// "7 h 5 min", "45 min".
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Whether a question is about the user's body, so Health is only read
    /// when it is actually needed.
    static func isHealthQuestion(_ text: String) -> Bool {
        let words = Set(PeopleIndex.words(in: text.lowercased()))
        return !words.isDisjoint(with: healthWords)
    }

    static let healthWords: Set<String> = [
        "sleep", "slept", "sleeping", "nap", "tired", "rest", "rested", "steps", "step", "walk",
        "walked", "walking", "workout", "workouts", "exercise", "exercised", "run", "ran",
        "running", "gym", "heart", "pulse", "health", "healthy", "active", "activity", "fitness",
        "swim", "swam", "cycling", "bike", "biked", "yoga", "training",
    ]
}

// MARK: - What a note gets

/// Everything the phone knows about a conversation's surroundings, gathered
/// on-device right before the note is composed.
struct NoteContext {
    var place: String = ""
    var people: [KnownPerson] = []
    var photoIdentifiers: [String] = []
    /// Text read off photos taken during the conversation (whiteboards, slides, receipts).
    var photoText: [String] = []

    static let empty = NoteContext()

    var isEmpty: Bool {
        place.isEmpty && people.isEmpty && photoText.isEmpty
    }

    /// The block added to the note prompt, trimmed to `budget` characters.
    func promptBlock(budget: Int) -> String {
        guard !isEmpty else { return "" }
        var lines = ["CONTEXT FROM THIS IPHONE (use it to spell names correctly and ground the notes; never invent beyond it):"]
        if !place.isEmpty { lines.append("PLACE: \(place)") }
        if !people.isEmpty {
            lines.append("PEOPLE FROM THE USER'S CONTACTS WHO WERE MENTIONED: " + people.map(\.summary).joined(separator: "; "))
        }
        if !photoText.isEmpty {
            lines.append("TEXT FROM PHOTOS THE USER TOOK DURING THE CONVERSATION:")
            for (index, text) in photoText.enumerated() {
                lines.append("[Photo \(index + 1)] \(text)")
            }
        }
        let block = lines.joined(separator: "\n")
        return block.count > budget ? String(block.prefix(budget)) : block
    }

    /// A heard attendee ("Alex") as their full contact name when one person matches.
    func resolveAttendee(_ name: String) -> String {
        PeopleIndex(people: people).resolve(name)?.fullName ?? name
    }
}
