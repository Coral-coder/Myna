import Foundation
import UserNotifications

/// Tells you — on your iPhone and, mirrored automatically, your Apple Watch —
/// the moment Myna does something on its own: books a calendar event, sets a
/// reminder, adds to a list. Each notification carries a **Cancel** button that
/// undoes the action right from your wrist, no need to open the app.
@MainActor
final class ActionNotifier {
    static let categoryID = "MYNA_ACTION"
    static let undoActionID = "MYNA_UNDO"

    /// Bumped on every posted notification, so the brain can tell whether a
    /// command already announced itself (and skip its generic backgrounded banner).
    private(set) var postedCount = 0

    /// Registers the notification category that gives action notifications their
    /// Cancel button. Safe to call before notification permission is granted.
    static func registerCategory() {
        let cancel = UNNotificationAction(
            identifier: undoActionID,
            title: "Cancel",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [cancel],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Posts an action notification with a Cancel button that will undo `undo`.
    func announce(title: String, body: String, undo: ActionUndo) {
        postedCount += 1
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = "myna.action"
        content.userInfo = undo.payload
        let request = UNNotificationRequest(
            identifier: "myna.action.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Clears the delivered notification once its action has been handled, so a
    /// cancelled action doesn't keep sitting on the wrist as if still pending.
    func clearDelivered(_ identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
