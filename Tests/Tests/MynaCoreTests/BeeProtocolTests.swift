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

/// An OK reply as the bracelet frames it: 0x8000, the echoed command, payload.
private func ok(_ command: UInt8, _ payload: [UInt8] = []) -> Data {
    Data([0x00, 0x80, command, 0xC0] + payload)
}

final class BeeEventTests: XCTestCase {
    // Bytes captured from a real bracelet right after connecting.
    func testRealConnectBurst() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x05, 0xA0, 0x00])), .event(.charging(false)))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x04, 0xA0, 0xD1, 0x0F])), .event(.batteryLevel(83)))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x03, 0xA0, 0x00, 0x01])),
                       .event(.deviceState(state: .mute, codec: .aac)))
    }

    func testBatteryPercentByte() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x04, 0xA0, 0x55])), .event(.batteryLevel(0x55)))
    }

    func testDoublePress() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x01, 0xA0])), .event(.buttonDoublePress))
    }

    func testHold() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x02, 0xA0, 0x01])), .event(.buttonHold(pressed: true)))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x02, 0xA0, 0x00])), .event(.buttonHold(pressed: false)))
    }

    func testChargingTrue() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x05, 0xA0, 0x01])), .event(.charging(true)))
    }

    func testDeviceStateEvent() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x03, 0xA0, 0x01, 0x00])),
                       .event(.deviceState(state: .recording, codec: .opus)))
    }

    func testTruncatedEventIsMalformed() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x04, 0xA0])), .malformed)
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x03, 0xA0, 0x01])), .malformed)
    }
}

final class BeeResponseTests: XCTestCase {
    func testBatteryAndCharge() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x0F, [0x4B, 0x01])),
                       .response(.batteryAndCharge(level: 75, charging: true)))
    }

    func testBitrateInt32LE() {
        // 0x0001F400 = 128000
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x09, [0x00, 0xF4, 0x01, 0x00])),
                       .response(.bitrate(128000)))
    }

    func testBrightness() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x17, [0x80])), .response(.brightness(128)))
    }

    func testDeviceID() {
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04]
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x0E, payload)),
                       .response(.deviceID("deadbeef01020304")))
    }

    func testDeviceStateResponse() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x0A, [0x04, 0x01])),
                       .response(.deviceState(state: .sleepSoftwareVAD, codec: .aac)))
    }

    func testFirmwareVersionByteOrder() {
        // patch=data[0], minor=data[1], major=data[2]
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x05, [0x07, 0x02, 0x01])),
                       .response(.firmwareVersion(major: 1, minor: 2, patch: 7)))
    }

    func testSecureIdsSealedFlag() {
        let id: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x1B, id + [0x00])),
                       .response(.secureIds(deviceID: "1122334455667788", isSealed: false)))
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x1B, id + [0x01])),
                       .response(.secureIds(deviceID: "1122334455667788", isSealed: true)))
    }

    func testSessionNonceIsTwelveBytes() {
        let nonce = (0..<12).map { UInt8($0) }
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x19, nonce + [0xFF, 0xFF])),
                       .response(.sessionNonce(Data(nonce))))
    }

    func testSessionNonceTooShortIsMalformed() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x19, Array(repeating: 0, count: 8))), .malformed)
    }

    func testEncryptionKeyResults() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x18)), .response(.encryptionKey(.installed)))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x04, 0x80])), .response(.encryptionKey(.alreadySet)))
    }

    func testFailures() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x01, 0x80])), .failure(.error))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x02, 0x80])), .failure(.invalidParam))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x03, 0x80])), .failure(.unknownCommand))
    }

    func testOKWithoutCommandIsMalformed() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x00, 0x80, 0x1B])), .malformed)
    }

    func testSetDeviceStateCommand() {
        XCTAssertEqual([UInt8](BeeCommand.setDeviceState.frame(payload: [0x01])), [0x06, 0xC0, 0x01])
    }

    func testUnknownIdIsUnhandled() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x99, [0x01])),
                       .unhandled(id: 0xC099, payload: Data([0x01])))
        XCTAssertEqual(BeeProtocol.parseControlMessage(Data([0x34, 0x12, 0x01])),
                       .unhandled(id: 0x1234, payload: Data([0x01])))
    }

    func testUnknownStateAndCodecRawValues() {
        XCTAssertEqual(BeeProtocol.parseControlMessage(ok(0x0A, [0x09, 0x09])),
                       .response(.deviceState(state: .unknown, codec: .unknown)))
    }
}

final class BeeADTSTests: XCTestCase {
    /// A 7-byte ADTS header (no CRC, AAC-LC, 16 kHz, mono) plus `body`.
    private func frame(_ body: [UInt8]) -> [UInt8] {
        let length = 7 + body.count
        return [0xFF, 0xF1, 0x60, 0x40 | UInt8((length >> 11) & 0x03),
                UInt8((length >> 3) & 0xFF), UInt8(((length & 0x07) << 5) | 0x1F), 0xFC] + body
    }

    func testFramesSpanPacketsAndWarmupIsDropped() {
        var adts = BeeADTSAssembler(warmup: 1)
        let stream = frame([0x01]) + frame([0x02, 0x03]) + frame([0x04])
        XCTAssertEqual(adts.append(Data(stream.prefix(10))), [])
        let out = adts.append(Data(stream.dropFirst(10)))
        XCTAssertEqual(out.map(\.payload), [Data([0x02, 0x03]), Data([0x04])])
        XCTAssertEqual(out.first?.sampleRate, 16000)
        XCTAssertEqual(out.first?.channels, 1)
    }

    func testResyncsPastGarbage() {
        var adts = BeeADTSAssembler(warmup: 0)
        XCTAssertEqual(adts.append(Data([0x00, 0x13] + frame([0x09]))).map(\.payload), [Data([0x09])])
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
