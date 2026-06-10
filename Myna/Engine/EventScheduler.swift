import EventKit
import Foundation

/// Writes AI-detected meetings into the user's calendar via EventKit.
final class EventScheduler {
    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Adds the event to the default calendar and returns the EKEvent identifier.
    func schedule(_ event: DetectedEvent) throws -> String {
        guard hasAccess else { throw SchedulerError.noAccess }
        guard let start = event.startDate else { throw SchedulerError.unresolvedDate }

        let duration = TimeInterval((event.durationMinutes ?? 60) * 60)
        let end = start.addingTimeInterval(duration)

        // Skip if an identical event is already on the calendar (re-runs, duplicates).
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: end, calendars: nil)
        if let existing = store.events(matching: predicate).first(where: { $0.title == event.title }) {
            return existing.eventIdentifier
        }

        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = event.title
        ekEvent.startDate = start
        ekEvent.endDate = end
        ekEvent.location = event.location
        var notesText = "Scheduled by Myna from a conversation."
        if !event.attendees.isEmpty {
            notesText += "\nWith: \(event.attendees.joined(separator: ", "))"
        }
        notesText += "\nAs heard: “\(event.rawWhen)”"
        ekEvent.notes = notesText
        ekEvent.calendar = store.defaultCalendarForNewEvents
        ekEvent.addAlarm(EKAlarm(relativeOffset: -15 * 60))

        try store.save(ekEvent, span: .thisEvent)
        return ekEvent.eventIdentifier
    }

    enum SchedulerError: LocalizedError {
        case noAccess
        case unresolvedDate

        var errorDescription: String? {
            switch self {
            case .noAccess: return "Calendar access has not been granted."
            case .unresolvedDate: return "Myna couldn't pin down a date and time for this event."
            }
        }
    }
}
