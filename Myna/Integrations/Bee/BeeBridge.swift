import CryptoKit
import Foundation
import SwiftData
import UIKit

/// Connects Myna to a Bee wearable through Bee's developer API.
///
/// - **Live:** Bee's real-time stream feeds Myna every utterance the Bee hears,
///   so "Myna, add oat milk to the shopping list" works when you're talking to
///   your Bee and the phone is across the room.
/// - **Notes:** finished Bee conversations are composed into Myna notes by the
///   on-device model, with tasks, shopping and reminders captured as usual.
/// - **To-dos:** your Bee's todos and Myna's to-dos/reminders stay in sync both ways.
///
/// Bee data lives in Bee's cloud; this is the one part of Myna that uses the
/// network beyond model downloads, and it's off until you connect.
@MainActor
final class BeeBridge: ObservableObject {

    enum Status: Equatable {
        case disconnected
        case pairing(URL)
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var accountName: String?
    @Published private(set) var isLive = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var facts: [String] = []

    weak var brain: MynaBrain?
    weak var pilot: ConversationPilot?
    private var modelContext: ModelContext?

    private var liveTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var pendingConversationFetches: Set<Int> = []

    private static let tokenAccount = "bee.token"
    /// Bee's pairing service and the developer app id its official CLI pairs as.
    private static let pairingURL = URL(string: "https://auth.beeai-services.com/apps/pairing/request")!
    private static let appID = "ph9fssu1kv1b0hns69fxf7rx"

    var composeNotesFromBee: Bool {
        UserDefaults.standard.object(forKey: "myna.bee.notes") as? Bool ?? true
    }

    var syncTodos: Bool {
        UserDefaults.standard.object(forKey: "myna.bee.todos") as? Bool ?? true
    }

    /// Only Bee conversations after this moment become Myna notes, so
    /// connecting doesn't re-scribe your whole history.
    private var connectedAt: Date {
        get { UserDefaults.standard.object(forKey: "myna.bee.connectedAt") as? Date ?? .now }
        set { UserDefaults.standard.set(newValue, forKey: "myna.bee.connectedAt") }
    }

    private var api: BeeAPI? {
        Keychain.string(for: Self.tokenAccount).map { BeeAPI(token: $0) }
    }

    var isConnected: Bool { status == .connected }

    init() {
        if Keychain.string(for: Self.tokenAccount) != nil {
            status = .connected
        }
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Pairing

    /// Starts Bee's app-pairing flow: opens bee.computer to approve Myna, then
    /// receives the API token sealed to a key that never leaves this phone.
    func startPairing() {
        pairingTask?.cancel()
        pairingTask = Task {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
            do {
                var opened = false
                let deadline = Date.now.addingTimeInterval(10 * 60)
                while !Task.isCancelled, Date.now < deadline {
                    let reply = try await requestPairing(publicKey: publicKey)
                    switch reply["status"] as? String {
                    case "completed":
                        guard let result = reply["result"] as? [String: Any],
                              let sealed = result["encryptedToken"] as? String else { throw BeeAPI.Failure.malformed }
                        let token = try NaClBox.openPairingToken(sealed, privateKey: privateKey)
                        connect(token: token)
                        return
                    case "pending":
                        if !opened, let requestID = reply["requestId"] as? String,
                           let url = URL(string: "https://bee.computer/connect#\(requestID)") {
                            status = .pairing(url)
                            opened = true
                            _ = await UIApplication.shared.open(url)
                        }
                    case "expired":
                        status = .failed("The pairing request expired. Try again.")
                        return
                    default:
                        throw BeeAPI.Failure.malformed
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                if case .pairing = status { status = .failed("Pairing timed out. Try again.") }
            } catch is CancellationError {
                // Cancelled by the user.
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        status = isConnected ? .connected : .disconnected
    }

    private func requestPairing(publicKey: String) async throws -> [String: Any] {
        var request = URLRequest(url: Self.pairingURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["app_id": Self.appID, "publicKey": publicKey])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BeeAPI.Failure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["ok"] as? Bool == true else { throw BeeAPI.Failure.malformed }
        return body
    }

    /// Also used for pasting a developer token by hand.
    func connect(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, for: Self.tokenAccount)
        connectedAt = .now
        status = .connected
        Task {
            await refresh()
            startLive()
        }
    }

    func disconnect() {
        stopLive()
        Keychain.set(nil, for: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: "myna.bee.connectedAt")
        status = .disconnected
        accountName = nil
        facts = []
    }

    // MARK: - Sync

    /// Pulls todos, facts and finished conversations. Call on launch and foreground.
    func refresh() async {
        guard let api else { return }
        do {
            let me = try await api.me()
            accountName = (me["first_name"] as? String) ?? (me["name"] as? String) ?? (me["email"] as? String)
            if syncTodos {
                mergeTodos(try await api.todos())
            }
            facts = (try? await api.facts()) ?? facts
            if composeNotesFromBee {
                for conversation in try await api.conversations(limit: 10) {
                    await importIfFinished(conversation)
                }
            }
            lastSync = .now
            if case .failed = status { status = .connected }
        } catch let failure as BeeAPI.Failure {
            if case .http(let code, _) = failure, code == 401 || code == 403 {
                status = .failed(failure.localizedDescription)
            }
        } catch {
            // Offline or Bee unreachable — try again next time.
        }
    }

    private func mergeTodos(_ todos: [BeeAPI.Todo]) {
        guard let modelContext, let brain else { return }
        let all = (try? modelContext.fetch(FetchDescriptor<MynaItem>())) ?? []
        for todo in todos {
            if let item = all.first(where: { $0.beeTodoID == todo.id }) {
                update(item, from: todo)
            } else if !todo.completed {
                let item = MynaItem(kind: todo.alarmAt == nil ? .todo : .reminder, text: todo.text, dueDate: todo.alarmAt, source: .bee)
                item.beeTodoID = todo.id
                modelContext.insert(item)
                brain.reminders.scheduleAlert(for: item)
                brain.reminders.mirror(item)
            }
        }
        try? modelContext.save()
    }

    private func update(_ item: MynaItem, from todo: BeeAPI.Todo) {
        guard let brain else { return }
        var changed = false
        if item.text != todo.text { item.text = todo.text; changed = true }
        if item.isDone != todo.completed {
            item.isDone = todo.completed
            item.completedAt = todo.completed ? .now : nil
            changed = true
        }
        if item.dueDate != todo.alarmAt, todo.alarmAt != nil {
            item.dueDate = todo.alarmAt
            changed = true
        }
        guard changed else { return }
        brain.reminders.cancelAlert(for: item)
        brain.reminders.scheduleAlert(for: item)
        brain.reminders.mirror(item)
    }

    private func importIfFinished(_ summary: BeeAPI.ConversationSummary) async {
        guard let api, let pilot, let ended = summary.endTime,
              ended > connectedAt, ended < .now.addingTimeInterval(60) else { return }
        guard let conversation = try? await api.conversation(id: summary.id) else { return }
        pilot.composeExternal(
            transcript: conversation.transcript,
            startedAt: summary.startTime ?? ended,
            endedAt: ended,
            sourceRef: "bee:\(summary.id)"
        )
    }

    /// Sends a Myna to-do/reminder change to the Bee.
    func push(_ item: MynaItem) {
        guard syncTodos, let api, item.kind == .todo || item.kind == .reminder else { return }
        let text = item.text, done = item.isDone, due = item.dueDate
        Task {
            if let id = item.beeTodoID {
                try? await api.updateTodo(id: id, text: text, completed: done)
            } else if !done, let created = try? await api.createTodo(text: text, alarmAt: due) {
                item.beeTodoID = created.id
                try? modelContext?.save()
            }
        }
    }

    func remove(_ item: MynaItem) {
        guard syncTodos, let api, let id = item.beeTodoID else { return }
        Task { try? await api.deleteTodo(id: id) }
    }

    // MARK: - Live stream

    func startLive() {
        guard liveTask == nil, isConnected else { return }
        liveTask = Task {
            var backoff: Double = 2
            while !Task.isCancelled, let api {
                do {
                    isLive = true
                    let stream = api.events(types: [
                        "new-utterance", "new-conversation", "update-conversation", "update-conversation-summary",
                        "todo-created", "todo-updated", "todo-deleted",
                    ])
                    for try await event in stream {
                        backoff = 2
                        handle(event)
                    }
                } catch let failure as BeeAPI.Failure {
                    if case .http(let code, _) = failure, code == 401 || code == 403 {
                        status = .failed(failure.localizedDescription)
                        break
                    }
                } catch {
                    // Dropped connection; reconnect below.
                }
                isLive = false
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 120)
            }
            isLive = false
            liveTask = nil
        }
    }

    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        isLive = false
    }

    private func handle(_ event: BeeAPI.Event) {
        switch event {
        case .utterance(let text, _):
            brain?.heardOnBee(text)

        case .conversationChanged(let id):
            guard composeNotesFromBee, !pendingConversationFetches.contains(id) else { return }
            pendingConversationFetches.insert(id)
            // Give Bee a moment to finish processing before reading it back.
            Task {
                try? await Task.sleep(for: .seconds(20))
                pendingConversationFetches.remove(id)
                guard let api, let conversation = try? await api.conversation(id: id) else { return }
                await importIfFinished(conversation.summary)
            }

        case .todoChanged(let todo):
            guard syncTodos else { return }
            mergeTodos([todo])

        case .todoDeleted(let id):
            guard syncTodos, let modelContext, let brain else { return }
            let items = (try? modelContext.fetch(FetchDescriptor<MynaItem>())) ?? []
            for item in items where item.beeTodoID == id {
                brain.reminders.cancelAlert(for: item)
                brain.reminders.removeMirror(of: item)
                modelContext.delete(item)
            }
            try? modelContext.save()

        case .other:
            break
        }
    }
}
