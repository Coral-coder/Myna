import Foundation
import SwiftData

/// Something actionable Myna parsed out of a Bee conversation transcript — a
/// shopping item, a to-do, an appointment, a phone number — offered to you as a
/// suggestion you can accept or dismiss. Nothing happens until you accept.
///
/// `SuggestionKind` / `SuggestionStatus` live in SuggestionKind.swift so the
/// transcript parser can use them without importing SwiftData.
@Model
final class Suggestion {
    var id: UUID = UUID()
    var kindRaw: String = SuggestionKind.note.rawValue
    /// The actionable text, e.g. "milk" or "call the dentist".
    var text: String = ""
    /// The surrounding sentence it came from, shown as context.
    var detail: String = ""
    /// A concrete date, for appointments and dated reminders.
    var date: Date?
    /// Lowercased kind+text, used to avoid offering the same thing twice.
    var dedupKey: String = ""
    /// The conversation note this came from.
    var noteID: UUID?
    /// Title of the source conversation, shown as provenance.
    var sourceTitle: String = ""
    var createdAt: Date = Date.now
    var statusRaw: String = SuggestionStatus.pending.rawValue

    init(
        kind: SuggestionKind,
        text: String,
        detail: String = "",
        date: Date? = nil,
        noteID: UUID? = nil,
        sourceTitle: String = ""
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.text = text
        self.detail = detail
        self.date = date
        self.dedupKey = kind.dedupKey(for: text)
        self.noteID = noteID
        self.sourceTitle = sourceTitle
        self.createdAt = .now
        self.statusRaw = SuggestionStatus.pending.rawValue
    }

    var kind: SuggestionKind {
        get { SuggestionKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }

    var status: SuggestionStatus {
        get { SuggestionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
}
