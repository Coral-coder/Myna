import Foundation

#if canImport(CommonCrypto)
import CommonCrypto

/// AES-128 in counter mode, for decrypting the bracelet's audio stream.
///
/// CryptoKit has no raw CTR, so this uses CommonCrypto's `CCCryptorCreateWithMode`
/// with `kCCModeCTR`. The key is the 16 bytes Myna generated and installed on
/// the bracelet; each packet's counter block is `nonce(12) || sequence(4 BE)`,
/// so decryption is stateless per packet — a dropped BLE notification only
/// costs that one frame, never the stream.
struct BeeAudioDecryptor {
    enum DecryptError: Error { case badKeyLength, badCounterLength, cryptorFailed(CCCryptorStatus) }

    private let key: Data

    init(key: Data) throws {
        guard key.count == kCCKeySizeAES128 else { throw DecryptError.badKeyLength }
        self.key = key
    }

    /// Decrypts one packet's ciphertext using its counter block.
    func decrypt(_ ciphertext: Data, counter: Data) throws -> Data {
        guard counter.count == kCCBlockSizeAES128 else { throw DecryptError.badCounterLength }
        guard !ciphertext.isEmpty else { return Data() }

        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            counter.withUnsafeBytes { counterBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    counterBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else { throw DecryptError.cryptorFailed(createStatus) }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: ciphertext.count)
        var moved = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { outBytes in
            ciphertext.withUnsafeBytes { inBytes in
                CCCryptorUpdate(cryptor, inBytes.baseAddress, ciphertext.count, outBytes.baseAddress, outputCount, &moved)
            }
        }
        guard status == kCCSuccess else { throw DecryptError.cryptorFailed(status) }
        output.removeSubrange(moved..<output.count)
        return output
    }

    /// Convenience: decrypt a full audio packet given the session nonce.
    func decrypt(packet: BeeAudioFraming.Packet, nonce: Data) throws -> Data {
        guard let counter = BeeAudioFraming.counterBlock(nonce: nonce, sequence: packet.sequence) else {
            throw DecryptError.badCounterLength
        }
        return try decrypt(packet.ciphertext, counter: counter)
    }
}
#endif
