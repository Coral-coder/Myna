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
    @Published private(set) var brightness: Int?
    @Published private(set) var bitrate: Int?
    @Published private(set) var txPower: Int?
    /// A short rolling log of what the bracelet sent and what Myna did, so a
    /// stalled handshake can be diagnosed from the device itself.
    @Published private(set) var diagnostics: [String] = []

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
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
    func setRecording(_ on: Bool) {
        guard isReadyForControl else { return }
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

        if isSealed {
            if let heldKey {
                // Already sealed with a key we installed before — reuse it.
                key = heldKey
                installDecryptor()
                log("Reusing stored key. Requesting session nonce (0xC019)…")
                central.writeControl(BeeCommand.getSessionNonce.frame())
            } else {
                // Sealed with a key Myna doesn't hold — it can't decrypt the audio.
                log("Sealed with a key Myna doesn't hold → factory reset needed.")
                pairing = .needsFactoryReset
            }
            return
        }

        // Unsealed: the bracelet only accepts a token sealed by Bee's server,
        // so fetch it (one round-trip, device id only) and install it.
        provisionFromBackend(deviceID: deviceID)
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
                self.pairing = .error("Couldn't get the bracelet's key from Bee: \(error.localizedDescription)")
            }
        }
    }

    private func handleKeyResult(_ result: BeeKeyResult) {
        switch result {
        case .installed:
            if let key { BeeKeyVault.store(key, deviceID: deviceID) }
            log("Key installed. Requesting session nonce (0xC019)…")
            central.writeControl(BeeCommand.getSessionNonce.frame())
        case .alreadySet:
            // We just installed a freshly fetched key; the bracelet reports it
            // already had one. Persist and continue — if it was a different key,
            // decryption simply yields nothing and the log shows no audio.
            if let key { BeeKeyVault.store(key, deviceID: deviceID) }
            log("Key already set. Requesting session nonce (0xC019)…")
            central.writeControl(BeeCommand.getSessionNonce.frame())
        case .unknown(let code):
            log("Key reply code \(code) (unrecognized).")
            pairing = .error("The bracelet rejected the key (code \(code)).")
        }
    }

    private func handleNonce(_ value: Data) {
        nonce = value
        decoder = codec.map { BeeAudioDecoder(codec: $0) }
        log("Session nonce received (\(value.count) bytes). Starting audio…")
        // Bee subscribes to audio only once the key and nonce are in place.
        central.startAudioNotifications()
        central.writeControl(BeeCommand.getDeviceState.frame())
        central.writeControl(BeeCommand.getBatteryAndChargeState.frame())
        central.writeControl(BeeCommand.getFirmwareVersion.frame())
        central.writeControl(BeeCommand.getBrightness.frame(payload: [0x01]))
        central.writeControl(BeeCommand.getBitrate.frame())
        central.writeControl(BeeCommand.getTxLevel.frame())
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
        }
    }

    private func installDecryptor() {
        guard let key else { return }
        decryptor = try? BeeAudioDecryptor(key: key)
        if decryptor == nil { pairing = .error("Couldn't set up decryption.") }
    }

    // MARK: - Audio

    private func handleAudio(_ data: Data) {
        guard case .streaming = pairing,
              let packet = BeeAudioFraming.parse(data),
              let nonce, let decryptor, let decoder else { return }
        guard let plaintext = try? decryptor.decrypt(packet: packet, nonce: nonce),
              !plaintext.isEmpty else { return }
        let buffers = decoder.decodeStream(plaintext)
        guard !buffers.isEmpty else { return }
        if packetsDecoded == 0 { log("Audio decoding (\(Int(decoder.sampleRate)) Hz).") }
        packetsDecoded += buffers.count
        if !feedingSpeech { beginSpeechFeed() }
        for pcm in buffers { listener?.feedExternalAudio(pcm) }
    }

    private func beginSpeechFeed() {
        feedingSpeech = true
        listener?.beginExternalSource()
        // Make sure recognition is actually running to receive the buffers.
        if let pilot, pilot.phase == .idle { pilot.startListening() }
    }

    private func endSpeechFeed() {
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
        case .setDeviceState(let ok):
            log(ok ? "Recording state set." : "Bracelet refused the recording state change.")
            central.writeControl(BeeCommand.getDeviceState.frame())
        }
    }
}
