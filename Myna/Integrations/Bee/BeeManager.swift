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

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    private static let enabledKey = "myna.bee.enabled"

    private let central = BeeCentral()
    private weak var listener: SpeechListener?
    private weak var pilot: ConversationPilot?

    private var key: Data?
    private var nonce: Data?
    private var decryptor: BeeAudioDecryptor?
    private var decoder: BeeAudioDecoder?
    private var feedingSpeech = false

    init(listener: SpeechListener, pilot: ConversationPilot) {
        self.listener = listener
        self.pilot = pilot
        central.delegate = self
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

    private func reset() {
        key = nil
        nonce = nil
        decryptor = nil
        decoder = nil
        deviceState = nil
        codec = nil
    }

    // MARK: - Handshake

    private func beginHandshake() {
        pairing = .provisioning
        central.writeControl(BeeCommand.getSecureIds.frame())
    }

    private func handleSecureIds(deviceID: String, isSealed: Bool) {
        self.deviceID = deviceID
        let heldKey = BeeKeyVault.existingKey(deviceID: deviceID)

        if isSealed {
            if let heldKey {
                // Sealed with the key we installed before — reuse it, no re-provision.
                key = heldKey
                installDecryptor()
                central.writeControl(BeeCommand.getSessionNonce.frame())
            } else {
                // Sealed with a key we don't have. Never try to recover it;
                // the user factory-resets, which clears it, then we set ours.
                pairing = .needsFactoryReset
            }
            return
        }

        // Unsealed: generate (or reuse) our own key and install it.
        do {
            let ourKey = try BeeKeyVault.loadOrCreateKey(deviceID: deviceID)
            key = ourKey
            installDecryptor()
            central.writeControl(BeeCommand.setEncryptionKey.frame(payload: [UInt8](ourKey)))
        } catch {
            pairing = .error("Couldn't prepare a key: \(error.localizedDescription)")
        }
    }

    private func handleKeyResult(_ result: BeeKeyResult) {
        switch result {
        case .installed, .alreadySet:
            central.writeControl(BeeCommand.getSessionNonce.frame())
        case .unknown(let code):
            pairing = .error("The bracelet rejected the key (code \(code)).")
        }
    }

    private func handleNonce(_ value: Data) {
        nonce = value
        central.writeControl(BeeCommand.getDeviceState.frame())
        central.writeControl(BeeCommand.getBatteryAndChargeState.frame())
        central.writeControl(BeeCommand.getFirmwareVersion.frame())
    }

    private func handleDeviceState(state: BeeDeviceState, codec: BeeCodec) {
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
              !plaintext.isEmpty,
              let pcm = decoder.decode(plaintext) else { return }
        packetsDecoded += 1
        if !feedingSpeech { beginSpeechFeed() }
        listener?.feedExternalAudio(pcm)
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
        switch BeeProtocol.parseControlMessage(data) {
        case .event(let event):
            handleEvent(event)
        case .response(let response):
            handleResponse(response)
        case .unhandled, .malformed:
            break
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
        case .bitrate, .brightness, .deviceID, .txLevel, .txPower:
            break
        }
    }
}
