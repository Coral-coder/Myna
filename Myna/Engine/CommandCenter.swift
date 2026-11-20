import Contacts
import EventKit
import Foundation

/// Carries out the things Lumi (on the server) asks the phone to do on the
/// device — put an event on the calendar, save a contact. These arrive through
/// HomeSync as "command" records, because Calendar and Contacts live on the
/// phone, not the server. Best-effort: if access isn't granted, the command is
/// quietly skipped (it stays recorded on the server either way).
@MainActor
enum CommandCenter {
    /// Run one command's data (the synced record's fields).
    static func run(_ data: [String: Any]) async {
        switch data["do"] as? String {
        case "calendar": await addEvent(data)
        case "contact": await addContact(data)
        default: break
        }
    }

    private static func addEvent(_ data: [String: Any]) async {
        guard let title = (data["title"] as? String), !title.isEmpty else { return }
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return }
        let event = EKEvent(eventStore: store)
        event.title = title
        let start = (data["start"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            ?? Date().addingTimeInterval(3600)
        let minutes = (data["durationMinutes"] as? Double) ?? Double(data["durationMinutes"] as? Int ?? 60)
        event.startDate = start
        event.endDate = start.addingTimeInterval(max(5, minutes) * 60)
        if let location = data["location"] as? String, !location.isEmpty { event.location = location }
        let notes = (data["notes"] as? String) ?? ""
        event.notes = notes.isEmpty ? "Added by Lumi" : notes
        event.calendar = store.defaultCalendarForNewEvents
        try? store.save(event, span: .thisEvent, commit: true)
    }

    private static func addContact(_ data: [String: Any]) async {
        guard let name = (data["name"] as? String), !name.isEmpty else { return }
        let store = CNContactStore()
        guard await requestContactsAccess(store) else { return }
        let contact = CNMutableContact()
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = parts.first ?? name
        if parts.count > 1 { contact.familyName = parts[1] }
        if let phone = data["phone"] as? String, !phone.isEmpty {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(string: phone))]
        }
        if let email = data["email"] as? String, !email.isEmpty {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try? store.execute(request)
    }

    private static func requestContactsAccess(_ store: CNContactStore) async -> Bool {
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { return true }
        return await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in continuation.resume(returning: granted) }
        }
    }
}
