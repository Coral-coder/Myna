import XCTest
@testable import MynaCore

final class BeeFramingTests: XCTestCase {
    func testCommandFramingIsLittleEndian() {
        XCTAssertEqual([UInt8](BeeCommand.getSecureIds.frame()), [0x1B, 0xC0])
        XCTAssertEqual([UInt8](BeeCommand.getSessionNonce.frame()), [0x19, 0xC0])
        XCTAssertEqual([UInt8](BeeCommand.getBrightness.frame(payload: [0x01])), [0x17, 0xC0, 0x01])
        XCTAssertEqual([UInt8](BeeCommand.setEncryptionKey.frame(payload: Array(repeating: 0xAB, count: 16))),
                       [0x18, 0xC0] + Array(repeating: 0xAB, count: 16))
    }

    func testMessageID() {
        XCTAssertEqual(BeeProtocol.messageID(Data([0x0F, 0xC0, 0x64, 0x01])), 0xC00F)
        XCTAssertEqual(BeeProtocol.messageID(Data([0x00, 0x80])), 0x8000)
        XCTAssertNil(BeeProtocol.messageID(Data([0x01])))
    }
}

final class BeeEventTests: XCTestCase {
    func testBatteryEvent() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x00, 0x80, 0x55])), .event(.batteryLevel(0x55)))
    }

    func testDoublePress() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x01, 0x80])), .event(.buttonDoublePress))
    }

    func testHold() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x02, 0x80, 0x01])), .event(.buttonHold(pressed: true)))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x02, 0x80, 0x00])), .event(.buttonHold(pressed: false)))
    }

    func testCharging() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x03, 0x80, 0x01])), .event(.charging(true)))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x03, 0x80, 0x00])), .event(.charging(false)))
    }

    func testDeviceStateEvent() {
        let msg = BeeProtocol.parseControlMessage(Data([0x04, 0x80, 0x01, 0x00]))
        XCTAssertEqual(msg, .event(.deviceState(state: .recording, codec: .opus)))
    }

    func testTruncatedEventIsMalformed() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x00, 0x80])), .malformed)
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x04, 0x80, 0x01])), .malformed)
    }
}

final class BeeResponseTests: XCTestCase {
    func testBatteryAndCharge() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x0F, 0xC0, 0x4B, 0x01])),
                       .response(.batteryAndCharge(level: 75, charging: true)))
    }

    func testBitrateInt32LE() {
        // 0x0001F400 = 128000
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x09, 0xC0, 0x00, 0xF4, 0x01, 0x00])),
                       .response(.bitrate(128000)))
    }

    func testBrightness() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x17, 0xC0, 0x80])),
                       .response(.brightness(128)))
    }

    func testDeviceID() {
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04]
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x0E, 0xC0] + payload)),
                       .response(.deviceID("deadbeef01020304")))
    }

    func testDeviceStateResponse() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x0A, 0xC0, 0x04, 0x01])),
                       .response(.deviceState(state: .sleepSoftwareVAD, codec: .aac)))
    }

    func testFirmwareVersionByteOrder() {
        // patch=data[0], minor=data[1], major=data[2]
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x05, 0xC0, 0x07, 0x02, 0x01])),
                       .response(.firmwareVersion(major: 1, minor: 2, patch: 7)))
    }

    func testSecureIdsSealedFlag() {
        let id: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x1B, 0xC0] + id + [0x00])),
                       .response(.secureIds(deviceID: "1122334455667788", isSealed: false)))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x1B, 0xC0] + id + [0x01])),
                       .response(.secureIds(deviceID: "1122334455667788", isSealed: true)))
    }

    func testSessionNonceIsTwelveBytes() {
        let nonce = (0..<12).map { UInt8($0) }
        let msg = BeeProtocol.parseControlMessage(Data([0x19, 0xC0] + nonce + [0xFF, 0xFF]))
        XCTAssertEqual(msg, .response(.sessionNonce(Data(nonce))))
    }

    func testSessionNonceTooShortIsMalformed() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x19, 0xC0] + Array(repeating: 0, count: 8))), .malformed)
    }

    func testEncryptionKeyResult() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x18, 0xC0, 0x00])), .response(.encryptionKey(.installed)))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x18, 0xC0, 0x01])), .response(.encryptionKey(.alreadySet)))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x18, 0xC0, 0x09])), .response(.encryptionKey(.unknown(9))))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x18, 0xC0])), .response(.encryptionKey(.installed)))
    }

    func testUnknownIdIsUnhandled() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x99, 0xC0, 0x01])),
                       .unhandled(id: 0xC099, payload: Data([0x01])))
    }

    func testUnknownStateAndCodecRawValues() {
        let msg = BeeProtocol.parseControlMessage(Data([0x0A, 0xC0, 0x09, 0x09]))
        XCTAssertEqual(msg, .response(.deviceState(state: .unknown, codec: .unknown)))
    }
}

final class BeeAudioFramingTests: XCTestCase {
    func testPacketSplitBigEndianSequence() {
        let packet = BeeAudioFraming.parse(Data([0x00, 0x00, 0x01, 0x05, 0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(packet?.sequence, 0x00000105)
        XCTAssertEqual(packet?.ciphertext, Data([0xAA, 0xBB, 0xCC]))
    }

    func testLargeSequence() {
        XCTAssertEqual(BeeAudioFraming.parse(Data([0xFF, 0xFF, 0xFF, 0xFF]))?.sequence, 0xFFFFFFFF)
    }

    func testTooShortIsNil() {
        XCTAssertNil(BeeAudioFraming.parse(Data([0x00, 0x01, 0x02])))
    }

    func testCounterBlockIsNonceThenBigEndianSequence() {
        let nonce = Data((0..<12).map { UInt8($0) })
        let block = BeeAudioFraming.counterBlock(nonce: nonce, sequence: 0x01020304)
        XCTAssertEqual(block, nonce + Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(block?.count, 16)
    }

    func testCounterBlockRejectsWrongNonceLength() {
        XCTAssertNil(BeeAudioFraming.counterBlock(nonce: Data(count: 11), sequence: 0))
        XCTAssertNil(BeeAudioFraming.counterBlock(nonce: Data(count: 16), sequence: 0))
    }
}
