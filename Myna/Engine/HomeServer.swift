import Foundation
import Security

/// The link to your home computer. When it's paired and answering, Myna sends
/// transcription and note-writing there; the moment it doesn't answer, the same
/// work is done on the phone instead, and the server is retried shortly after.
@MainActor
final class HomeServer: ObservableObject {
    static let shared = HomeServer()

    struct Info: Equatable {
        var version = ""
        var transcriber = ""
        var writer = ""
    }

    @Published private(set) var isPaired = false
    /// nil until the first check; then whether the server answered last time.
    @Published private(set) var reachable: Bool?
    @Published private(set) var info = Info()
    @Published private(set) var latencyMs: Int?
    @Published private(set) var lastError: String?
    /// "Home server" or "This iPhone", and what for — shown in Settings.
    @Published private(set) var lastRoute: String = ""
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "myna.server.enabled"
    private static let urlKey = "myna.server.url"
    private static let keychainService = "com.lightwave.myna.server"

    private var baseURL: URL?
    private var token = ""
    /// After a failure, don't try the server again until this time — so an
    /// outage costs one timeout, not one per sentence.
    private var retryAfter: Date = .distantPast
    private var recheck: Task<Void, Never>?

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if let stored = UserDefaults.standard.string(forKey: Self.urlKey), let url = URL(string: stored) {
            let saved = Self.readToken()
            if !saved.isEmpty {
                baseURL = url
                token = saved
                isPaired = true
            }
        }
        if isPaired { Task { await check() } }
    }

    var address: String { baseURL?.absoluteString ?? "" }

    /// Use the server for the next job? Paired, switched on, and not in the
    /// short quiet period that follows a failure.
    var shouldTry: Bool { enabled && isPaired && Date() >= retryAfter }

    // MARK: - Pairing

    /// Accepts the link the server shows: `myna://pair?url=…&token=…`.
    @discardableResult
    func pair(link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let items = components.queryItems,
              let rawURL = items.first(where: { $0.name == "url" })?.value,
              let url = URL(string: rawURL), url.scheme == "http" || url.scheme == "https", url.host != nil,
              let newToken = items.first(where: { $0.name == "token" })?.value, newToken.count >= 16 else {
            lastError = "That isn't a Myna pairing link."
            return false
        }
        baseURL = url
        token = newToken
        UserDefaults.standard.set(url.absoluteString, forKey: Self.urlKey)
        Self.writeToken(newToken)
        isPaired = true
        retryAfter = .distantPast
        lastError = nil
        Task { await check() }
        return true
    }

    func unpair() {
        baseURL = nil
        token = ""
        isPaired = false
        reachable = nil
        info = Info()
        latencyMs = nil
        UserDefaults.standard.removeObject(forKey: Self.urlKey)
        Self.writeToken("")
    }

    // MARK: - Talking to the server

    /// Ask the server whether it's there. Updates `reachable`.
    func check() async {
        guard isPaired else { return }
        let started = Date()
        do {
            let json = try await send(path: "health", method: "GET", body: nil, contentType: nil, timeout: 6)
            reachable = true
            latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            info = Info(version: json["version"] as? String ?? "",
                        transcriber: json["transcriber"] as? String ?? "",
                        writer: json["writer"] as? String ?? "")
            retryAfter = .distantPast
            lastError = nil
        } catch {
            markDown(error)
        }
    }

    /// Transcribe one utterance (16-bit mono WAV). Throws if the server can't,
    /// so the caller does it on the phone.
    func transcribe(wav: Data, audioSeconds: Double) async throws -> String {
        do {
            // A graphics card does this far faster than real time; if it takes
            // this long, something is wrong and the phone should take over.
            let json = try await send(path: "v1/transcribe", method: "POST", body: wav, contentType: "audio/wav",
                                      timeout: max(8, audioSeconds))
            markUp()
            lastRoute = "Home server · transcription"
            return json["text"] as? String ?? ""
        } catch {
            markDown(error)
            throw error
        }
    }

    /// Write something with the server's language model.
    func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        do {
            let payload: [String: Any] = ["instructions": instructions, "prompt": prompt, "max_tokens": min(max(1, maxTokens), 8192)]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let json = try await send(path: "v1/generate", method: "POST", body: body, contentType: "application/json", timeout: 240)
            guard let text = json["text"] as? String, !text.isEmpty else { throw ServerError(message: "The server returned nothing.") }
            markUp()
            lastRoute = "Home server · writing"
            return text
        } catch {
            markDown(error)
            throw error
        }
    }

    /// Record that the phone did a job itself.
    func noteLocal(_ what: String) {
        guard isPaired, enabled else { return }
        lastRoute = "This iPhone · \(what)"
    }

    private func markUp() {
        if reachable != true { reachable = true }
        lastError = nil
    }

    private func markDown(_ error: Error) {
        reachable = false
        lastError = error.localizedDescription
        retryAfter = Date().addingTimeInterval(20)
        // Keep looking for it in the background so work moves back by itself.
        guard recheck == nil else { return }
        recheck = Task { [weak self] in
            while let self, self.isPaired, self.reachable != true {
                try? await Task.sleep(for: .seconds(20))
                await self.check()
            }
            self?.recheck = nil
        }
    }

    private func send(path: String, method: String, body: Data?, contentType: String?, timeout: TimeInterval) async throws -> [String: Any] {
        guard let baseURL else { throw ServerError(message: "No home server is paired.") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let reply: (Data, URLResponse)
        if let body {
            reply = try await URLSession.shared.upload(for: request, from: body)
        } else {
            reply = try await URLSession.shared.data(for: request)
        }
        let json = (try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any]) ?? [:]
        if let http = reply.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServerError(message: (json["detail"] as? String) ?? "The server answered with an error (\(http.statusCode)).")
        }
        return json
    }

    // MARK: - Token storage (Keychain)

    private static func readToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    private static func writeToken(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "token",
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
