import Foundation

// The audio characteristic's packet format and the AES-128-CTR counter block.
// Pure byte work, kept apart from the CommonCrypto decryptor so it is
// unit-tested on its own.
//
// Each audio packet is:  [4-byte big-endian sequence number][ciphertext]
// The CTR counter/IV block (16 bytes) is:  sessionNonce(12) || sequence(4, big-endian)
// The ciphertext is a codec frame (Opus or AAC) encrypted with the 16-byte key
// Myna generated and installed on the bracelet.

enum BeeAudioFraming {
    /// One audio packet split into its sequence number and ciphertext.
    struct Packet: Equatable {
        let sequence: UInt32
        let ciphertext: Data
    }

    /// Splits a raw audio-characteristic notification. nil when it's too short
    /// to hold a sequence number.
    static func parse(_ data: Data) -> Packet? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        let sequence = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return Packet(sequence: sequence, ciphertext: Data(data.dropFirst(4)))
    }

    /// The 16-byte CTR counter block: the 12-byte session nonce followed by the
    /// big-endian sequence number. Returns nil when the nonce isn't 12 bytes.
    static func counterBlock(nonce: Data, sequence: UInt32) -> Data? {
        guard nonce.count == BeeProtocol.nonceLength else { return nil }
        var block = nonce
        block.append(UInt8((sequence >> 24) & 0xFF))
        block.append(UInt8((sequence >> 16) & 0xFF))
        block.append(UInt8((sequence >> 8) & 0xFF))
        block.append(UInt8(sequence & 0xFF))
        return block
    }
}

/// Reassembles the bracelet's AAC stream. After decryption each packet is a
/// slice of a continuous ADTS byte stream — a frame can span packets — so
/// bytes are buffered and only complete frames come out. This mirrors Bee's own
/// AudioMessageDecoder.processPacket exactly: find the 0xFFF sync, read the
/// 13-bit frame length, trust it, emit the frame and advance; the first 3
/// frames are dropped while the encoder warms up. Each emitted Frame carries
/// the AAC-LC config (object type, sample-rate index, channels) so the decoder
/// can build the AudioSpecificConfig that Apple's AAC decoder needs.
struct BeeADTSAssembler {
    struct Frame: Equatable {
        /// Raw AAC access unit, ADTS header removed.
        let payload: Data
        let sampleRate: Double
        let channels: UInt32
        /// ADTS sample-rate index (0–12) and MPEG-4 audio object type (profile+1),
        /// both needed to synthesize the AudioSpecificConfig / magic cookie.
        let sampleRateIndex: Int
        let objectType: Int
    }

    private var buffer: [UInt8] = []
    private var warmup: Int

    init(warmup: Int = 3) {
        self.warmup = warmup
    }

    static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    mutating func append(_ data: Data) -> [Frame] {
        buffer.append(contentsOf: data)
        var frames: [Frame] = []
        var i = 0
        while i + 7 <= buffer.count {
            // ADTS sync: 0xFFF (12 bits). Same gate Bee uses — blind trust of
            // the frame length is correct for a correctly-decrypted stream.
            guard buffer[i] == 0xFF, buffer[i + 1] & 0xF0 == 0xF0 else {
                i += 1
                continue
            }
            let length = (Int(buffer[i + 3] & 0x03) << 11) | (Int(buffer[i + 4]) << 3) | (Int(buffer[i + 5]) >> 5)
            // Bee breaks (waits for more bytes) on a too-short or not-yet-complete
            // frame rather than resyncing — match that.
            guard length > 7 else { break }
            guard i + length <= buffer.count else { break }
            let protectionAbsent = buffer[i + 1] & 0x01 == 1
            let headerLength = protectionAbsent ? 7 : 9
            let rateIndex = Int((buffer[i + 2] >> 2) & 0x0F)
            // ADTS channel-config field → channel count (config 7 == 8 channels).
            let channelConfig = Int((buffer[i + 2] & 0x01) << 2) | Int(buffer[i + 3] >> 6)
            let channels = channelConfig == 7 ? 8 : channelConfig
            // ADTS profile is objectType-1; AudioObjectType = profile + 1.
            let objectType = Int(buffer[i + 2] >> 6) + 1
            if warmup > 0 {
                warmup -= 1
            } else if length > headerLength, rateIndex < Self.sampleRates.count, channels >= 1 {
                frames.append(Frame(
                    payload: Data(buffer[(i + headerLength)..<(i + length)]),
                    sampleRate: Self.sampleRates[rateIndex],
                    channels: UInt32(channels),
                    sampleRateIndex: rateIndex,
                    objectType: objectType
                ))
            }
            i += length
        }
        if i > 0 { buffer.removeFirst(min(i, buffer.count)) }
        // Never let a corrupt stream grow without bound.
        if buffer.count > 16_384 { buffer.removeAll() }
        return frames
    }

    mutating func reset() {
        buffer.removeAll()
        warmup = 3
    }
}
