import Combine
import Foundation
import SwiftData

/// Brings your Bee conversations into Myna as notes.
///
/// Bee records the room (far-field mics, speaker separation) and transcribes it;
/// this pulls the finished conversations from your Bee account and files each as
/// a Myna note with its speaker-labelled transcript, so your notes live in one
/// place. Each conversation is imported once (tracked by `bee:<id>` in the
/// note's sourceRef). The API token is kept in the Keychain, on this device.
@MainActor
final class BeeCloudImporter: ObservableObject {
    enum Status: Equatable {
        case idle
        case importing
        case done(added: Int)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastImport: Date?
    /// Display name on the connected Bee account, once known.
    @Published private(set) var accountName: String?
    /// Facts Bee has learned about you (fed to the assistant as context).
    @Published private(set) var facts: [String] = []

    /// The log-in / pairing flow. Approve Myna once on bee.computer and the
    /// token arrives automatically — no copy-paste.
    let pairing = BeeCloudPairing()

    private static let tokenAccount = "bee.cloud.token"
    private static let enabledKey = "myna.beeCloud.enabled"
    private static let lastImportKey = "myna.beeCloud.lastImport"

    private var modelContext: ModelContext?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        lastImport = UserDefaults.standard.object(forKey: Self.lastImportKey) as? Date
        pairing.onToken = { [weak self] token in
            self?.saveToken(token)
        }
        // Re-publish pairing progress so views observing the importer update.
        pairing.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Begin the Bee log-in flow.
    func connect() {
        pairing.start()
    }

    func disconnect() {
        saveToken("")
        accountName = nil
        facts = []
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Settings

    var hasToken: Bool { token?.isEmpty == false }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey) && hasToken
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        objectWillChange.send()
    }

    private var token: String? {
        Keychain.data(for: Self.tokenAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(Self.tokenAccount)
        } else {
            try? Keychain.set(Data(trimmed.utf8), for: Self.tokenAccount)
            Task { await refreshAccount() }
        }
        objectWillChange.send()
    }

    // MARK: - Account & facts

    /// Pulls the account name and facts; also refreshes on foreground.
    func refreshAccount() async {
        guard let token, !token.isEmpty else { return }
        let api = BeeCloudAPI(token: token)
        accountName = (try? await api.accountName()) ?? accountName
        if let fetched = try? await api.facts() { facts = fetched }
    }

    /// Facts for the assistant's context, capped so the prompt stays small.
    func assistantFacts(limit: Int = 25) -> [String] {
        Array(facts.prefix(limit))
    }

    // MARK: - Import

    /// Called on foreground when auto-import is on.
    func importIfEnabled() {
        guard isEnabled, status != .importing else { return }
        Task {
            await refreshAccount()
            await importRecent()
        }
    }

    /// Awaitable refresh for the background task — pulls account, facts and new
    /// conversations, then returns so the task can report completion to iOS.
    func backgroundRefresh() async {
        guard isEnabled, status != .importing else { return }
        await refreshAccount()
        await importRecent()
    }

    /// Pulls recent conversations and files the new ones. Returns how many were added.
    @discardableResult
    func importRecent(limit: Int = 20) async -> Int {
        guard let token, !token.isEmpty, let modelContext else {
            status = .failed("Add your Bee API token first.")
            return 0
        }
        status = .importing
        let api = BeeCloudAPI(token: token)
        do {
            let summaries = try await api.recentConversations(limit: limit)
            var added = 0
            for summary in summaries {
                let sourceRef = "bee:\(summary.id)"
                if Self.alreadyImported(sourceRef, in: modelContext) { continue }
                let conversation = try await api.conversation(id: summary.id)
                guard !conversation.transcript.isEmpty else { continue }
                modelContext.insert(Self.note(from: conversation, sourceRef: sourceRef))
                added += 1
            }
            try? modelContext.save()
            lastImport = .now
            UserDefaults.standard.set(lastImport, forKey: Self.lastImportKey)
            status = .done(added: added)
            return added
        } catch {
            status = .failed(error.localizedDescription)
            return 0
        }
    }

    private static func alreadyImported(_ sourceRef: String, in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<ConversationNote>(predicate: #Predicate { $0.sourceRef == sourceRef })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    private static func note(from conversation: BeeCloudAPI.ImportedConversation, sourceRef: String) -> ConversationNote {
        ConversationNote(
            startedAt: conversation.start,
            endedAt: conversation.end,
            title: conversation.title,
            overview: conversation.summary,
            detailedNotes: conversation.summary,
            keyPoints: [],
            decisions: [],
            actionItems: [],
            detectedEvents: [],
            followUps: [],
            transcript: conversation.transcript,
            modelName: "Bee",
            sourceRef: sourceRef
        )
    }
}
