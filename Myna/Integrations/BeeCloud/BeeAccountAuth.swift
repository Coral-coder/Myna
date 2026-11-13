import Foundation
import CryptoKit
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reproduces the Bee app's own account auth so Myna can fetch a bracelet's
/// sealed key the way the app does — no per-use capture.
///
/// The Bee app authenticates `/ble/secure-key` with three things:
///   • `x-bee-ephemeral-token` — short-lived, minted from a durable session token
///   • `x-bee-proof` / `x-bee-secret` — a proof-of-possession pair derived from
///     the account's root key
///
/// Myna can't read the Bee app's keychain (iOS sandbox), and it can't mint a Bee
/// session over OAuth. So it needs, ONCE: the durable **session token** (captured
/// from one Bee request) and the account **recovery passphrase**. From those it
/// mints ephemeral tokens itself and derives proof/secret itself — reproducing
/// the app's chain, verified against Bee's own `/encryption/verify` before use.
///
/// All constants (salts, iteration counts, HKDF info, the BIP32-style key tree,
/// byte layouts) are recovered from the Bee app's `BackgroundSecureAuth` and
/// `MnemonicCryptoEngine`.
enum BeeAccountAuth {
    static let authHost = "auth.beeai-services.com"
    /// Candidate API hosts (the app discovers this at runtime; these cover the
    /// known production + enclave domains).
    static let apiHostCandidates = ["api.beeai-services.com", "ce-beeai-services.com"]
    /// Candidate recovery-blob endpoints (the exact path is built at runtime in
    /// the app; these are the observed `/encryption/*` surface).
    static let recoveryPaths = ["/encryption/recovery", "/encryption/recovery-blob", "/users/me/recovery", "/encryption/recovery-key"]

    enum AuthError: LocalizedError {
        case http(String, Int)
        case malformed(String)
        case noEphemeral
        case noRecoveryBlob
        case decryptFailed
        case verifyFailed
        case badTokenSize(Int)

        var errorDescription: String? {
            switch self {
            case .http(let what, let code): return "Bee \(what) returned HTTP \(code)."
            case .malformed(let what): return "Bee's \(what) response was unreadable."
            case .noEphemeral: return "Couldn't mint a session token — the captured token may be expired. Grab a fresh one."
            case .noRecoveryBlob: return "Couldn't find your recovery blob on Bee's server. Make sure you've set up a recovery passphrase in the Bee app."
            case .decryptFailed: return "Your recovery passphrase didn't decrypt the account key. Check the words and spacing."
            case .verifyFailed: return "Derived the account keys, but Bee rejected them. The passphrase or recovery format may differ — send the device log."
            case .badTokenSize(let n): return "Bee returned a \(n)-byte key token — expected 108."
            }
        }
    }

    struct Result { let keyToken: Data; let apiHost: String }

    // MARK: - Orchestration

    /// Full chain: session token + passphrase + device id → the 108-byte sealed
    /// key token (its bytes 12..<28 are the AES key). Self-verifies before the
    /// final fetch so a wrong constant fails loudly instead of yielding garbage.
    static func fetchBraceletKey(sessionToken: String, passphrase: String, deviceIDHex: String, session: URLSession = .shared) async throws -> Result {
        let ephemeral = try await mintEphemeral(sessionToken: sessionToken, session: session)

        // Try each API host; the recovery blob + verify + key all live on it.
        var lastError: Error = AuthError.noRecoveryBlob
        for apiHost in apiHostCandidates {
            do {
                let blob = try await fetchRecoveryBlob(apiHost: apiHost, ephemeral: ephemeral, session: session)
                let (proof, secret) = try deriveProofSecret(passphrase: passphrase, recoveryBlob: blob)
                guard try await verify(apiHost: apiHost, ephemeral: ephemeral, proof: proof, secret: secret, session: session) else {
                    throw AuthError.verifyFailed
                }
                let token = try await fetchKeyToken(apiHost: apiHost, ephemeral: ephemeral, proof: proof, secret: secret, deviceIDHex: deviceIDHex, session: session)
                return Result(keyToken: token, apiHost: apiHost)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    // MARK: - Steps

    /// POST {auth}/users/sessions/token  (header x-bee-token) → ephemeral token.
    static func mintEphemeral(sessionToken: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: URL(string: "https://\(authHost)/users/sessions/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionToken.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-bee-token")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AuthError.http("session exchange", code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else { throw AuthError.noEphemeral }
        return token
    }

    /// GET {api}/encryption/<recovery> (ephemeral-authed) → the encrypted
    /// recovery blob (base64 or raw bytes). Tries known paths.
    static func fetchRecoveryBlob(apiHost: String, ephemeral: String, session: URLSession) async throws -> Data {
        for path in recoveryPaths {
            var request = URLRequest(url: URL(string: "https://\(apiHost)\(path)")!)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(ephemeral, forHTTPHeaderField: "x-bee-ephemeral-token")
            guard let (data, response) = try? await session.data(for: request),
                  let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { continue }
            if let blob = extractBlob(from: data) { return blob }
        }
        throw AuthError.noRecoveryBlob
    }

    /// POST {api}/encryption/verify with proof/secret — confirms the derived
    /// pair before we rely on it.
    static func verify(apiHost: String, ephemeral: String, proof: String, secret: String, session: URLSession) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://\(apiHost)/encryption/verify")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ephemeral, forHTTPHeaderField: "x-bee-ephemeral-token")
        request.setValue(proof, forHTTPHeaderField: "x-bee-proof")
        request.setValue(secret, forHTTPHeaderField: "x-bee-secret")
        request.httpBody = Data("{}".utf8)
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// POST {api}/ble/secure-key — the same call BeeCloudAPI makes, now with
    /// self-derived auth.
    static func fetchKeyToken(apiHost: String, ephemeral: String, proof: String, secret: String, deviceIDHex: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://\(apiHost)/ble/secure-key")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(ephemeral, forHTTPHeaderField: "x-bee-ephemeral-token")
        request.setValue(proof, forHTTPHeaderField: "x-bee-proof")
        request.setValue(secret, forHTTPHeaderField: "x-bee-secret")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceId": deviceIDHex])
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AuthError.http("secure-key", code) }
        guard let token = BeeCloudAPI.braceletToken(fromResponse: data) else { throw AuthError.malformed("secure-key") }
        guard token.count == 108 || token.count == 16 || token.count >= 28 else { throw AuthError.badTokenSize(token.count) }
        return token
    }

    // MARK: - Crypto: passphrase → proof/secret

    /// recovery passphrase + encrypted recovery blob → (proof, secret).
    static func deriveProofSecret(passphrase: String, recoveryBlob: Data) throws -> (proof: String, secret: String) {
        let aesKey = try mnemonicAESKey(passphrase: passphrase)
        let plaintext = try gcmOpen(recoveryBlob, key: aesKey)

        // The decrypted material is either the raw 64-byte account key, or the
        // 161-byte serialized key blob (possibly base64-wrapped). Handle all.
        if let (proof, secret) = proofSecretFromSerialized(plaintext) { return (proof, secret) }
        if plaintext.count == 64 { return proofSecret(fromAccountKey: plaintext) }
        if let inner = Data(base64Encoded: plaintext), inner.count == 64 { return proofSecret(fromAccountKey: inner) }
        // Last resort: treat whatever we got as the seed.
        guard plaintext.count >= 32 else { throw AuthError.decryptFailed }
        return proofSecret(fromAccountKey: plaintext)
    }

    /// Modern Bee derivation: PBKDF2-HMAC-SHA512 → HKDF-SHA256 → 32-byte AES key.
    private static func mnemonicAESKey(passphrase: String) throws -> SymmetricKey {
        let normalized = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
        let pbkdf = try pbkdf2SHA512(password: normalized, salt: "bee-mnemonic-seed-v2", iterations: 210_000, keyLength: 64)
        let hkdf = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pbkdf),
            salt: Data("bee-hkdf-salt-v2".utf8),
            info: Data("bee-aes-key-v2".utf8),
            outputByteCount: 32
        )
        return hkdf
    }

    /// AES-256-GCM: blob = [12-byte IV][ciphertext][16-byte tag].
    private static func gcmOpen(_ blob: Data, key: SymmetricKey) throws -> Data {
        guard blob.count > 12 + 16 else { throw AuthError.decryptFailed }
        let iv = blob.prefix(12)
        let tag = blob.suffix(16)
        let ciphertext = blob.dropFirst(12).dropLast(16)
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw AuthError.decryptFailed
        }
    }

    /// 64-byte account key → proof/secret via Bee's BIP32-style HMAC-SHA512 tree.
    private static func proofSecret(fromAccountKey accountKey: Data) -> (proof: String, secret: String) {
        let root = deriveRoot(seed: accountKey)
        let account = deriveChild(chainCode: root.chain, index: "account")
        let server = deriveChild(chainCode: root.chain, index: "server")
        return (account.key.base64EncodedString(), server.chain.base64EncodedString())
    }

    /// If the plaintext is the already-serialized 161-byte blob (raw or base64):
    /// proof = bytes[129..161], secret = bytes[33..65].
    private static func proofSecretFromSerialized(_ data: Data) -> (proof: String, secret: String)? {
        let bytes: Data
        if data.count == 161 { bytes = data }
        else if let inner = Data(base64Encoded: data), inner.count == 161 { bytes = inner }
        else { return nil }
        let proof = bytes.subdata(in: 129..<161)
        let secret = bytes.subdata(in: 33..<65)
        return (proof.base64EncodedString(), secret.base64EncodedString())
    }

    private static func deriveRoot(seed: Data) -> (key: Data, chain: Data) {
        let mac = HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: Data("Bee Account Root Master Seed".utf8)))
        let out = Data(mac)
        return (out.prefix(32), out.suffix(32))
    }

    private static func deriveChild(chainCode: Data, index: String) -> (key: Data, chain: Data) {
        var message = Data([0x00])
        message.append(Data(index.utf8))
        let mac = HMAC<SHA512>.authenticationCode(for: message, using: SymmetricKey(data: chainCode))
        let out = Data(mac)
        return (out.prefix(32), out.suffix(32))
    }

    // MARK: - Helpers

    private static func extractBlob(from data: Data) -> Data? {
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            var found: Data?
            func consider(_ s: String) {
                if let b = Data(base64Encoded: s.padding(toLength: ((s.count + 3) / 4) * 4, withPad: "=", startingAt: 0)), b.count > 28 {
                    if found == nil || b.count > found!.count { found = b }
                }
            }
            func walk(_ v: Any) {
                if let s = v as? String { consider(s) }
                else if let d = v as? [String: Any] { d.values.forEach(walk) }
                else if let a = v as? [Any] { a.forEach(walk) }
            }
            walk(obj)
            if let found { return found }
        }
        return data.count > 28 ? data : nil
    }

    private static func pbkdf2SHA512(password: String, salt: String, iterations: Int, keyLength: Int) throws -> Data {
        #if canImport(CommonCrypto)
        var derived = Data(count: keyLength)
        let saltData = Data(salt.utf8)
        let passwordData = Data(password.utf8)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            saltData.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw AuthError.decryptFailed }
        return derived
        #else
        throw AuthError.decryptFailed
        #endif
    }
}
