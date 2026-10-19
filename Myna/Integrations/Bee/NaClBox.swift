import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Just enough of NaCl's `crypto_box` (X25519 + XSalsa20-Poly1305) to open the
/// sealed token Bee hands back at the end of app pairing. CryptoKit supplies
/// X25519; it has no XSalsa20, so the stream cipher and MAC live here.
enum NaClBox {

    enum Failure: Error {
        case malformed
        case authenticationFailed
    }

    /// Opens a box given the raw X25519 shared secret (`crypto_scalarmult`).
    static func open(ciphertext: [UInt8], nonce: [UInt8], sharedSecret: [UInt8]) throws -> [UInt8] {
        guard nonce.count == 24, sharedSecret.count == 32, ciphertext.count >= 16 else { throw Failure.malformed }
        // crypto_box_beforenm: k = HSalsa20(shared, 0)
        let boxKey = hsalsa20(key: sharedSecret, input: [UInt8](repeating: 0, count: 16))
        return try secretboxOpen(ciphertext: ciphertext, nonce: nonce, key: boxKey)
    }

    /// `crypto_secretbox_open`: XSalsa20 stream, Poly1305 tag up front.
    static func secretboxOpen(ciphertext: [UInt8], nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard nonce.count == 24, key.count == 32, ciphertext.count >= 16 else { throw Failure.malformed }
        let subkey = hsalsa20(key: key, input: Array(nonce[0..<16]))
        let streamNonce = Array(nonce[16..<24])
        let tag = Array(ciphertext[0..<16])
        let body = Array(ciphertext[16...])

        let stream = salsa20Stream(key: subkey, nonce: streamNonce, count: 32 + body.count)
        let macKey = Array(stream[0..<32])
        guard constantTimeEqual(poly1305(message: body, key: macKey), tag) else {
            throw Failure.authenticationFailed
        }
        var plain = [UInt8](repeating: 0, count: body.count)
        for index in 0..<body.count {
            plain[index] = body[index] ^ stream[32 + index]
        }
        return plain
    }

    // MARK: - Salsa20

    private static let sigma: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574] // "expand 32-byte k"

    private static func load32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func rotl(_ value: UInt32, _ shift: UInt32) -> UInt32 {
        (value << shift) | (value >> (32 - shift))
    }

    private static func doubleRounds(_ x: inout [UInt32]) {
        for _ in 0..<10 {
            x[4] ^= rotl(x[0] &+ x[12], 7);  x[8] ^= rotl(x[4] &+ x[0], 9)
            x[12] ^= rotl(x[8] &+ x[4], 13); x[0] ^= rotl(x[12] &+ x[8], 18)
            x[9] ^= rotl(x[5] &+ x[1], 7);   x[13] ^= rotl(x[9] &+ x[5], 9)
            x[1] ^= rotl(x[13] &+ x[9], 13); x[5] ^= rotl(x[1] &+ x[13], 18)
            x[14] ^= rotl(x[10] &+ x[6], 7); x[2] ^= rotl(x[14] &+ x[10], 9)
            x[6] ^= rotl(x[2] &+ x[14], 13); x[10] ^= rotl(x[6] &+ x[2], 18)
            x[3] ^= rotl(x[15] &+ x[11], 7); x[7] ^= rotl(x[3] &+ x[15], 9)
            x[11] ^= rotl(x[7] &+ x[3], 13); x[15] ^= rotl(x[11] &+ x[7], 18)

            x[1] ^= rotl(x[0] &+ x[3], 7);   x[2] ^= rotl(x[1] &+ x[0], 9)
            x[3] ^= rotl(x[2] &+ x[1], 13);  x[0] ^= rotl(x[3] &+ x[2], 18)
            x[6] ^= rotl(x[5] &+ x[4], 7);   x[7] ^= rotl(x[6] &+ x[5], 9)
            x[4] ^= rotl(x[7] &+ x[6], 13);  x[5] ^= rotl(x[4] &+ x[7], 18)
            x[11] ^= rotl(x[10] &+ x[9], 7); x[8] ^= rotl(x[11] &+ x[10], 9)
            x[9] ^= rotl(x[8] &+ x[11], 13); x[10] ^= rotl(x[9] &+ x[8], 18)
            x[12] ^= rotl(x[15] &+ x[14], 7); x[13] ^= rotl(x[12] &+ x[15], 9)
            x[14] ^= rotl(x[13] &+ x[12], 13); x[15] ^= rotl(x[14] &+ x[13], 18)
        }
    }

    private static func initialState(key: [UInt8], input: [UInt8]) -> [UInt32] {
        [
            sigma[0], load32(key, 0), load32(key, 4), load32(key, 8),
            load32(key, 12), sigma[1], load32(input, 0), load32(input, 4),
            load32(input, 8), load32(input, 12), sigma[2], load32(key, 16),
            load32(key, 20), load32(key, 24), load32(key, 28), sigma[3],
        ]
    }

    static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        var x = initialState(key: key, input: input)
        doubleRounds(&x)
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for index in [0, 5, 10, 15, 6, 7, 8, 9] {
            let word = x[index]
            out += [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)]
        }
        return out
    }

    static func salsa20Stream(key: [UInt8], nonce: [UInt8], count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count + 64)
        var counter: UInt64 = 0
        while out.count < count {
            var input = nonce
            for shift in stride(from: 0, to: 64, by: 8) {
                input.append(UInt8(truncatingIfNeeded: counter >> UInt64(shift)))
            }
            let start = initialState(key: key, input: input)
            var x = start
            doubleRounds(&x)
            for index in 0..<16 {
                let word = x[index] &+ start[index]
                out += [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)]
            }
            counter += 1
        }
        return Array(out[0..<count])
    }

    // MARK: - Poly1305 (26-bit limbs, after poly1305-donna)

    static func poly1305(message: [UInt8], key: [UInt8]) -> [UInt8] {
        let r0 = load32(key, 0) & 0x3ff_ffff
        let r1 = (load32(key, 3) >> 2) & 0x3ff_ff03
        let r2 = (load32(key, 6) >> 4) & 0x3ff_c0ff
        let r3 = (load32(key, 9) >> 6) & 0x3f0_3fff
        let r4 = (load32(key, 12) >> 8) & 0x00f_ffff
        let s1 = UInt64(r1 * 5), s2 = UInt64(r2 * 5), s3 = UInt64(r3 * 5), s4 = UInt64(r4 * 5)
        let r = [UInt64(r0), UInt64(r1), UInt64(r2), UInt64(r3), UInt64(r4)]

        var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0
        var offset = 0
        while offset < message.count {
            var block = [UInt8](repeating: 0, count: 17)
            let length = min(16, message.count - offset)
            for index in 0..<length { block[index] = message[offset + index] }
            let hibit: UInt32
            if length == 16 {
                hibit = 1 << 24
            } else {
                block[length] = 1
                hibit = 0
            }
            h0 &+= load32(block, 0) & 0x3ff_ffff
            h1 &+= (load32(block, 3) >> 2) & 0x3ff_ffff
            h2 &+= (load32(block, 6) >> 4) & 0x3ff_ffff
            h3 &+= (load32(block, 9) >> 6) & 0x3ff_ffff
            h4 &+= (load32(block, 12) >> 8) | hibit

            let d0 = UInt64(h0) * r[0] + UInt64(h1) * s4 + UInt64(h2) * s3 + UInt64(h3) * s2 + UInt64(h4) * s1
            var d1 = UInt64(h0) * r[1] + UInt64(h1) * r[0] + UInt64(h2) * s4 + UInt64(h3) * s3 + UInt64(h4) * s2
            var d2 = UInt64(h0) * r[2] + UInt64(h1) * r[1] + UInt64(h2) * r[0] + UInt64(h3) * s4 + UInt64(h4) * s3
            var d3 = UInt64(h0) * r[3] + UInt64(h1) * r[2] + UInt64(h2) * r[1] + UInt64(h3) * r[0] + UInt64(h4) * s4
            var d4 = UInt64(h0) * r[4] + UInt64(h1) * r[3] + UInt64(h2) * r[2] + UInt64(h3) * r[1] + UInt64(h4) * r[0]

            var carry = d0 >> 26; h0 = UInt32(d0 & 0x3ff_ffff)
            d1 += carry; carry = d1 >> 26; h1 = UInt32(d1 & 0x3ff_ffff)
            d2 += carry; carry = d2 >> 26; h2 = UInt32(d2 & 0x3ff_ffff)
            d3 += carry; carry = d3 >> 26; h3 = UInt32(d3 & 0x3ff_ffff)
            d4 += carry; carry = d4 >> 26; h4 = UInt32(d4 & 0x3ff_ffff)
            h0 &+= UInt32(carry) &* 5
            let c = h0 >> 26; h0 &= 0x3ff_ffff
            h1 &+= c

            offset += 16
        }

        // Full carry and reduction mod 2^130 - 5.
        var c = h1 >> 26; h1 &= 0x3ff_ffff
        h2 &+= c; c = h2 >> 26; h2 &= 0x3ff_ffff
        h3 &+= c; c = h3 >> 26; h3 &= 0x3ff_ffff
        h4 &+= c; c = h4 >> 26; h4 &= 0x3ff_ffff
        h0 &+= c &* 5; c = h0 >> 26; h0 &= 0x3ff_ffff
        h1 &+= c

        var g0 = h0 &+ 5; c = g0 >> 26; g0 &= 0x3ff_ffff
        var g1 = h1 &+ c; c = g1 >> 26; g1 &= 0x3ff_ffff
        var g2 = h2 &+ c; c = g2 >> 26; g2 &= 0x3ff_ffff
        var g3 = h3 &+ c; c = g3 >> 26; g3 &= 0x3ff_ffff
        let g4 = h4 &+ c &- (1 << 26)

        let mask = (g4 >> 31) &- 1 // all ones when h >= p
        g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask
        let g4m = g4 & mask
        let inverse = ~mask
        h0 = (h0 & inverse) | g0
        h1 = (h1 & inverse) | g1
        h2 = (h2 & inverse) | g2
        h3 = (h3 & inverse) | g3
        h4 = (h4 & inverse) | g4m

        let w0 = h0 | (h1 << 26)
        let w1 = (h1 >> 6) | (h2 << 20)
        let w2 = (h2 >> 12) | (h3 << 14)
        let w3 = (h3 >> 18) | (h4 << 8)

        var f = UInt64(w0) + UInt64(load32(key, 16)); let o0 = UInt32(truncatingIfNeeded: f)
        f = UInt64(w1) + UInt64(load32(key, 20)) + (f >> 32); let o1 = UInt32(truncatingIfNeeded: f)
        f = UInt64(w2) + UInt64(load32(key, 24)) + (f >> 32); let o2 = UInt32(truncatingIfNeeded: f)
        f = UInt64(w3) + UInt64(load32(key, 28)) + (f >> 32); let o3 = UInt32(truncatingIfNeeded: f)

        var tag: [UInt8] = []
        for word in [o0, o1, o2, o3] {
            tag += [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)]
        }
        return tag
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

#if canImport(CryptoKit)
extension NaClBox {
    /// Opens Bee's pairing payload: version byte (1) ‖ nonce (24) ‖ sender's
    /// ephemeral X25519 public key (32) ‖ box.
    static func openPairingToken(_ payloadBase64: String, privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> String {
        guard let packed = Data(base64Encoded: payloadBase64).map({ [UInt8]($0) }),
              packed.count >= 1 + 24 + 32 + 16,
              packed[0] == 1 else { throw Failure.malformed }
        let nonce = Array(packed[1..<25])
        let senderKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(packed[25..<57]))
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: senderKey)
        let sharedBytes = shared.withUnsafeBytes { [UInt8]($0) }
        let plain = try open(ciphertext: Array(packed[57...]), nonce: nonce, sharedSecret: sharedBytes)
        guard let token = String(bytes: plain, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { throw Failure.malformed }
        return token
    }
}
#endif
