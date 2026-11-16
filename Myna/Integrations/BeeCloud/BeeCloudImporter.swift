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
    /// When the current import began. An import iOS suspended mid-way would
    /// otherwise leave `status` stuck on `.importing` and block every later run.
    private var importStartedAt: Date?
    var isBusy: Bool {
        guard status == .importing, let started = importStartedAt else { return false }
        return Date.now.timeIntervalSince(started) < 180
    }
    private static let rescanKey = "myna.beeCloud.rescan.v2"
    /// Bee todo ids already pulled into Lists, so re-imports don't duplicate.
    private static let importedTodoIDsKey = "myna.beeCloud.importedTodoIDs"
    /// What the last import read and did, shown in Backstage.
    @Published private(set) var lastReport: String?
    /// Acts on confident findings (calendar, reminders, lists) and notifies.
    weak var brain: MynaBrain?
    /// Runs the user's downloaded model for in-context extraction. Set by
    /// AppServices; nil falls back to keyword suggestions (Inbox only).
    var generate: ConversationExtractor.Generate?

    static let autoAddKey = "myna.beeCloud.autoAdd"
    /// Add confident finds automatically (with a Cancel-able notification on
    /// iPhone / Apple Watch) instead of waiting in the Inbox. On by default.
    var autoAddEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoAddKey) as? Bool ?? true
    }
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

    /// Fetch the bracelet's sealed key token from Bee (for BeeManager).
    func braceletKeyToken(deviceIDHex: String) async throws -> Data {
        guard let token, !token.isEmpty else { throw BeeCloudAPI.Failure.http(401) }
        return try await BeeCloudAPI(token: token).secureKeyToken(deviceIDHex: deviceIDHex)
    }

    // MARK: - Settings

    var hasToken: Bool { token?.isEmpty == false }

    /// The connected Bee account token, so the bracelet key-fetch UI can reuse it
    /// as the session token instead of making you capture one by hand.
    var storedToken: String? { token }

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
        guard isEnabled, !isBusy else { return }
        Task {
            await refreshAccount()
            await importRecent()
        }
    }

    /// Awaitable refresh for the background task — pulls account, facts and new
    /// conversations, then returns so the task can report completion to iOS.
    func backgroundRefresh() async {
        guard isEnabled, !isBusy else { return }
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
        importStartedAt = .now
        let api = BeeCloudAPI(token: token)
        do {
            // Bee's own server-extracted to-dos — the most reliable action
            // items, since Bee's cloud model did the work. Import the open ones
            // straight into Lists before any on-device extraction.
            let beeTodosAdded = await importBeeTodos(api)
            let summaries = try await api.recentConversations(limit: limit)
            var added = 0
            // Suggestions we've already offered (any status) — so we never
            // re-surface one you dismissed, and never duplicate across notes.
            var knownKeys = Self.existingSuggestionKeys(in: modelContext)
            var toApply: [Suggestion] = []
            // Only act automatically on recent conversations, so the first
            // import doesn't replay weeks of old plans onto your calendar.
            let recentCutoff = Date.now.addingTimeInterval(-48 * 3600)
            var usedModel = false
            var inboxCount = 0
            var checked = 0

            // One-time second look at the last 48 hours with the current
            // extraction, so conversations the previous build passed over
            // still get acted on.
            if !UserDefaults.standard.bool(forKey: Self.rescanKey) {
                var descriptor = FetchDescriptor<ConversationNote>(predicate: #Predicate { $0.endedAt >= recentCutoff })
                descriptor.fetchLimit = 30
                let recentNotes = ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.sourceRef.hasPrefix("bee:") }
                for note in recentNotes where !note.transcript.isEmpty {
                    let found = await findActions(transcript: note.transcript, summary: note.overview,
                                                       date: note.startedAt, wearer: accountName)
                    usedModel = usedModel || found.usedModel
                    let made = Self.makeSuggestions(from: found.items, note: note, in: modelContext, known: &knownKeys)
                    toApply += made.filter(\.autoAdd).map(\.suggestion)
                    inboxCount += made.filter { !$0.autoAdd }.count
                    checked += 1
                }
                UserDefaults.standard.set(true, forKey: Self.rescanKey)
            }

            for summary in summaries {
                let sourceRef = "bee:\(summary.id)"
                if Self.alreadyImported(sourceRef, in: modelContext) { continue }
                let conversation = try await api.conversation(id: summary.id)
                guard !conversation.transcript.isEmpty else { continue }
                let note = Self.note(from: conversation, sourceRef: sourceRef)
                modelContext.insert(note)
                let found = await findActions(transcript: conversation.transcript, summary: conversation.summary,
                                                   date: conversation.start, wearer: accountName)
                usedModel = usedModel || found.usedModel
                let made = Self.makeSuggestions(from: found.items, note: note, in: modelContext, known: &knownKeys)
                inboxCount += made.filter { !$0.autoAdd }.count
                if conversation.end >= recentCutoff {
                    toApply += made.filter(\.autoAdd).map(\.suggestion)
                }
                added += 1
                checked += 1
            }
            try? modelContext.save()
            var applied = 0
            if autoAddEnabled, let brain, !toApply.isEmpty {
                for suggestion in toApply {
                    if await brain.autoApply(suggestion) {
                        suggestion.status = .accepted
                        applied += 1
                    }
                }
                try? modelContext.save()
            } else if !autoAddEnabled {
                inboxCount += toApply.count
            }
            if checked > 0 || beeTodosAdded > 0 {
                let ai = usedModel ? (AppServices.shared.modelManager.activeModel?.displayName ?? "the on-device model") : "keyword matching"
                let beePart = beeTodosAdded > 0 ? " \(beeTodosAdded) to-do\(beeTodosAdded == 1 ? "" : "s") from Bee," : ""
                lastReport = "Read \(checked) conversation\(checked == 1 ? "" : "s") with \(ai):\(beePart) added \(applied), \(inboxCount) waiting in the Inbox."
            }
            lastImport = .now
            UserDefaults.standard.set(lastImport, forKey: Self.lastImportKey)
            status = .done(added: added)
            return added
        } catch {
            status = .failed(error.localizedDescription)
            return 0
        }
    }

    /// Pull Bee's own extracted to-dos into Myna's Lists. Open items with a time
    /// become reminders, the rest to-dos; each Bee id is imported once. Returns
    /// how many new items were added. Never throws — a missing `/v1/todos`
    /// endpoint just yields nothing and the conversation import carries on.
    private func importBeeTodos(_ api: BeeCloudAPI) async -> Int {
        guard let brain else { return 0 }
        guard let todos = try? await api.todos(limit: 60), !todos.isEmpty else { return 0 }
        var seen = Set(UserDefaults.standard.stringArray(forKey: Self.importedTodoIDsKey) ?? [])
        var added = 0
        for todo in todos where !todo.completed && !seen.contains(todo.id) {
            seen.insert(todo.id)
            let kind: ItemKind = todo.due != nil ? .reminder : .todo
            let made = brain.add(kind, texts: [todo.text], due: todo.due,
                                 detail: "From Bee", source: .conversation, announce: false)
            added += made.count
        }
        UserDefaults.standard.set(Array(seen), forKey: Self.importedTodoIDsKey)
        return added
    }

    /// What to act on in one conversation. TV / film / podcast audio yields
    /// nothing. Otherwise the keyword parser always runs (calendar events with
    /// a date, "remind me to…", shopping…), and when Apple Intelligence is
    /// available its in-context reading is merged on top — catching what the
    /// keywords miss and vetoing media the keywords can't recognise.
    private func findActions(transcript: String, summary: String, date: Date, wearer: String?) async -> (items: [ParsedSuggestion], usedModel: Bool) {
        if TranscriptParser.looksLikeMedia(summary: summary, transcript: transcript) {
            return ([], false)
        }
        let heuristic = TranscriptParser.parse(transcript)
        guard let result = await ConversationExtractor.extract(
            transcript: transcript, beeSummary: summary, wearerName: wearer,
            conversationDate: date, generate: generate
        ) else {
            // No model available — keyword matches, Inbox only, never auto-added.
            return (heuristic.map { var i = $0; i.autoAdd = false; return i }, false)
        }
        if result.isMedia { return ([], true) }
        // The model understood the conversation: it alone decides what to add.
        // Keyword items it didn't cover ride along as Inbox suggestions only.
        let extras = heuristic
            .filter { h in !result.items.contains { TranscriptParser.wordsOverlap($0.text, h.text) } }
            .map { var i = $0; i.autoAdd = false; return i }
        return (TranscriptParser.dedup(result.items + extras), true)
    }

    private static func makeSuggestions(
        from parsedItems: [ParsedSuggestion],
        note: ConversationNote,
        in context: ModelContext,
        known: inout Set<String>
    ) -> [(suggestion: Suggestion, autoAdd: Bool)] {
        var made: [(suggestion: Suggestion, autoAdd: Bool)] = []
        for parsed in parsedItems where known.insert(parsed.dedupKey).inserted {
            let suggestion = Suggestion(
                kind: parsed.kind,
                text: parsed.text,
                detail: parsed.detail,
                date: parsed.date,
                noteID: note.id,
                sourceTitle: note.title
            )
            context.insert(suggestion)
            made.append((suggestion, parsed.autoAdd))
        }
        return made
    }

    private static func existingSuggestionKeys(in context: ModelContext) -> Set<String> {
        let all = (try? context.fetch(FetchDescriptor<Suggestion>())) ?? []
        return Set(all.map { $0.dedupKey })
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
