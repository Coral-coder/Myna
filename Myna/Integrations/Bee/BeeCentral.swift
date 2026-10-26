import CoreBluetooth
import Foundation

/// The low-level CoreBluetooth client for the Bee bracelet: scan, connect,
/// discover the control + audio characteristics, enable notifications on both,
/// write control commands and deliver incoming bytes.
///
/// It runs with the `bluetooth-central` background mode and state restoration,
/// so iOS can relaunch Myna into the background when the bracelet reconnects.
/// It knows nothing about the protocol's meaning — `BeeManager` interprets the
/// bytes. All delegate work hops to the main actor.
@MainActor
protocol BeeCentralDelegate: AnyObject {
    func beeCentralDidUpdateState(_ central: BeeCentral)
    func beeCentralDidConnect(_ central: BeeCentral)
    func beeCentral(_ central: BeeCentral, didDisconnectWithError error: Error?)
    func beeCentralDidReady(_ central: BeeCentral)
    func beeCentral(_ central: BeeCentral, didReceiveControl data: Data)
    func beeCentral(_ central: BeeCentral, didReceiveAudio data: Data)
}

@MainActor
final class BeeCentral: NSObject, ObservableObject {
    enum Phase: Equatable {
        case poweredOff
        case unauthorized
        case idle
        case scanning
        case connecting
        case discovering
        case ready
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var discoveredName: String?

    weak var delegate: BeeCentralDelegate?

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?

    // Type-level so the nonisolated CoreBluetooth delegate callbacks can read them.
    private static let serviceUUID = CBUUID(string: BeeProtocol.serviceUUID)
    private static let advertisedUUID = CBUUID(string: BeeProtocol.advertisedServiceShort)
    private static let controlUUID = CBUUID(string: BeeProtocol.controlCharacteristicUUID)
    private static let audioUUID = CBUUID(string: BeeProtocol.audioCharacteristicUUID)

    private static let restoreIdentifier = "com.lightwave.myna.bee.central"
    /// Remember the paired bracelet so we can reconnect without scanning.
    private static let knownPeripheralKey = "myna.bee.peripheralID"

    var isReady: Bool { phase == .ready }
    /// Low-level problems worth showing in the device log.
    var onDiagnostic: ((String) -> Void)?

    /// Create the manager. Call once CoreBluetooth use is actually wanted, so
    /// the system permission prompt doesn't appear before the user opts in.
    func activate() {
        guard manager == nil else { return }
        manager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
    }

    func startScan() {
        guard let manager, manager.state == .poweredOn else { return }
        if reconnectKnownPeripheral() { return }
        phase = .scanning
        manager.scanForPeripherals(withServices: [Self.advertisedUUID, Self.serviceUUID], options: nil)
    }

    func stopScan() {
        manager?.stopScan()
        if phase == .scanning { phase = .idle }
    }

    /// Whether an unexpected drop should trigger an automatic reconnect. Cleared
    /// when the user turns the bracelet off, so we don't fight for the link.
    private var shouldReconnect = false

    func disconnect() {
        shouldReconnect = false
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
    }

    /// Writes a framed control command. Bee's app uses a normal (acknowledged)
    /// write; a write-without-response to a characteristic that doesn't
    /// support it is silently dropped by iOS.
    func writeControl(_ data: Data) {
        guard let peripheral, let controlCharacteristic else { return }
        let type: CBCharacteristicWriteType = controlCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: controlCharacteristic, type: type)
    }

    /// Subscribe to audio. Bee does this only after the key and session nonce
    /// are in place, so the first packets are already decryptable.
    func startAudioNotifications() {
        guard let peripheral, let audioCharacteristic, !audioCharacteristic.isNotifying else { return }
        peripheral.setNotifyValue(true, for: audioCharacteristic)
    }

    // MARK: - Reconnect

    private func reconnectKnownPeripheral() -> Bool {
        guard let manager,
              let idString = UserDefaults.standard.string(forKey: Self.knownPeripheralKey),
              let uuid = UUID(uuidString: idString),
              let known = manager.retrievePeripherals(withIdentifiers: [uuid]).first else { return false }
        connect(known)
        return true
    }

    private func connect(_ peripheral: CBPeripheral) {
        shouldReconnect = true
        self.peripheral = peripheral
        peripheral.delegate = self
        discoveredName = peripheral.name
        phase = .connecting
        manager?.stopScan()
        manager?.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownPeripheralKey)
    }
}

// MARK: - CBCentralManagerDelegate

extension BeeCentral: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if phase == .poweredOff || phase == .idle { phase = .idle }
            case .poweredOff: phase = .poweredOff
            case .unauthorized: phase = .unauthorized
            default: phase = .idle
            }
            delegate?.beeCentralDidUpdateState(self)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        Task { @MainActor in
            if let peripheral = restored?.first {
                self.peripheral = peripheral
                peripheral.delegate = self
                discoveredName = peripheral.name
                phase = peripheral.state == .connected ? .discovering : .connecting
                if peripheral.state == .connected { peripheral.discoverServices([Self.serviceUUID]) }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            guard self.peripheral == nil else { return }
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            phase = .discovering
            peripheral.discoverServices([Self.serviceUUID])
            delegate?.beeCentralDidConnect(self)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.peripheral = nil
            phase = .idle
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            controlCharacteristic = nil
            audioCharacteristic = nil
            phase = .idle
            delegate?.beeCentral(self, didDisconnectWithError: error)
            // Come back after a short pause — not in a tight loop. If another app
            // (e.g. the Bee app) is holding the bracelet's single BLE link, an
            // instant reconnect just ping-pongs; the delay lets the link settle.
            guard shouldReconnect else { return }
            try? await Task.sleep(for: .seconds(2))
            guard self.shouldReconnect, self.phase == .idle, central.state == .poweredOn else { return }
            manager?.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BeeCentral: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                phase = .idle
                return
            }
            peripheral.discoverCharacteristics([Self.controlUUID, Self.audioUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case Self.controlUUID:
                    controlCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case Self.audioUUID:
                    // Subscribed later, once the handshake is done.
                    audioCharacteristic = characteristic
                default:
                    break
                }
            }
            // Not ready yet: wait until the bracelet confirms control
            // notifications are on (below). Writing the first command before
            // that lost its reply — the bracelet answered into the void.
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        let message = error.localizedDescription
        Task { @MainActor in onDiagnostic?("Write failed: \(message)") }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let isControl = characteristic.uuid == Self.controlUUID
        let notifying = characteristic.isNotifying
        let failure = error?.localizedDescription
        Task { @MainActor in
            if let failure { onDiagnostic?("Notifications failed: \(failure)") }
            guard isControl, notifying, phase != .ready,
                  controlCharacteristic != nil, audioCharacteristic != nil else { return }
            phase = .ready
            delegate?.beeCentralDidReady(self)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let isControl = characteristic.uuid == Self.controlUUID
        let isAudio = characteristic.uuid == Self.audioUUID
        Task { @MainActor in
            if isControl {
                delegate?.beeCentral(self, didReceiveControl: value)
            } else if isAudio {
                delegate?.beeCentral(self, didReceiveAudio: value)
            }
        }
    }
}
