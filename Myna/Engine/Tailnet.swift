import Foundation
import Tailnet
import UIKit

/// Tailscale inside Myna: this iPhone's own place on your private network, so
/// the home computer can be reached from anywhere without a separate app. It
/// starts only when a paired home server has a private-network address.
@MainActor
final class TailnetLink: ObservableObject {
    static let shared = TailnetLink()

    enum State: Equatable {
        case off
        case starting
        case needsSignIn(URL)
        case connected(String)
        case failed(String)
    }

    @Published private(set) var state: State = .off

    private var node: TailnetNode?
    private var watcher: Task<Void, Never>?

    private init() {}

    /// Addresses Tailscale hands out (100.64.0.0/10).
    static func isPrivateNetwork(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    func start() {
        guard node == nil, watcher == nil else { return }
        state = .starting
        watcher = Task { [weak self] in
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tailscale", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let made: Result<TailnetNode, Error> = await Task.detached {
                Result { try TailnetNode(directory: folder.path, hostName: "myna-iphone") }
            }.value
            guard let self else { return }
            switch made {
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
                self.watcher = nil
                return
            case .success(let node):
                self.node = node
                await self.watch(node)
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        if let node {
            Task.detached { node.close() }
        }
        node = nil
        state = .off
    }

    /// Follow the node's state: waiting for sign-in, then connected.
    private func watch(_ node: TailnetNode) async {
        while !Task.isCancelled {
            let status = await Task.detached { try? node.status() }.value
            if let status {
                if status.state == "Running" {
                    let wasConnected = isConnected
                    state = .connected(status.address)
                    if !wasConnected { Task { await HomeServer.shared.check() } }
                } else if let url = URL(string: status.signInURL), !status.signInURL.isEmpty {
                    state = .needsSignIn(url)
                } else if !isConnected {
                    state = .starting
                }
            }
            try? await Task.sleep(for: .seconds(isConnected ? 15 : 2))
        }
    }

    /// Open Tailscale's sign-in page in the browser.
    func signIn() {
        if case .needsSignIn(let url) = state { UIApplication.shared.open(url) }
    }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "The private network isn't connected yet." }
    }

    /// One HTTP request to the home computer over the private network.
    func send(_ request: URLRequest, body: Data?) async throws -> (Data, Int) {
        guard let node, isConnected, let url = request.url, let host = url.host else { throw Unavailable() }
        let port = url.port ?? 80
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?" + query }
        let method = request.httpMethod ?? "GET"
        let headers = request.allHTTPHeaderFields ?? [:]
        let timeout = request.timeoutInterval
        // Connecting to a computer that is switched off can hang for a long
        // time inside Tailscale; give up at the request's own time limit so the
        // phone takes the work over promptly.
        let reply = try await Self.withDeadline(timeout + 2) {
            try node.http(host: host, port: port, method: method, path: path, headers: headers, body: body, timeout: timeout)
        }
        return (reply.body, reply.status)
    }

    struct TimedOut: LocalizedError {
        var errorDescription: String? { "The home server didn't answer in time." }
    }

    private static func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                                  _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let gate = OnceGate()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try work() }
                if gate.claim() { continuation.resume(with: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if gate.claim() { continuation.resume(throwing: TimedOut()) }
            }
        }
    }
}

/// Lets exactly one of two racing callers go ahead.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
