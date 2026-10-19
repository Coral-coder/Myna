import Foundation
import SwiftData

/// Where an item came from — shown as a small hint in the lists.
enum ItemSource: String, Codable {
    case voice          // "Myna, add milk…"
    case typed          // typed into the app
    case conversation   // picked up from a conversation note
    case siri           // App Shortcuts / Siri

    var icon: String {
        switch self {
        case .voice: return "waveform"
        case .typed: return "keyboard"
        case .conversation: return "bubble.left.and.bubble.right"
        case .siri: return "mic.circle"
        }
    }
}

/// A to-do, shopping item, reminder or memo. Lives in Myna's private store and
/// is optionally mirrored to Apple Reminders.
@Model
final class MynaItem {
    var id: UUID = UUID()
    var kindRaw: String = ItemKind.todo.rawValue
    var text: String = ""
    var detail: String = ""
    var dueDate: Date?
    var isDone: Bool = false
    var createdAt: Date = Date.now
    var completedAt: Date?
    var sourceRaw: String = ItemSource.typed.rawValue
    /// The conversation note this was captured from, if any.
    var noteID: UUID?
    /// `EKReminder.calendarItemIdentifier` when mirrored to Apple Reminders.
    var reminderID: String?

    init(kind: ItemKind, text: String, detail: String = "", dueDate: Date? = nil, source: ItemSource, noteID: UUID? = nil) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.text = text
        self.detail = detail
        self.dueDate = dueDate
        self.createdAt = .now
        self.sourceRaw = source.rawValue
        self.noteID = noteID
    }

    var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .todo }
        set { kindRaw = newValue.rawValue }
    }

    var source: ItemSource {
        ItemSource(rawValue: sourceRaw) ?? .typed
    }

    /// Identifier for the local notification that fires at `dueDate`.
    var notificationID: String { "myna.item.\(id.uuidString)" }
}

/// A conversation heard while the language model couldn't run (the phone was
/// locked, or no model was ready). Composed into a note as soon as it can be.
@Model
final class PendingConversation {
    var id: UUID = UUID()
    var transcript: String = ""
    var startedAt: Date = Date.now
    var endedAt: Date = Date.now
    var sourceRef: String = ""
    var queuedAt: Date = Date.now
    var attempts: Int = 0

    init(transcript: String, startedAt: Date, endedAt: Date, sourceRef: String) {
        self.id = UUID()
        self.transcript = transcript
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sourceRef = sourceRef
        self.queuedAt = .now
    }
}
