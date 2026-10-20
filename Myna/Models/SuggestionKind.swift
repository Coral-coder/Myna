import Foundation

/// What kind of thing Myna spotted in a Bee conversation and is offering to act
/// on. Kept in its own Foundation-only file (no SwiftData) so the transcript
/// parser and its unit tests can use it without pulling in the persistence layer.
enum SuggestionKind: String, Codable, CaseIterable, Identifiable {
    case shopping      // "grab milk" → shopping list
    case todo          // "remember to call the dentist" → to-do
    case reminder      // a dated thing to be nudged about
    case appointment   // a meeting / event with a time → calendar
    case contact       // a person + phone number worth saving
    case phone         // a bare phone number
    case note          // an address, a link, or anything else worth keeping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shopping: return "Shopping"
        case .todo: return "To-Do"
        case .reminder: return "Reminder"
        case .appointment: return "Appointment"
        case .contact: return "Contact"
        case .phone: return "Phone number"
        case .note: return "Note"
        }
    }

    var icon: String {
        switch self {
        case .shopping: return "cart.fill"
        case .todo: return "checklist"
        case .reminder: return "bell.badge.fill"
        case .appointment: return "calendar"
        case .contact: return "person.crop.circle.fill"
        case .phone: return "phone.fill"
        case .note: return "note.text"
        }
    }

    /// A stable key for "the same suggestion", so we never offer it twice.
    func dedupKey(for text: String) -> String {
        "\(rawValue)|\(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

enum SuggestionStatus: String, Codable {
    case pending     // waiting for you to accept or dismiss
    case accepted    // you took it — it's now a list item / event
    case dismissed   // you waved it off
}
