import Foundation

// The Bee bracelet's control protocol — command framing and the parsing of
// responses and unsolicited events. Pure byte work with no CoreBluetooth, so
// it is unit-tested on its own.
//
// Framing: every control request is a 2-byte little-endian command id followed
// by its payload. Every message the control characteristic sends back — a reply
// to a command, or an unsolicited event — likewise begins with a 2-byte
// little-endian id, then its payload.

// MARK: - Commands

/// The control commands Myna sends. Ids are little-endian on the wire.
enum BeeCommand: UInt16 {
    case setTxPower = 0xC001
    case getTxLevel = 0xC002
    case getChargingSpeed = 0xC004
    case getFirmwareVersion = 0xC005
    case setBitrate = 0xC008
    case getBitrate = 0xC009
    case getDeviceState = 0xC00A
    case getDeviceID = 0xC00E
    case getBatteryAndChargeState = 0xC00F
    case getBrightness = 0xC017
    case setEncryptionKey = 0xC018
    case getSessionNonce = 0xC019
    case getSecureIds = 0xC01B

    /// `[id low, id high, payload...]`.
    func frame(payload: [UInt8] = []) -> Data {
        BeeProtocol.frame(rawValue, payload: payload)
    }
}

// MARK: - Enums from the device

/// Reported in DeviceState and the device-state event.
enum BeeDeviceState: UInt8, CustomStringConvertible {
    case mute = 0
    case recording = 1
    case sleepHardwareVAD = 2
    case powerOff = 3
    case sleepSoftwareVAD = 4
    case unknown = 0xFF

    init(raw: UInt8) { self = BeeDeviceState(rawValue: raw) ?? .unknown }

    var description: String {
        switch self {
        case .mute: return "muted"
        case .recording: return "recording"
        case .sleepHardwareVAD: return "asleep (hardware VAD)"
        case .sleepSoftwareVAD: return "asleep (software VAD)"
        case .powerOff: return "powered off"
        case .unknown: return "unknown"
        }
    }

    /// Whether the bracelet is actively capturing audio.
    var isRecording: Bool { self == .recording }
}

/// The codec the audio characteristic emits.
enum BeeCodec: UInt8, CustomStringConvertible {
    case opus = 0
    case aac = 1
    case unknown = 0xFF

    init(raw: UInt8) { self = BeeCodec(rawValue: raw) ?? .unknown }

    var description: String {
        switch self {
        case .opus: return "Opus"
        case .aac: return "AAC"
        case .unknown: return "unknown"
        }
    }
}

/// The reply to SetEncryptionKey (0xC018). Exact byte layout is confirmed on
/// the device; `installed` and `alreadySet` are the two success states the
/// protocol notes, and the raw byte is kept for anything else.
enum BeeKeyResult: Equatable {
    case installed
    case alreadySet
    case unknown(UInt8)
}

// MARK: - Parsed messages

/// An unsolicited event from the control characteristic (0x8000–0x8004).
enum BeeEvent: Equatable {
    case batteryLevel(Int)            // 0x8000
    case buttonDoublePress            // 0x8001
    case buttonHold(pressed: Bool)    // 0x8002
    case charging(Bool)               // 0x8003
    case deviceState(state: BeeDeviceState, codec: BeeCodec) // 0x8004
}

/// A reply to a command, keyed by the id we sent.
enum BeeResponse: Equatable {
    case batteryAndCharge(level: Int, charging: Bool)   // 0xC00F
    case bitrate(Int)                                   // 0xC009
    case brightness(Int)                                // 0xC017
    case deviceID(String)                               // 0xC00E
    case deviceState(state: BeeDeviceState, codec: BeeCodec) // 0xC00A
    case firmwareVersion(major: Int, minor: Int, patch: Int) // 0xC005
    case secureIds(deviceID: String, isSealed: Bool)    // 0xC01B
    case sessionNonce(Data)                             // 0xC019
    case encryptionKey(BeeKeyResult)                    // 0xC018
    case txLevel(Int)                                   // 0xC002
    case txPower(Int)                                   // 0xC001
}

/// What a message off the control characteristic turned out to be.
enum BeeControlMessage: Equatable {
    case event(BeeEvent)
    case response(BeeResponse)
    /// A well-formed message we don't model (or a confirmed-on-device command).
    case unhandled(id: UInt16, payload: Data)
    case malformed
}

// MARK: - Parser

enum BeeProtocol {
    /// Advertised 16-bit service used as the scan filter.
    static let advertisedServiceShort = "D5C4"
    /// Primary GATT service.
    static let serviceUUID = "03D5D5C4-A86C-11EE-9D89-8F2089A49E7E"
    /// Control characteristic (write + notify).
    static let controlCharacteristicUUID = "05E1F93C-D8D0-5ED8-DD88-379E4C1A3E3E"
    /// Audio characteristic (notify).
    static let audioCharacteristicUUID = "B189A505-A86C-11EE-A5FB-8F2089A49E7E"

    static let nonceLength = 12
    static let keyLength = 16

    static func frame(_ id: UInt16, payload: [UInt8] = []) -> Data {
        var bytes: [UInt8] = [UInt8(id & 0xFF), UInt8((id >> 8) & 0xFF)]
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    /// The leading 2-byte little-endian id, or nil when there aren't two bytes.
    static func messageID(_ data: Data) -> UInt16? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    /// Classifies a message from the control characteristic.
    static func parseControlMessage(_ data: Data) -> BeeControlMessage {
        guard let id = messageID(data) else { return .malformed }
        let payload = Data(data.dropFirst(2))
        // Events are 0x80xx, command responses are 0xC0xx — both have the high
        // bit set, so route by the high byte, not by >= 0x8000.
        switch id >> 8 {
        case 0x80:
            return parseEvent(id: id, payload: payload)
        default:
            return parseResponse(id: id, payload: payload)
        }
    }

    // MARK: Events

    private static func parseEvent(id: UInt16, payload: Data) -> BeeControlMessage {
        let bytes = [UInt8](payload)
        switch id {
        case 0x8000:
            guard let level = bytes.first else { return .malformed }
            return .event(.batteryLevel(Int(level)))
        case 0x8001:
            return .event(.buttonDoublePress)
        case 0x8002:
            guard let b = bytes.first else { return .malformed }
            return .event(.buttonHold(pressed: b == 1))
        case 0x8003:
            guard let b = bytes.first else { return .malformed }
            return .event(.charging(b != 0))
        case 0x8004:
            guard bytes.count >= 2 else { return .malformed }
            return .event(.deviceState(state: BeeDeviceState(raw: bytes[0]), codec: BeeCodec(raw: bytes[1])))
        default:
            return .unhandled(id: id, payload: payload)
        }
    }

    // MARK: Responses

    private static func parseResponse(id: UInt16, payload: Data) -> BeeControlMessage {
        let bytes = [UInt8](payload)
        guard let command = BeeCommand(rawValue: id) else {
            return .unhandled(id: id, payload: payload)
        }
        switch command {
        case .getBatteryAndChargeState:
            guard bytes.count >= 2 else { return .malformed }
            return .response(.batteryAndCharge(level: Int(bytes[0]), charging: bytes[1] != 0))
        case .getBitrate:
            guard bytes.count >= 4 else { return .malformed }
            let value = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)
            return .response(.bitrate(value))
        case .getBrightness:
            guard let b = bytes.first else { return .malformed }
            return .response(.brightness(Int(b)))
        case .getDeviceID:
            guard bytes.count >= 8 else { return .malformed }
            return .response(.deviceID(hex(bytes.prefix(8))))
        case .getDeviceState:
            guard bytes.count >= 2 else { return .malformed }
            return .response(.deviceState(state: BeeDeviceState(raw: bytes[0]), codec: BeeCodec(raw: bytes[1])))
        case .getFirmwareVersion:
            guard bytes.count >= 3 else { return .malformed }
            return .response(.firmwareVersion(major: Int(bytes[2]), minor: Int(bytes[1]), patch: Int(bytes[0])))
        case .getSecureIds:
            guard bytes.count >= 9 else { return .malformed }
            return .response(.secureIds(deviceID: hex(bytes.prefix(8)), isSealed: bytes[8] != 0))
        case .getSessionNonce:
            guard bytes.count >= nonceLength else { return .malformed }
            return .response(.sessionNonce(Data(bytes.prefix(nonceLength))))
        case .setEncryptionKey:
            return .response(.encryptionKey(keyResult(bytes)))
        case .getTxLevel:
            guard let b = bytes.first else { return .malformed }
            return .response(.txLevel(Int(b)))
        case .setTxPower:
            guard let b = bytes.first else { return .malformed }
            return .response(.txPower(Int(b)))
        case .setBitrate, .getChargingSpeed:
            return .unhandled(id: id, payload: payload)
        }
    }

    /// SetEncryptionKey reply. The exact code bytes are confirmed on the
    /// device; an empty payload is treated as a bare success (installed).
    private static func keyResult(_ bytes: [UInt8]) -> BeeKeyResult {
        guard let code = bytes.first else { return .installed }
        switch code {
        case 0: return .installed
        case 1: return .alreadySet
        default: return .unknown(code)
        }
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
