import Foundation
import libtailscale

/// One device on the user's private Tailscale network, running inside this app.
/// Every call here blocks, so call them off the main thread.
public final class TailnetNode: @unchecked Sendable {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct Status: Sendable {
        /// "NeedsLogin", "Starting", "Running", "Stopped", …
        public let state: String
        /// Where to sign in, when a sign-in is needed.
        public let signInURL: String
        /// This device's address on the private network, once it has one.
        public let address: String
    }

    public struct Reply: Sendable {
        public let status: Int
        public let body: Data
    }

    private let handle: Int32

    /// Starts the node. Its identity is kept in `directory`, so a sign-in is
    /// needed only once.
    public init(directory: String, hostName: String) throws {
        handle = tailscale_new()
        guard handle > 0 else { throw Failure(message: "Tailscale couldn't start.") }
        _ = tailscale_set_dir(handle, directory)
        _ = tailscale_set_hostname(handle, hostName)
        _ = tailscale_set_control_url(handle, "https://controlplane.tailscale.com")
        _ = tailscale_set_ephemeral(handle, 0)
        // Tailscale's own log goes nowhere; Myna shows only the state.
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 { _ = tailscale_set_logfd(handle, null) }
        guard tailscale_start(handle) == 0 else {
            let message = lastError()
            _ = tailscale_close(handle)
            throw Failure(message: message)
        }
    }

    public func close() {
        _ = tailscale_close(handle)
    }

    private func lastError() -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        _ = tailscale_errmsg(handle, &buffer, buffer.count)
        let message = String(cString: buffer)
        return message.isEmpty ? "Tailscale reported an error." : message
    }

    /// Where the node stands: signed in or not, and its address.
    public func status() throws -> Status {
        var out: UnsafeMutablePointer<CChar>?
        guard tailscale_status_json(handle, &out) == 0, let out else { throw Failure(message: lastError()) }
        defer { free(out) }
        let data = Data(bytes: out, count: strlen(out))
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let addresses = json["TailscaleIPs"] as? [String] ?? []
        return Status(state: json["BackendState"] as? String ?? "",
                      signInURL: json["AuthURL"] as? String ?? "",
                      address: addresses.first(where: { $0.contains(".") }) ?? addresses.first ?? "")
    }

    /// One HTTP request to a device on the private network, over a connection
    /// made by Tailscale itself. No local proxy is involved, so it keeps
    /// working after iOS has had the app asleep.
    public func http(host: String, port: Int, method: String, path: String,
                     headers: [String: String], body: Data?, timeout: TimeInterval) throws -> Reply {
        var connection: Int32 = 0
        guard tailscale_dial(handle, "tcp", "\(host):\(port)", &connection) == 0, connection > 0 else {
            throw Failure(message: lastError())
        }
        defer { Darwin.close(connection) }

        var limit = timeval(tv_sec: Int(max(1, timeout)), tv_usec: 0)
        _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        // HTTP/1.0 with "Connection: close": the reply is everything up to the
        // end of the connection, with no chunking to undo.
        var head = "\(method) \(path) HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n\r\n"
        var message = Data(head.utf8)
        if let body { message.append(body) }
        try write(message, to: connection)

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(connection, &chunk, chunk.count)
            if count > 0 {
                received.append(chunk, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw Failure(message: "The home server stopped answering.")
            }
        }
        return try Self.parse(received)
    }

    private func write(_ data: Data, to connection: Int32) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(connection, raw.baseAddress! + sent, raw.count - sent)
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw Failure(message: "Couldn't send to the home server.")
                }
            }
        }
    }

    static func parse(_ received: Data) throws -> Reply {
        let separator = Data("\r\n\r\n".utf8)
        guard let split = received.range(of: separator),
              let head = String(data: received[received.startIndex..<split.lowerBound], encoding: .isoLatin1) else {
            throw Failure(message: "The home server sent an answer Myna couldn't read.")
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw Failure(message: "The home server sent an answer Myna couldn't read.")
        }
        var body = Data(received[split.upperBound..<received.endIndex])
        let chunked = lines.dropFirst().contains { line in
            let lower = line.lowercased()
            return lower.hasPrefix("transfer-encoding:") && lower.contains("chunked")
        }
        if chunked { body = unchunk(body) }
        return Reply(status: status, body: body)
    }

    /// Undo chunked transfer encoding, in case a server uses it anyway.
    static func unchunk(_ data: Data) -> Data {
        var out = Data()
        var index = data.startIndex
        let newline = Data("\r\n".utf8)
        while index < data.endIndex, let lineEnd = data.range(of: newline, in: index..<data.endIndex) {
            let sizeText = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii) ?? ""
            let digits = sizeText.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(digits.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            guard let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) else { break }
            out.append(data[start..<end])
            index = min(data.endIndex, data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex)
        }
        return out
    }
}
