import Foundation
import CryptoKit
import UIKit

/// Bee's app-pairing flow — the "log in" step for the developer API.
///
/// Myna makes an X25519 keypair, asks Bee's pairing service for a request, and
/// opens bee.computer/connect so you approve Myna in your own Bee account (which
/// is where your Apple / Amazon / phone login lives). Bee seals the API token to
/// Myna's public key; Myna polls, decrypts it locally (`NaClBox`), and hands it
/// back to be stored in the Keychain. The private key never leaves the device.
@MainActor
final class BeeCloudPairing: ObservableObject {
    enum State: Equatable {
        case idle
        case requesting
        case awaitingApproval(URL)
        case success
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Called with the API token once pairing completes.
    var onToken: ((String) -> Void)?

    private var task: Task<Void, Never>?

    // Bee's pairing service, and the developer app id the official CLI pairs as.
    private static let pairingURL = URL(string: "https://auth.beeai-services.com/apps/pairing/request")!
    private static let appID = "ph9fssu1kv1b0hns69fxf7rx"

    var isBusy: Bool {
        switch state {
        case .requesting, .awaitingApproval: return true
        default: return false
        }
    }

    func start() {
        task?.cancel()
        state = .requesting
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    private func run() async {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let deadline = Date.now.addingTimeInterval(10 * 60)
        var opened = false

        do {
            while !Task.isCancelled, Date.now < deadline {
                let reply = try await request(publicKey: publicKey)
                switch reply["status"] as? String {
                case "completed":
                    guard let result = reply["result"] as? [String: Any],
                          let sealed = result["encryptedToken"] as? String else { throw Bee.malformed }
                    let token = try NaClBox.openPairingToken(sealed, privateKey: privateKey)
                    onToken?(token)
                    state = .success
                    return
                case "pending":
                    if !opened, let requestID = reply["requestId"] as? String,
                       let url = URL(string: "https://bee.computer/connect#\(requestID)") {
                        opened = true
                        state = .awaitingApproval(url)
                        _ = await UIApplication.shared.open(url)
                    }
                case "expired":
                    state = .failed("The pairing request expired. Try again.")
                    return
                default:
                    throw Bee.malformed
                }
                try? await Task.sleep(for: .seconds(2))
            }
            if !Task.isCancelled { state = .failed("Pairing timed out. Try again.") }
        } catch is CancellationError {
            // user cancelled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func request(publicKey: String) async throws -> [String: Any] {
        var req = URLRequest(url: Self.pairingURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["app_id": Self.appID, "publicKey": publicKey])
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Bee.http(code) }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["ok"] as? Bool == true else { throw Bee.malformed }
        return body
    }

    private enum Bee: LocalizedError {
        case http(Int), malformed
        var errorDescription: String? {
            switch self {
            case .http(let code): return "Bee's pairing service returned HTTP \(code)."
            case .malformed: return "Bee sent something Myna couldn't read."
            }
        }
    }
}
