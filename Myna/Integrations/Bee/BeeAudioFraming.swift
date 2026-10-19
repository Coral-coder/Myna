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
