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
    /// A control write was refused until the link is encrypted, so iOS is
    /// showing the pairing prompt. Lets the manager tell the user and wait.
    func beeCentralDidBeginPairing(_ central: BeeCentral)
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

    // Control commands go out one at a time with response: the bracelet only
    // answers a bonded central, and a with-response write is what makes iOS
    // put up the pairing prompt and encrypt the link. We serialize because
    // CoreBluetooth keeps only one with-response write in flight, and the
    // handshake sends commands in bursts.
    private var writeQueue: [Data] = []
    private var writeInFlight = false
    private var writeRetries = 0
    private var didAnnouncePairing = false
    /// ~24s of retries so there's time to accept the iOS pairing prompt.
    private static let maxWriteRetries = 16

    // Type-level so the nonisolated CoreBluetooth delegate callbacks can read them.
    private static let serviceUUID = CBUUID(string: BeeProtocol.serviceUUID)
    private static let advertisedUUID = CBUUID(string: BeeProtocol.advertisedServiceShort)
    private static let controlUUID = CBUUID(string: BeeProtocol.controlCharacteristicUUID)
    private static let audioUUID = CBUUID(string: BeeProtocol.audioCharacteristicUUID)

    private static let restoreIdentifier = "com.lightwave.myna.bee.central"
    /// Remember the paired bracelet so we can reconnect without scanning.
    private static let knownPeripheralKey = "myna.bee.peripheralID"

    var isReady: Bool { phase == .ready }

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

    func disconnect() {
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
    }

    /// Queues a framed control command. Each is written with response, one at a
    /// time, so the bracelet acknowledges it — and so the first command triggers
    /// iOS pairing on the encrypted link the bracelet requires.
    func writeControl(_ data: Data) {
        writeQueue.append(data)
        pumpWrites()
    }

    private func pumpWrites() {
        guard !writeInFlight, let peripheral, let controlCharacteristic, !writeQueue.isEmpty else { return }
        writeInFlight = true
        peripheral.writeValue(writeQueue[0], for: controlCharacteristic, type: .withResponse)
    }

    private func clearWriteQueue() {
        writeQueue.removeAll()
        writeInFlight = false
        writeRetries = 0
        didAnnouncePairing = false
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
            clearWriteQueue()
            phase = .idle
            delegate?.beeCentral(self, didDisconnectWithError: error)
            // Try to come back; iOS wakes us when a connect completes in the background.
            if central.state == .poweredOn { manager?.connect(peripheral, options: nil) }
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
                    audioCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                default:
                    break
                }
            }
            if controlCharacteristic != nil && audioCharacteristic != nil {
                phase = .ready
                delegate?.beeCentralDidReady(self)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.controlUUID else { return }
        Task { @MainActor in
            writeInFlight = false
            if error != nil {
                // Mid-handshake this almost always means the link isn't encrypted
                // yet and iOS is prompting to pair. Keep the command queued and
                // retry while the user accepts; give up after a bounded wait.
                if !didAnnouncePairing {
                    didAnnouncePairing = true
                    delegate?.beeCentralDidBeginPairing(self)
                }
                writeRetries += 1
                guard writeRetries <= Self.maxWriteRetries else { clearWriteQueue(); return }
                try? await Task.sleep(for: .milliseconds(1500))
                pumpWrites()
                return
            }
            // Acknowledged: the link is up. Advance to the next queued command.
            writeRetries = 0
            didAnnouncePairing = false
            if !writeQueue.isEmpty { writeQueue.removeFirst() }
            pumpWrites()
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
