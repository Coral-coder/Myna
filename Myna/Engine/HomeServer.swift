import Foundation
import Security

/// The link to your home computer. When it's paired and answering, Myna sends
/// transcription and note-writing there; the moment it doesn't answer, the same
/// work is done on the phone instead, and the server is retried shortly after.
@MainActor
final class HomeServer: ObservableObject {
    static let shared = HomeServer()

    struct Info: Equatable, Sendable {
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

    /// Every address the server gave when pairing (home network, private
    /// network). `baseURL` is the one that answered last.
    private var addresses: [URL] = []
    private var baseURL: URL?
    private var token = ""
    /// After a failure, don't try the server again until this time — so an
    /// outage costs one timeout, not one per sentence.
    private var retryAfter: Date = .distantPast
    private var recheck: Task<Void, Never>?
    /// Called when the server starts answering after not doing so.
    var onBack: (() -> Void)?

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        let stored = (UserDefaults.standard.string(forKey: Self.urlKey) ?? "")
            .split(separator: "\n").compactMap { URL(string: String($0)) }
        if let url = stored.first {
            let saved = Self.readToken()
            if !saved.isEmpty {
                addresses = stored
                baseURL = url
                token = saved
                isPaired = true
            }
        }
        if isPaired {
            startPrivateNetworkIfNeeded()
            Task { await check() }
        }
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
              let newToken = items.first(where: { $0.name == "token" })?.value, newToken.count >= 16 else {
            lastError = "That isn't a Myna pairing link."
            return false
        }
        let urls = items.filter { $0.name == "url" }
            .compactMap { $0.value }
            .compactMap { URL(string: $0) }
            .filter { ($0.scheme == "http" || $0.scheme == "https") && $0.host != nil }
        guard let url = urls.first else {
            lastError = "That isn't a Myna pairing link."
            return false
        }
        if newToken != token { HomeSync.shared.reset() }
        addresses = urls
        baseURL = url
        token = newToken
        UserDefaults.standard.set(urls.map(\.absoluteString).joined(separator: "\n"), forKey: Self.urlKey)
        Self.writeToken(newToken)
        isPaired = true
        retryAfter = .distantPast
        lastError = nil
        startPrivateNetworkIfNeeded()
        Task { await check() }
        return true
    }

    func unpair() {
        baseURL = nil
        addresses = []
        token = ""
        isPaired = false
        reachable = nil
        info = Info()
        latencyMs = nil
        UserDefaults.standard.removeObject(forKey: Self.urlKey)
        Self.writeToken("")
        TailnetLink.shared.stop()
    }

    // MARK: - Talking to the server

    /// Ask the server whether it's there. Updates `reachable`.
    func check() async {
        guard isPaired else { return }
        do {
            // Ask every known address at once and use the first that answers:
            // the home network at home, the private network elsewhere.
            let candidates = addresses
            let found = await withTaskGroup(of: Probe?.self) { group -> Probe? in
                for url in candidates {
                    group.addTask { [weak self] in await self?.probe(url) }
                }
                for await result in group {
                    if let result {
                        group.cancelAll()
                        return result
                    }
                }
                return nil
            }
            guard let found else { throw ServerError(message: "The home server didn't answer.") }
            baseURL = found.url
            let wasAway = reachable != true
            reachable = true
            if wasAway { onBack?() }
            latencyMs = found.ms
            info = found.info
            retryAfter = .distantPast
            lastError = nil
        } catch {
            markDown(error)
        }
    }

    private struct Probe: Sendable {
        let url: URL
        let info: Info
        let ms: Int
    }

    private func probe(_ url: URL) async -> Probe? {
        let started = Date()
        guard let json = try? await send(path: "health", method: "GET", body: nil, contentType: nil, timeout: 6, to: url) else {
            return nil
        }
        return Probe(url: url,
                     info: Info(version: json["version"] as? String ?? "",
                                transcriber: json["transcriber"] as? String ?? "",
                                writer: json["writer"] as? String ?? ""),
                     ms: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// One stretch of a clip, by one speaker, as the server heard it.
    struct Segment: Sendable {
        let text: String
        /// Seconds from the start of the clip.
        let start: Double
        let duration: Double
        /// The speaker's voice print (same voice model as the phone's), if any.
        let voice: [Float]
    }

    /// The clip split by speaker, from the last `transcribe` call. Empty when
    /// the server didn't separate speakers.
    private(set) var lastSegments: [Segment] = []

    /// Transcribe one utterance (16-bit mono WAV). Throws if the server can't,
    /// so the caller does it on the phone.
    func transcribe(wav: Data, audioSeconds: Double) async throws -> String {
        lastSegments = []
        do {
            // A graphics card does this far faster than real time; if it takes
            // this long, something is wrong and the phone should take over.
            let json = try await send(path: "v1/transcribe", method: "POST", body: wav, contentType: "audio/wav",
                                      timeout: max(8, audioSeconds))
            markUp()
            lastRoute = "Home server · transcription"
            lastSegments = (json["segments"] as? [[String: Any]] ?? []).compactMap { piece in
                guard let text = piece["text"] as? String, !text.isEmpty else { return nil }
                let voice = (piece["voice"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.floatValue }
                return Segment(text: text, start: piece["start"] as? Double ?? 0,
                               duration: piece["duration"] as? Double ?? 0, voice: voice)
            }
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

    struct AskResult { let reply: String; let searched: String; let steps: [String] }

    /// Ask Lumi on the server — the full agent, with its tools, Markdown answers
    /// and a trace of what it did. Used by the phone's Ask tab when the server is
    /// reachable, so the phone is a remote of the one brain.
    func ask(question: String, history: [[String: String]]) async throws -> AskResult {
        do {
            let payload: [String: Any] = ["question": question, "history": history]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let json = try await send(path: "browse/ask.json", method: "POST", body: body,
                                      contentType: "application/json", timeout: 240)
            markUp()
            lastRoute = "Home server · Lumi"
            return AskResult(reply: json["reply"] as? String ?? "",
                             searched: json["searched"] as? String ?? "",
                             steps: (json["steps"] as? [Any])?.compactMap { $0 as? String } ?? [])
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

    private func send(path: String, method: String, body: Data?, contentType: String?, timeout: TimeInterval,
                      to address: URL? = nil) async throws -> [String: Any] {
        guard let baseURL = address ?? baseURL else { throw ServerError(message: "No home server is paired.") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, status) = try await perform(request, body: body)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if !(200..<300).contains(status) {
            throw ServerError(message: (json["detail"] as? String) ?? "The server answered with an error (\(status)).")
        }
        return json
    }

    /// Carry one request: over the private network (Tailscale inside Myna) for
    /// private-network addresses, directly for the home Wi-Fi address.
    private func perform(_ request: URLRequest, body: Data?) async throws -> (Data, Int) {
        if let host = request.url?.host, TailnetLink.isPrivateNetwork(host) {
            return try await TailnetLink.shared.send(request, body: body)
        }
        let reply: (Data, URLResponse)
        if let body {
            reply = try await URLSession.shared.upload(for: request, from: body)
        } else {
            reply = try await URLSession.shared.data(for: request)
        }
        return (reply.0, (reply.1 as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Whether any paired address is on the private network — if so, Myna's
    /// built-in Tailscale is started.
    private func startPrivateNetworkIfNeeded() {
        if addresses.contains(where: { TailnetLink.isPrivateNetwork($0.host ?? "") }) {
            TailnetLink.shared.start()
        }
    }

    var hasPrivateAddress: Bool { addresses.contains { TailnetLink.isPrivateNetwork($0.host ?? "") } }

    /// One exchange with the home database: sends changes, returns the reply.
    func syncExchange(_ body: Data) async throws -> Data {
        guard let baseURL else { throw ServerError(message: "No home server is paired.") }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/sync"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await perform(request, body: body)
        if !(200..<300).contains(status) {
            throw ServerError(message: "The home database answered with an error (\(status)).")
        }
        return data
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
