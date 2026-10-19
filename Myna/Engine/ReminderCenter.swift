import EventKit
import Foundation
import UserNotifications

/// Makes reminders actually remind: a time-sensitive notification at the due
/// time (it breaks through Focus), plus an optional mirror in Apple Reminders
/// so lists show up on your Watch, Mac and in Siri.
@MainActor
final class ReminderCenter {
    private let store = EKEventStore()

    var mirrorToAppleReminders: Bool {
        UserDefaults.standard.object(forKey: "myna.mirrorReminders") as? Bool ?? true
    }

    // MARK: - Permissions

    func requestNotificationAccess() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func requestRemindersAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    var hasRemindersAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    // MARK: - Notifications

    func scheduleAlert(for item: MynaItem) {
        guard let due = item.dueDate, due > .now, !item.isDone else { return }
        let content = UNMutableNotificationContent()
        content.title = item.kind == .shopping ? "Shopping" : "Reminder"
        content.body = item.text
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "myna.\(item.kind.rawValue)"
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: item.notificationID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelAlert(for item: MynaItem) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.notificationID])
    }

    /// A quiet heads-up, used when Myna does something while the phone is in a pocket.
    func announce(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: "myna.announce.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Apple Reminders mirror

    /// Creates (or updates) the matching Apple Reminder. Memos aren't mirrored.
    func mirror(_ item: MynaItem) {
        guard mirrorToAppleReminders, hasRemindersAccess, item.kind != .memo else { return }
        let reminder: EKReminder
        if let identifier = item.reminderID, let existing = store.calendarItem(withIdentifier: identifier) as? EKReminder {
            reminder = existing
        } else {
            guard let list = calendar(for: item.kind) else { return }
            reminder = EKReminder(eventStore: store)
            reminder.calendar = list
        }
        reminder.title = item.text
        reminder.notes = item.detail.isEmpty ? "Added by Myna" : item.detail
        reminder.isCompleted = item.isDone
        if let due = item.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        } else {
            reminder.dueDateComponents = nil
        }
        do {
            try store.save(reminder, commit: true)
            item.reminderID = reminder.calendarItemIdentifier
        } catch {
            // Mirroring is best-effort; Myna's own list is the source of truth.
        }
    }

    func removeMirror(of item: MynaItem) {
        guard let identifier = item.reminderID,
              let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        try? store.remove(reminder, commit: true)
    }

    /// Shopping goes to a list called "Shopping" (or "Groceries" if you already
    /// have one); everything else to your default Reminders list.
    private func calendar(for kind: ItemKind) -> EKCalendar? {
        guard kind == .shopping else { return store.defaultCalendarForNewReminders() }
        let lists = store.calendars(for: .reminder)
        if let existing = lists.first(where: { ["shopping", "groceries", "grocery", "shopping list"].contains($0.title.lowercased()) }) {
            return existing
        }
        guard let source = store.defaultCalendarForNewReminders()?.source else { return nil }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = "Shopping"
        list.source = source
        do {
            try store.saveCalendar(list, commit: true)
            return list
        } catch {
            return store.defaultCalendarForNewReminders()
        }
    }
}
