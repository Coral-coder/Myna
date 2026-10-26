import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads your own conversations from Bee's developer API (docs.bee.computer)
/// with an API token from your Bee account. Used to bring Bee's recordings and
/// speaker-labelled transcripts into Myna — Bee does the far-field capture, Myna
/// keeps and works the notes. Read-only; it never sends your audio or notes out.
struct BeeCloudAPI {
    static let baseURL = URL(string: "https://api.developer.bee.amazon.dev")!

    var token: String
    var session: URLSession = .shared

    struct ConversationSummary: Equatable {
        var id: Int
        var start: Date?
        var end: Date?
        var summary: String
        var state: String
    }

    /// A conversation ready to file as a Myna note.
    struct ImportedConversation {
        var id: Int
        var start: Date
        var end: Date
        var summary: String
        /// "Speaker 1: …" lines in spoken order.
        var transcript: String
        var title: String
    }

    enum Failure: LocalizedError {
        case http(Int)
        case malformed
        case route(host: String, code: Int)
        var errorDescription: String? {
            switch self {
            case .http(401), .http(403): return "Bee didn't accept that token. Check it in Backstage."
            case .http(let code): return "Bee returned HTTP \(code)."
            case .malformed: return "Bee sent something Myna couldn't read."
            case .route(let host, let code): return "Bee key endpoint on \(host) returned HTTP \(code)."
            }
        }
    }

    /// Finished conversations, most recent first.
    func recentConversations(limit: Int = 20) async throws -> [ConversationSummary] {
        let body = try await get("/v1/conversations?limit=\(limit)")
        let list = (body["conversations"] as? [[String: Any]]) ?? []
        return list.compactMap(Self.summary).filter { $0.state.lowercased() != "in_progress" }
    }

    /// One conversation with its full speaker-labelled transcript.
    func conversation(id: Int) async throws -> ImportedConversation {
        let body = try await get("/v1/conversations/\(id)")
        let record = (body["conversation"] as? [String: Any]) ?? body
        guard let summary = Self.summary(record) else { throw Failure.malformed }

        let transcriptions = (record["transcriptions"] as? [[String: Any]]) ?? []
        let utterances = transcriptions.flatMap { ($0["utterances"] as? [[String: Any]]) ?? [] }
        let lines = utterances.compactMap { raw -> (Date, String)? in
            guard let text = (raw["text"] as? String), !text.isEmpty else { return nil }
            let speakerRaw = (raw["speaker"] as? String) ?? ""
            let speaker = speakerRaw.replacingOccurrences(of: "speaker_", with: "Speaker ")
            let when = Self.date(raw["spoken_at"] ?? raw["start"]) ?? .distantPast
            return (when, speaker.isEmpty ? text : "\(speaker): \(text)")
        }
        let transcript = lines.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")

        let title = Self.title(from: summary.summary)
        return ImportedConversation(
            id: summary.id,
            start: summary.start ?? .now,
            end: summary.end ?? summary.start ?? .now,
            summary: summary.summary,
            transcript: transcript,
            title: title
        )
    }

    /// The display name on the connected Bee account, if any.
    func accountName() async throws -> String? {
        let body = try await get("/v1/me")
        let record = (body["user"] as? [String: Any]) ?? body
        return (record["first_name"] as? String)
            ?? (record["name"] as? String)
            ?? (record["email"] as? String)
    }

    /// Facts Bee has learned about you — handy context for Myna's assistant.
    func facts(limit: Int = 50) async throws -> [String] {
        let body = try await get("/v1/facts?limit=\(limit)")
        let list = (body["facts"] as? [[String: Any]]) ?? (body["items"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Bracelet key

    /// Fetches the bracelet's sealed encryption-key token from Bee's backend.
    ///
    /// The bracelet only accepts a key sealed/signed by Bee, so "my own key"
    /// isn't possible on the stock firmware. Bee's app gets this blob from
    /// `POST /ble/secure-key` with the bracelet's device id and hands the whole
    /// thing to the device; the actual AES-128 CTR key is bytes 12..<28 of it
    /// (or the whole blob when it's exactly 16 bytes). This is the one call that
    /// touches Bee's server — the audio itself still never leaves the phone.
    func secureKeyToken(deviceIDHex: String) async throws -> Data {
        let (data, contentType) = try await postRaw("/ble/secure-key", json: ["device_id": deviceIDHex], host: Self.baseURL.host ?? "?")
        if contentType.contains("application/octet-stream") { return data }
        // Otherwise a JSON { "token": "<hex pairs or base64>" }.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String else { throw Failure.malformed }
        if let bytes = Self.hexBytes(token) { return bytes }
        if let b64 = Data(base64Encoded: token) { return b64 }
        throw Failure.malformed
    }

    /// The 16-byte AES-CTR key carried inside a sealed token.
    static func ctrKey(fromToken token: Data) -> Data? {
        if token.count == BeeProtocol.keyLength { return token }
        if token.count >= 28 { return token.subdata(in: 12..<28) }
        return nil
    }

    private static func hexBytes(_ string: String) -> Data? {
        let chars = Array(string)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            out.append(byte)
            i += 2
        }
        return Data(out)
    }

    // MARK: - HTTP

    /// Builds a request URL. Uses string concatenation, not
    /// `appendingPathComponent`, which percent-encodes the `?` of a query string
    /// into `%3F` and turns e.g. `/v1/facts?limit=50` into a 404.
    static func endpoint(_ path: String) -> URL? {
        URL(string: baseURL.absoluteString + path)
    }

    /// POST returning the raw body and its content-type (for the key blob,
    /// which may be octet-stream or JSON).
    private func postRaw(_ path: String, json: [String: Any], host: String = "") async throws -> (Data, String) {
        guard let url = Self.endpoint(path) else { throw Failure.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw host.isEmpty ? Failure.http(code) : Failure.route(host: host, code: code)
        }
        let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return (data, contentType)
    }

    private func get(_ path: String) async throws -> [String: Any] {
        guard let url = Self.endpoint(path) else { throw Failure.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.malformed }
        return object
    }

    // MARK: - Parsing

    private static func summary(_ raw: [String: Any]) -> ConversationSummary? {
        guard let id = raw["id"] as? Int else { return nil }
        return ConversationSummary(
            id: id,
            start: date(raw["start_time"] ?? raw["started_at"]),
            end: date(raw["end_time"] ?? raw["ended_at"]),
            summary: (raw["summary"] as? String) ?? (raw["short_summary"] as? String) ?? "",
            state: (raw["state"] as? String) ?? ""
        )
    }

    private static func title(from summary: String) -> String {
        let firstLine = summary
            .split(whereSeparator: { $0 == "\n" || $0 == "." })
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if firstLine.isEmpty { return "Bee conversation" }
        return String(firstLine.prefix(80))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            return isoFormatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
        return nil
    }
}
