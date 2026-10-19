import Contacts
import Foundation

/// Knows who the people in your conversations are.
///
/// Reads only names, nickname, company and job title — never phone numbers,
/// emails, addresses or notes — and works with iOS 18's limited contact
/// access, in which case Myna knows only the contacts you picked. The index
/// lives in memory and is rebuilt when your contacts change.
@MainActor
final class ContactsContext: ObservableObject {
    @Published private(set) var authorization: CNAuthorizationStatus

    private let store = CNContactStore()
    private var cached: PeopleIndex?
    private var changeObserver: NSObjectProtocol?

    init() {
        authorization = CNContactStore.authorizationStatus(for: .contacts)
        changeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cached = nil }
        }
    }

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .limited
    }

    func requestAccess() async -> Bool {
        _ = try? await store.requestAccess(for: .contacts)
        authorization = CNContactStore.authorizationStatus(for: .contacts)
        cached = nil
        return isAuthorized
    }

    /// The people index, built off the main thread on first use.
    func index() async -> PeopleIndex {
        if let cached { return cached }
        guard isAuthorized else { return PeopleIndex(people: []) }
        let store = self.store
        let people = await Task.detached(priority: .utility) {
            Self.fetchPeople(from: store)
        }.value
        let index = PeopleIndex(people: people)
        cached = index
        return index
    }

    private nonisolated static func fetchPeople(from store: CNContactStore) -> [KnownPerson] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var people: [KnownPerson] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            people.append(KnownPerson(
                givenName: contact.givenName,
                familyName: contact.familyName,
                nickname: contact.nickname,
                organization: contact.organizationName,
                jobTitle: contact.jobTitle
            ))
        }
        return people
    }
}
