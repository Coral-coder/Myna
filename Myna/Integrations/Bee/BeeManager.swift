import AVFoundation
import Combine
import Foundation

/// Myna's Bee bracelet integration: owns the Bluetooth client, runs the
/// own-key handshake, and turns the bracelet's encrypted audio into PCM for the
/// existing speech pipeline.
///
/// "My device, my key": on an unsealed bracelet Myna generates its own 16-byte
/// AES key (Keychain, this device only) and installs it with the device's own
/// SetEncryptionKey command, then reads audio encrypted with that key. It never
/// touches the vendor's existing key or stream — a bracelet already sealed with
/// a key Myna doesn't hold is left alone, with instructions to factory-reset it.
@MainActor
final class BeeManager: ObservableObject {
    enum Pairing: Equatable {
        case off
        case bluetoothOff
        case unauthorized
        case scanning
        case connecting
        case provisioning
        case needsFactoryReset
        case streaming
        case audioUnavailable(String)
        case error(String)
    }

    @Published private(set) var pairing: Pairing = .off
    @Published private(set) var deviceID = ""
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var firmware: String?
    @Published private(set) var deviceState: BeeDeviceState?
    @Published private(set) var codec: BeeCodec?
    @Published private(set) var packetsDecoded = 0
    /// True while audio frames are actively arriving from the bracelet.
    @Published private(set) var audioActive = false
    @Published private(set) var lastAudioAt: Date?
    /// Raw audio notifications received from the bracelet, before any decode.
    /// Distinguishes "no audio arriving" from "arriving but not decoding".
    @Published private(set) var rawAudioCount = 0
    private var audioDropReasonLogged = false
    private var firstPacketLogged = false
    @Published private(set) var brightness: Int?
    @Published private(set) var bitrate: Int?
    @Published private(set) var txPower: Int?
    /// A short rolling log of what the bracelet sent and what Myna did, so a
    /// stalled handshake can be diagnosed from the device itself.
    @Published private(set) var diagnostics: [String] = []

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// The Bee-signed key token Myna holds for this bracelet, as hex — the thing
    /// that lets Myna (or anything) decrypt the audio with no Bee server. Full
    /// token if we have it, otherwise the bare 16-byte AES key.
    var exportableKeyHex: String? {
        let id = deviceID.isEmpty ? "default" : deviceID
        if let token = BeeKeyVault.existingToken(deviceID: id) { return BeeProtocol.hex([UInt8](token)) }
        if let key = BeeKeyVault.existingKey(deviceID: id) { return BeeProtocol.hex([UInt8](key)) }
        return nil
    }

    var exportableKeyLabel: String {
        let id = deviceID.isEmpty ? "default" : deviceID
        if let t = BeeKeyVault.existingToken(deviceID: id) { return "\(t.count)-byte Bee token (AES key = bytes 12–27)" }
        if BeeKeyVault.existingKey(deviceID: id) != nil { return "16-byte AES key" }
        return "none stored"
    }
    private static let enabledKey = "myna.bee.enabled"

    /// Bumped each handshake so a stale timeout from an earlier attempt is ignored.
    private var handshakeToken = 0

    private let central = BeeCentral()
    private weak var listener: SpeechListener?
    private weak var pilot: ConversationPilot?

    private var key: Data?
    private var nonce: Data?
    /// Fetches the bracelet's sealed key token from Bee (set by AppServices).
    /// Returns the full token; the 16-byte CTR key is extracted from it.
    var fetchSecureKeyToken: ((String) async throws -> Data)?
    /// The session token from your linked Bee account (the cloud-import
    /// connection), set by AppServices. Used as the session token for the
    /// automatic key fetch so you never have to paste one by hand.
    var linkedSessionToken: (() -> String?)?
    private var decryptor: BeeAudioDecryptor?
    private var decoder: BeeAudioDecoder?
    private var feedingSpeech = false

    init(listener: SpeechListener, pilot: ConversationPilot) {
        self.listener = listener
        self.pilot = pilot
        central.delegate = self
        central.onDiagnostic = { [weak self] line in self?.log(line) }
        if isEnabled { start() }
    }

    // MARK: - On/off

    /// Turn the integration on: creates the Bluetooth manager (prompting for
    /// permission the first time) and starts looking for the bracelet.
    func enable() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        start()
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        central.disconnect()
        central.stopScan()
        endSpeechFeed()
        reset()
        pairing = .off
    }

    /// After a vendor factory reset (rapid-press the button 5× to blue+green),
    /// forget the old key so the next connection provisions a fresh one.
    func forgetKeyAndReprovision() {
        if !deviceID.isEmpty { BeeKeyVault.forget(deviceID: deviceID) }
        key = nil
        central.disconnect()
        pairing = .scanning
        central.startScan()
    }

    /// Called when provisioning fails unrecoverably: Myna removes the bracelet and
    /// falls back to syncing from Bee's cloud. Wired by AppServices.
    var onSyncFallback: (() -> Void)?

    /// User-triggered: remove the bracelet and fall back to Bee cloud sync, even
    /// when nothing has failed (a manual "stop fighting the bracelet" button).
    func removeAndSync() {
        removeBraceletAndSync(reason: "removed by you")
    }

    /// On an unrecoverable key failure: remove the bracelet (forget its stored key
    /// and drop the BLE link so Myna stops looping a provisioning it can't finish),
    /// then fall back to syncing conversations from Bee's cloud.
    private func removeBraceletAndSync(reason: String) {
        if !deviceID.isEmpty { BeeKeyVault.forget(deviceID: deviceID) }
        reset()
        endSpeechFeed()
        central.forget()
        pairing = .error("Couldn't get the bracelet's key (\(reason)). Removed the bracelet — syncing from Bee instead.")
        log("Removed the bracelet after the key fetch failed. Syncing from Bee cloud…")
        onSyncFallback?()
    }

    private func start() {
        pairing = .scanning
        central.activate()
        central.startScan()
    }

    // MARK: - Direct control
    //
    // Driving the bracelet's own settings. These need a connected device; each
    // write is followed by the matching read so the published value reflects
    // what the bracelet actually accepted.

    /// Command id for the brightness setter. The 0xC016 opcode is documented;
    /// confirm the payload on the device.
    private static let setBrightnessCommand: UInt16 = 0xC016

    /// Screen/LED brightness, 0–255.
    func setBrightness(_ value: Int) {
        guard isReadyForControl else { return }
        let byte = UInt8(max(0, min(255, value)))
        central.writeControl(BeeProtocol.frame(Self.setBrightnessCommand, payload: [0x01, byte]))
        central.writeControl(BeeCommand.getBrightness.frame(payload: [0x01]))
    }

    /// Audio bitrate in bits per second (sent as int32 little-endian, matching
    /// the GetBitrate reply).
    func setBitrate(_ value: Int) {
        guard isReadyForControl, value > 0 else { return }
        let v = UInt32(value)
        let payload: [UInt8] = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        central.writeControl(BeeCommand.setBitrate.frame(payload: payload))
        central.writeControl(BeeCommand.getBitrate.frame())
    }

    /// Bluetooth transmit power (device-defined units).
    func setTxPower(_ value: Int) {
        guard isReadyForControl else { return }
        central.writeControl(BeeCommand.setTxPower.frame(payload: [UInt8(max(0, min(255, value)))]))
        central.writeControl(BeeCommand.getTxLevel.frame())
    }

    /// Unmute (start recording) or mute the bracelet — SetDeviceState 0xC006,
    /// 1 = recording, 0 = mute, as Bee's app sends it.
    private var lastRecordingSet: Date = .distantPast
    func setRecording(_ on: Bool) {
        guard isReadyForControl, Date.now.timeIntervalSince(lastRecordingSet) > 1.5 else { return }
        lastRecordingSet = .now
        central.writeControl(BeeCommand.setDeviceState.frame(payload: [on ? 0x01 : 0x00]))
    }

    /// Re-read everything the bracelet reports.
    func refreshStatus() {
        guard isReadyForControl else { return }
        central.writeControl(BeeCommand.getBatteryAndChargeState.frame())
        central.writeControl(BeeCommand.getBrightness.frame(payload: [0x01]))
        central.writeControl(BeeCommand.getBitrate.frame())
        central.writeControl(BeeCommand.getDeviceState.frame())
        central.writeControl(BeeCommand.getTxLevel.frame())
        central.writeControl(BeeCommand.getFirmwareVersion.frame())
    }

    /// A connected, provisioned bracelet that can take control commands.
    var isReadyForControl: Bool {
        switch pairing {
        case .streaming, .audioUnavailable: return true
        default: return false
        }
    }

    private func reset() {
        key = nil
        nonce = nil
        decryptor = nil
        decoder = nil
        deviceState = nil
        codec = nil
        firstPacketLogged = false
        decryptProbed = false
    }

    // MARK: - Handshake

    /// Retry after an error — re-run the handshake if still connected, else rescan.
    func retry() {
        diagnostics.removeAll()
        if central.isReady {
            beginHandshake()
        } else {
            start()
        }
    }

    private func beginHandshake() {
        pairing = .provisioning
        handshakeToken += 1
        diagnostics.removeAll()
        log("Connected. Requesting secure IDs (0xC01B)…")
        // Same opening burst as Bee's app (onControlStarted).
        central.writeControl(BeeCommand.getDeviceID.frame())
        central.writeControl(BeeCommand.getSecureIds.frame())
        central.writeControl(BeeCommand.getDeviceState.frame())
        central.writeControl(BeeCommand.getFirmwareVersion.frame())
        central.writeControl(BeeCommand.getBatteryAndChargeState.frame())
        scheduleHandshakeTimeout(handshakeToken)
        scheduleSecureIdsRetry(handshakeToken, attempt: 1)
    }

    /// Belt and braces: if the secure IDs don't come back, ask again every 3s.
    private func scheduleSecureIdsRetry(_ token: Int, attempt: Int) {
        guard attempt <= 3 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.handshakeToken == token, case .provisioning = self.pairing,
                  self.secureIdsToken != token, self.central.isReady else { return }
            self.log("No secure IDs yet — asking again (\(attempt + 1))…")
            self.central.writeControl(BeeCommand.getSecureIds.frame())
            self.scheduleSecureIdsRetry(token, attempt: attempt + 1)
        }
    }

    /// If the handshake is still provisioning after a while, stop waiting and
    /// point the user at the device log rather than hanging on "Setting up your
    /// key…". A completed or factory-reset flow leaves `.provisioning`, so this
    /// no-ops then.
    private func scheduleHandshakeTimeout(_ token: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.handshakeToken == token, case .provisioning = self.pairing else { return }
            self.log("No reply that finished key setup within 12s.")
            self.pairing = .error("The bracelet didn't finish key setup. Open the device log below and send it to me — your bracelet may use a different provisioning step than this build expects.")
        }
    }

    private func log(_ line: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        diagnostics.append("\(stamp)  \(line)")
        if diagnostics.count > 40 { diagnostics.removeFirst(diagnostics.count - 40) }
    }

    /// Copyable device log for sharing.
    var diagnosticsText: String { diagnostics.joined(separator: "\n") }

    /// The handshake that last received secure IDs (stops the retries).
    private var secureIdsToken = -1

    private func handleSecureIds(deviceID: String, isSealed: Bool) {
        secureIdsToken = handshakeToken
        self.deviceID = deviceID
        let heldKey = BeeKeyVault.existingKey(deviceID: deviceID)
        log("Secure IDs: device \(deviceID.prefix(8)), sealed=\(isSealed), keyHeld=\(heldKey != nil)")

        // A captured Bee-signed token (pasted in Backstage) gives the AES key
        // directly — bytes 12..<28 — with no Bee server at all.
        let capturedToken = BeeKeyVault.existingToken(deviceID: deviceID)
        // Keep the token around for the audio decryption probe, whichever path
        // sets up the key (fresh install or reusing the sealed/stored key).
        if let capturedToken { installedToken = capturedToken }

        if isSealed {
            if let heldKey {
                // Already sealed with a key we hold — reuse it.
                key = heldKey
                installDecryptor()
                log("Reusing stored key. Fetching the session nonce…")
                requestSessionNonce()
            } else if let capturedToken, let ctr = BeeCloudAPI.ctrKey(fromToken: capturedToken) {
                // Sealed with the key this token carries (Bee installed it, we
                // captured it): decrypt with the token's key, no re-install.
                key = ctr
                BeeKeyVault.store(ctr, deviceID: deviceID)
                installDecryptor()
                log("Using captured key. Fetching the session nonce…")
                requestSessionNonce()
            } else {
                log("Sealed with a key Myna doesn't hold → capture the key or factory reset.")
                pairing = .needsFactoryReset
            }
            return
        }

        // Unsealed: the firmware's 0xC018 only accepts Bee's full ~108-byte
        // ECDSA-signed token. A bare 16-byte key (count < 44) can NOT be
        // installed here — it comes back invalidParam every time — it's only
        // usable to decrypt a bracelet already sealed with it. So install only a
        // real token; otherwise fetch the genuine signed token from the connected
        // Bee account rather than jamming a key the firmware will reject.
        if let capturedToken, capturedToken.count >= 44 {
            installToken(capturedToken, deviceID: deviceID, source: "captured")
        } else if attemptAutoAccountFetch() {
            // Saved Bee login on file — re-mint the key automatically.
        } else {
            // No installable token and no saved secret. Point the user at the
            // account login. If Bee is linked, they only need the passphrase.
            let linked = (linkedSessionToken?()?.isEmpty == false)
            if linked {
                log("Unsealed — no key yet. Your Bee account is linked, so in Backstage → Bee → ‘Advanced: fetch key with Bee login’, just enter your recovery passphrase and tap Fetch. Myna remembers it and re-fetches automatically after that.")
                pairing = .error("This bracelet needs Bee's key. In Backstage → Bee → ‘Advanced: fetch key with Bee login’, enter your recovery passphrase and tap Fetch (your linked Bee account supplies the token).")
            } else {
                log("Unsealed — no key yet. In Backstage → Bee, link your Bee account (for the token) or open ‘Advanced: fetch key with Bee login’ and paste your x-bee-token, then enter your recovery passphrase and tap Fetch. Myna remembers it after the first time.")
                pairing = .error("This bracelet needs Bee's key. In Backstage → Bee, link your Bee account, then open ‘Advanced: fetch key with Bee login’, enter your recovery passphrase and tap Fetch. Myna remembers it for next time.")
            }
        }
    }

    /// The session token to authenticate Bee with, preferring a token you pasted
    /// but falling back to the one from your linked Bee account — so a linked
    /// account means no paste at all.
    func effectiveSessionToken() -> String? {
        let pasted = BeeAccountVault.load().sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty { return pasted }
        if let linked = linkedSessionToken?()?.trimmingCharacters(in: .whitespacesAndNewlines), !linked.isEmpty {
            return linked
        }
        return nil
    }

    /// If we have a secret (saved passphrase or proof/secret) and a session token
    /// from either source, re-mint the bracelet key automatically — once per
    /// connection. Returns true when a fetch was kicked off.
    @discardableResult
    private func attemptAutoAccountFetch() -> Bool {
        guard !autoAccountFetchTried, !deviceID.isEmpty else { return false }
        let creds = BeeAccountVault.load()
        guard creds.hasSecret, let sessionToken = effectiveSessionToken() else { return false }
        autoAccountFetchTried = true
        let source = BeeAccountVault.load().sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "linked Bee account" : "saved login"
        log("Unsealed — fetching the key with your \(source)…")
        pairing = .provisioning
        if !creds.passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fetchKeyFromBeeAccount(sessionToken: sessionToken, passphrase: creds.passphrase)
        } else {
            fetchKeyFromBeeAccount(sessionToken: sessionToken, proof: creds.proof, secret: creds.secret)
        }
        return true
    }

    /// Whether Myna can fetch the key with no paste: a saved secret plus a
    /// session token from either the paste or the linked Bee account.
    var canAutoFetchKey: Bool { BeeAccountVault.load().hasSecret && effectiveSessionToken() != nil }

    /// Whether a secret (passphrase or proof/secret) is saved.
    var hasSavedBeeLogin: Bool { BeeAccountVault.load().hasSecret }

    /// The saved Bee login, for prefilling the Backstage fields.
    var savedBeeLogin: BeeAccountVault.Credentials { BeeAccountVault.load() }

    /// Persist the login, but don't store a session token that just mirrors the
    /// linked Bee account's (that token self-refreshes; a saved copy would shadow
    /// it and go stale). The durable secret is always kept.
    private func rememberLogin(sessionToken: String, passphrase: String? = nil, proof: String? = nil, secret: String? = nil) {
        let linked = linkedSessionToken?()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenToStore: String? = (trimmedToken == linked) ? nil : trimmedToken
        BeeAccountVault.remember(sessionToken: tokenToStore, passphrase: passphrase, proof: proof, secret: secret)
    }

    /// Forget the saved Bee login (stops automatic key fetches).
    func forgetBeeAccount() {
        BeeAccountVault.clear()
        log("Forgot the saved Bee login.")
    }

    /// Install a full Bee-signed key token on the bracelet and keep its AES key.
    private func installToken(_ token: Data, deviceID: String, source: String) {
        guard let ctr = BeeCloudAPI.ctrKey(fromToken: token) else {
            log("\(source.capitalized) token was \(token.count) bytes — can't read a key from it.")
            pairing = .error("That key token is the wrong size (\(token.count) bytes). It should be the 108 bytes after 18 C0.")
            return
        }
        key = ctr
        installedToken = token
        installDecryptor()
        log("Installing \(source) key on the bracelet (0xC018, \(token.count) bytes)…")
        central.writeControl(BeeCommand.setEncryptionKey.frame(payload: [UInt8](token)))
    }

    /// The full key token last installed, so the audio probe can test key offsets.
    private var installedToken: Data?
    private var decryptProbed = false

    /// Save a token captured from the bracelet's BLE pairing (hex, optionally
    /// with the leading 18 C0 command bytes) and retry the handshake with it.
    func setCapturedKeyToken(_ raw: String) {
        let hex = raw.lowercased().filter { $0.isHexDigit }
        guard hex.count % 2 == 0, hex.count >= 2 else {
            pairing = .error("That doesn't look like hex. Paste the bytes from the SetEncryptionKey write.")
            return
        }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return }
            bytes.append(b); i = j
        }
        // Drop a leading 18 C0 (the 0xC018 command id) if the whole frame was pasted.
        if bytes.count >= 2, bytes[0] == 0x18, bytes[1] == 0xC0 { bytes.removeFirst(2) }
        guard BeeCloudAPI.ctrKey(fromToken: Data(bytes)) != nil else {
            pairing = .error("That token is \(bytes.count) bytes — expected 16, or 28+ (108 for Bee).")
            return
        }
        let id = deviceID.isEmpty ? "default" : deviceID
        BeeKeyVault.forget(deviceID: id)   // clear any stale derived key/token first
        BeeKeyVault.storeToken(Data(bytes), deviceID: id)
        log("Saved a captured key token (\(bytes.count) bytes). Reconnecting…")
        retry()
    }

    /// The full in-app path: reproduce the Bee app's account auth from your
    /// session token + recovery passphrase, derive proof/secret, and fetch the
    /// sealed key — no header capture needed beyond the one durable session token.
    func fetchKeyFromBeeAccount(sessionToken: String, passphrase: String) {
        let id = deviceID.isEmpty ? "default" : deviceID
        let deviceHex = deviceID
        guard !deviceHex.isEmpty else {
            pairing = .error("Connect to the bracelet first so Myna knows its device id, then fetch the key.")
            return
        }
        // Remember the login so the next connect can re-mint the key with no
        // paste. The passphrase is durable; the session token may later expire.
        rememberLogin(sessionToken: sessionToken, passphrase: passphrase)
        log("Deriving your Bee account keys from the recovery passphrase…")
        let logger: @Sendable (String) -> Void = { [weak self] msg in Task { @MainActor in self?.log(msg) } }
        Task { [weak self] in
            do {
                let result = try await BeeAccountAuth.fetchBraceletKey(
                    sessionToken: sessionToken, passphrase: passphrase, deviceIDHex: deviceHex, log: logger
                )
                guard let self else { return }
                guard BeeCloudAPI.ctrKey(fromToken: result.keyToken) != nil else {
                    self.pairing = .error("Bee returned a \(result.keyToken.count)-byte token — expected 108.")
                    return
                }
                BeeKeyVault.forget(deviceID: id)
                BeeKeyVault.storeToken(result.keyToken, deviceID: id)
                self.log("Got your bracelet key from Bee (\(result.keyToken.count) bytes, via \(result.apiHost)). Reconnecting…")
                self.retry()
            } catch {
                guard let self else { return }
                BeeTLSDelegate.drain().forEach { self.log($0) }
                self.log("Bee account key fetch failed: \(error.localizedDescription)")
                self.pairing = .error("Couldn't fetch the key: \(error.localizedDescription)")
            }
        }
    }

    /// In-app fetch using captured proof/secret (no recovery passphrase needed).
    /// Mints a fresh ephemeral from the durable session token, so it never
    /// expires like a pasted ephemeral would.
    func fetchKeyFromBeeAccount(sessionToken: String, proof: String, secret: String) {
        let id = deviceID.isEmpty ? "default" : deviceID
        let deviceHex = deviceID
        guard !deviceHex.isEmpty else {
            pairing = .error("Connect to the bracelet first so Myna knows its device id, then fetch the key.")
            return
        }
        // Remember the login so the next connect can re-mint the key with no
        // paste. proof/secret are durable; the session token may later expire.
        rememberLogin(sessionToken: sessionToken, proof: proof, secret: secret)
        log("Minting a fresh token and fetching your bracelet key from Bee…")
        let logger: @Sendable (String) -> Void = { [weak self] msg in Task { @MainActor in self?.log(msg) } }
        Task { [weak self] in
            do {
                let result = try await BeeAccountAuth.fetchBraceletKey(
                    sessionToken: sessionToken, proof: proof, secret: secret, deviceIDHex: deviceHex, log: logger
                )
                guard let self else { return }
                guard BeeCloudAPI.ctrKey(fromToken: result.keyToken) != nil else {
                    self.pairing = .error("Bee returned a \(result.keyToken.count)-byte token — expected 108.")
                    return
                }
                BeeKeyVault.forget(deviceID: id)
                BeeKeyVault.storeToken(result.keyToken, deviceID: id)
                self.log("Got your bracelet key from Bee (\(result.keyToken.count) bytes, via \(result.apiHost)). Reconnecting…")
                self.retry()
            } catch {
                guard let self else { return }
                BeeTLSDelegate.drain().forEach { self.log($0) }
                self.log("Bee account key fetch failed: \(error.localizedDescription)")
                self.pairing = .error("Couldn't fetch the key: \(error.localizedDescription)")
            }
        }
    }

    /// Masquerade as the Bee app: call Bee's `/ble/secure-key` with the account
    /// auth headers (captured once from any Bee request) to fetch this bracelet's
    /// sealed token, store it, and reconnect so the handshake uses its key. No
    /// BLE capture or factory reset needed — just the account's proof/secret/token.
    func fetchKeyFromBeeServer(host: String, proof: String, secret: String, sessionToken: String, amazonToken: String? = nil) {
        let id = deviceID.isEmpty ? "default" : deviceID
        let deviceHex = deviceID.isEmpty ? "" : deviceID
        guard !deviceHex.isEmpty else {
            pairing = .error("Connect to the bracelet first so Myna knows its device id, then fetch the key.")
            return
        }
        log("Fetching the sealed key from Bee's server (masquerading as the app)…")
        Task { [weak self] in
            do {
                let token = try await BeeCloudAPI.fetchBraceletToken(
                    host: host, deviceIDHex: deviceHex,
                    proof: proof, secret: secret,
                    sessionToken: sessionToken, amazonToken: amazonToken
                )
                guard let self else { return }
                guard BeeCloudAPI.ctrKey(fromToken: token) != nil else {
                    self.log("Bee returned a token Myna couldn't use (\(token.count) bytes).")
                    self.pairing = .error("Bee returned a \(token.count)-byte token — expected 108.")
                    return
                }
                BeeKeyVault.forget(deviceID: id)
                BeeKeyVault.storeToken(token, deviceID: id)
                self.log("Got the sealed key from Bee (\(token.count) bytes). Reconnecting…")
                self.retry()
            } catch {
                guard let self else { return }
                self.log("Bee key fetch failed: \(error.localizedDescription)")
                self.pairing = .error("Couldn't fetch the key from Bee: \(error.localizedDescription)")
            }
        }
    }

    private func provisionFromBackend(deviceID: String) {
        guard let fetchSecureKeyToken else {
            log("No Bee account connected — connect Bee in Backstage to get the bracelet key.")
            pairing = .error("Connect your Bee account in Backstage so Myna can fetch the bracelet's key.")
            return
        }
        let token = handshakeToken
        log("Unsealed. Fetching the sealed key from Bee…")
        Task { [weak self] in
            do {
                let blob = try await fetchSecureKeyToken(deviceID)
                guard let self, self.handshakeToken == token else { return }
                guard let ctr = BeeCloudAPI.ctrKey(fromToken: blob) else {
                    self.log("Key token was \(blob.count) bytes — can't read a key from it.")
                    self.pairing = .error("Bee returned a key Myna couldn't use (\(blob.count) bytes).")
                    return
                }
                self.key = ctr
                self.installDecryptor()
                self.log("Got sealed key (\(blob.count) bytes). Installing on the bracelet (0xC018)…")
                self.central.writeControl(BeeCommand.setEncryptionKey.frame(payload: [UInt8](blob)))
            } catch {
                guard let self, self.handshakeToken == token else { return }
                self.log("Bee key fetch failed: \(error.localizedDescription)")
                self.removeBraceletAndSync(reason: error.localizedDescription)
            }
        }
    }

    private func handleKeyResult(_ result: BeeKeyResult) {
        switch result {
        case .installed:
            if let key { BeeKeyVault.store(key, deviceID: deviceID) }
            log("Key installed. Fetching the session nonce…")
            requestSessionNonce()
        case .alreadySet:
            // We just installed a freshly fetched key; the bracelet reports it
            // already had one. Persist and continue — if it was a different key,
            // decryption simply yields nothing and the log shows no audio.
            if let key { BeeKeyVault.store(key, deviceID: deviceID) }
            log("Key already set. Fetching the session nonce…")
            requestSessionNonce()
        case .unknown(let code):
            log("Key reply code \(code) (unrecognized).")
            pairing = .error("The bracelet rejected the key (code \(code)).")
        }
    }

    /// Ask the bracelet for its current session nonce. This is the whole secure
    /// handshake step the Bee app does once the key is set (ConnectionGuard
    /// requestSessionNonce → SessionNonce → configureDecryptor). We do NOT mute
    /// or force a record: the nonce is for the live session and AES-CTR decrypts
    /// the ongoing stream at any sequence. Muting here was what desynced it.
    private func requestSessionNonce() {
        central.writeControl(BeeCommand.getSessionNonce.frame())
    }

    private func handleNonce(_ value: Data) {
        nonce = value
        decoder = codec.map { BeeAudioDecoder(codec: $0) }
        log("Session nonce received (\(value.count) bytes). Starting audio…")
        // Audio can arrive the instant we subscribe, so go to streaming now
        // rather than waiting for the next device-state reply (that race was
        // dropping the first burst of audio as "pairing is provisioning").
        if key != nil, decoder?.unavailableReason == nil, decoder != nil {
            pairing = .streaming
        }
        // Bee subscribes to audio only once the key and nonce are in place.
        central.startAudioNotifications()
        // Nothing else to send: the nonce we just read belongs to the bracelet's
        // live session, and AES-CTR is seekable — every packet carries its own
        // sequence number, so the decryptor lines up on the ongoing stream from
        // whatever sequence it's currently at. This mirrors the Bee app exactly
        // (ConnectionGuard: SetEncryptionKey → SessionNonce → configure, no
        // device-state change). If the bracelet is muted, handleDeviceState asks
        // it to record — that's orthogonal and never re-latches the nonce.
        scheduleAudioWatchdog(handshakeToken)
        central.writeControl(BeeCommand.getDeviceState.frame())
        central.writeControl(BeeCommand.getBatteryAndChargeState.frame())
        central.writeControl(BeeCommand.getFirmwareVersion.frame())
        central.writeControl(BeeCommand.getBrightness.frame(payload: [0x01]))
        central.writeControl(BeeCommand.getBitrate.frame())
        central.writeControl(BeeCommand.getTxLevel.frame())
    }

    /// If no audio has arrived a while after subscribing, say why in plain terms
    /// rather than sitting silent.
    private func scheduleAudioWatchdog(_ token: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.handshakeToken == token, self.rawAudioCount == 0 else { return }
            if self.deviceState?.isRecording == true {
                self.log("No audio 12s after subscribing, though the bracelet says it's recording. If the Bee app is still connected (even backgrounded), fully quit it — the bracelet streams to one app at a time.")
            } else {
                self.log("No audio yet — the bracelet isn't in recording mode. It uses voice detection, so speak near it, or it may be asleep.")
            }
        }
    }

    private func handleDeviceState(state: BeeDeviceState, codec: BeeCodec) {
        if deviceState != state || self.codec != codec {
            log("Bracelet \(state.description), codec \(codec.description).")
        }
        deviceState = state
        if self.codec != codec {
            self.codec = codec
            decoder = BeeAudioDecoder(codec: codec)
        }
        if let reason = decoder?.unavailableReason {
            pairing = .audioUnavailable(reason)
        } else if key != nil, nonce != nil {
            pairing = .streaming
            // Start the bracelet recording ourselves so Myna doesn't need the
            // Bee app to "unlock" it. Once per connection; the rate limiter in
            // setRecording keeps the device's own VAD toggles from spamming.
            if state == .mute, !autoRecordTried {
                autoRecordTried = true
                log("Asking the bracelet to start recording…")
                setRecording(true)
            }
        }
    }

    /// Reset when a connection ends so the next one tries auto-record again.
    private var autoRecordTried = false

    /// So we attempt the automatic account key fetch at most once per connection
    /// (a failure must not loop into a fetch storm).
    private var autoAccountFetchTried = false

    private func installDecryptor() {
        guard let key else { return }
        decryptor = try? BeeAudioDecryptor(key: key)
        if decryptor == nil { pairing = .error("Couldn't set up decryption.") }
    }

    // MARK: - Developer lab
    //
    // A reconnaissance surface for the bracelet's firmware: dump the full GATT
    // table, probe whether the key-set command will take an unsigned/null key,
    // and send arbitrary control frames. Everything goes to the device log so it
    // can be copied out. None of this can forge Bee's signed token — it's for
    // learning exactly what the firmware will and won't accept.

    /// Enumerate and log every service + characteristic on the bracelet.
    func labDumpGatt() {
        log("Lab: dumping the full GATT table…")
        central.dumpGatt()
    }

    /// Try to set an all-zero ("null") key, both as a bare 16-byte key and as a
    /// 108-byte zero token. We expect the firmware's 0xC018 to reject both with
    /// invalidParam (it demands Bee's ECDSA-signed token) — this confirms it on
    /// your device and rules the idea out for good, or surprises us.
    func labProbeNullKey() {
        log("Lab: 0xC018 ← 16 zero bytes (bare null key)…")
        central.writeControl(BeeCommand.setEncryptionKey.frame(payload: [UInt8](repeating: 0, count: 16)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.log("Lab: 0xC018 ← 108 zero bytes (null token)…")
            self.central.writeControl(BeeCommand.setEncryptionKey.frame(payload: [UInt8](repeating: 0, count: 108)))
        }
    }

    /// Send a raw control frame (hex). First two bytes are the little-endian
    /// command id, the rest payload. The reply is logged by the normal handler.
    func labSendControl(hex raw: String) {
        let clean = raw.lowercased().filter { $0.isHexDigit }
        guard clean.count >= 4, clean.count % 2 == 0 else {
            log("Lab: enter at least 2 bytes of hex (id low, id high, …).")
            return
        }
        var bytes: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            if let b = UInt8(clean[i..<j], radix: 16) { bytes.append(b) }
            i = j
        }
        log("Lab: control ← \(BeeProtocol.hex(bytes))")
        central.writeControl(Data(bytes))
    }

    // MARK: - Audio

    private func handleAudio(_ data: Data) {
        func dropOnce(_ why: String) {
            guard !audioDropReasonLogged else { return }
            audioDropReasonLogged = true
            log("Audio not decoding — \(why).")
        }
        guard let packet = BeeAudioFraming.parse(data) else { return dropOnce("packet < 4 bytes (\(data.count))") }
        guard let nonce else { return dropOnce("no session nonce yet") }
        guard let decryptor else { return dropOnce("no decryptor (key missing)") }
        guard let decoder else { return dropOnce("no decoder (codec unknown)") }
        guard let plaintext = try? decryptor.decrypt(packet: packet, nonce: nonce), !plaintext.isEmpty else {
            return dropOnce("decrypt failed (wrong key?)")
        }
        // One-time look at the decrypted bytes: genuine AAC starts with an ADTS
        // sync (ff f1 / ff f9). Anything else means the key or framing is wrong,
        // not the decoder — this tells us which without guessing.
        if !firstPacketLogged {
            firstPacketLogged = true
            let head = plaintext.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
            let adts = plaintext.count >= 2 && plaintext[plaintext.startIndex] == 0xFF && (plaintext[plaintext.index(after: plaintext.startIndex)] & 0xF0) == 0xF0
            log("First decrypted packet: \(plaintext.count)B seq \(packet.sequence) [\(head)] \(adts ? "✓ ADTS" : "✗ not ADTS")")
        }
        if !decryptProbed { decryptProbed = true; probeDecryption(ciphertext: packet.ciphertext, nonce: nonce, seq: packet.sequence) }
        let buffers = decoder.decodeStream(plaintext)
        guard !buffers.isEmpty else { return dropOnce("decoder produced no PCM (codec \(codec?.description ?? "?"))") }
        if packetsDecoded == 0 { log("Audio decoding (\(Int(decoder.sampleRate)) Hz)."); audioDropReasonLogged = false }
        packetsDecoded += buffers.count
        audioActive = true
        lastAudioAt = .now
        if !feedingSpeech { beginSpeechFeed() }
        for pcm in buffers { listener?.feedExternalAudio(pcm) }
    }

    /// One-shot diagnostic: try candidate AES-CTR key offsets and counter layouts
    /// against the real first packet and report which (if any) yields an ADTS
    /// sync. Pins down a key/nonce/seq mismatch deterministically, no guessing.
    private func probeDecryption(ciphertext: Data, nonce: Data, seq: UInt32) {
        guard let token = installedToken else { log("probe: no installed token."); return }
        func be(_ v: UInt32) -> Data { Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        func le(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func adtsAt(_ d: Data) -> Int? {
            let b = [UInt8](d); var i = 0
            while i + 1 < b.count { if b[i] == 0xFF, (b[i + 1] & 0xF0) == 0xF0 { return i }; i += 1 }
            return nil
        }
        var keys: [(String, Data)] = []
        if let k = key, k.count == 16 { keys.append(("currentKey", k)) }
        if token.count >= 28 { keys.append(("tok[12:28]", token.subdata(in: 12..<28))) }
        if token.count >= 16 { keys.append(("tok[0:16]", token.subdata(in: 0..<16))) }
        if token.count >= 44 { keys.append(("tok[28:44]", token.subdata(in: 28..<44))) }
        if token.count >= 16 { keys.append(("tok[last16]", Data(token.suffix(16)))) }
        var ctrs: [(String, Data)] = [
            ("nonce||seqBE", nonce + be(seq)),
            ("nonce||seqLE", nonce + le(seq)),
            ("nonce||0", nonce + Data([0, 0, 0, 0])),
            ("seqBE||nonce", be(seq) + nonce),
        ]
        ctrs.removeAll { $0.1.count != 16 }
        let probe = Data(ciphertext.prefix(64))
        var hits = 0
        for (kn, k) in keys {
            guard let dec = try? BeeAudioDecryptor(key: k) else { continue }
            for (cn, c) in ctrs {
                guard let pt = try? dec.decrypt(probe, counter: c), let idx = adtsAt(pt) else { continue }
                hits += 1
                let h = pt.prefix(6).map { String(format: "%02x", $0) }.joined(separator: " ")
                log("probe HIT: key=\(kn) ctr=\(cn) sync@\(idx) [\(h)]")
            }
        }
        log("probe done (token \(token.count)B, nonce \(nonce.count)B, seq \(seq)): \(hits) hit(s).")
    }

    private func beginSpeechFeed() {
        feedingSpeech = true
        listener?.beginExternalSource()
        // Make sure recognition is actually running to receive the buffers.
        if let pilot, pilot.phase == .idle { pilot.startListening() }
    }

    private func endSpeechFeed() {
        audioActive = false
        guard feedingSpeech else { return }
        feedingSpeech = false
        listener?.endExternalSource()
    }

    // MARK: - Events

    private func handleEvent(_ event: BeeEvent) {
        switch event {
        case .batteryLevel(let level):
            batteryLevel = level
        case .charging(let charging):
            isCharging = charging
        case .buttonDoublePress:
            // Wrap up the current conversation now, keep listening.
            pilot?.composeNow()
        case .buttonHold(let pressed):
            // Hold to start a fresh listening session; release is a no-op.
            if pressed, let pilot, pilot.phase == .idle { pilot.startListening() }
        case .deviceState(let state, let codec):
            handleDeviceState(state: state, codec: codec)
            // Audio stops flowing when the bracelet leaves the recording state.
            if !state.isRecording { endSpeechFeed() }
        }
    }
}

// MARK: - BeeCentralDelegate

extension BeeManager: BeeCentralDelegate {
    func beeCentralDidUpdateState(_ central: BeeCentral) {
        switch central.phase {
        case .poweredOff: pairing = .bluetoothOff
        case .unauthorized: pairing = .unauthorized
        case .idle where isEnabled && pairing != .streaming && pairing != .provisioning:
            pairing = .scanning
            central.startScan()
        default:
            break
        }
    }

    func beeCentralDidConnect(_ central: BeeCentral) {}

    func beeCentralDidReady(_ central: BeeCentral) {
        beginHandshake()
    }

    func beeCentral(_ central: BeeCentral, didDisconnectWithError error: Error?) {
        endSpeechFeed()
        autoRecordTried = false
        autoAccountFetchTried = false
        audioDropReasonLogged = false
        reset()
        if isEnabled { pairing = .scanning }
    }

    func beeCentral(_ central: BeeCentral, didReceiveControl data: Data) {
        let message = BeeProtocol.parseControlMessage(data)
        switch message {
        case .event(let event):
            handleEvent(event)
        case .response(let response):
            handleResponse(response)
        case .failure(let failure):
            log("Bracelet replied \(failure) ← \(BeeProtocol.hex([UInt8](data)))")
            if case .provisioning = pairing, failure != .unknownCommand {
                pairing = .error("The bracelet refused a setup step (\(failure)). Send me the device log.")
            }
        case .unhandled(let id, let payload):
            // A well-formed message Myna doesn't model. During provisioning this
            // is probably the real key-set reply in a shape this build didn't
            // expect — log the raw bytes so we can learn the device's scheme.
            log("Unhandled 0x\(String(format: "%04X", id)) ← \(BeeProtocol.hex([UInt8](payload)))")
        case .malformed:
            log("Malformed ← \(BeeProtocol.hex([UInt8](data)))")
        }
    }

    func beeCentral(_ central: BeeCentral, didReceiveAudio data: Data) {
        rawAudioCount += 1
        if rawAudioCount == 1 { log("First audio notification (\(data.count) bytes).") }
        handleAudio(data)
    }

    private func handleResponse(_ response: BeeResponse) {
        switch response {
        case .secureIds(let id, let sealed):
            handleSecureIds(deviceID: id, isSealed: sealed)
        case .encryptionKey(let result):
            handleKeyResult(result)
        case .sessionNonce(let value):
            handleNonce(value)
        case .deviceState(let state, let codec):
            handleDeviceState(state: state, codec: codec)
        case .batteryAndCharge(let level, let charging):
            batteryLevel = level
            isCharging = charging
        case .firmwareVersion(let major, let minor, let patch):
            firmware = "\(major).\(minor).\(patch)"
        case .brightness(let value):
            brightness = value
        case .bitrate(let value):
            bitrate = value
        case .txLevel(let value), .txPower(let value):
            txPower = value
        case .deviceID:
            break
        case .setDeviceState(let state):
            // The bracelet also sends these unsolicited as its VAD flips
            // mute/record — just track it, don't treat it as a command reply.
            if deviceState != state {
                deviceState = state
                if !state.isRecording { endSpeechFeed() }
            }
        case .serial(let serial):
            if !serial.isEmpty { log("Serial \(serial)") }
        }
    }
}
