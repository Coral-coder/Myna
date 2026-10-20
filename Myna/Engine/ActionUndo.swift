import Foundation

/// What the Cancel button on a Myna action notification should undo.
///
/// Encodes to and from a notification's `userInfo` dictionary. Kept free of
/// UserNotifications (and any platform import) so the round-trip is unit-testable
/// off-device — the notification that reaches your Apple Watch carries exactly
/// what `ActionNotifier` posts here.
enum ActionUndo: Equatable {
    /// A calendar event, undone by its `EKEvent` identifier.
    case event(id: String)
    /// One or more `MynaItem`s (to-dos, shopping, reminders, memos) by UUID string.
    case items(ids: [String])

    /// The key under which the kind is stored, so it can't collide with other userInfo.
    static let kindKey = "myna.undo"

    var payload: [String: Any] {
        switch self {
        case .event(let id):
            return [Self.kindKey: "event", "eventID": id]
        case .items(let ids):
            return [Self.kindKey: "items", "itemIDs": ids]
        }
    }

    init?(payload: [AnyHashable: Any]) {
        switch payload[Self.kindKey] as? String {
        case "event":
            guard let id = payload["eventID"] as? String, !id.isEmpty else { return nil }
            self = .event(id: id)
        case "items":
            guard let ids = payload["itemIDs"] as? [String], !ids.isEmpty else { return nil }
            self = .items(ids: ids)
        default:
            return nil
        }
    }
}
