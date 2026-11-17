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
    // Confirmed live: auth.beeai-services.com serves /ble/secure-key and
    // /encryption/* (both return 401, i.e. exist + need auth). api.beeai-services.com
    // no longer resolves.
    // From a live proxy capture of the Bee app: the main API (encryption, key,
    // recovery) is served by api-3.ce-beeai-services.com; auth.beeai-services.com
    // handles /users/sessions/token (session exchange). Try the API host first.
    static let apiHostCandidates = ["api-3.ce-beeai-services.com", "auth.beeai-services.com"]
    /// Candidate recovery-blob endpoints (the exact path is built at runtime in
    /// the app; these are the observed `/encryption/*` surface).
    static let recoveryPaths = ["/encryption/recovery", "/encryption/recovery-blob", "/users/me/recovery", "/encryption/recovery-key"]

    enum AuthError: LocalizedError {
        case http(String, Int, String)
        case malformed(String)
        case noEphemeral
        case noRecoveryBlob
        case decryptFailed
        case verifyFailed
        case badTokenSize(Int)

        var errorDescription: String? {
            switch self {
            case .http(let what, let code, let body):
                let detail = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
                return detail.isEmpty ? "Bee \(what) returned HTTP \(code)." : "Bee \(what) returned HTTP \(code): \(detail)"
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

    /// Same fetch, but with proof/secret you captured directly (no recovery
    /// passphrase). Still mints a fresh ephemeral from the durable session
    /// token each time, so the stored credentials never expire.
    static func fetchBraceletKey(sessionToken: String, proof: String, secret: String, deviceIDHex: String, session: URLSession = .shared) async throws -> Result {
        let ephemeral = try await mintEphemeral(sessionToken: sessionToken, session: session)
        var lastError: Error = AuthError.http("secure-key", 0, "")
        for apiHost in apiHostCandidates {
            do {
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
        guard (200..<300).contains(code) else { throw AuthError.http("session exchange", code, String(data: data, encoding: .utf8) ?? "") }
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
        // This services host validates snake_case `device_id`; the Bee app's own
        // host took camelCase `deviceId`. Send both so either validator is happy.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["device_id": deviceIDHex, "deviceId": deviceIDHex])
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AuthError.http("secure-key", code, String(data: data, encoding: .utf8) ?? "") }
        guard let token = BeeCloudAPI.braceletToken(fromResponse: data) else { throw AuthError.malformed("secure-key") }
        guard token.count == 108 || token.count == 16 || token.count >= 28 else { throw AuthError.badTokenSize(token.count) }
        return token
    }

    // MARK: - Crypto: passphrase → proof/secret

    /// recovery passphrase + encrypted recovery blob → (proof, secret).
    static func deriveProofSecret(passphrase: String, recoveryBlob: Data) throws -> (proof: String, secret: String) {
        // The Bee app picks modern vs legacy derivation by the mnemonic shape
        // (hyphenated words = legacy). We don't need to guess: try modern first,
        // then legacy, and use whichever actually opens the GCM box.
        let normalized = normalizeMnemonic(passphrase)
        var plaintext: Data?
        for aesKey in [try modernAESKey(normalized), try legacyAESKey(normalized)] {
            if let pt = try? gcmOpen(recoveryBlob, key: aesKey) { plaintext = pt; break }
        }
        guard let plaintext else { throw AuthError.decryptFailed }
        // The decrypted recovery blob is JSON that carries the account's proof and
        // secret directly (confirmed from the Bee app's MnemonicCryptoEngine):
        //   {"x-bee-proof":"…","x-bee-secret":"…","x-bee-ephemeral-token":"…",…}
        guard let obj = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let proof = (obj["x-bee-proof"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = (obj["x-bee-secret"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !proof.isEmpty, !secret.isEmpty else {
            throw AuthError.decryptFailed
        }
        return (proof, secret)
    }

    /// Bee's mnemonic normalization: trim, lowercase, collapse runs of
    /// whitespace to single spaces.
    static func normalizeMnemonic(_ passphrase: String) -> String {
        passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
    }

    /// Modern Bee derivation: PBKDF2-HMAC-SHA512 (salt "bee-mnemonic-seed-v2",
    /// 210k) → HKDF-SHA256 (salt "bee-hkdf-salt-v2", info "bee-aes-key-v2") →
    /// 32-byte AES key. `normalized` is already normalizeMnemonic'd.
    private static func modernAESKey(_ normalized: String) throws -> SymmetricKey {
        let pbkdf = try pbkdf2(password: normalized, salt: "bee-mnemonic-seed-v2", iterations: 210_000, keyLength: 64, prf: kCCPRFHmacAlgSHA512)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pbkdf),
            salt: Data("bee-hkdf-salt-v2".utf8),
            info: Data("bee-aes-key-v2".utf8),
            outputByteCount: 32
        )
    }

    /// Legacy Bee derivation: PBKDF2-HMAC-SHA256 (salt "bee-mnemonic-seed-v1",
    /// 120k) → 32-byte AES key directly (no HKDF).
    private static func legacyAESKey(_ normalized: String) throws -> SymmetricKey {
        let pbkdf = try pbkdf2(password: normalized, salt: "bee-mnemonic-seed-v1", iterations: 120_000, keyLength: 32, prf: kCCPRFHmacAlgSHA256)
        return SymmetricKey(data: pbkdf)
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


    // MARK: - Helpers

    /// Peel Bee's recovery wrapper down to the raw AES-GCM input `[IV|ct|tag]`.
    ///
    /// The server (or a pasted blob) wraps the ciphertext in one or more layers:
    /// it may be base64 of a JSON object `{"cipherText":"<base64>","version":N}`,
    /// where `cipherText` itself base64-decodes to `[12-byte IV | ciphertext |
    /// 16-byte tag]`. Earlier builds grabbed the wrong layer (the JSON bytes, or
    /// the outer base64 string) and fed that straight to AES-GCM, which failed
    /// with a bad-tag error that looked exactly like a wrong passphrase. This
    /// peels every layer — base64-of-JSON, the `cipherText` field, nested
    /// base64 — until it reaches the GCM envelope.
    private static func extractBlob(from data: Data) -> Data? {
        unwrapToGCM(data, depth: 0)
    }

    /// Known field names that carry the ciphertext envelope, best first.
    private static let cipherFields = ["cipherText", "ciphertext", "cipher_text", "data", "blob", "recoveryBlob", "recovery_blob", "encrypted", "payload"]

    private static func unwrapToGCM(_ data: Data, depth: Int) -> Data? {
        guard depth < 6 else { return nil }

        // 1) A JSON object/array: look for the ciphertext field, else the largest
        //    base64-decodable string, and keep peeling.
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            if let dict = obj as? [String: Any] {
                for key in cipherFields {
                    if let s = dict[key] as? String, let b = decodeBase64(s) {
                        return unwrapToGCM(b, depth: depth + 1) ?? b
                    }
                }
            }
            if let best = largestBase64(in: obj) {
                return unwrapToGCM(best, depth: depth + 1) ?? best
            }
            return nil
        }

        // 2) Not JSON: the bytes may be an ASCII base64 string of a deeper layer.
        if let s = String(data: data, encoding: .utf8),
           let b = decodeBase64(s.trimmingCharacters(in: .whitespacesAndNewlines)), b != data {
            if let peeled = unwrapToGCM(b, depth: depth + 1) { return peeled }
            if b.count > 28 { return b }
        }

        // 3) Already raw `[IV|ct|tag]`.
        return data.count > 28 ? data : nil
    }

    /// Lenient base64 decode: tolerates URL-safe alphabet and missing padding.
    /// Returns nil for anything that isn't plausibly base64 (so binary GCM bytes
    /// aren't mistaken for an encoded string).
    private static func decodeBase64(_ s: String) -> Data? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/-_=")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        var t = trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t.removeAll { $0 == "=" }
        let pad = (4 - t.count % 4) % 4
        t += String(repeating: "=", count: pad)
        return Data(base64Encoded: t)
    }

    private static func largestBase64(in obj: Any) -> Data? {
        var best: Data?
        func consider(_ s: String) {
            if let b = decodeBase64(s), b.count > 28, best == nil || b.count > best!.count { best = b }
        }
        func walk(_ v: Any) {
            if let s = v as? String { consider(s) }
            else if let d = v as? [String: Any] { d.values.forEach(walk) }
            else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(obj)
        return best
    }

    private static func pbkdf2(password: String, salt: String, iterations: Int, keyLength: Int, prf: Int) throws -> Data {
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
                        CCPseudoRandomAlgorithm(prf),
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
