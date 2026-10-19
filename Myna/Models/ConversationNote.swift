import Foundation
import SwiftData

/// A single action item extracted from a conversation.
struct ActionItem: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var task: String
    var owner: String?
    var due: String?
    var isDone: Bool = false
}

/// A meeting or event the AI detected being planned in conversation.
struct DetectedEvent: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    /// Resolved concrete start date, when the model (or a date detector) could pin one down.
    var startDate: Date?
    /// The phrase as heard, e.g. "next Tuesday after lunch" — kept so the user can fix ambiguity.
    var rawWhen: String
    var durationMinutes: Int?
    var location: String?
    var attendees: [String] = []
    var confidence: Double?
    /// Identifier of the EKEvent once scheduled, nil until then.
    var calendarEventID: String?

    var isScheduled: Bool { calendarEventID != nil }
}

/// One captured conversation, fully processed into structured notes.
/// Everything in this model was produced on-device and never leaves the phone.
@Model
final class ConversationNote {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var startedAt: Date = Date.now
    var endedAt: Date = Date.now
    var title: String = ""
    var overview: String = ""
    var detailedNotes: String = ""
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [ActionItem] = []
    var detectedEvents: [DetectedEvent] = []
    var followUps: [String] = []
    var transcript: String = ""
    var modelName: String = ""
    /// Where the conversation was heard: "" for this iPhone's microphone.
    var sourceRef: String = ""

    init(
        startedAt: Date,
        endedAt: Date,
        title: String,
        overview: String,
        detailedNotes: String,
        keyPoints: [String],
        decisions: [String],
        actionItems: [ActionItem],
        detectedEvents: [DetectedEvent],
        followUps: [String],
        transcript: String,
        modelName: String,
        sourceRef: String = ""
    ) {
        self.id = UUID()
        self.createdAt = .now
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.overview = overview
        self.detailedNotes = detailedNotes
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.detectedEvents = detectedEvents
        self.followUps = followUps
        self.transcript = transcript
        self.modelName = modelName
        self.sourceRef = sourceRef
    }

    var durationMinutes: Int {
        max(1, Int(endedAt.timeIntervalSince(startedAt) / 60))
    }

    /// Markdown-flavored export used for sharing into Apple Notes.
    var exportText: String {
        var lines: [String] = []
        lines.append(title)
        lines.append("")
        let range = "\(startedAt.formatted(date: .abbreviated, time: .shortened)) – \(endedAt.formatted(date: .omitted, time: .shortened))"
        lines.append("🕑 \(range)  ·  composed on-device by Myna")
        lines.append("")
        if !overview.isEmpty {
            lines.append("Overview")
            lines.append(overview)
            lines.append("")
        }
        if !detailedNotes.isEmpty {
            lines.append("Notes")
            lines.append(detailedNotes)
            lines.append("")
        }
        if !keyPoints.isEmpty {
            lines.append("Key Points")
            lines.append(contentsOf: keyPoints.map { "• \($0)" })
            lines.append("")
        }
        if !decisions.isEmpty {
            lines.append("Decisions")
            lines.append(contentsOf: decisions.map { "✔ \($0)" })
            lines.append("")
        }
        if !actionItems.isEmpty {
            lines.append("Action Items")
            for item in actionItems {
                var entry = "☐ \(item.task)"
                if let owner = item.owner, !owner.isEmpty { entry += " — \(owner)" }
                if let due = item.due, !due.isEmpty { entry += " (due \(due))" }
                lines.append(entry)
            }
            lines.append("")
        }
        if !detectedEvents.isEmpty {
            lines.append("Events Mentioned")
            for event in detectedEvents {
                let when = event.startDate?.formatted(date: .abbreviated, time: .shortened) ?? event.rawWhen
                lines.append("📅 \(event.title) — \(when)")
            }
            lines.append("")
        }
        if !followUps.isEmpty {
            lines.append("Follow-ups")
            lines.append(contentsOf: followUps.map { "→ \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
