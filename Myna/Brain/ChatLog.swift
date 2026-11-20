import Foundation

/// The Ask conversation. Kept on disk so it is still there after switching
/// tabs or reopening Myna, and handed to the model so follow-up questions
/// ("and the one before that?") make sense.
@MainActor
final class ChatLog: ObservableObject {
    static let shared = ChatLog()

    struct Message: Identifiable, Equatable, Codable {
        enum Role: String, Codable { case me, myna }
        var id = UUID()
        var role: Role
        var text: String
        var at = Date()
        /// What Lumi did to answer (shown when "thinking" is on). Myna messages only.
        var steps: [String] = []
    }

    @Published private(set) var messages: [Message] = []

    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ask-chat.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([Message].self, from: data) {
            messages = saved
        }
    }

    func add(_ role: Message.Role, _ text: String, steps: [String] = []) {
        messages.append(Message(role: role, text: text, steps: steps))
        if messages.count > 400 { messages.removeFirst(messages.count - 400) }
        save()
    }

    /// Start a new chat.
    func clear() {
        messages.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(messages) { try? data.write(to: Self.file, options: .atomic) }
    }

    /// The last few turns as text for the model, leaving out the question
    /// being asked right now. Only turns from the last two hours count as the
    /// same conversation.
    func recentContext(excluding question: String) -> String {
        var turns = messages.filter { Date().timeIntervalSince($0.at) < 7_200 }
        if let last = turns.last, last.role == .me, last.text == question { turns.removeLast() }
        return turns.suffix(10).map { turn in
            "\(turn.role == .me ? "USER" : "YOU"): \(turn.text.prefix(500))"
        }.joined(separator: "\n")
    }
}
