import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bee's developer API (docs.bee.computer): your Bee wearable's conversations,
/// todos and facts, plus a live event stream. Talks to Bee's public HTTPS
/// endpoint with the token from app pairing.
struct BeeAPI {
    static let baseURL = URL(string: "https://api.developer.bee.amazon.dev")!

    var token: String
    var session: URLSession = .shared

    // MARK: - Models

    struct Todo: Equatable {
        var id: Int
        var text: String
        var completed: Bool
        var alarmAt: Date?
    }

    struct ConversationSummary: Equatable {
        var id: Int
        var startTime: Date?
        var endTime: Date?
        var summary: String?
        var state: String
    }

    struct Utterance: Equatable {
        var text: String
        var speaker: String
        var spokenAt: Date?
    }

    struct Conversation: Equatable {
        var summary: ConversationSummary
        var utterances: [Utterance]

        /// "Speaker 1: …" lines in spoken order, ready for the notes engine.
        var transcript: String {
            utterances
                .sorted { ($0.spokenAt ?? .distantPast) < ($1.spokenAt ?? .distantPast) }
                .map { utterance in
                    let speaker = utterance.speaker.replacingOccurrences(of: "speaker_", with: "Speaker ")
                    return speaker.isEmpty ? utterance.text : "\(speaker): \(utterance.text)"
                }
                .joined(separator: "\n")
        }
    }

    enum Event: Equatable {
        case utterance(text: String, speaker: String)
        case conversationChanged(id: Int)
        case todoChanged(Todo)
        case todoDeleted(id: Int)
        case other(String)
    }

    enum Failure: LocalizedError {
        case http(Int, String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .http(401, _), .http(403, _): return "Bee didn't accept the connection. Reconnect your Bee in Backstage."
            case .http(let code, let body): return "Bee returned \(code). \(body.prefix(120))"
            case .malformed: return "Bee sent something Myna couldn't read."
            }
        }
    }

    // MARK: - Endpoints

    func me() async throws -> [String: Any] {
        try await json("GET", "/v1/me")
    }

    func todos(limit: Int = 100) async throws -> [Todo] {
        let body = try await json("GET", "/v1/todos?limit=\(limit)")
        return Self.array(body, "todos").compactMap(Self.todo)
    }

    func createTodo(text: String, alarmAt: Date?) async throws -> Todo? {
        var body: [String: Any] = ["text": text]
        if let alarmAt { body["alarm_at"] = Self.iso(alarmAt) }
        let response = try await json("POST", "/v1/todos", body: body)
        return Self.todo(response["todo"] as? [String: Any] ?? response)
    }

    func updateTodo(id: Int, text: String? = nil, completed: Bool? = nil) async throws {
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        if let completed { body["completed"] = completed }
        _ = try await json("PUT", "/v1/todos/\(id)", body: body)
    }

    func deleteTodo(id: Int) async throws {
        _ = try await json("DELETE", "/v1/todos/\(id)")
    }

    func facts(limit: Int = 50) async throws -> [String] {
        let body = try await json("GET", "/v1/facts?limit=\(limit)")
        return Self.array(body, "facts").compactMap { $0["text"] as? String }
    }

    func conversations(limit: Int = 10) async throws -> [ConversationSummary] {
        let body = try await json("GET", "/v1/conversations?limit=\(limit)")
        return Self.array(body, "conversations").compactMap(Self.conversationSummary)
    }

    func conversation(id: Int) async throws -> Conversation {
        let body = try await json("GET", "/v1/conversations/\(id)")
        let record = body["conversation"] as? [String: Any] ?? body
        guard let summary = Self.conversationSummary(record) else { throw Failure.malformed }
        let transcriptions = record["transcriptions"] as? [[String: Any]] ?? []
        let utterances = transcriptions
            .flatMap { $0["utterances"] as? [[String: Any]] ?? [] }
            .compactMap { raw -> Utterance? in
                guard let text = raw["text"] as? String, !text.isEmpty else { return nil }
                return Utterance(
                    text: text,
                    speaker: raw["speaker"] as? String ?? "",
                    spokenAt: Self.date(raw["spoken_at"] ?? raw["start"])
                )
            }
        return Conversation(summary: summary, utterances: utterances)
    }

    /// The live event stream. Ends when the connection drops; callers reconnect.
    func events(types: [String]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var components = URLComponents(url: Self.baseURL.appendingPathComponent("v1/stream"), resolvingAgainstBaseURL: false)!
                    components.queryItems = [URLQueryItem(name: "types", value: types.joined(separator: ","))]
                    var request = URLRequest(url: components.url!)
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 60 * 60
                    #if canImport(Darwin)
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw Failure.http(http.statusCode, "")
                    }
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        if let event = parser.feed(line: line) {
                            continuation.yield(Self.event(named: event.name, data: event.data))
                        }
                        // `lines` skips the blank separators SSE uses, so treat
                        // each data line (Bee sends one per event) as the end.
                        if line.hasPrefix("data"), let event = parser.feed(line: "") {
                            continuation.yield(Self.event(named: event.name, data: event.data))
                        }
                    }
                    #endif
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Plumbing

    private func json(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.baseURL)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        if data.isEmpty { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        if let dictionary = object as? [String: Any] { return dictionary }
        if let array = object as? [Any] { return ["items": array] }
        return [:]
    }

    /// The array under `key`, or the only array in the response if Bee named it differently.
    static func array(_ body: [String: Any], _ key: String) -> [[String: Any]] {
        if let items = body[key] as? [[String: Any]] { return items }
        if let items = body["items"] as? [[String: Any]] { return items }
        return body.values.compactMap { $0 as? [[String: Any]] }.first ?? []
    }

    static func todo(_ raw: [String: Any]) -> Todo? {
        guard let id = int(raw["id"]), let text = raw["text"] as? String else { return nil }
        return Todo(
            id: id,
            text: text,
            completed: raw["completed"] as? Bool ?? false,
            alarmAt: date(raw["alarm_at"] ?? raw["alarmAt"])
        )
    }

    static func conversationSummary(_ raw: [String: Any]) -> ConversationSummary? {
        guard let id = int(raw["id"]) else { return nil }
        return ConversationSummary(
            id: id,
            startTime: date(raw["start_time"]),
            endTime: date(raw["end_time"]),
            summary: (raw["short_summary"] as? String) ?? (raw["summary"] as? String) ?? (raw["title"] as? String),
            state: raw["state"] as? String ?? ""
        )
    }

    static func event(named name: String, data: String) -> Event {
        guard let json = data.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return .other(name) }
        switch name {
        case "new-utterance":
            let utterance = body["utterance"] as? [String: Any] ?? body
            guard let text = utterance["text"] as? String else { return .other(name) }
            return .utterance(text: text, speaker: utterance["speaker"] as? String ?? "")
        case "new-conversation", "update-conversation", "update-conversation-summary":
            let conversation = body["conversation"] as? [String: Any]
            guard let id = int(conversation?["id"] ?? body["conversation_id"] ?? body["id"]) else { return .other(name) }
            return .conversationChanged(id: id)
        case "todo-created", "todo-updated":
            guard let todo = todo(body["todo"] as? [String: Any] ?? body) else { return .other(name) }
            return .todoChanged(todo)
        case "todo-deleted":
            let raw = body["todo"] as? [String: Any] ?? body
            guard let id = int(raw["id"] ?? raw["todo_id"] ?? body["todo_id"]) else { return .other(name) }
            return .todoDeleted(id: id)
        default:
            return .other(name)
        }
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// Bee sends times as epoch milliseconds, sometimes as ISO 8601 strings.
    static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            if let millis = Double(text) { return Date(timeIntervalSince1970: millis / 1000) }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        guard let number = value as? Double ?? (value as? Int).map(Double.init) ?? (value as? NSNumber)?.doubleValue,
              number > 0 else { return nil }
        // Seconds vs milliseconds: anything past 1e11 is milliseconds.
        return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Server-sent events, one line at a time: `event:` and `data:` fields, a
/// blank line ends the event, `:` lines are keep-alive comments.
struct SSEParser {
    struct Event: Equatable {
        var name: String
        var data: String
    }

    private var name: String?
    private var dataLines: [String] = []

    mutating func feed(line rawLine: String) -> Event? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { name = nil; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return Event(name: name ?? "message", data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}
